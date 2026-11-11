defmodule SofaChangesStatusTest do
  @moduledoc """
  How `Sofa.Changes` tells `handle_status/2` that the feed came up or went
  down, and what `Sofa.Changes.status/2` reports, driven through
  `Sofa.FakeCouch` and observed through `Sofa.TestFollower`.
  """

  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Sofa.{Changes, FakeCouch, TestFollower}

  import Sofa.CouchFixtures, only: [row: 3, seq: 1]

  setup do
    couch = FakeCouch.open()
    %{couch: couch, db: couch.db}
  end

  defp follow(db, opts \\ [], extra \\ %{}) do
    args = Map.merge(%{db: db, opts: opts, pid: self()}, extra)
    {:ok, pid} = Changes.start_link(TestFollower, args)
    pid
  end

  defp start_monitored(args) do
    {:ok, pid} = Changes.start(TestFollower, args)
    ref = Process.monitor(pid)
    on_exit(fn -> if Process.alive?(pid), do: Changes.stop(pid) end)
    {pid, ref}
  end

  defp streaming(couch, pid, lines, opts \\ []) do
    FakeCouch.expect_changes(couch, fn conn ->
      conn
      |> FakeCouch.report(pid)
      |> FakeCouch.stream(couch, pid, lines, opts)
    end)
  end

  describe "handle_status/2 :up" do
    test "is reported on the first heartbeat of a 200, before any row", %{couch: couch, db: db} do
      streaming(couch, self(), [:heartbeat], heartbeat: :infinity)
      follow(db)

      assert_receive {:status, :up}, 1000
      refute_received {:change, _, _}
    end

    test "is reported once, not on every chunk", %{couch: couch, db: db} do
      streaming(couch, self(), [row("a", 1, "1-a"), :heartbeat, row("b", 2, "1-b")],
        heartbeat: 20
      )

      follow(db)

      assert_receive {:status, :up}, 1000
      assert_receive {:change, %{"id" => "b"}, 2}, 1000
      refute_receive {:status, _}, 200
    end

    test "is reported for a longpoll batch", %{couch: couch, db: db} do
      pid = self()

      FakeCouch.stub_changes(couch, fn conn ->
        conn |> FakeCouch.report(pid) |> FakeCouch.respond([row("a", 1, "1-a")], seq(1))
      end)

      follow(db, feed: :longpoll)

      assert_receive {:status, :up}, 1000
      assert_receive {:change, %{"id" => "a"}, 1}, 1000
      assert_receive {:status, {:down, :ended}}, 1000
    end
  end

  describe "handle_status/2 {:down, reason}" do
    test "a failed first request is reported down, once", %{couch: couch, db: db} do
      pid = self()

      FakeCouch.stub_changes(couch, fn conn ->
        conn |> FakeCouch.report(pid) |> FakeCouch.error(500, "error", "reason")
      end)

      follow(db, [], %{on_error: {:retry, 10}})

      assert_receive {:status, {:down, :internal_server_error}}, 1000
      assert_receive {:error, :internal_server_error}, 1000
      assert_receive {:error, :internal_server_error}, 2000
      refute_received {:status, _}
    end

    test "the response ending is reported, and the reconnect is up again", %{
      couch: couch,
      db: db
    } do
      streaming(couch, self(), [row("a", 1, "1-a")])
      follow(db)

      assert_receive {:status, :up}, 1000
      assert_receive {:feed, feed}, 1000
      FakeCouch.close(feed)

      assert_receive {:status, {:down, :ended}}, 1000
      assert_receive {:status, :up}, 2000
    end

    test "missing heartbeats are reported as :no_heartbeat", %{couch: couch, db: db} do
      streaming(couch, self(), [row("a", 1, "1-a")], heartbeat: :infinity)
      follow(db, heartbeat: 300)

      assert_receive {:status, :up}, 1000
      assert_receive {:status, {:down, :no_heartbeat}}, 2000
    end

    test "the death of the connection process is reported as {:exit, reason}", %{
      couch: couch,
      db: db
    } do
      streaming(couch, self(), [:heartbeat])
      follower = follow(db)

      assert_receive {:status, :up}, 1000
      %Changes{worker: worker} = :sys.get_state(follower)
      Process.exit(worker, :kill)

      assert_receive {:status, {:down, {:exit, :killed}}}, 1000
      assert_receive {:status, :up}, 2000
    end

    test "a connection dropped mid-stream is reported as {:conn_failed, _}", %{
      couch: couch,
      db: db
    } do
      streaming(couch, self(), [row("a", 1, "1-a")])
      follow(db, heartbeat: 10_000)

      assert_receive {:status, :up}, 1000
      Bypass.down(couch.bypass)

      assert_receive {:status, {:down, {:conn_failed, _}}}, 2000
      # the refused reconnect goes to handle_error/2, but is not news
      assert_receive {:error, {:conn_failed, :econnrefused}}, 2000
      refute_received {:status, _}
    end

    test "{:stop, reason, state} stops the follower", %{couch: couch, db: db} do
      streaming(couch, self(), [row("a", 1, "1-a")], heartbeat: :infinity)

      {follower, ref} =
        start_monitored(%{db: db, opts: [heartbeat: 300], pid: self(), stop_on_status: :down})

      assert_receive {:status, :up}, 1000
      assert_receive {:status, {:down, :no_heartbeat}}, 2000
      assert_receive {:terminate, :stopped_by_status}, 1000
      assert_receive {:DOWN, ^ref, :process, ^follower, :stopped_by_status}, 1000
    end

    test "{:stop, reason, state} on :up stops before any row is handled", %{
      couch: couch,
      db: db
    } do
      streaming(couch, self(), [row("a", 1, "1-a")])
      {follower, ref} = start_monitored(%{db: db, pid: self(), stop_on_status: :up})

      assert_receive {:DOWN, ^ref, :process, ^follower, :stopped_by_status}, 1000
      refute_received {:change, _, _}
    end
  end

  describe "status/2" do
    test "starts with nothing known", %{couch: couch, db: db} do
      pid = self()

      FakeCouch.expect_changes(couch, fn conn ->
        Process.sleep(200)
        conn |> FakeCouch.report(pid) |> FakeCouch.stream(couch, pid)
      end)

      follower = follow(db)

      assert Changes.status(follower) == %{
               connected: false,
               status: nil,
               last_data: nil,
               since: nil
             }

      assert_receive {:changes_request, _}, 2000
    end

    test "reports the feed up, with the last sequence", %{couch: couch, db: db} do
      streaming(couch, self(), [row("a", 1, "1-a")])
      follower = follow(db)

      assert_receive {:change, %{"id" => "a"}, 1}, 1000
      assert %{connected: true, status: :up, since: since} = Changes.status(follower)
      assert since == seq(1)
    end

    test "last_data moves on with every heartbeat on an idle feed", %{couch: couch, db: db} do
      streaming(couch, self(), [], heartbeat: 30)
      follower = follow(db)

      assert_receive {:status, :up}, 1000
      %{last_data: first} = Changes.status(follower)
      assert is_integer(first)

      Process.sleep(150)
      %{last_data: later} = Changes.status(follower)
      assert later > first
      assert later <= System.monotonic_time(:millisecond)
      refute_received {:change, _, _}
    end

    test "reports the latest reason while down", %{couch: couch, db: db} do
      pid = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      FakeCouch.stub_changes(couch, fn conn ->
        conn = FakeCouch.report(conn, pid)

        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 -> FakeCouch.error(conn, 500, "error", "reason")
          _ -> FakeCouch.error(conn, 401, "unauthorized", "reason")
        end
      end)

      follower = follow(db, [], %{on_error: {:retry, :infinity}})

      assert_receive {:error, :internal_server_error}, 1000
      Changes.retry_now(follower)
      assert_receive {:error, :unauthorized}, 2000

      assert %{connected: false, status: {:down, :unauthorized}} = Changes.status(follower)
      assert_received {:status, {:down, :internal_server_error}}
      refute_received {:status, _}
    end
  end
end
