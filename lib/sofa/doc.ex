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
            rev: "",
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

  @spec new(String.t() | %{}) :: %__MODULE__{}
  def new(id) when is_binary(id) do
    %__MODULE__{id: id, body: %{}}
  end

  def new(%{id: id}) when is_binary(id) do
    %__MODULE__{id: id, body: %{}}
  end

  def new(%{id: id, body: body}) when is_binary(id) and is_map(body) do
    %__MODULE__{id: id, body: body}
  end

  @doc """
  Check if doc exists via `HEAD /:db/:doc and returns either:

  - {:error, _reason} # an unhandled error occurred
  - {:error, not_found} # doc doesn't exist
  - {:ok, %Sofa.Doc{}} # doc exists and has metadata
  """
  @spec exists(%Sofa{}, String.t()) :: {:error, any()} | {:ok, %{}}
  def exists(sofa = %Sofa{database: db}, doc) when is_binary(doc) do
    case Sofa.raw(sofa, db <> "/" <> doc, :head) do
      {:error, reason} ->
        {:error, reason}

      {:ok, _sofa,
       %Sofa.Response{
         status: 200,
         headers: %{etag: etag}
       }} ->
        {:ok, sofa, %__MODULE__{id: doc, rev: etag}}

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
  @spec exists?(%Sofa{}, String.t()) :: false | true
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
  Converts internal %Sofa.Doc{} format to CouchDB-native JSON-friendly map
  """
  @spec to_map(%__MODULE__{}) :: map()
  def to_map(doc = %Sofa.Doc{}) do
    Map.from_struct(doc)
  end

  @doc """
  Converts CouchDB-native JSON-friendly map to internal %Sofa.Doc{} format
  """
  @spec from_map(map()) :: %__MODULE__{}
  def from_map(m = %{id: id}) do
    # remove all keys that are defined already in the struct
    body = Map.drop(m, Map.from_struct(%Sofa.Doc{}) |> Map.keys())
    # grab the rest we need them
    rev = Map.get(m, :rev, nil)
    atts = Map.get(m, :attachments, nil)
    type = Map.get(m, :type, nil)
    %Sofa.Doc{attachments: atts, body: body, id: id, rev: rev, type: type}
  end

  # this would be a Protocol for people to defimpl on their own structs
  # @spec from_struct(map()) :: %__MODULE__{}
  # def from_struct(m = %{id: id, __Struct__: type}) do
  # end

  # @doc """
  # create an empty doc
  # """

  #   @spec new() :: {%Sofa.Doc.t()}
  #   def new(), do: new(__MODULE__)

  #   @doc """
  #   create doc
  #   """
  #   @spec create(%Sofa{}, String.t()) :: {:error, any()} | {:ok, %Sofa{}, any()}
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

  #   @doc """
  #   delete doc
  #   """
  #   @spec delete(%Sofa{}, String.t()) :: {:error, any()} | {:ok, %Sofa{}, any()}
  #   def delete(sofa = %Sofa{}, db) when is_binary(db) do
  #     case Sofa.raw(sofa, db, :delete) do
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
end
