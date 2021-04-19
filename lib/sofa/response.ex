defmodule Sofa.Response do
  @moduledoc """
  HTTP Response Handler for Sofa, the Elixir-native Apache CouchDB client

  > If the only tool you have is CouchDB, then
  > everything looks like {:ok, :relax}

  ## Examples

  iex> Sofa.init() |> Sofa.client() |> Sofa.connect!() |> Sofa.raw("/_up")
  %Sofa.Response{
    body: nil,
    headers: [
      {"cache-control", "must-revalidate"},
      {"date", "Mon, 19 Apr 2021 12:11:43 GMT"},
      {"server", "CouchDB/3.1.1 (Erlang OTP/22)"},
      {"content-length", "27"},
      {"content-type", "application/json"},
      {"x-couch-request-id", "e12bb5190d"},
      {"x-couchdb-body-time", "0"}
    ],
    method: :get,
    query: [],
    status: 200,
    url: "http://localhost:5984/_up"
  }
  """

  @enforce_keys [:status, :method, :body]
  defstruct body: %{},
            status: nil,
            method: :get,
            query: "",
            headers: [],
            url: "/"
end
