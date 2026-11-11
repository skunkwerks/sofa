defmodule Sofa.Health do
  @moduledoc """
  A cached health check of a CouchDB server, for load balancer probes and
  status pages that must answer at once.

  > If the only tool you have is CouchDB, then
  > everything looks like `{:ok, :relax}`

  Start a checker in your own supervision tree with a server handle. It
  asks CouchDB's `GET /_up` every 15 seconds and keeps the result.

      children = [
        {Sofa.Health, sofa: Sofa.init(url) |> Sofa.client()}
      ]

  Then ask it, as often as you like:

      Sofa.healthy?()
      #=> true

      Sofa.Health.status()
      #=> %{healthy: true, ok_at: -576460751234, age: 4210, checked_at: -576460751234, error: nil}

  Readers never wait on the checker or on HTTP. The checker writes its
  result to a protected ETS table named after it, and readers look it up
  in their own process. `:persistent_term` was the other choice. It is
  cheaper to read. Each write to it makes the VM scan every process for
  references to the old value. That suits a value that is set once at
  boot. This one is written every 15 seconds.

  Each probe runs in a process of its own, with a deadline. A hung
  connection or an exception is then a failed check, and the checker
  goes on. The next probe is due one `interval` after the last one ends.

  ## Options

    * `:sofa` - the `%Sofa{}` server handle to probe, required. Its
      `database` is ignored.
    * `:name` - the checker's name, an atom, default `Sofa.Health`. The
      process and its table are registered under it, so that each
      checker needs a name of its own.
    * `:interval` - milliseconds between probes, default 15000.
    * `:timeout` - milliseconds a probe may take, default 5000.
  """

  use GenServer

  require Logger

  @default_name __MODULE__
  @interval 15_000
  @timeout 5_000
  @max_age 60_000

  @typedoc "A checker's name, as given in the `:name` option"
  @type name :: atom()

  @typedoc """
  Why the last probe failed: a status as from `Sofa.Response.error/1`, a
  failed connection as in `Sofa.Changes`, the probe's deadline passing,
  an exception, or no checker running under that name
  """
  @type error ::
          Sofa.Response.error()
          | {:conn_failed, term()}
          | :timeout
          | {:exception, Exception.t() | term()}
          | :not_started
          | term()

  @typedoc """
  What `status/2` returns. Times are `System.monotonic_time/1` in
  milliseconds. `ok_at` is the last 200, `age` how long ago that was, and
  `checked_at` when the last probe ended. `error` is why the last probe
  failed, or nil when it passed
  """
  @type status :: %{
          healthy: boolean(),
          ok_at: integer() | nil,
          age: non_neg_integer() | nil,
          checked_at: integer() | nil,
          error: error() | nil
        }

  # the checker's own state. The cache lives in the ETS table
  defstruct [:name, :sofa, :interval, :timeout, :probe]

  @typedoc false
  @type t :: %__MODULE__{
          name: name(),
          sofa: Sofa.t(),
          interval: pos_integer(),
          timeout: pos_integer(),
          probe: {pid(), reference(), reference(), reference()} | nil
        }

  @doc "A child spec whose id is the checker's name, so several can run side by side."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{id: Keyword.get(opts, :name, @default_name), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts a checker linked to the current process, see the options above."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  True when the checker called `name` saw a 200 from CouchDB less than
  `max_age` milliseconds ago. False before the first 200, and when no
  checker runs under that name.

  Options:

    * `:max_age` - milliseconds, default 60000.

  ## Examples

      iex> Sofa.Health.healthy?(:no_such_checker)
      false
  """
  @spec healthy?(name(), keyword()) :: boolean()
  def healthy?(name \\ @default_name, opts \\ []) when is_atom(name) and is_list(opts) do
    status(name, opts).healthy
  end

  @doc """
  The details behind `healthy?/2`, see `t:status/0`. Takes the same
  options.

  ## Examples

      iex> Sofa.Health.status(:no_such_checker)
      %{healthy: false, ok_at: nil, age: nil, checked_at: nil, error: :not_started}
  """
  @spec status(name(), keyword()) :: status()
  def status(name \\ @default_name, opts \\ []) when is_atom(name) and is_list(opts) do
    max_age = Keyword.get(opts, :max_age, @max_age)
    {ok_at, checked_at, error} = lookup(name)
    age = if ok_at, do: max(now() - ok_at, 0)

    %{
      healthy: age != nil and age < max_age,
      ok_at: ok_at,
      age: age,
      checked_at: checked_at,
      error: error
    }
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, @default_name)

    sofa =
      case Keyword.get(opts, :sofa) do
        sofa = %Sofa{client: nil} -> Sofa.client(sofa)
        sofa = %Sofa{} -> sofa
        other -> raise ArgumentError, "expected sofa: %Sofa{}, got: #{inspect(other)}"
      end

    timeout = Keyword.get(opts, :timeout, @timeout)

    _table = :ets.new(name, [:named_table, :protected, :set, read_concurrency: true])
    true = :ets.insert(name, {:health, nil, nil, nil})
    send(self(), {:"$sofa_health", :probe})

    {:ok,
     %__MODULE__{
       name: name,
       # the client's own receive timeout should give up before the deadline
       sofa: %{sofa | timeout: timeout},
       interval: Keyword.get(opts, :interval, @interval),
       timeout: timeout
     }}
  end

  @impl GenServer
  # the probe process sends its result tagged with `tag`, then exits. The
  # monitor only matters when it dies some other way
  def handle_info({:"$sofa_health", :probe}, state = %__MODULE__{probe: nil, sofa: sofa}) do
    owner = self()
    tag = make_ref()
    {pid, mref} = spawn_monitor(fn -> send(owner, {tag, probe(sofa)}) end)
    deadline = Process.send_after(owner, {:"$sofa_health", :deadline, tag}, state.timeout)
    {:noreply, %{state | probe: {pid, mref, tag, deadline}}}
  end

  def handle_info({tag, result}, state = %__MODULE__{probe: {_pid, mref, tag, deadline}}) do
    true = Process.demonitor(mref, [:flush])
    _remaining = Process.cancel_timer(deadline)
    {:noreply, done(state, result)}
  end

  def handle_info(
        {:DOWN, mref, :process, pid, reason},
        state = %__MODULE__{probe: {pid, mref, _tag, deadline}}
      ) do
    _remaining = Process.cancel_timer(deadline)
    {:noreply, done(state, {:error, {:exception, reason}})}
  end

  def handle_info(
        {:"$sofa_health", :deadline, tag},
        state = %__MODULE__{probe: {pid, mref, tag, _deadline}}
      ) do
    true = Process.demonitor(mref, [:flush])
    Process.exit(pid, :kill)
    {:noreply, done(state, {:error, :timeout})}
  end

  # a stale result or deadline, or a probe message while one is in flight
  def handle_info(_msg, state = %__MODULE__{}), do: {:noreply, state}

  ## the probe

  # runs in its own process. Anything it raises is a failed check
  @spec probe(Sofa.t()) :: :ok | {:error, error()}
  defp probe(sofa) do
    case Sofa.raw(sofa, "_up", :get) do
      {:ok, _sofa, %Sofa.Response{status: 200}} -> :ok
      {:ok, _sofa, response = %Sofa.Response{}} -> {:error, Sofa.Response.error(response)}
      {:error, response = %Sofa.Response{}} -> {:error, Sofa.Response.error(response)}
      {:error, %Req.TransportError{reason: reason}} -> {:error, {:conn_failed, reason}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    :exit, reason -> {:error, {:exception, reason}}
  end

  @spec done(t(), :ok | {:error, error()}) :: t()
  defp done(state = %__MODULE__{name: name}, result) do
    {ok_at, _checked_at, _error} = lookup(name)
    at = now()

    record =
      case result do
        :ok ->
          {:health, at, at, nil}

        {:error, error} ->
          Logger.debug("#{inspect(name)}: CouchDB /_up failed: #{inspect(error)}")
          {:health, ok_at, at, error}
      end

    true = :ets.insert(name, record)
    _timer = Process.send_after(self(), {:"$sofa_health", :probe}, state.interval)
    %{state | probe: nil}
  end

  # the table goes with its checker, so a lookup without one finds nothing
  @spec lookup(name()) :: {integer() | nil, integer() | nil, error() | nil}
  defp lookup(name) do
    case :ets.lookup(name, :health) do
      [{:health, ok_at, checked_at, error}] -> {ok_at, checked_at, error}
      [] -> {nil, nil, :not_started}
    end
  rescue
    ArgumentError -> {nil, nil, :not_started}
  end

  @spec now() :: integer()
  defp now, do: System.monotonic_time(:millisecond)
end
