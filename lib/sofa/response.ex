defmodule Sofa.Response do
  @moduledoc """
  HTTP Response Handler for Sofa, the Elixir-native Apache CouchDB client

  > If the only tool you have is CouchDB, then
  > everything looks like {:ok, :relax}

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

  @enforce_keys [:status, :method, :body]
  defstruct body: %{},
            status: nil,
            method: :get,
            query: "",
            headers: %{},
            url: "/"
end
