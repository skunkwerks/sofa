defmodule Sofa.View do
  @moduledoc """
  Queries views, `_all_docs` and `_design_docs`, the CouchDB index reads.

  > If the only tool you have is CouchDB, then
  > everything looks like `{:ok, :relax}`

  See https://docs.couchdb.org/en/stable/api/ddoc/views.html and the
  `_all_docs` section of the database API. All three return the same
  shape, a `%Sofa.View{}` with its rows, so one module covers them.

  ## Options

  The documented query parameters, by name. Keys are JSON values and are
  encoded as such: `key: "meatballs"` is sent as `key="meatballs"`, and
  `startkey: ["a", 1]` as a JSON array. Everything else is sent as its
  string form, and `nil` drops the parameter.

  - selection: `key`, `keys`, `startkey`, `endkey`, `startkey_docid`,
    `endkey_docid`, `inclusive_end`, `descending`, `limit`, `skip`
  - reduce: `reduce`, `group`, `group_level`
  - content: `include_docs`, `conflicts`, `attachments`, `att_encoding_info`
  - freshness: `update`, `stable`, `stale`, `update_seq`, `sorted`

  `keys` is sent as a `POST` body, as the docs describe. With
  `include_docs: true` each row's `doc` is a `%Sofa.Doc{}`.

  ## Examples

      {:ok, view} = Sofa.View.query(db, "recipes", "by_ingredient", key: "meatballs")
      view.rows
      #=> [%Sofa.View.Row{id: "SpaghettiWithMeatballs", key: "meatballs", value: 1}]

      Sofa.View.all_docs(db, include_docs: true, limit: 10)
      Sofa.View.stream(db, "recipes", "by_ingredient", limit: 100) |> Enum.count()
  """

  alias Sofa.{Cushion, Doc, Response}

  defmodule Row do
    @moduledoc "One row of a view result. `doc` is set with `include_docs: true`."

    @type t :: %__MODULE__{
            id: String.t() | nil,
            key: term(),
            value: term(),
            doc: Doc.t() | nil,
            error: String.t() | nil
          }

    defstruct [:id, :key, :value, :doc, :error]

    @doc "A row from its JSON object. A `doc` becomes a `%Sofa.Doc{}`, a missing key an error."
    @spec from_map(map()) :: t()
    def from_map(row) when is_map(row) do
      %__MODULE__{
        id: row["id"],
        key: row["key"],
        value: row["value"],
        doc:
          if(is_map(row["doc"]) and Map.has_key?(row["doc"], "_id"), do: Doc.from_map(row["doc"])),
        error: row["error"]
      }
    end
  end

  @type t :: %__MODULE__{
          rows: [Row.t()],
          total_rows: non_neg_integer() | nil,
          offset: non_neg_integer() | nil,
          update_seq: term() | nil
        }

  defstruct rows: [], total_rows: nil, offset: nil, update_seq: nil

  @type error :: Response.error() | term()

  # parameters whose values are JSON, as the docs mark them `json`
  @json_params [:key, :keys, :startkey, :endkey, :start_key, :end_key]

  @doc """
  Queries a view of a design document.
  """
  @spec query(Sofa.t(), String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def query(sofa = %Sofa{database: db}, ddoc, view, opts \\ [])
      when is_binary(db) and is_binary(ddoc) and is_binary(view) do
    fetch(sofa, Cushion.path([db, "_design/" <> ddoc, "_view", view]), opts)
  end

  @doc "Bang! version of `query/4`. Returns the result or raises `Sofa.Error`."
  @spec query!(Sofa.t(), String.t(), String.t(), keyword()) :: t()
  def query!(sofa = %Sofa{}, ddoc, view, opts \\ []) do
    case query(sofa, ddoc, view, opts) do
      {:ok, result} ->
        result

      {:error, reason} ->
        raise Sofa.Error, "unable to query view #{ddoc}/#{view}: #{inspect(reason)}"
    end
  end

  @doc """
  Lists the documents of the database by id, via `_all_docs`. Each row's
  `value` carries the document's `rev`.
  """
  @spec all_docs(Sofa.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def all_docs(sofa = %Sofa{database: db}, opts \\ []) when is_binary(db) do
    fetch(sofa, Cushion.path([db, "_all_docs"]), opts)
  end

  @doc "Lists the design documents of the database, via `_design_docs`."
  @spec design_docs(Sofa.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def design_docs(sofa = %Sofa{database: db}, opts \\ []) when is_binary(db) do
    fetch(sofa, Cushion.path([db, "_design_docs"]), opts)
  end

  @doc """
  Runs several queries against one view in a single request, via the
  `/queries` endpoint, and returns one result per query, in order. Pass
  `:all_docs` or `:design_docs` as the view for those indexes.

      Sofa.View.queries(db, "recipes", "by_ingredient", [[key: "meatballs"], [key: "tomato sauce"]])
  """
  @spec queries(Sofa.t(), String.t() | :all_docs | :design_docs, String.t() | nil, [keyword()]) ::
          {:ok, [t()]} | {:error, error()}
  def queries(sofa, index, view \\ nil, queries)

  def queries(sofa = %Sofa{database: db}, :all_docs, nil, queries) when is_list(queries),
    do: multi(sofa, Cushion.path([db, "_all_docs", "queries"]), queries)

  def queries(sofa = %Sofa{database: db}, :design_docs, nil, queries) when is_list(queries),
    do: multi(sofa, Cushion.path([db, "_design_docs", "queries"]), queries)

  def queries(sofa = %Sofa{database: db}, ddoc, view, queries)
      when is_binary(ddoc) and is_binary(view) and is_list(queries),
      do: multi(sofa, Cushion.path([db, "_design/" <> ddoc, "_view", view, "queries"]), queries)

  @doc """
  Streams the rows of a view, fetching `limit` rows per request (default
  100) and continuing from the last row of each page, so results of any
  size can be consumed lazily. Raises `Sofa.Error` mid-stream on failure.
  Not for reduced results, which have no row to continue from. Pass
  `reduce: false` on a view with a reduce function.

      Sofa.View.stream(db, "recipes", "by_ingredient", include_docs: true)
      |> Stream.map(& &1.doc)
      |> Enum.take(1000)
  """
  @spec stream(Sofa.t(), String.t() | :all_docs | :design_docs, String.t() | nil, keyword()) ::
          Enumerable.t()
  def stream(sofa, index, view \\ nil, opts \\ [])

  def stream(sofa = %Sofa{}, index, view, opts) when is_list(opts) do
    {page, opts} = Keyword.pop(opts, :limit, 100)
    opts = Keyword.drop(opts, [:skip])

    Stream.resource(
      fn -> {:start, opts} end,
      fn
        :done ->
          {:halt, :done}

        {:start, opts} ->
          page(sofa, index, view, Keyword.put(opts, :limit, page + 1), page)

        {:next, opts} ->
          page(sofa, index, view, Keyword.put(opts, :limit, page + 1), page)
      end,
      fn _ -> :ok end
    )
  end

  # one page: ask for one row more than wanted, and if it arrives, continue
  # from it with startkey and startkey_docid, as the CouchDB docs recommend
  defp page(sofa, index, view, opts, page) do
    rows =
      case run(sofa, index, view, opts) do
        {:ok, %__MODULE__{rows: rows}} ->
          rows

        {:error, reason} ->
          raise Sofa.Error, "unable to stream view #{inspect(index)}: #{inspect(reason)}"
      end

    case Enum.split(rows, page) do
      {wanted, [next | _]} ->
        continue =
          [startkey: next.key, startkey_docid: next.id]
          |> Keyword.merge(Keyword.take(opts, [:limit]))

        {wanted,
         {:next,
          Keyword.merge(Keyword.drop(opts, [:startkey, :startkey_docid, :key, :keys]), continue)}}

      {wanted, []} ->
        {wanted, :done}
    end
  end

  defp run(sofa, :all_docs, nil, opts), do: all_docs(sofa, opts)
  defp run(sofa, :design_docs, nil, opts), do: design_docs(sofa, opts)
  defp run(sofa, ddoc, view, opts) when is_binary(ddoc), do: query(sofa, ddoc, view, opts)

  ## requests

  @spec fetch(Sofa.t(), String.t(), keyword()) :: {:ok, t()} | {:error, error()}
  defp fetch(sofa, path, opts) do
    {keys, opts} = Keyword.pop(opts, :keys)
    {method, body} = if keys, do: {:post, %{"keys" => keys}}, else: {:get, ""}

    case Sofa.raw(sofa, path, method, params(opts), body) do
      {:ok, _sofa, %Response{status: 200, body: body}} -> {:ok, from_map(body)}
      other -> error(other)
    end
  end

  @spec multi(Sofa.t(), String.t(), [keyword()]) :: {:ok, [t()]} | {:error, error()}
  defp multi(sofa, path, queries) do
    body = %{"queries" => Enum.map(queries, &Map.new/1)}

    case Sofa.raw(sofa, path, :post, [], body) do
      {:ok, _sofa, %Response{status: 200, body: %{"results" => results}}} ->
        {:ok, Enum.map(results, &from_map/1)}

      other ->
        error(other)
    end
  end

  @doc "A result from its JSON body."
  @spec from_map(map()) :: t()
  def from_map(body = %{"rows" => rows}) when is_list(rows) do
    %__MODULE__{
      rows: Enum.map(rows, &Row.from_map/1),
      total_rows: body["total_rows"],
      offset: body["offset"],
      update_seq: body["update_seq"]
    }
  end

  @doc """
  The query string for view options: JSON for the key parameters, string
  form for the rest, `nil` dropped.

      iex> Sofa.View.params(key: "meatballs", startkey: ["a", 1], limit: 5, include_docs: true, skip: nil)
      [key: ~s("meatballs"), startkey: ~s(["a",1]), limit: "5", include_docs: "true"]
  """
  @spec params(keyword()) :: keyword()
  def params(opts) do
    for {name, value} <- opts, value != nil do
      {name, if(name in @json_params, do: Jason.encode!(value), else: to_string(value))}
    end
  end

  @spec error({:ok, Sofa.t(), Response.t()} | {:error, term()}) :: {:error, error()}
  defp error({:ok, _sofa, response = %Response{}}), do: {:error, Response.error(response)}
  defp error({:error, response = %Response{}}), do: {:error, Response.error(response)}
  defp error({:error, reason}), do: {:error, reason}
end
