defmodule Sofa.Doc do
  @moduledoc """
  Documentation for `Sofa.Doc`, a test-driven idiomatic Apache CouchDB client.

  > If the only tool you have is CouchDB, then
  > everything looks like {:ok, :relax}

  ## Examples

  iex> Sofa.Doc.new()

  """

  defstruct attachments: %{},
            body: %{},
            id: "",
            rev: nil,
            # type is used to allow Sofa to fake reading and writing Elixir
            # Structs directly to/from CouchDB, by duck-typing an additional
            # `type` key, which contains the usual `__MODULE__` struct name.
            type: nil

  @type t :: %__MODULE__{
          attachments: map(),
          body: map(),
          id: binary(),
          rev: nil | binary(),
          type: atom() | nil
        }

  alias Sofa.Doc

  @doc """
  Creates a new (empty) document
  """

  @spec new(String.t() | %{}) :: t()
  def new(id) when is_binary(id) do
    %Sofa.Doc{id: id, body: %{}}
  end

  def new(%{id: id}) when is_binary(id) do
    %Sofa.Doc{id: id, body: %{}}
  end

  def new(%{id: id, body: body}) when is_binary(id) and is_map(body) do
    %Sofa.Doc{id: id, body: body}
  end

  @doc """
  Check if doc exists via `HEAD /:db/:doc` and returns either:

  - {:error, not_found} # doc doesn't exist
  - {:ok, %Sofa.Doc{}} # doc exists and has metadata
  """
  @spec exists(Sofa.t(), String.t()) :: {:error, any()} | {:ok, %{}}
  def exists(sofa = %Sofa{database: db}, doc) when is_binary(doc) do
    case Sofa.raw(sofa, db <> "/" <> doc, :head) do
      {:error, reason} ->
        {:error, reason}

      {:ok, _sofa,
       %Sofa.Response{
         status: 200,
         headers: %{etag: etag}
       }} ->
        {:ok, %Sofa.Doc{id: doc, rev: etag}}

      {:ok, _sofa,
       %Sofa.Response{
         status: 404
       }} ->
        {:error, :not_found}
    end
  end

  @doc """
  Check if doc exists via `HEAD /:db/:doc` and returns either true or false
  """
  @spec exists?(Sofa.t(), String.t()) :: false | true
  def exists?(sofa = %Sofa{database: db}, doc) when is_binary(doc) do
    case Sofa.raw(sofa, db <> "/" <> doc, :head) do
      {:ok, _sofa,
       %Sofa.Response{
         status: 200,
         headers: %{etag: _etag}
       }} ->
        true

      _ ->
        false
    end
  end

  @doc """
  GET doc and returns standard HTTP status, or the requested doc

  - {:error, :not_found}  # doc doesn't exist, or similar HTTP status
  - %Sofa.Doc{}           # doc exists and has metadata
  """
  @spec get(Sofa.t(), String.t()) :: {:error, any()} | t()
  def get(sofa = %Sofa{database: db}, doc) when is_binary(doc) do
    case Sofa.raw(sofa, db <> "/" <> doc, :get) do
      {:ok, _sofa,
       %Sofa.Response{
         status: 404
       }} ->
        {:error, :not_found}

      {:ok, _sofa,
       %Sofa.Response{
         status: 200,
         body: body
       }} ->
        from_map(body)

      {:error,
       %Sofa.Response{
         status: 401
       }} ->
        {:error, :unauthorized}

      {:error,
       %Sofa.Response{
         status: 403
       }} ->
        {:error, :forbidden}

      {:error,
       %Sofa.Response{
         status: 404
       }} ->
        {:error, :not_found}
    end
  end

  @doc """
  Optimistically write/update doc assuming rev matches
  """
  @spec put(Sofa.t(), t()) :: {:ok, t()} | {:error, any()}
  def put(sofa = %Sofa{database: db}, doc = %Sofa.Doc{id: id, rev: _rev}) do
    case Sofa.raw(sofa, db <> "/" <> id, :put, [], to_map(doc)) do
      {:ok, _sofa,
       %Sofa.Response{
         status: 201,
         body: %{"rev" => rev}
       }} ->
        {:ok, %Doc{doc | rev: rev}}

      {:ok, _sofa,
       %Sofa.Response{
         status: 202,
         body: %{"rev" => rev}
       }} ->
        {:ok, %Doc{doc | rev: rev}}

      {:error,
       %Sofa.Response{
         status: 400
       }} ->
        {:error, :bad_request}

      {:error,
       %Sofa.Response{
         status: 401
       }} ->
        {:error, :unauthorized}

      {:error,
       %Sofa.Response{
         status: 403
       }} ->
        {:error, :forbidden}

      {:error,
       %Sofa.Response{
         status: 409
       }} ->
        {:error, :conflict}
    end
  end

  @doc """
  Converts internal %Sofa.Doc{} format to CouchDB-native JSON-friendly map

  ## Examples

      iex> %Sofa.Doc{id: "smol", rev: "1-cute", body: %{"yes" => true}} |> to_map()
      %{ "_id" => "smol", "_rev" => "1-cute", "yes" => true}
  """
  @spec to_map(t()) :: map()
  def to_map(
        doc = %Sofa.Doc{
          body: body,
          id: id,
          rev: rev,
          type: type,
          attachments: atts
        }
      )
      when is_struct(doc, Sofa.Doc) do
    # rebuild the couch-style map
    m =
      %{}
      |> Map.put("_id", id)
      |> Map.put("_rev", rev)
      |> Map.put("_attachments", atts)
      |> Map.put("type", coerce_to_json_string(type))

    # skip all top level keys with value nil
    m = :maps.filter(&drop_nil_values/2, m)
    # merge with precedence taking from Struct side
    Map.merge(body, m)
  end

  @spec drop_nil_values(any, any) :: false | true
  defp drop_nil_values(_, v) do
    case v do
      nil -> false
      _ -> true
    end
  end

  @spec coerce_to_json_string(atom) :: String.t() | nil
  defp coerce_to_json_string(nil), do: nil
  # _users docs (type: :user, id: "org.couchdb.user:...) are special
  defp coerce_to_json_string(:user), do: "user"

  defp coerce_to_json_string(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> module -> module
      _ -> nil
    end
  end

  @doc """
  Converts CouchDB-native JSON-friendly map to internal %Sofa.Doc{} format

  ## Examples

      iex> %{ "_id" => "smol", "_rev" => "1-cute", "yes" => true} |> from_map()
      %Sofa.Doc{
        attachments: nil,
        body: %{"yes" => true},
        id: "smol",
        rev: "1-cute",
        type: nil
      }
  """
  @spec from_map(map()) :: t()
  def from_map(m = %{"_id" => id}) when not is_struct(m) do
    # remove all keys that are defined already in the struct, and any
    # key beginning with "_" as they are restricted within CouchDB
    body =
      Map.drop(m, [
        "__struct__",
        "_attachments",
        "_id",
        "_rev",
        "type",
        :__struct__,
        :_attachments,
        :_id,
        :_rev
        | Map.from_struct(%Sofa.Doc{}) |> Map.keys()
      ])

    # grab the rest we need them
    rev = Map.get(m, "_rev", nil)
    atts = Map.get(m, "_attachments", nil)
    type = Map.get(m, "type", "nil") |> coerce_to_elixir_type()
    %Sofa.Doc{attachments: atts, body: body, id: id, rev: rev, type: type}
  end

  @doc """
  Coerces a CouchDB "type" field to an existing atom. It is assumed that there
  will be a related Elixir Module Type of the same name. Elixir prefixes Module
  names with Elixir. and then elides this in iex, tests, and elsewhere, but
  here we need to make that explicit.

  The "user" type is special-cased as it is already present in CouchDB /_users
  database.

  This function is expected to be paired up with Ecto Schemas to properly manage
  the appropriate fields in your document body.
  """
  @spec coerce_to_elixir_type(String.t()) :: atom
  def coerce_to_elixir_type("user"), do: :user

  def coerce_to_elixir_type(type) do
    # exception generated if no existing type is found
    String.to_existing_atom("Elixir." <> type)
  rescue
    ArgumentError -> nil
  else
    found -> found
  end

  # this would be a Protocol for people to defimpl on their own structs
  # @spec from_struct(map()) :: %Sofa.Doc{}
  # def from_struct(m = %{id: id, __Struct__: type}) do
  # end

  # @doc """
  # create an empty doc
  # """

  #   @spec new() :: {%Sofa.Doc.t()}
  #   def new(), do: new(Sofa.Doc)

  #   @doc """
  #   create doc
  #   """
  #   @spec create(Sofa.t(), String.t()) :: {:error, any()} | {:ok, Sofa.t(), any()}
  #   def create(sofa = %Sofa{}, db) when is_binary(db) do
  #     case Sofa.raw(sofa, db, :put) do
  #       {:error, reason} ->
  #         {:error, reason}

  #       {:ok, _sofa, resp} ->
  #         {:ok, sofa,
  #          %Sofa.Response{
  #            body: resp.body,
  #            url: resp.url,
  #            query: resp.query,
  #            method: resp.method,
  #            headers: resp.headers,
  #            status: resp.status
  #          }}
  #     end
  #   end

  @doc """
  delete doc
  """
  @spec delete(Sofa.t(), t()) :: {:error, any()} | {:ok, Sofa.t(), any()}
  def delete(sofa = %Sofa{database: db}, %Sofa.Doc{id: id, rev: rev})
      when is_binary(db) and is_binary(rev) do
    case Sofa.raw(sofa, db <> "/" <> id, :delete, [], "", [{"If-Match", rev}]) do
      {:error, %Sofa.Response{status: 409}} ->
        {:error, :conflict}

      {:error, %Sofa.Response{status: 404}} ->
        {:error, :not_found}

      {:error, %Sofa.Response{status: 400}} ->
        {:error, :bad_request}

      {:error, %Sofa.Response{status: 401}} ->
        {:error, :unathorized}

      {:ok, _sofa, _resp} ->
        :ok
    end
  end
end
