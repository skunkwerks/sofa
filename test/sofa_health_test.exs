defmodule SofaHealthTest do
  @moduledoc """
  `Sofa.Health` against a fake CouchDB `/_up` on Bypass: what the cache
  says before, during and after a run of good and failed probes.
  """

  use ExUnit.Case, async: true

  @moduletag capture_log: true

  import Sofa.BypassHelpers

  alias Sofa.Health

  doctest Health

  setup do
    start()
  end

  # each test gets its own checker name, so they can run side by side
  defp checker(sofa, opts \\ []) do
    name = :"sofa_health_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([sofa: sofa, name: name, interval: 20, timeout: 2000], opts)
    _pid = start_supervised!({Health, opts})
    name
  end

  # polls until `fun` returns a truthy value, or fails after three seconds
  defp eventually(fun, tries \\ 300) do
    case fun.() do
      result when result in [nil, false] and tries > 0 ->
        Process.sleep(10)
        eventually(fun, tries - 1)

      result when result in [nil, false] ->
        flunk("condition never held")

      result ->
        result
    end
  end

  # a client that takes `ms` before it sends anything
  defp slow(sofa, ms) do
    client =
      Req.Request.prepend_request_steps(sofa.client,
        slow: &tap(&1, fn _ -> Process.sleep(ms) end)
      )

    %{sofa | client: client}
  end

  defp up(bypass, pid \\ nil) do
    Bypass.stub(bypass, "GET", "/_up", fn conn ->
      if pid, do: send(pid, :probed)
      json(conn, 200, "up_200.json")
    end)
  end

  describe "healthy?/2" do
    test "is true once /_up answers 200", %{bypass: bypass, sofa: sofa} do
      up(bypass)
      name = checker(sofa)

      assert eventually(fn -> Health.healthy?(name) end)
      assert Sofa.healthy?(name)
      assert Sofa.healthy?(name, max_age: 60_000)
    end

    test "is false when the last 200 is older than max_age", %{bypass: bypass, sofa: sofa} do
      up(bypass)
      name = checker(sofa, interval: 60_000)

      assert eventually(fn -> Health.healthy?(name) end)
      Process.sleep(60)

      refute Health.healthy?(name, max_age: 50)
      assert Health.healthy?(name, max_age: 60_000)
    end

    test "turns false after CouchDB stops answering", %{bypass: bypass, sofa: sofa} do
      up(bypass)
      name = checker(sofa)

      assert eventually(fn -> Health.healthy?(name, max_age: 100) end)
      Bypass.down(bypass)

      assert eventually(fn -> Health.status(name).error end)
      assert eventually(fn -> not Health.healthy?(name, max_age: 100) end)
      assert %{ok_at: ok_at} = Health.status(name)
      assert is_integer(ok_at)
    end

    test "is false when /_up never answered 200", %{bypass: bypass, sofa: sofa} do
      Bypass.stub(bypass, "GET", "/_up", fn conn ->
        Sofa.FakeCouch.json(conn, 404, %{"status" => "maintenance_mode"})
      end)

      name = checker(sofa)

      assert eventually(fn -> Health.status(name).checked_at end)
      refute Health.healthy?(name)
      assert %{ok_at: nil, age: nil, error: :not_found} = Health.status(name)
    end

    test "is false without a checker of that name" do
      refute Sofa.healthy?(:sofa_health_never_started)
    end
  end

  describe "status/2" do
    test "is empty before the first probe ends", %{sofa: sofa} do
      name = checker(slow(sofa, 300))

      assert Health.status(name) == %{
               healthy: false,
               ok_at: nil,
               age: nil,
               checked_at: nil,
               error: nil
             }
    end

    test "gives the time and age of the last 200", %{bypass: bypass, sofa: sofa} do
      up(bypass)
      before = System.monotonic_time(:millisecond)
      name = checker(sofa, interval: 60_000)

      %{ok_at: ok_at} = eventually(fn -> Health.status(name).ok_at && Health.status(name) end)
      assert ok_at >= before
      assert %{healthy: true, age: age, checked_at: ^ok_at, error: nil} = Health.status(name)
      assert age >= 0
    end

    test "a 500 is the last error, and the next 200 clears it", %{bypass: bypass, sofa: sofa} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "GET", "/_up", fn conn ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 -> Sofa.FakeCouch.error(conn, 500, "unknown_error", "boom")
          _ -> json(conn, 200, "up_200.json")
        end
      end)

      name = checker(sofa)

      assert %Sofa.Response{status: 500} = eventually(fn -> Health.status(name).error end)
      assert eventually(fn -> Health.healthy?(name) end)
      assert %{error: nil} = Health.status(name)
    end
  end

  describe "failing soft" do
    test "a probe slower than the timeout is a failed check", %{sofa: sofa} do
      name = checker(slow(sofa, 1000), timeout: 50)
      pid = Process.whereis(name)

      assert :timeout = eventually(fn -> Health.status(name).error end)
      refute Health.healthy?(name)
      assert Process.whereis(name) == pid
    end

    test "an exception in the probe is a failed check", %{sofa: sofa} do
      client = Req.Request.prepend_request_steps(sofa.client, boom: fn _ -> raise "boom" end)
      name = checker(%{sofa | client: client})
      pid = Process.whereis(name)

      assert {:exception, %RuntimeError{message: "boom"}} =
               eventually(fn -> Health.status(name).error end)

      # and it goes on probing, from the same process
      Process.sleep(50)
      assert Process.whereis(name) == pid
      assert %{error: {:exception, _}} = Health.status(name)
    end

    test "probes repeat every interval", %{bypass: bypass, sofa: sofa} do
      up(bypass, self())
      _name = checker(sofa, interval: 20)

      assert_receive :probed, 1000
      assert_receive :probed, 1000
      assert_receive :probed, 1000
    end
  end

  describe "starting" do
    test "several checkers run side by side", %{bypass: bypass, sofa: sofa} do
      up(bypass)
      down = start()
      Bypass.down(down.bypass)

      good = checker(sofa)
      bad = checker(down.sofa)

      assert eventually(fn -> Health.healthy?(good) end)
      assert {:conn_failed, :econnrefused} = eventually(fn -> Health.status(bad).error end)
      refute Health.healthy?(bad)
    end

    test "the default name is Sofa.Health" do
      assert Health.child_spec(sofa: Sofa.init()).id == Sofa.Health
      assert Health.child_spec(sofa: Sofa.init(), name: :couch_b).id == :couch_b
    end

    test "a handle without a client gets one", %{bypass: bypass, url: url} do
      up(bypass)
      name = checker(Sofa.init(url))

      assert eventually(fn -> Health.healthy?(name) end)
    end

    test "anything but a %Sofa{} is refused" do
      assert {:error, {{%ArgumentError{message: message}, _stack}, _child}} =
               start_supervised({Health, sofa: "http://nope/"})

      assert message == ~s(expected sofa: %Sofa{}, got: "http://nope/")
    end
  end
end
