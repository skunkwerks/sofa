defmodule SofaChangesQueryTest do
  use ExUnit.Case, async: true

  alias Sofa.Changes.Query

  doctest Query

  @seq "5-g1AAAAF9eJzLYWBg4MhgTmHgz8tPSTV0MDQy1zMAQsMcoARTIkOS"
  @start "0"

  test "defaults to a continuous GET with heartbeat and timeout" do
    assert %Query{method: :get, feed: :continuous, body: nil, since: nil} = query = Query.new([])

    assert Query.params(query) == [
             {"feed", "continuous"},
             {"heartbeat", "60000"},
             {"timeout", "7200000"}
           ]
  end

  test "booleans, integers, atoms and strings are encoded as documented" do
    params =
      Query.new(
        include_docs: true,
        attachments: false,
        limit: 5,
        style: :all_docs,
        view: "ingredients/by_recipe",
        filter: "_view"
      )
      |> Query.params()
      |> Map.new()

    assert params == %{
             "feed" => "continuous",
             "heartbeat" => "60000",
             "timeout" => "7200000",
             "include_docs" => "true",
             "attachments" => "false",
             "limit" => "5",
             "style" => "all_docs",
             "view" => "ingredients/by_recipe",
             "filter" => "_view"
           }
  end

  test "string values are sent verbatim, never JSON-quoted" do
    assert {"style", "all_docs"} in Query.params(Query.new(style: "all_docs"))
  end

  test "since is an opaque string or now, sent last" do
    for {since, expected} <- [{@seq, @seq}, {:now, "now"}] do
      assert List.last(Query.params(Query.new(since: since))) == {"since", expected}
    end
  end

  test "omitting since leaves it nil and drops the parameter" do
    query = Query.new([])
    assert query.since == nil
    refute List.keymember?(Query.params(query), "since", 0)
  end

  test "since rejects an integer" do
    assert_raise ArgumentError, ~r/since must be :now/, fn -> Query.new(since: 0) end
    assert_raise ArgumentError, ~r/since must be :now/, fn -> Query.new(since: -1) end
  end

  test "since rejects an arbitrary atom" do
    assert_raise ArgumentError, ~r/since must be :now/, fn -> Query.new(since: :latest) end
  end

  test "since rejects a float" do
    assert_raise ArgumentError, ~r/since must be :now/, fn -> Query.new(since: 1.5) end
  end

  test "since rejects a map or list" do
    assert_raise ArgumentError, ~r/since must be :now/, fn -> Query.new(since: %{"seq" => 1}) end
    assert_raise ArgumentError, ~r/since must be :now/, fn -> Query.new(since: [1]) end
  end

  test "since accepts an opaque update sequence string, including @start" do
    for since <- [@start, @seq] do
      assert Query.new(since: since).since == since
      assert {"since", since} in Query.params(Query.new(since: since))
    end
  end

  test "since/2 advances the sequence for the next request" do
    query = Query.new(since: @start) |> Query.since(@seq)
    assert query.since == @seq
    assert {"since", @seq} in Query.params(query)
  end

  test "nil drops a parameter, so heartbeat: nil leaves timeout in charge" do
    query = Query.new(heartbeat: nil, timeout: 500)
    assert query.heartbeat == nil
    assert query.timeout == 500
    assert Query.params(query) == [{"feed", "continuous"}, {"timeout", "500"}]
  end

  test "longpoll: true selects the longpoll feed without sending longpoll" do
    query = Query.new(longpoll: true)
    assert query.feed == :longpoll
    assert {"feed", "longpoll"} in Query.params(query)
    refute List.keymember?(Query.params(query), "longpoll", 0)
  end

  test "feed: :normal and feed strings are accepted, anything else is not" do
    assert Query.new(feed: :normal).feed == :normal
    assert Query.new(feed: "longpoll").feed == :longpoll
    assert_raise ArgumentError, ~r/feed must be/, fn -> Query.new(feed: :eventsource) end
  end

  test "doc_ids POSTs a JSON body with filter=_doc_ids, overriding filter" do
    query = Query.new(doc_ids: ["SpaghettiWithMeatballs", "LasagneAlForno"], filter: "ignored")
    assert query.method == :post
    assert query.body == %{"doc_ids" => ["SpaghettiWithMeatballs", "LasagneAlForno"]}
    assert {"filter", "_doc_ids"} in Query.params(query)
    refute List.keymember?(Query.params(query), "doc_ids", 0)
  end

  test "selector POSTs a JSON body with filter=_selector" do
    selector = %{"_id" => %{"$regex" => "^_design/"}}
    query = Query.new(selector: selector)
    assert query.method == :post
    assert query.body == %{"selector" => selector}
    assert {"filter", "_selector"} in Query.params(query)
    refute List.keymember?(Query.params(query), "selector", 0)
  end

  test "query_params adds raw parameters for filter functions" do
    params =
      Query.new(filter: "recipes/by_cuisine", query_params: [cuisine: "italian"])
      |> Query.params()

    assert {"filter", "recipes/by_cuisine"} in params
    assert {"cuisine", "italian"} in params
  end

  test "values that cannot be query parameters are rejected" do
    assert_raise ArgumentError, ~r/must be strings, atoms or integers/, fn ->
      Query.new(style: %{nested: true})
    end
  end
end
