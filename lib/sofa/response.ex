defmodule Sofa.Response do
  @moduledoc """
  HTTP Response Handler for Sofa, the Elixir-native Apache CouchDB client

  > If the only tool you have is CouchDB, then
  > everything looks like `{:ok, :relax}`

  ## Examples

      iex> Sofa.init() |> Sofa.client() |> Sofa.connect!() |> Sofa.raw("/_up")
      %Sofa.Response{
        body: nil,
        headers: %{
          cache_control: "must-revalidate",
          content_length: 95,
          content_type: "application/json",
          couch_body_time: 0,
          couch_request_id: "aa6cc50741",
          date: "Sun, 25 Apr 2021 20:04:34 GMT",
          server: "CouchDB/3.1.1 (Erlang OTP/22)"
        },
        method: :get,
        query: [],
        status: 200,
        url: "http://localhost:5984/_up"
      }
  """

  @type t :: %__MODULE__{
          body: map() | binary() | nil,
          status: integer() | nil,
          method: atom(),
          query: list() | binary(),
          headers: map(),
          url: binary()
        }

  @typedoc "The usual atoms for the statuses CouchDB documents, or the response itself"
  @type error ::
          :bad_request
          | :unauthorized
          | :forbidden
          | :not_found
          | :conflict
          | :precondition_failed
          | t()

  @doc """
  The reason to return for a failed response: an atom for the statuses the
  CouchDB API documents on most endpoints, otherwise the response itself
  so nothing is lost.

      iex> Sofa.Response.error(%Sofa.Response{status: 404, method: :get, body: nil})
      :not_found
      iex> %Sofa.Response{status: 500, method: :get, body: nil} |> Sofa.Response.error() |> Map.get(:status)
      500
  """
  @spec error(t()) :: error()
  def error(%__MODULE__{status: 400}), do: :bad_request
  def error(%__MODULE__{status: 401}), do: :unauthorized
  def error(%__MODULE__{status: 403}), do: :forbidden
  def error(%__MODULE__{status: 404}), do: :not_found
  def error(%__MODULE__{status: 409}), do: :conflict
  def error(%__MODULE__{status: 412}), do: :precondition_failed
  def error(response = %__MODULE__{}), do: response

  @enforce_keys [:status, :method, :body]
  defstruct body: %{},
            status: nil,
            method: :get,
            query: "",
            headers: %{},
            url: "/"
end
