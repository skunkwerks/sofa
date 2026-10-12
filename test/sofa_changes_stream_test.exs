defmodule SofaChangesStreamTest do
  @moduledoc """
  `Sofa.Changes` against `Sofa.FakeCouch`: the request it sends, how it
  reads a continuous feed, and how it resumes when the server ends one.
  Observed only through the reported requests and `Sofa.TestFollower`.
  """

  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Sofa.{Changes, CouchFixtures, FakeCouch, TestFollower}

  import CouchFixtures, only: [row: 3, seq: 1]

  setup do
    couch = FakeCouch.open()
    %{couch: couch, db: couch.db}
  end

  defp follow(db, opts \\ []) do
    {:ok, pid} = Changes.start_link(TestFollower, %{db: db, opts: opts, pid: self()})
    pid
  end

  # Starts an unlinked, monitored follower so a `{:stop, _}` exit does not
  # take the test process down with it. Stopped again at test exit.
  defp start_monitored(args) do
    {:ok, pid} = Changes.start(TestFollower, args)
    ref = Process.monitor(pid)
    on_exit(fn -> if Process.alive?(pid), do: Changes.stop(pid) end)
    {pid, ref}
  end

  # A handler that reports the request and holds a continuous feed open.
  defp streaming(couch, pid, lines \\ [], opts \\ []) do
    FakeCouch.expect_changes(couch, fn conn ->
      conn
      |> FakeCouch.report(pid)
      |> FakeCouch.stream(couch, pid, lines, opts)
    end)
  end

  describe "request" do
    test "targets GET /{db}/_changes with Accept: application/json" do
      couch = FakeCouch.open(db: "my-db")
      streaming(couch, self())
      follow(couch.db)

      assert_receive {:changes_request,
                      %{method: "GET", headers: %{"accept" => "application/json"}}},
                     1000

      assert FakeCouch.changes_path(couch) == "/my-db/_changes"
    end

    test "defaults to feed=continuous with heartbeat=60000 and timeout=7200000", %{
      couch: couch,
      db: db
    } do
      streaming(couch, self())
      follow(db)

      assert_receive {:changes_request, %{query: query}}, 1000
      assert query == %{"feed" => "continuous", "heartbeat" => "60000", "timeout" => "7200000"}
    end

    test "options are forwarded as query parameters", %{couch: couch, db: db} do
      streaming(couch, self())

      follow(db,
        since: seq(5),
        include_docs: true,
        conflicts: true,
        descending: false,
        limit: 10,
        filter: "app/by_type",
        style: "all_docs",
        seq_interval: 100,
        heartbeat: 1000,
        timeout: 5000
      )

      assert_receive {:changes_request, %{query: query}}, 1000

      assert query == %{
               "feed" => "continuous",
               "since" => seq(5),
               "include_docs" => "true",
               "conflicts" => "true",
               "descending" => "false",
               "limit" => "10",
               "filter" => "app/by_type",
               "style" => "all_docs",
               "seq_interval" => "100",
               "heartbeat" => "1000",
               "timeout" => "5000"
             }
    end

    test "filter function arguments go through query_params", %{couch: couch, db: db} do
      streaming(couch, self())
      follow(db, filter: "recipes/by_cuisine", query_params: [cuisine: "italian"])

      assert_receive {:changes_request, %{query: query}}, 1000
      assert query["filter"] == "recipes/by_cuisine"
      assert query["cuisine"] == "italian"
    end

    test "doc_ids are POSTed as a JSON body with filter=_doc_ids", %{couch: couch, db: db} do
      pid = self()

      FakeCouch.expect_changes(couch, "POST", fn conn ->
        conn |> FakeCouch.report(pid) |> FakeCouch.stream(couch, pid)
      end)

      follow(db, doc_ids: ["SpaghettiWithMeatballs", "LasagneAlForno"], filter: "ignored/anyway")

      assert_receive {:changes_request,
                      %{method: "POST", query: query, body: body, headers: headers}},
                     1000

      assert query["filter"] == "_doc_ids"
      refute Map.has_key?(query, "doc_ids")
      assert headers["content-type"] == "application/json"
      assert Jason.decode!(body) == %{"doc_ids" => ["SpaghettiWithMeatballs", "LasagneAlForno"]}
    end

    test "a selector is POSTed as a JSON body with filter=_selector", %{couch: couch, db: db} do
      pid = self()

      FakeCouch.expect_changes(couch, "POST", fn conn ->
        conn |> FakeCouch.report(pid) |> FakeCouch.stream(couch, pid)
      end)

      follow(db, selector: %{"_id" => %{"$regex" => "^_design/"}})

      assert_receive {:changes_request, %{method: "POST", query: query, body: body}}, 1000
      assert query["filter"] == "_selector"
      assert Jason.decode!(body) == %{"selector" => %{"_id" => %{"$regex" => "^_design/"}}}
    end

    test "the GenServer timeout from init/1 fires while the server is quiet", %{
      couch: couch,
      db: db
    } do
      pid = self()

      FakeCouch.expect_changes(couch, fn conn ->
        Process.sleep(200)
        conn |> FakeCouch.report(pid) |> FakeCouch.stream(couch, pid)
      end)

      {:ok, _} = Changes.start_link(TestFollower, %{db: db, opts: [], pid: self(), timeout: 10})

      assert_receive {:info, :timeout}, 1000
      assert_receive {:changes_request, _}, 1000
    end
  end

  describe "handle_change/2" do
    test "is called once per row, in order, threading state", %{couch: couch, db: db} do
      streaming(couch, self(), [row("a", 1, "1-a"), row("b", 2, "1-b"), row("c", 3, "1-c")])
      pid = follow(db)

      assert_receive {:change, %{"id" => "a"}, 1}, 1000
      assert_receive {:change, %{"id" => "b"}, 2}, 1000
      assert_receive {:change, %{"id" => "c"}, 3}, 1000
      assert %{seen: 3} = Changes.call(pid, :state)
    end

    test "rows arriving later on the open feed are delivered", %{couch: couch, db: db} do
      streaming(couch, self())
      follow(db)

      assert_receive {:feed, feed}, 1000
      refute_receive {:change, _, _}, 100

      FakeCouch.push(feed, row("late", 7, "1-late"))
      assert_receive {:change, %{"id" => "late", "seq" => seq}, 1}, 1000
      assert seq == seq(7)
    end

    test "a JSON object split across chunks is buffered until complete", %{couch: couch, db: db} do
      {first, second} = row("split", 9, "1-split") |> Jason.encode!() |> String.split_at(20)

      # CouchDB only sends heartbeats between rows, never inside one, so the
      # fake must not either while the second half is pending
      streaming(couch, self(), [first], heartbeat: :infinity)
      follow(db)

      assert_receive {:feed, feed}, 1000
      refute_receive {:change, _, _}, 100

      FakeCouch.push(feed, second <> "\n")
      assert_receive {:change, %{"id" => "split"}, 1}, 1000
    end

    test "several lines in one chunk are all delivered", %{couch: couch, db: db} do
      chunk =
        Enum.map_join([row("x", 1, "1-x"), row("y", 2, "1-y")], &(Jason.encode!(&1) <> "\n"))

      streaming(couch, self(), [chunk])
      follow(db)

      assert_receive {:change, %{"id" => "x"}, 1}, 1000
      assert_receive {:change, %{"id" => "y"}, 2}, 1000
    end

    test "CRLF line endings and heartbeats are handled", %{couch: couch, db: db} do
      lines = Enum.map(CouchFixtures.continuous_rows(), &(Jason.encode!(&1) <> "\r\n"))
      streaming(couch, self(), [:heartbeat | lines], heartbeat: 20)
      follow(db)

      assert_receive {:change, %{"id" => "fresh"}, 1}, 1000
      assert_receive {:change, %{"id" => "updated"}, 2}, 1000
      assert_receive {:change, %{"id" => "deleted", "deleted" => true}, 3}, 1000
      refute_receive {:change, _, _}, 200
    end

    test "rows are passed through untouched", %{couch: couch, db: db} do
      fixture = CouchFixtures.include_docs_row()
      streaming(couch, self(), [fixture])
      follow(db)

      assert_receive {:change, ^fixture, 1}, 1000
    end

    test "error objects in the stream are skipped", %{couch: couch, db: db} do
      streaming(couch, self(), [CouchFixtures.missing_selector_error(), row("after", 2, "1-a")])
      follow(db)

      assert_receive {:change, %{"id" => "after"}, 1}, 1000
      refute_receive {:change, %{"error" => _}, _}, 100
    end

    test "{:stop, reason, state} stops the follower and calls terminate/2", %{
      couch: couch,
      db: db
    } do
      streaming(couch, self(), [row("fine", 1, "1-f"), row("boom", 2, "1-b")])
      {pid, ref} = start_monitored(%{db: db, pid: self(), stop_on: "boom"})

      assert_receive {:change, %{"id" => "boom"}, 2}, 1000
      assert_receive {:terminate, :stopped_by_change}, 1000
      assert_receive {:DOWN, ^ref, :process, ^pid, :stopped_by_change}, 1000
    end
  end

  describe "sequence tracking" do
    test "when the server ends the response the stream restarts from the last seq", %{
      couch: couch,
      db: db
    } do
      streaming(couch, self(), [row("a", 1, "1-a"), row("b", 7, "1-b")])
      follow(db)

      assert_receive {:changes_request, %{query: query}}, 1000
      refute Map.has_key?(query, "since")
      assert_receive {:change, %{"id" => "b"}, 2}, 1000
      assert_receive {:feed, feed}, 1000

      FakeCouch.close(feed)
      assert_receive {:changes_request, %{query: %{"since" => since}}}, 2000
      assert since == seq(7)
    end

    test "a trailing last_seq object (feed ended by limit) advances since", %{
      couch: couch,
      db: db
    } do
      streaming(couch, self(), [row("a", 3, "1-a"), CouchFixtures.last_seq_line(9)], hold: false)
      follow(db, limit: 1)

      assert_receive {:change, %{"id" => "a"}, 1}, 1000
      refute_receive {:change, %{"last_seq" => _}, _}, 100
      assert_receive {:changes_request, %{query: %{"since" => since, "limit" => "1"}}}, 2000
      assert since == seq(9)
    end
  end

  describe "normal and longpoll responses" do
    # answers the first request with `first`, later ones with an empty batch
    defp batches(couch, pid, first) do
      FakeCouch.expect_changes(couch, fn conn ->
        conn = FakeCouch.report(conn, pid)

        case conn.query_params["since"] do
          nil -> FakeCouch.json(conn, 200, first)
          since -> FakeCouch.respond(conn, [], since)
        end
      end)
    end

    test "longpoll results are delivered as a batch, then polling resumes from last_seq", %{
      couch: couch,
      db: db
    } do
      batches(couch, self(), CouchFixtures.normal_feed())
      follow(db, longpoll: true)

      assert_receive {:changes_request, %{query: %{"feed" => "longpoll"} = query}}, 1000
      refute Map.has_key?(query, "longpoll")
      assert_receive {:change, %{"id" => "fresh", "changes" => [%{"rev" => "1-" <> _}]}, 1}, 1000
      assert_receive {:change, %{"id" => "updated"}, 2}, 1000
      assert_receive {:change, %{"id" => "deleted", "deleted" => true}, 3}, 1000
      assert_receive {:changes_request, %{query: %{"since" => since}}}, 2000
      assert since == seq(5)
    end

    test "an empty longpoll response (timeout) reconnects with the same since", %{
      couch: couch,
      db: db
    } do
      pid = self()

      FakeCouch.expect_changes(couch, fn conn ->
        conn
        |> FakeCouch.report(pid)
        |> FakeCouch.respond([], conn.query_params["since"] || seq(2))
      end)

      follow(db, longpoll: true, since: seq(2))

      assert_receive {:changes_request, %{query: %{"since" => s1}}}, 1000
      assert_receive {:changes_request, %{query: %{"since" => s2}}}, 2000
      assert s1 == seq(2)
      assert s2 == seq(2)
      refute_received {:change, _, _}
    end

    test "style=all_docs rows list every leaf revision", %{couch: couch, db: db} do
      batches(couch, self(), %{
        "results" => [CouchFixtures.all_docs_row()],
        "last_seq" => seq(5),
        "pending" => 0
      })

      follow(db, longpoll: true, style: :all_docs)

      assert_receive {:changes_request, %{query: %{"style" => "all_docs"}}}, 1000

      assert_receive {:change, %{"changes" => [%{"rev" => "6-" <> _}, %{"rev" => "5-" <> _}]}, 1},
                     1000
    end

    test "feed=normal returns all past changes once and does not reconnect", %{
      couch: couch,
      db: db
    } do
      pid = self()

      FakeCouch.expect_changes(couch, fn conn ->
        conn |> FakeCouch.report(pid) |> FakeCouch.respond(CouchFixtures.normal_rows(), seq(5))
      end)

      follower = follow(db, feed: :normal)

      assert_receive {:changes_request, %{query: %{"feed" => "normal"}}}, 1000
      assert_receive {:change, %{"id" => "deleted"}, 3}, 1000
      refute_receive {:changes_request, _}, 1000
      assert %Changes{worker: nil, query: %{since: since}} = :sys.get_state(follower)
      assert since == seq(5)
      assert Process.alive?(follower)
    end
  end

  describe "resilience" do
    test "missing heartbeats restart the stream", %{couch: couch, db: db} do
      streaming(couch, self(), [], heartbeat: :infinity)
      follow(db, heartbeat: 100)

      assert_receive {:changes_request, _}, 1000
      assert_receive {:changes_request, _}, 2000
    end

    test "regular heartbeats keep the stream alive", %{couch: couch, db: db} do
      # the watchdog fires after twice the heartbeat, so leave it room for a
      # few late beats from the fake while the rest of the suite runs
      streaming(couch, self(), [], heartbeat: 50)
      follow(db, heartbeat: 200)

      assert_receive {:changes_request, _}, 1000
      refute_receive {:changes_request, _}, 800
      refute_received {:error, _}
    end

    test "without a heartbeat the watchdog is off and the server timeout applies", %{
      couch: couch,
      db: db
    } do
      streaming(couch, self(), [], heartbeat: :infinity)
      follower = follow(db, heartbeat: nil, timeout: 500)

      assert_receive {:changes_request, %{query: query}}, 1000
      refute Map.has_key?(query, "heartbeat")
      assert %Changes{watchdog: nil} = :sys.get_state(follower)
      refute_receive {:changes_request, _}, 600
    end

    test "the death of the connection process restarts the stream", %{couch: couch, db: db} do
      streaming(couch, self())
      follower = follow(db)

      assert_receive {:changes_request, _}, 1000
      %Changes{worker: worker} = :sys.get_state(follower)
      assert is_pid(worker)

      Process.exit(worker, :kill)
      assert_receive {:changes_request, _}, 2000
      refute_received {:error, _}
    end

    test "a connection dropped mid-stream is reopened without an error", %{couch: couch, db: db} do
      streaming(couch, self(), [row("a", 1, "1-a")])
      follow(db, heartbeat: 10_000)

      assert_receive {:change, %{"id" => "a"}, 1}, 1000
      Bypass.down(couch.bypass)

      # the drop itself is not an error, the refused reconnect is
      assert_receive {:error, {:conn_failed, :econnrefused}}, 2000
      Bypass.up(couch.bypass)
      assert_receive {:changes_request, %{query: %{"since" => since}}}, 3000
      assert since == seq(1)
    end
  end

  describe "stopping" do
    test "stop/1 calls terminate/2 and tears down the connection process", %{couch: couch, db: db} do
      streaming(couch, self())
      follower = follow(db)

      assert_receive {:changes_request, _}, 1000
      %Changes{worker: worker} = :sys.get_state(follower)
      assert is_pid(worker)
      worker_ref = Process.monitor(worker)

      assert Changes.stop(follower) == :ok
      assert_receive {:terminate, :normal}
      refute Process.alive?(follower)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1000
    end
  end
end
