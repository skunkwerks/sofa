defmodule Sofa.Design do
  @moduledoc ~S'''
  Design documents: the `_design/` documents that hold views, filters and
  validation functions, built as pipelines and saved like any document.

  > If the only tool you have is CouchDB, then
  > everything looks like `{:ok, :relax}`

  See https://docs.couchdb.org/en/stable/api/ddoc/common.html and the
  design documents guide. A design document is an ordinary `%Sofa.Doc{}`
  whose id starts with `_design/`, so `Sofa.Doc.save/2`, `Sofa.Doc.get/3`
  and `Sofa.Attachment` all apply. This module builds them and reads
  their index information.

  ## Examples

  JavaScript functions are written with the `~JS` sigil, see `sigil_JS/2`:

      import Sofa.Design, only: [sigil_JS: 2]

      by_title = ~JS"""
      function(doc) {
        if (doc.title) emit(doc.title, null);
      }
      """

      by_ingredient = ~JS"""
      function(doc) {
        doc.ingredients.forEach(function(i) { emit(i, 1); });
      }
      """

      validate = ~JS"""
      function(newDoc, oldDoc, userCtx) {
        if (!newDoc.title) throw({forbidden: 'needs a title'});
      }
      """

      Sofa.Design.new("recipes")
      |> Sofa.Design.view("by_title", by_title)
      |> Sofa.Design.view("by_ingredient", by_ingredient, "_sum")
      |> Sofa.Design.filter("important", ~JS"function(doc, req) { return doc.important === true; }")
      |> Sofa.Design.validate(validate)
      |> Sofa.Doc.save(db)

      {:ok, %{"name" => "recipes", "view_index" => %{"language" => "javascript"}}} = Sofa.Design.info(db, "recipes")
      Sofa.View.query(db, "recipes", "by_title")
  '''

  alias Sofa.{Cushion, Doc, Response, View}

  @type error :: Response.error() | term()

  @doc ~S'''
  A JavaScript function as a string, for views, filters, updates and
  validation. Nothing is interpolated or escaped, so the function reads
  exactly as CouchDB will store it.

      import Sofa.Design, only: [sigil_JS: 2]

      ~JS"""
      function(doc) {
        if (doc.title) emit(doc.title, null);
      }
      """

  The single-line form `~JS"function(doc) { emit(doc._id, 1); }"` suits
  short functions. The sigil takes no modifiers.
  '''
  @spec sigil_JS(String.t(), []) :: String.t()
  def sigil_JS(javascript, []) when is_binary(javascript), do: javascript

  @doc """
  A new design document named `_design/{name}`, in JavaScript unless
  `language:` says otherwise. Further options go into the body as given:
  `views:`, `filters:`, `updates:`, `validate_doc_update:`, `options:`,
  `autoupdate:`.
  """
  @spec new(String.t(), keyword()) :: Doc.t()
  def new(name, opts \\ []) when is_binary(name) and is_list(opts) do
    body =
      opts |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put_new("language", "javascript")

    Doc.new(%{id: id(name), body: body})
  end

  @doc "Adds a view with a map function and, optionally, a reduce function such as `\"_sum\"`."
  @spec view(Doc.t(), String.t(), String.t(), String.t() | nil) :: Doc.t()
  def view(doc = %Doc{}, name, map, reduce \\ nil) when is_binary(name) and is_binary(map) do
    view = if reduce, do: %{"map" => map, "reduce" => reduce}, else: %{"map" => map}
    put_in_body(doc, ["views", name], view)
  end

  @doc "Adds a filter function, for `Sofa.Changes` and replication with `filter: \"{name}/{filter}\"`."
  @spec filter(Doc.t(), String.t(), String.t()) :: Doc.t()
  def filter(doc = %Doc{}, name, fun) when is_binary(name) and is_binary(fun),
    do: put_in_body(doc, ["filters", name], fun)

  @doc "Adds an update function, as called via `/{db}/_design/{ddoc}/_update/{name}`."
  @spec update(Doc.t(), String.t(), String.t()) :: Doc.t()
  def update(doc = %Doc{}, name, fun) when is_binary(name) and is_binary(fun),
    do: put_in_body(doc, ["updates", name], fun)

  @doc "Sets the `validate_doc_update` function, which CouchDB runs on every write to the database."
  @spec validate(Doc.t(), String.t()) :: Doc.t()
  def validate(doc = %Doc{body: body}, fun) when is_binary(fun),
    do: %Doc{doc | body: Map.put(body, "validate_doc_update", fun)}

  @doc "Fetches a design document by name, with or without the `_design/` prefix."
  @spec get(Sofa.t(), String.t(), keyword()) :: {:error, error()} | Doc.t()
  def get(sofa = %Sofa{}, name, opts \\ []) when is_binary(name),
    do: Doc.get(sofa, id(name), opts)

  @doc "Bang! version of `get/3`."
  @spec get!(Sofa.t(), String.t(), keyword()) :: Doc.t()
  def get!(sofa = %Sofa{}, name, opts \\ []) when is_binary(name),
    do: Doc.get!(sofa, id(name), opts)

  @doc "Every design document of the database, as `%Sofa.Doc{}` structs."
  @spec all(Sofa.t()) :: {:ok, [Doc.t()]} | {:error, error()}
  def all(sofa = %Sofa{}) do
    case View.design_docs(sofa, include_docs: true) do
      {:ok, %View{rows: rows}} -> {:ok, Enum.map(rows, & &1.doc)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The index information of a design document, via `_info`: its name and
  a `"view_index"` map with the signature, sizes, update sequence and
  whether an update or compaction is running, as documented.
  """
  @spec info(Sofa.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def info(sofa = %Sofa{database: db}, name) when is_binary(db) and is_binary(name) do
    case Sofa.raw(sofa, Cushion.path([db, id(name), "_info"]), :get) do
      {:ok, _sofa, %Response{status: 200, body: info = %{"name" => _}}} -> {:ok, info}
      {:ok, _sofa, response = %Response{}} -> {:error, Response.error(response)}
      {:error, response = %Response{}} -> {:error, Response.error(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec id(String.t()) :: String.t()
  defp id(id = "_design/" <> _), do: id
  defp id(name), do: "_design/" <> name

  @spec put_in_body(Doc.t(), [String.t()], term()) :: Doc.t()
  defp put_in_body(doc = %Doc{body: body}, [section, name], value) do
    %Doc{doc | body: Map.update(body, section, %{name => value}, &Map.put(&1, name, value))}
  end
end
