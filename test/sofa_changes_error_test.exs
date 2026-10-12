defmodule SofaChangesErrorTest do
  @moduledoc """
  How `Sofa.Changes` reports failed requests to `handle_error/2`, and what
  each of its replies does, driven through `Sofa.FakeCouch`.
  """

  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Sofa.{Changes, FakeCouch, TestFollower}

  import Sofa.CouchFixtures, only: [row: 3, seq: 1]

  setup do
    couch = FakeCouch.open()
    %{couch: couch, db: couch.db}
  end

  defp start_monitored(args) do
    {:ok, pid} = Changes.start(TestFollower, args)
    ref = Process.monitor(pid)
    on_exit(fn -> if Process.alive?(pid), do: Changes.stop(pid) end)
    {pid, ref}
  end

  # fails the first request with `status`, then streams
  defp failing_once(couch, pid, status) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    FakeCouch.expect_changes(couch, fn conn ->
      conn = FakeCouch.report(conn, pid)

      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> FakeCouch.error(conn, status, "error", "reason")
        _ -> FakeCouch.stream(conn, couch, pid)
      end
    end)
  end

  describe "status codes" do
    for {status, reason} <- [
          {401, :unauthorized},
          {403, :forbidden},
          {404, :not_found},
          {500, :internal_server_error},
          {429, {:status_code, 429}}
        ] do
      test "a #{status} response is reported as #{inspect(reason)}", %{couch: couch, db: db} do
        pid = self()

        FakeCouch.expect_changes(couch, fn conn ->
          conn |> FakeCouch.report(pid) |> FakeCouch.error(unquote(status), "error", "reason")
        end)

        {follower, ref} = start_monitored(%{db: db, pid: self(), on_error: {:stop, :gave_up}})

        assert_receive {:error, unquote(Macro.escape(reason))}, 1000
        assert_receive {:DOWN, ^ref, :process, ^follower, :gave_up}, 1000
      end
    end

    test "a 400 with nothing to fall back to stops with :bad_request", %{couch: couch, db: db} do
      pid = self()

      FakeCouch.expect_changes(couch, fn conn ->
        conn
        |> FakeCouch.report(pid)
        |> FakeCouch.json(400, Sofa.CouchFixtures.missing_selector_error())
      end)

      {follower, ref} = start_monitored(%{db: db, pid: self()})

      assert_receive {:DOWN, ^ref, :process, ^follower, :bad_request}, 1000
      assert_receive {:terminate, :bad_request}
    end

    test "the failed request is closed before handle_error/2 runs", %{couch: couch, db: db} do
      pid = self()

      FakeCouch.expect_changes(couch, fn conn ->
        conn |> FakeCouch.report(pid) |> FakeCouch.error(500, "error", "reason")
      end)

      {follower, _ref} = start_monitored(%{db: db, pid: self(), on_error: {:retry, :infinity}})

      assert_receive {:error, :internal_server_error}, 1000
      assert %Changes{worker: nil, retry: :infinity} = :sys.get_state(follower)

      # the worker's own exit is not the callback module's business
      refute_receive {:info, {:EXIT, _pid, _reason}}, 200
      assert %Changes{workers: workers} = :sys.get_state(follower)
      assert workers == %{}
    end
  end

  describe "400 fallback" do
    # rejects every since except seq(5), which streams one row and ends
    defp rejecting_except_five(couch, pid) do
      known = seq(5)

      FakeCouch.expect_changes(couch, fn conn ->
        conn = FakeCouch.report(conn, pid)

        case conn.query_params["since"] do
          ^known ->
            FakeCouch.stream(conn, couch, pid, [row("a", 6, "1-a")], hold: false)

          _bad ->
            FakeCouch.error(
              conn,
              400,
              "bad_request",
              "Malformed sequence supplied in 'since' parameter."
            )
        end
      end)
    end

    test "a 400 after a known-good sequence retries once from that sequence", %{
      couch: couch,
      db: db
    } do
      known = seq(5)

      rejecting_except_five(couch, self())
      {follower, ref} = start_monitored(%{db: db, opts: [since: known], pid: self()})

      assert_receive {:changes_request, %{query: %{"since" => ^known}}}, 1000
      assert_receive {:changes_request, %{query: %{"since" => bad}}}, 2000
      assert bad == seq(6)
      assert_receive {:changes_request, %{query: %{"since" => ^known}}}, 2000
      refute_received {:error, _}

      # the fallback is not re-armed, so the same rejection is now fatal
      assert_receive {:changes_request, %{query: %{"since" => ^bad}}}, 2000
      assert_receive {:DOWN, ^ref, :process, ^follower, :bad_request}, 2000
    end

    test "a 400 on the very first request has nothing to fall back to", %{couch: couch, db: db} do
      pid = self()

      FakeCouch.expect_changes(couch, fn conn ->
        conn = FakeCouch.report(conn, pid)

        case conn.query_params["since"] do
          nil ->
            FakeCouch.stream(conn, couch, pid, [row("a", 6, "1-a")], hold: false)

          _bad ->
            FakeCouch.error(
              conn,
              400,
              "bad_request",
              "Malformed sequence supplied in 'since' parameter."
            )
        end
      end)

      {follower, ref} = start_monitored(%{db: db, pid: self()})

      assert_receive {:changes_request, %{query: %{"since" => bad}}}, 2000
      assert bad == seq(6)
      assert_receive {:DOWN, ^ref, :process, ^follower, :bad_request}, 2000
      assert_receive {:terminate, :bad_request}
    end
  end

  describe "handle_error/2 replies" do
    test "{:retry, ms, state} retries after the given delay", %{couch: couch, db: db} do
      failing_once(couch, self(), 500)

      {:ok, _} = Changes.start_link(TestFollower, %{db: db, pid: self(), on_error: {:retry, 50}})

      assert_receive {:changes_request, _}, 1000
      assert_receive {:error, :internal_server_error}, 1000
      assert_receive {:changes_request, _}, 2000
      assert_receive {:feed, _}, 1000
    end

    test "{:retry, state} retries right away", %{couch: couch, db: db} do
      failing_once(couch, self(), 503)

      {:ok, _} = Changes.start_link(TestFollower, %{db: db, pid: self(), on_error: :retry})

      assert_receive {:error, {:status_code, 503}}, 1000
      assert_receive {:changes_request, _}, 1000
      assert_receive {:changes_request, _}, 1000
    end

    test "{:retry, :infinity, state} waits for retry_now/1", %{couch: couch, db: db} do
      failing_once(couch, self(), 500)

      {:ok, follower} =
        Changes.start_link(TestFollower, %{db: db, pid: self(), on_error: {:retry, :infinity}})

      assert_receive {:changes_request, _}, 1000
      assert_receive {:error, :internal_server_error}, 1000
      refute_receive {:changes_request, _}, 700

      assert Changes.retry_now(follower) == :ok
      assert_receive {:changes_request, _}, 1000
      assert_receive {:feed, _}, 1000
    end

    test "{:stop, reason, state} stops the follower", %{couch: couch, db: db} do
      pid = self()

      FakeCouch.expect_changes(couch, fn conn ->
        conn |> FakeCouch.report(pid) |> FakeCouch.error(500, "unknown_error", "boom")
      end)

      {follower, ref} = start_monitored(%{db: db, pid: self(), on_error: {:stop, :enough}})

      assert_receive {:error, :internal_server_error}, 1000
      assert_receive {:terminate, :enough}, 1000
      assert_receive {:DOWN, ^ref, :process, ^follower, :enough}, 1000
    end

    test "a refused connection is reported as {:conn_failed, _} and retried", %{
      couch: couch,
      db: db
    } do
      pid = self()

      FakeCouch.expect_changes(couch, fn conn ->
        conn |> FakeCouch.report(pid) |> FakeCouch.stream(couch, pid)
      end)

      Bypass.down(couch.bypass)

      {:ok, _} = Changes.start_link(TestFollower, %{db: db, pid: self(), on_error: {:retry, 10}})

      assert_receive {:error, {:conn_failed, :econnrefused}}, 1000
      Bypass.up(couch.bypass)
      assert_receive {:changes_request, _}, 3000
    end
  end
end
