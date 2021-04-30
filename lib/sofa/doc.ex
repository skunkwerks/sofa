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
          attachments: %{},
          id: binary,
          rev: nil | binary,
          type: atom
        }

  alias Sofa.Doc

  @doc """
  Creates a new (empty) document
  """

  @spec new(String.t() | %{}) :: %Sofa.Doc{}
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
  Check if doc exists via `HEAD /:db/:doc and returns either:

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
  Check if doc exists via `HEAD /:db/:doc and returns either true or false
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
  Fetch doc and return either

  - {:error, not_found} # doc doesn't exist
  - {:ok, %Sofa.Doc{}} # doc exists and has metadata
  """
  @spec get(Sofa.t(), String.t()) :: {:error, any()} | {:ok, Sofa.Doc.t()}
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
  @spec put(Sofa.t(), Sofa.Doc.t()) :: {:ok, Sofa.Doc.t()} | {:error, any()}
  def put(sofa = %Sofa{database: db}, doc = %Sofa.Doc{id: id, rev: rev}) do
    case Sofa.raw(sofa, db <> "/" <> id, :put, [], to_map(doc)) do
      {:ok, _sofa,
       %Sofa.Response{
         status: 201,
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
  @spec to_map(%Sofa.Doc{}) :: map()
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
      |> Map.put("type", type)

    # skip all top level keys with value nil
    m = :maps.filter(&Sofa.Doc.drop_nil_values/2, m)
    # merge with precedence taking from Struct side
    Map.merge(body, m)
  end

  @spec drop_nil_values(any, any) :: false | true
  def drop_nil_values(_, v) do
    case v do
      nil -> false
      _ -> true
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
  @spec from_map(map()) :: Sofa.Doc.t()
  def from_map(m = %{"_id" => id}) when not is_struct(m) do
    # remove all keys that are defined already in the struct, and any
    # key beginning with "_" as they are restricted within CouchDB
    body =
      Map.drop(m, [
        "_rev",
        "_id",
        "_attachments",
        :_rev,
        :_id,
        :_attachments
        | Map.from_struct(%Sofa.Doc{}) |> Map.keys()
      ])

    # grab the rest we need them
    rev = Map.get(m, "_rev", nil)
    atts = Map.get(m, "_attachments", nil)
    type = Map.get(m, "type", nil)
    %Sofa.Doc{attachments: atts, body: body, id: id, rev: rev, type: type}
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
  @spec delete(Sofa.t(), String.t()) :: {:error, any()} | {:ok, Sofa.t(), any()}
  def delete(sofa = %Sofa{}, doc) when is_binary(doc) do
    case Sofa.raw(sofa, doc, :delete) do
      {:error, reason} ->
        {:error, reason}

      {:ok, _sofa, resp} ->
        {:ok, sofa,
         %Sofa.Response{
           body: resp.body,
           url: resp.url,
           query: resp.query,
           method: resp.method,
           headers: resp.headers,
           status: resp.status
         }}
    end
  end

  @doc """
  delete doc
  """
  @spec delete!(Sofa.t(), String.t()) :: {:error, any()} | {:ok, Sofa.t(), any()}
  def delete!(sofa = %Sofa{database: db}, doc) when is_binary(doc) and is_binary(db) do
    case Sofa.raw(sofa, db <> "/" <> doc, :delete) do
      {:error, %Sofa.Response{status: 409}} ->
        {:error, :conflict}

      {:error, %Sofa.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, _sofa, _resp} ->
        :ok
    end
  end
end
