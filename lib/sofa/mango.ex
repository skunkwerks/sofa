defmodule Sofa.Mango do
  @moduledoc """
  Mango, the CouchDB declarative query API: `_find`, `_explain` and the
  `_index` endpoints.

  > If the only tool you have is CouchDB, then
  > everything looks like `{:ok, :relax}`

  See https://docs.couchdb.org/en/stable/api/database/find.html. A query
  is a selector, a JSON object such as `%{"year" => %{"$gt" => 2010}}`,
  plus the documented options sent alongside it in the request body:
  `limit` (default 25), `skip`, `sort`, `fields`, `use_index`,
  `allow_fallback`, `conflicts`, `r`, `bookmark`, `update`, `stable`,
  `stale` and `execution_stats`.

  Matching documents come back as `%Sofa.Doc{}` structs, except when
  `fields` leaves out `_id`, in which case they stay plain maps.

  ## Examples

      {:ok, result} = Sofa.Mango.find(db, %{"year" => %{"$gt" => 2010}}, sort: [%{"year" => "asc"}], limit: 2)
      Enum.map(result.docs, & &1.body["title"])
      #=> ["The Tragedy of Man", "Drive"]

      Sofa.Mango.index(db, ["year"], name: "by_year")
      Sofa.Mango.stream(db, %{"year" => %{"$gt" => 2010}}) |> Enum.count()
  """

  alias Sofa.{Cushion, Doc, Response}

  @type selector :: %{optional(String.t()) => term()}
  @type error :: Response.error() | term()

  @type t :: %__MODULE__{
          docs: [Doc.t() | map()],
          bookmark: String.t() | nil,
          warning: String.t() | nil,
          execution_stats: map() | nil
        }

  defstruct docs: [], bookmark: nil, warning: nil, execution_stats: nil

  @doc """
  Finds the documents matching a selector, see the module documentation
  for the options.
  """
  @spec find(Sofa.t(), selector(), keyword()) :: {:ok, t()} | {:error, error()}
  def find(sofa = %Sofa{database: db}, selector, opts \\ [])
      when is_binary(db) and is_map(selector) do
    case Sofa.raw(sofa, Cushion.path([db, "_find"]), :post, [], body(selector, opts)) do
      {:ok, _sofa, %Response{status: 200, body: body}} -> {:ok, from_map(body)}
      other -> error(other)
    end
  end

  @doc "Bang! version of `find/3`. Returns the result or raises `Sofa.Error`."
  @spec find!(Sofa.t(), selector(), keyword()) :: t()
  def find!(sofa = %Sofa{}, selector, opts \\ []) do
    case find(sofa, selector, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise Sofa.Error, "unable to find documents: #{inspect(reason)}"
    end
  end

  @doc """
  Streams every document matching a selector, fetching `limit` at a time
  (default 100) and following the `bookmark` CouchDB returns for the next
  page. Raises `Sofa.Error` mid-stream on failure.

      Sofa.Mango.stream(db, %{"type" => "order"}, fields: ["_id", "total"]) |> Enum.take(1000)
  """
  @spec stream(Sofa.t(), selector(), keyword()) :: Enumerable.t()
  def stream(sofa = %Sofa{}, selector, opts \\ []) when is_map(selector) do
    {page, opts} = Keyword.pop(opts, :limit, 100)
    opts = Keyword.drop(opts, [:skip, :bookmark])

    Stream.resource(
      fn -> {:page, nil} end,
      fn
        :done ->
          {:halt, :done}

        {:page, bookmark} ->
          case find(sofa, selector, Keyword.merge(opts, limit: page, bookmark: bookmark)) do
            {:ok, %__MODULE__{docs: docs}} when length(docs) < page -> {docs, :done}
            {:ok, %__MODULE__{docs: docs, bookmark: next}} -> {docs, {:page, next}}
            {:error, reason} -> raise Sofa.Error, "unable to stream documents: #{inspect(reason)}"
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Explains how a query would run, without running it: which index would
  be used, and why, as the documented `_explain` response.
  """
  @spec explain(Sofa.t(), selector(), keyword()) :: {:ok, map()} | {:error, error()}
  def explain(sofa = %Sofa{database: db}, selector, opts \\ [])
      when is_binary(db) and is_map(selector) do
    case Sofa.raw(sofa, Cushion.path([db, "_explain"]), :post, [], body(selector, opts)) do
      {:ok, _sofa, %Response{status: 200, body: body}} -> {:ok, body}
      other -> error(other)
    end
  end

  @doc """
  Creates a JSON index on the given fields, each a field name or a
  `%{"field" => "asc" | "desc"}` map, and returns its design document id
  and name. CouchDB answers `:exists` for an identical index.

  Options: `name:` and `ddoc:` to choose the names, otherwise CouchDB
  generates them. `partial_filter_selector:` to index a subset. `type:`,
  which defaults to `"json"`. `partitioned:`.

      Sofa.Mango.index(db, ["year", "title"], name: "by_year_title", ddoc: "movies")
      #=> {:ok, %{result: :created, ddoc: "_design/movies", name: "by_year_title"}}
  """
  @spec index(Sofa.t(), [String.t() | map()], keyword()) ::
          {:ok, %{result: :created | :exists, ddoc: String.t(), name: String.t()}}
          | {:error, error()}
  def index(sofa = %Sofa{database: db}, fields, opts \\ [])
      when is_binary(db) and is_list(fields) do
    body =
      Map.merge(Map.new(opts, fn {k, v} -> {to_string(k), v} end), %{
        "index" => %{"fields" => fields}
      })

    case Sofa.raw(sofa, Cushion.path([db, "_index"]), :post, [], body) do
      {:ok, _sofa,
       %Response{status: 200, body: %{"result" => result, "id" => id, "name" => name}}} ->
        {:ok, %{result: String.to_existing_atom(result), ddoc: id, name: name}}

      other ->
        error(other)
    end
  end

  @doc """
  Lists the indexes of the database, as CouchDB describes them: maps
  with `"ddoc"`, `"name"`, `"type"` and `"def"`. The built-in primary
  index on `_id` is always among them.
  """
  @spec indexes(Sofa.t()) :: {:ok, [map()]} | {:error, error()}
  def indexes(sofa = %Sofa{database: db}) when is_binary(db) do
    case Sofa.raw(sofa, Cushion.path([db, "_index"]), :get) do
      {:ok, _sofa, %Response{status: 200, body: %{"indexes" => indexes}}} -> {:ok, indexes}
      other -> error(other)
    end
  end

  @doc "Deletes a JSON index by its design document (with or without the `_design/` prefix) and name."
  @spec delete_index(Sofa.t(), String.t(), String.t()) :: :ok | {:error, error()}
  def delete_index(sofa = %Sofa{database: db}, ddoc, name)
      when is_binary(db) and is_binary(ddoc) and is_binary(name) do
    ddoc = String.replace_prefix(ddoc, "_design/", "")

    case Sofa.raw(sofa, Cushion.path([db, "_index", "_design/" <> ddoc, "json", name]), :delete) do
      {:ok, _sofa, %Response{status: 200}} -> :ok
      other -> error(other)
    end
  end

  @doc "A result from its JSON body. Documents with an `_id` become `%Sofa.Doc{}` structs."
  @spec from_map(map()) :: t()
  def from_map(body = %{"docs" => docs}) when is_list(docs) do
    %__MODULE__{
      docs:
        Enum.map(docs, fn doc -> if Map.has_key?(doc, "_id"), do: Doc.from_map(doc), else: doc end),
      bookmark: body["bookmark"],
      warning: body["warning"],
      execution_stats: body["execution_stats"]
    }
  end

  @spec body(selector(), keyword()) :: map()
  defp body(selector, opts) do
    opts
    |> Enum.reject(fn {_key, value} -> value == nil end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("selector", selector)
  end

  @spec error({:ok, Sofa.t(), Response.t()} | {:error, term()}) :: {:error, error()}
  defp error({:ok, _sofa, response = %Response{}}), do: {:error, Response.error(response)}
  defp error({:error, response = %Response{}}), do: {:error, Response.error(response)}
  defp error({:error, reason}), do: {:error, reason}
end
