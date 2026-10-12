defmodule Sofa.TestFollower do
  @moduledoc """
  A `Sofa.Changes` follower that reports every callback invocation to a
  test process, so the behaviour can be observed from the outside.

  Start it with `Sofa.Changes.start_link(Sofa.TestFollower, args)` where
  `args` is one of:

    * `:ignore` - `init/1` returns `:ignore`
    * `{:stop, reason}` - `init/1` returns `{:stop, reason}`
    * `%{db: db, pid: pid}` - `init/1` returns `{:ok, db, state}`
    * `%{db: db, opts: opts, pid: pid}` - returns `{:ok, db, opts, state}`
    * `%{db: db, opts: opts, pid: pid, timeout: t}` - returns
      `{:ok, db, opts, state, t}`

  Further keys in the args map become part of the state and tune behaviour:

    * `:on_error` - what `handle_error/2` returns: `:retry`,
      `{:retry, ms | :infinity}` or `{:stop, reason}`, default `{:retry, 10}`
    * `:stop_on` - a document id. `handle_change/2` returns
      `{:stop, :stopped_by_change, state}` when it sees it

  Messages sent to `pid`:

      {:change, change, count}   handle_change/2, count of changes so far
      {:error, reason}           handle_error/2
      {:call, request}           handle_call/3 (unknown requests)
      {:cast, request}           handle_cast/2
      {:info, message}           handle_info/2
      {:terminate, reason}       terminate/2
  """

  use Sofa.Changes

  @impl true
  def init(:ignore), do: :ignore
  def init({:stop, reason}), do: {:stop, reason}

  def init(args = %{db: _db}) do
    state =
      args
      |> Map.drop([:db, :opts, :timeout])
      |> Map.put_new(:on_error, {:retry, 10})
      |> Map.put(:seen, 0)

    case args do
      %{db: db, opts: opts, timeout: timeout} -> {:ok, db, opts, state, timeout}
      %{db: db, opts: opts} -> {:ok, db, opts, state}
      %{db: db} -> {:ok, db, state}
    end
  end

  @impl true
  def handle_change(change, state = %{pid: pid, seen: seen}) do
    seen = seen + 1
    send(pid, {:change, change, seen})
    state = %{state | seen: seen}

    if change["id"] != nil and change["id"] == state[:stop_on] do
      {:stop, :stopped_by_change, state}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_error(reason, state = %{pid: pid, on_error: on_error}) do
    send(pid, {:error, reason})

    case on_error do
      :retry -> {:retry, state}
      {:retry, wait} -> {:retry, wait, state}
      {:stop, stop_reason} -> {:stop, stop_reason, state}
    end
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}
  def handle_call({:stop, reason}, _from, state), do: {:stop, reason, :ok, state}

  def handle_call(request, _from, state = %{pid: pid}) do
    send(pid, {:call, request})
    {:reply, {:echo, request}, state}
  end

  @impl true
  def handle_cast(request, state = %{pid: pid}) do
    send(pid, {:cast, request})
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state = %{pid: pid}) do
    send(pid, {:info, message})
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %{pid: pid}) do
    send(pid, {:terminate, reason})
    :ok
  end

  @impl true
  def code_change(_old_vsn, state, extra), do: {:ok, Map.put(state, :code_changed, extra)}
end

defmodule Sofa.DefaultFollower do
  @moduledoc "A `Sofa.Changes` follower with nothing overridden, to test the injected defaults."
  use Sofa.Changes
end
