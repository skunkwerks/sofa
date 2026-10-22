defmodule SofaChangesWorkerTest do
  @moduledoc "The request `Sofa.Changes.Worker` builds, inspected without sending it."

  use ExUnit.Case, async: true

  alias Sofa.Changes.{Query, Worker}

  @seq "5-g1AAAAF9eJzLYWBg4MhgTmHgz8tPSTV0MDQy1zMAQsMcoARTIkOS"

  @db Sofa.init("http://admin:passwd@localhost:5984/")
      |> Sofa.client()
      |> Map.put(:database, "recipes")

  test "request/2 targets the database's _changes with the query's parameters" do
    query = Query.new(since: @seq, include_docs: true)
    request = Worker.request(@db, query)

    assert request.method == :get
    assert request.options[:base_url] == "http://localhost:5984/"
    assert request.url.path == "/recipes/_changes"
    assert request.options[:params] == Query.params(query)
    refute Map.has_key?(request.options, :json)
    assert request.options[:auth] == {:basic, "admin:passwd"}
  end

  test "request/2 POSTs the body of a doc_ids or selector query" do
    request = Worker.request(@db, Query.new(doc_ids: ["a", "b"]))
    assert request.method == :post
    assert request.options[:json] == %{"doc_ids" => ["a", "b"]}
    assert {"filter", "_doc_ids"} in request.options[:params]
  end

  test "request/2 URL-encodes the database name" do
    db = %Sofa{@db | database: "my/db"}
    assert Worker.request(db, Query.new([])).url.path == "/my%2Fdb/_changes"
  end

  test "request/2 outlives the server's heartbeat or timeout" do
    # with a heartbeat, two missed beats. Without one, the server's timeout
    assert Worker.request(@db, Query.new(heartbeat: 1000)).options[:receive_timeout] == 7000

    assert Worker.request(@db, Query.new(heartbeat: nil, timeout: 500)).options[:receive_timeout] ==
             5500

    # and a fallback when the caller disabled both
    assert Worker.request(@db, Query.new(heartbeat: nil, timeout: nil)).options[:receive_timeout] ==
             15_000
  end
end
