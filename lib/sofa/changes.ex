defmodule Sofa.Changes do
  @moduledoc """
  A behaviour for following the CouchDB `_changes` feed of a database.

  > If the only tool you have is CouchDB, then
  > everything looks like `{:ok, :relax}`

  `Sofa.Changes` is a `GenServer` with one extra callback,
  `c:handle_change/2`, which is invoked once per changed document, in
  order, and one extra way of returning from `c:init/1`: alongside the
  state it names the database to follow and, optionally, the feed options
  described in `Sofa.Changes.Query`.

      defmodule Follower do
        use Sofa.Changes

        def start_link(db), do: Sofa.Changes.start_link(__MODULE__, db)

        @impl true
        def init(db), do: {:ok, db, [include_docs: true], nil}

        @impl true
        def handle_change(%{"id" => id, "deleted" => true}, state) do
          Logger.warning("deleted: \#{id}")
          {:ok, state}
        end

        def handle_change(%{"doc" => %Sofa.Doc{id: id, rev: rev, body: body}}, state) do
          Logger.info("doc \#{id} rev=\#{rev} fields: \#{inspect(Map.keys(body))}")
          {:ok, state}
        end

        def handle_change(change, state) do
          Logger.error("unhandled change: \#{inspect(change)}")
          {:ok, state}
        end
      end

  A ready-to-run script version of this example lives at
  `examples/follower.exs`. It prints each document's `id`, `rev` and body
  fields, and logs deletions without crashing.

  The database is a `%Sofa{}` with its `database` set, as returned by
  `Sofa.DB.open!/2`. The follower reuses its Req client and credentials.

  `use Sofa.Changes` declares the behaviour and injects overridable
  defaults for every callback, so only `c:init/1` and `c:handle_change/2`
  usually need writing.

  The remaining `GenServer` callbacks (`handle_call`, `handle_cast`,
  `handle_info`, `terminate`, `code_change`) are delegated to the callback
  module with its own state threaded through, and `c:handle_error/2`
  decides what to do when a request fails.

  Each follower is one process with its own HTTP connection. Changes are
  delivered as messages to that process, so `c:handle_change/2` is single
  threaded and ordered.
  """

  use GenServer

  alias Sofa.Changes.Query

  @typedoc "A follower, as accepted by `GenServer` functions"
  @type follower ::
          pid() | atom() | {:global, term()} | {:via, module(), term()} | {atom(), node()}

  @typedoc "The reply tag passed to `c:handle_call/3`"
  @type from :: {pid(), term()}

  @typedoc "A changed document, as decoded from the feed"
  @type change :: Sofa.Changes.Parser.row()

  @typedoc "Why a request failed, as given to `c:handle_error/2`"
  @type error ::
          :bad_request
          | :unauthorized
          | :forbidden
          | :not_found
          | :internal_server_error
          | {:status_code, pos_integer()}
          | {:conn_failed, term()}

  @type on_start :: {:ok, pid()} | :ignore | {:error, {:already_started, pid()} | term()}

  @doc """
  Called when the follower starts, inside the `GenServer` init.

  Returns the database to follow, optionally the feed options (see
  `Sofa.Changes.Query`), the callback state, and optionally a `GenServer`
  timeout. `:ignore` and `{:stop, reason}` behave as in `GenServer`.
  """
  @callback init(args :: term()) ::
              {:ok, db :: Sofa.t(), state}
              | {:ok, db :: Sofa.t(), opts :: keyword(), state}
              | {:ok, db :: Sofa.t(), opts :: keyword(), state, timeout() | :hibernate}
              | :ignore
              | {:stop, reason :: term()}
            when state: term()

  @doc """
  Called once for every changed document, in the order received.

  A deleted document arrives as a change whose `"deleted"` key is `true`.
  With `include_docs: true` its embedded `"doc"` is a tombstone whose body
  carries only `"_deleted" => true` and none of the document's former
  fields. Callbacks should match on `"deleted"` (or on `"id"`) before
  assuming a field such as a document body is present, otherwise a
  deletion will raise a `FunctionClauseError` and stop the follower.

  `{:stop, reason, state}` stops the follower and calls `c:terminate/2`.
  """
  @callback handle_change(change(), state :: term()) ::
              {:ok, new_state}
              | {:ok, new_state, timeout() | :hibernate}
              | {:stop, reason :: term(), new_state}
            when new_state: term()

  @doc """
  Called when a request fails with a non-200 status or a connection error.

  `{:retry, state}` reconnects right away, `{:retry, ms, state}` after
  `ms` milliseconds, `{:retry, :infinity, state}` waits for `retry_now/1`,
  and `{:stop, reason, state}` stops the follower. The default waits 60
  seconds, which also prevents a follower with bad credentials from
  tripping CouchDB's account lockout timer.
  """
  @callback handle_error(error(), state :: term()) ::
              {:retry, new_state}
              | {:retry, timeout(), new_state}
              | {:stop, reason :: term(), new_state}
            when new_state: term()

  @callback handle_call(request :: term(), from(), state :: term()) ::
              {:reply, reply, new_state}
              | {:reply, reply, new_state, timeout() | :hibernate}
              | {:noreply, new_state}
              | {:noreply, new_state, timeout() | :hibernate}
              | {:stop, reason, reply, new_state}
              | {:stop, reason, new_state}
            when reply: term(), new_state: term(), reason: term()

  @callback handle_cast(request :: term(), state :: term()) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout() | :hibernate}
              | {:stop, reason :: term(), new_state}
            when new_state: term()

  @callback handle_info(msg :: :timeout | term(), state :: term()) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout() | :hibernate}
              | {:stop, reason :: term(), new_state}
            when new_state: term()

  @callback terminate(reason, state :: term()) :: term()
            when reason: :normal | :shutdown | {:shutdown, term()} | term()

  @callback code_change(old_vsn, state :: term(), extra :: term()) ::
              {:ok, new_state :: term()} | {:error, reason :: term()}
            when old_vsn: term() | {:down, term()}

  @doc false
  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour Sofa.Changes

      @doc false
      def init(args), do: {:ok, args, nil}

      @doc false
      def handle_change(_change, state), do: {:ok, state}

      @doc false
      def handle_error(_error, state), do: {:retry, 60_000, state}

      @doc false
      def handle_call(_request, _from, state), do: {:noreply, state}

      @doc false
      def handle_cast(_request, state), do: {:noreply, state}

      @doc false
      def handle_info(_msg, state), do: {:noreply, state}

      @doc false
      def terminate(_reason, _state), do: :ok

      @doc false
      def code_change(_old_vsn, state, _extra), do: {:ok, state}

      defoverridable init: 1,
                     handle_change: 2,
                     handle_error: 2,
                     handle_call: 3,
                     handle_cast: 2,
                     handle_info: 2,
                     terminate: 2,
                     code_change: 3
    end
  end

  # The follower's own state: the callback module's state lives in `mstate`.
  # Fields are documented where they are first used.
  defstruct [:module, :mstate, :db, :query, :timeout]

  @typedoc "The follower's internal state, visible via `:sys.get_state/1`"
  @type t :: %__MODULE__{
          module: module(),
          mstate: term(),
          db: Sofa.t(),
          query: Query.t(),
          timeout: timeout() | :hibernate | nil
        }

  ## Public API, mirroring GenServer

  @doc "Starts a follower linked to the current process, see `GenServer.start_link/3`."
  @spec start_link(module(), term(), GenServer.options()) :: on_start()
  def start_link(module, args, gen_opts \\ []) when is_atom(module) and is_list(gen_opts) do
    GenServer.start_link(__MODULE__, {module, args}, gen_opts)
  end

  @doc "Starts an unlinked follower, see `GenServer.start/3`."
  @spec start(module(), term(), GenServer.options()) :: on_start()
  def start(module, args, gen_opts \\ []) when is_atom(module) and is_list(gen_opts) do
    GenServer.start(__MODULE__, {module, args}, gen_opts)
  end

  @doc "Stops a follower, closing its connection and calling `c:terminate/2`."
  @spec stop(follower(), reason :: term(), timeout()) :: :ok
  def stop(follower, reason \\ :normal, timeout \\ :infinity) do
    GenServer.stop(follower, reason, timeout)
  end

  @doc "Calls the follower, handled by its `c:handle_call/3`."
  @spec call(follower(), request :: term(), timeout()) :: term()
  def call(follower, request, timeout \\ 5000), do: GenServer.call(follower, request, timeout)

  @doc "Casts to the follower, handled by its `c:handle_cast/2`."
  @spec cast(follower(), request :: term()) :: :ok
  def cast(follower, request), do: GenServer.cast(follower, request)

  @doc "Replies to a call, see `GenServer.reply/2`."
  @spec reply(from(), term()) :: :ok
  def reply(from, reply), do: GenServer.reply(from, reply)

  @doc "Resolves a registered name to a pid, see `GenServer.whereis/1`."
  @spec whereis(follower()) :: pid() | {atom(), node()} | nil
  def whereis(follower), do: GenServer.whereis(follower)

  @doc """
  Reconnects a follower that is waiting after `{:retry, :infinity, state}`
  from `c:handle_error/2`. A no-op while a request is in flight.
  """
  @spec retry_now(follower()) :: :ok
  def retry_now(follower) do
    send(follower, {:"$sofa_changes", :retry_now})
    :ok
  end

  ## GenServer callbacks

  @impl GenServer
  def init({module, args}) do
    # exits from the connection process arrive as messages, see handle_info/2
    Process.flag(:trap_exit, true)

    case module.init(args) do
      {:ok, db, mstate} ->
        {:ok, new(module, db, [], mstate), {:continue, :start}}

      {:ok, db, opts, mstate} ->
        {:ok, new(module, db, opts, mstate), {:continue, :start}}

      {:ok, db, opts, mstate, timeout} ->
        {:ok, %{new(module, db, opts, mstate) | timeout: timeout}, {:continue, :start}}

      :ignore ->
        :ignore

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  @spec new(module(), Sofa.t(), keyword(), term()) :: t()
  defp new(module, db = %Sofa{database: database}, opts, mstate) when is_binary(database) do
    # a %Sofa{} straight from Sofa.init/1 has no client yet
    db = if db.client, do: db, else: Sofa.client(db)
    %__MODULE__{module: module, mstate: mstate, db: db, query: Query.new(opts)}
  end

  defp new(_module, db, _opts, _mstate) do
    raise ArgumentError,
          "expected a %Sofa{} with a database, as from Sofa.DB.open!/2, got: #{inspect(db)}"
  end

  @impl GenServer
  def handle_continue(:start, state = %__MODULE__{timeout: nil}),
    do: {:noreply, start_stream(state)}

  def handle_continue(:start, state = %__MODULE__{timeout: timeout}) do
    {:noreply, start_stream(%{state | timeout: nil}), timeout}
  end

  # The first request is issued here, after init/1 has returned, so that
  # start_link/3 succeeds even when the server will refuse the request.
  @spec start_stream(t()) :: t()
  defp start_stream(state = %__MODULE__{}), do: state

  @impl GenServer
  def handle_call(request, from, state = %__MODULE__{module: module, mstate: mstate}) do
    case module.handle_call(request, from, mstate) do
      {:reply, reply, mstate} -> {:reply, reply, %{state | mstate: mstate}}
      {:reply, reply, mstate, timeout} -> {:reply, reply, %{state | mstate: mstate}, timeout}
      {:noreply, mstate} -> {:noreply, %{state | mstate: mstate}}
      {:noreply, mstate, timeout} -> {:noreply, %{state | mstate: mstate}, timeout}
      {:stop, reason, reply, mstate} -> {:stop, reason, reply, %{state | mstate: mstate}}
      {:stop, reason, mstate} -> {:stop, reason, %{state | mstate: mstate}}
    end
  end

  @impl GenServer
  def handle_cast(request, state = %__MODULE__{module: module, mstate: mstate}) do
    module.handle_cast(request, mstate) |> noreply(state)
  end

  @impl GenServer
  def handle_info({:"$sofa_changes", :retry_now}, state = %__MODULE__{}), do: {:noreply, state}

  def handle_info(msg, state = %__MODULE__{module: module, mstate: mstate}) do
    module.handle_info(msg, mstate) |> noreply(state)
  end

  # wraps the callback module's state back into ours for noreply-style replies
  @spec noreply(term(), t()) ::
          {:noreply, t()} | {:noreply, t(), timeout()} | {:stop, term(), t()}
  defp noreply({:noreply, mstate}, state), do: {:noreply, %{state | mstate: mstate}}

  defp noreply({:noreply, mstate, timeout}, state),
    do: {:noreply, %{state | mstate: mstate}, timeout}

  defp noreply({:stop, reason, mstate}, state), do: {:stop, reason, %{state | mstate: mstate}}

  @impl GenServer
  def terminate(reason, %__MODULE__{module: module, mstate: mstate}) do
    module.terminate(reason, mstate)
  end

  @impl GenServer
  def code_change(old_vsn, state = %__MODULE__{module: module, mstate: mstate}, extra) do
    case module.code_change(old_vsn, mstate, extra) do
      {:ok, mstate} -> {:ok, %{state | mstate: mstate}}
      other -> other
    end
  end
end
