defmodule SofaChangesTest do
  @moduledoc """
  Behaviour tests for `Sofa.Changes`: the callback contract and the
  GenServer plumbing, observed only from the outside through
  `Sofa.TestFollower`.
  """

  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Sofa.{Changes, DefaultFollower, TestFollower}

  # a database handle that is never connected to in these tests
  @db Sofa.init("http://127.0.0.1:1/") |> Sofa.client() |> Map.put(:database, "recipes")

  # Starts an unlinked, monitored follower so a `{:stop, _}` exit does not
  # take the test process down with it. Stopped again at test exit.
  defp start_monitored(args) do
    {:ok, pid} = Changes.start(TestFollower, args)
    ref = Process.monitor(pid)
    on_exit(fn -> if Process.alive?(pid), do: Changes.stop(pid) end)
    {pid, ref}
  end

  describe "use Sofa.Changes" do
    test "declares the behaviour" do
      assert Changes in List.wrap(DefaultFollower.__info__(:attributes)[:behaviour])
    end

    test "defines the seven callbacks plus code_change" do
      callbacks = Changes.behaviour_info(:callbacks) |> Enum.sort()

      assert callbacks == [
               code_change: 3,
               handle_call: 3,
               handle_cast: 2,
               handle_change: 2,
               handle_error: 2,
               handle_info: 2,
               init: 1,
               terminate: 2
             ]

      # function_exported?/3 only shows actually loaded modules
      Code.ensure_loaded!(DefaultFollower)

      for {name, arity} <- callbacks do
        assert function_exported?(DefaultFollower, name, arity), "#{name}/#{arity} missing"
      end
    end

    test "injects overridable defaults" do
      from = {self(), make_ref()}

      assert DefaultFollower.init(:args) == {:ok, :args, nil}
      assert DefaultFollower.handle_change(%{"id" => "x"}, :state) == {:ok, :state}
      assert DefaultFollower.handle_call(:request, from, :state) == {:noreply, :state}
      assert DefaultFollower.handle_cast(:request, :state) == {:noreply, :state}
      assert DefaultFollower.handle_info(:message, :state) == {:noreply, :state}
      assert DefaultFollower.handle_error(:oops, :state) == {:retry, 60_000, :state}
      assert DefaultFollower.terminate(:normal, :state) == :ok
      assert DefaultFollower.code_change(1, :state, :extra) == {:ok, :state}
    end
  end

  describe "init/1" do
    test "returning :ignore" do
      assert Changes.start_link(TestFollower, :ignore) == :ignore
    end

    test "returning {:stop, reason}" do
      assert Changes.start(TestFollower, {:stop, :nope}) == {:error, :nope}
    end

    test "{:ok, db, state} keeps the database and default query" do
      {:ok, pid} = Changes.start_link(TestFollower, %{db: @db, pid: self()})

      assert %Changes{db: %Sofa{database: "recipes"}, query: %Changes.Query{feed: :continuous}} =
               :sys.get_state(pid)
    end

    test "{:ok, db, opts, state} parses the feed options" do
      {:ok, pid} =
        Changes.start_link(
          TestFollower,
          %{db: @db, opts: [longpoll: true, since: "3-g1AAAA"], pid: self()}
        )

      assert %Changes{query: %Changes.Query{feed: :longpoll, since: "3-g1AAAA"}} =
               :sys.get_state(pid)
    end

    test "{:ok, db, opts, state, timeout} delivers :timeout to handle_info/2" do
      {:ok, _} = Changes.start_link(TestFollower, %{db: @db, opts: [], pid: self(), timeout: 10})
      assert_receive {:info, :timeout}, 1000
    end

    test "a database handle without a client gets one" do
      db = Sofa.init("http://127.0.0.1:1/") |> Map.put(:database, "recipes")
      {:ok, pid} = Changes.start_link(TestFollower, %{db: db, pid: self()})
      assert %Changes{db: %Sofa{client: %Req.Request{}}} = :sys.get_state(pid)
    end

    test "anything but a %Sofa{} with a database is rejected" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{}, _}} =
               Changes.start_link(TestFollower, %{db: "recipes", pid: self()})
    end
  end

  describe "GenServer plumbing" do
    test "call/cast/info are delegated to the callback module" do
      {:ok, follower} = Changes.start_link(TestFollower, %{db: @db, pid: self()})

      assert Changes.call(follower, :hello) == {:echo, :hello}
      assert_receive {:call, :hello}

      assert Changes.cast(follower, :world) == :ok
      assert_receive {:cast, :world}, 1000

      send(follower, :raw)
      assert_receive {:info, :raw}, 1000
    end

    test "stop/1 calls terminate/2" do
      {:ok, follower} = Changes.start_link(TestFollower, %{db: @db, pid: self()})

      assert Changes.stop(follower) == :ok
      assert_receive {:terminate, :normal}
      refute Process.alive?(follower)
    end

    test "a stop reply from handle_call/3 stops the follower" do
      {follower, ref} = start_monitored(%{db: @db, pid: self()})

      assert Changes.call(follower, {:stop, :normal}) == :ok
      assert_receive {:terminate, :normal}
      assert_receive {:DOWN, ^ref, :process, ^follower, :normal}, 1000
    end

    test "name registration, whereis/1 and reply/2" do
      {:ok, follower} =
        Changes.start_link(TestFollower, %{db: @db, pid: self()}, name: :sofa_test_follower)

      assert Changes.whereis(:sofa_test_follower) == follower
      assert Changes.whereis(:nobody_here) == nil
      assert Changes.reply({self(), make_ref()}, :pong) == :ok
    end

    test "code_change/3 is delegated" do
      {:ok, follower} = Changes.start_link(TestFollower, %{db: @db, pid: self()})

      :ok = :sys.suspend(follower)
      :ok = :sys.change_code(follower, Changes, 1, :upgraded)
      :ok = :sys.resume(follower)

      assert %{code_changed: :upgraded} = Changes.call(follower, :state)
    end

    test "retry_now/1 is harmless while nothing is waiting" do
      {:ok, follower} = Changes.start_link(TestFollower, %{db: @db, pid: self()})
      assert Changes.retry_now(follower) == :ok
      assert %{seen: 0} = Changes.call(follower, :state)
    end
  end
end
