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
  usually need writing. The remaining `GenServer` callbacks (`handle_call`,
  `handle_cast`, `handle_info`, `terminate`, `code_change`) are delegated to
  the callback module with its own state threaded through, and
  `c:handle_error/2` decides what to do when a request fails.

  ## Streaming and reconnecting

  Each follower is one process with its own HTTP connection, run by a
  linked `Sofa.Changes.Worker`. Chunks of the feed are delivered as
  messages to the follower, so `c:handle_change/2` is single threaded and
  ordered. Rows are passed through as decoded maps, see
  `Sofa.Changes.Parser`.

  The follower remembers the `seq` of every delivered row, and the
  `last_seq` a response ends with. When the server ends the response, as it
  does on its `timeout`, on `limit`, or after each longpoll batch, the
  follower reconnects with `since` set to that sequence, after a random
  delay of up to 500 ms so that many followers do not reconnect at once.
  With `feed: :normal` the single batch is delivered and the follower then
  stays idle, which suits a one-off catch-up.
  Sequences are opaque and never parsed. Because shards can move, a change
  may occasionally be delivered twice. CouchDB documents this, so
  `c:handle_change/2` should be idempotent.

  Should the server reject an advanced `since` with a 400, the follower
  retries once from the last sequence the server did accept, the one it
  sent on the previous successful request. If that is rejected too, or
  there is no such sequence, the follower stops with reason `:bad_request`.

  A watchdog restarts the connection when nothing, not even a heartbeat,
  has arrived for twice the `heartbeat` interval, which catches half-open
  TCP connections the server will never notice. Client-side receive
  timeouts, dropped connections and a crashed connection process restart
  the stream the same way, from the last sequence, without involving
  `c:handle_error/2`.

  ## Errors

  A response with a status other than 200, or a failed connection, is
  reported to `c:handle_error/2` as one of `t:error/0`, after closing the
  connection. The reply decides whether and when to reconnect.
  """

  use GenServer

  require Logger

  alias Sofa.Changes.{Parser, Query, Worker}

  @typedoc "A follower, as accepted by `GenServer` functions"
  @type follower ::
          pid() | atom() | {:global, term()} | {:via, module(), term()} | {atom(), node()}

  @typedoc "The reply tag passed to `c:handle_call/3`"
  @type from :: {pid(), term()}

  @typedoc "A changed document, as decoded from the feed"
  @type change :: Parser.row()

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

  The first request is only made after `c:init/1` returns, so starting
  succeeds even when the server will refuse it. The refusal then reaches
  `c:handle_error/2`.
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
  and `{:stop, reason, state}` stops the follower. Every reconnect adds up
  to 500 ms of jitter. The default waits 60 seconds, which also keeps a
  follower with bad credentials from tripping CouchDB's account lockout.
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

  # The follower's own state. The callback module's state lives in `mstate`.
  defstruct [
    :module,
    :mstate,
    :db,
    :query,
    # a GenServer timeout from init/1, applied once the stream has started
    :timeout,
    # the current Sofa.Changes.Worker and the reference tagging its messages
    :worker,
    :ref,
    # every worker spawned and not yet exited, so their exit signals can be
    # told apart from those of processes the callback module linked to
    workers: %{},
    # the partial last line of a continuous feed
    buffer: "",
    # whether the current request has been answered with a 200 yet
    connected: false,
    # the last `since` the server accepted, and the one last fallen back to,
    # so that two sequences cannot ping-pong between 400 and fallback
    lkg: nil,
    fallback: nil,
    # a pending reconnect timer, or :infinity while waiting for retry_now/1
    retry: nil,
    # the heartbeat watchdog timer for the current request
    watchdog: nil
  ]

  @typedoc "The follower's internal state, visible via `:sys.get_state/1`"
  @type t :: %__MODULE__{
          module: module(),
          mstate: term(),
          db: Sofa.t(),
          query: Query.t(),
          timeout: timeout() | :hibernate | nil,
          worker: pid() | nil,
          workers: %{optional(pid()) => true},
          ref: reference() | nil,
          buffer: binary(),
          connected: boolean(),
          lkg: Query.since(),
          fallback: Query.since(),
          retry: reference() | :infinity | nil,
          watchdog: reference() | nil
        }

  @jitter 500

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

  # The first request is issued here, after init/1 has returned, so that
  # start_link/3 succeeds even when the server will refuse the request.
  @impl GenServer
  def handle_continue(:start, state = %__MODULE__{timeout: nil}),
    do: {:noreply, start_stream(state)}

  def handle_continue(:start, state = %__MODULE__{timeout: timeout}) do
    {:noreply, start_stream(%{state | timeout: nil}), timeout}
  end

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

  ## messages from the current worker. Anything tagged with an old ref is stale

  @impl GenServer
  def handle_info({ref, :data, chunk}, state = %__MODULE__{ref: ref, buffer: buffer}) do
    {events, buffer} = Parser.feed(buffer, chunk)
    deliver(events, %{(state |> connected() |> watchdog()) | buffer: buffer})
  end

  def handle_info(
        {ref, :done, %Req.Response{status: 200, body: body}},
        state = %__MODULE__{ref: ref}
      ) do
    events =
      case state.query.feed do
        :continuous -> Parser.flush(state.buffer)
        _batch -> Parser.batch(body)
      end

    case deliver(events, %{connected(state) | buffer: ""}) do
      {:noreply, state} -> {:noreply, ended(state)}
      {:noreply, state, timeout} -> {:noreply, ended(state), timeout}
      stop -> stop
    end
  end

  # a 400 usually means the advanced `since` is one the server no longer
  # knows. Fall back once to the last one it accepted, otherwise stop
  def handle_info(
        {ref, :done, %Req.Response{status: 400, body: body}},
        state = %__MODULE__{ref: ref}
      ) do
    case state do
      %__MODULE__{lkg: lkg, query: query} when lkg != nil ->
        Logger.warning(
          "#{inspect(state.module)}: _changes rejected since #{inspect(query.since)}, " <>
            "retrying from #{inspect(lkg)}"
        )

        state = %{state | query: Query.since(query, lkg), lkg: nil, fallback: lkg}
        {:noreply, state |> stop_stream() |> schedule(0)}

      _ ->
        Logger.error("#{inspect(state.module)}: _changes request rejected: #{inspect(body)}")
        {:stop, :bad_request, stop_stream(state)}
    end
  end

  def handle_info({ref, :done, %Req.Response{status: status}}, state = %__MODULE__{ref: ref}) do
    Logger.warning("#{inspect(state.module)}: _changes request failed with HTTP #{status}")
    state |> stop_stream() |> handle_error(reason(status))
  end

  # a connection that timed out or dropped mid-stream is simply reopened
  def handle_info(
        {ref, :error, %Req.TransportError{reason: reason}},
        state = %__MODULE__{ref: ref}
      )
      when reason in [:timeout, :closed] do
    Logger.warning("#{inspect(state.module)}: _changes connection #{reason}, will reconnect")
    {:noreply, state |> stop_stream() |> schedule(0)}
  end

  def handle_info({ref, :error, exception}, state = %__MODULE__{ref: ref}) do
    Logger.warning(
      "#{inspect(state.module)}: _changes request failed: #{Exception.message(exception)}"
    )

    state |> stop_stream() |> handle_error({:conn_failed, reason(exception)})
  end

  def handle_info({:"$sofa_changes", :watchdog, ref}, state = %__MODULE__{ref: ref}) do
    Logger.warning("#{inspect(state.module)}: no heartbeat from _changes, will reconnect")
    {:noreply, state |> stop_stream() |> schedule(0)}
  end

  # workers exit normally after their :done or :error message, or killed by
  # stop_stream/1. Only the current one dying any other way needs a restart
  def handle_info({:EXIT, pid, reason}, state = %__MODULE__{workers: workers})
      when is_map_key(workers, pid) do
    state = %{state | workers: Map.delete(workers, pid)}

    if pid == state.worker and reason != :normal do
      Logger.warning(
        "#{inspect(state.module)}: connection process died, will reconnect: #{inspect(reason)}"
      )

      {:noreply, state |> stop_stream() |> schedule(0)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:"$sofa_changes", :start, ref}, state = %__MODULE__{retry: ref}) do
    {:noreply, start_stream(%{state | retry: nil})}
  end

  def handle_info({:"$sofa_changes", :retry_now}, state = %__MODULE__{retry: :infinity}) do
    {:noreply, start_stream(%{state | retry: nil})}
  end

  def handle_info({:"$sofa_changes", :retry_now}, state = %__MODULE__{}), do: {:noreply, state}

  def handle_info({ref, _tag, _payload}, state = %__MODULE__{}) when is_reference(ref) do
    # from a worker that has since been replaced
    {:noreply, state}
  end

  def handle_info({:"$sofa_changes", _tag, _ref}, state = %__MODULE__{}), do: {:noreply, state}

  def handle_info(msg, state = %__MODULE__{module: module, mstate: mstate}) do
    module.handle_info(msg, mstate) |> noreply(state)
  end

  @impl GenServer
  def terminate(reason, state = %__MODULE__{module: module, mstate: mstate}) do
    _closed = stop_stream(state)
    module.terminate(reason, mstate)
  end

  @impl GenServer
  def code_change(old_vsn, state = %__MODULE__{module: module, mstate: mstate}, extra) do
    case module.code_change(old_vsn, mstate, extra) do
      {:ok, mstate} -> {:ok, %{state | mstate: mstate}}
      other -> other
    end
  end

  ## the stream

  @spec start_stream(t()) :: t()
  defp start_stream(state = %__MODULE__{db: db, query: query}) do
    ref = make_ref()

    Logger.debug(
      "#{inspect(state.module)}: requesting /#{db.database}/_changes since #{inspect(query.since)}"
    )

    worker = Worker.start_link(self(), ref, db, query)
    workers = Map.put(state.workers, worker, true)

    %{state | ref: ref, worker: worker, workers: workers, buffer: "", connected: false}
    |> watchdog()
  end

  # a normal feed is a one-off batch. The others reconnect from the last seq
  @spec ended(t()) :: t()
  defp ended(state = %__MODULE__{query: %Query{feed: :normal}}) do
    Logger.debug("#{inspect(state.module)}: normal feed delivered, not reconnecting")
    stop_stream(state)
  end

  defp ended(state = %__MODULE__{}) do
    Logger.debug("#{inspect(state.module)}: response ended, will reconnect")
    state |> stop_stream() |> schedule(0)
  end

  # (re)arms the watchdog: with a heartbeat, silence for twice its interval
  # means the connection is dead. Without one, the server's timeout applies
  @spec watchdog(t()) :: t()
  defp watchdog(state = %__MODULE__{query: %Query{heartbeat: nil}}), do: state

  defp watchdog(state = %__MODULE__{query: %Query{heartbeat: heartbeat}, ref: ref}) do
    state = cancel_watchdog(state)
    timer = Process.send_after(self(), {:"$sofa_changes", :watchdog, ref}, heartbeat * 2)
    %{state | watchdog: timer}
  end

  @spec cancel_watchdog(t()) :: t()
  defp cancel_watchdog(state = %__MODULE__{watchdog: nil}), do: state

  defp cancel_watchdog(state = %__MODULE__{watchdog: timer}) do
    _remaining = Process.cancel_timer(timer)
    %{state | watchdog: nil}
  end

  # The server accepted this request's `since`, so remember it as the last
  # known good one, unless it is the sequence just fallen back to: that one
  # has already had its retry, and re-arming it would loop forever.
  @spec connected(t()) :: t()
  defp connected(state = %__MODULE__{connected: true}), do: state

  defp connected(state = %__MODULE__{query: %Query{since: since}, fallback: fallback}) do
    lkg = if since != nil and since != fallback, do: since, else: state.lkg
    %{state | connected: true, lkg: lkg}
  end

  # kills the worker, which closes the connection. Its messages become stale,
  # and its exit signal, still linked, prunes it from the workers map
  @spec stop_stream(t()) :: t()
  defp stop_stream(state = %__MODULE__{worker: nil}), do: cancel_watchdog(state)

  defp stop_stream(state = %__MODULE__{worker: worker}) do
    Process.exit(worker, :kill)
    %{cancel_watchdog(state) | worker: nil, ref: nil, buffer: ""}
  end

  # reconnects after `delay` plus jitter, so a fleet of followers staggers
  @spec schedule(t(), non_neg_integer()) :: t()
  defp schedule(state = %__MODULE__{}, delay) do
    ref = make_ref()

    _timer =
      Process.send_after(self(), {:"$sofa_changes", :start, ref}, delay + :rand.uniform(@jitter))

    %{state | retry: ref}
  end

  # hands each event to the callback module, advancing `since` as it goes
  @spec deliver([Parser.event()], t()) ::
          {:noreply, t()} | {:noreply, t(), timeout()} | {:stop, term(), t()}
  defp deliver(events, state = %__MODULE__{}) do
    Enum.reduce_while(events, {:noreply, state}, fn
      {:change, row}, {:noreply, state, _timeout} ->
        change(row, state)

      {:change, row}, {:noreply, state} ->
        change(row, state)

      {:last_seq, seq}, {:noreply, state, timeout} ->
        {:cont, {:noreply, since(state, seq), timeout}}

      {:last_seq, seq}, {:noreply, state} ->
        {:cont, {:noreply, since(state, seq)}}

      {:error, error}, acc ->
        {:cont, log_error(error, acc)}
    end)
  end

  @spec change(Parser.row(), t()) ::
          {:cont, {:noreply, t()} | {:noreply, t(), timeout()}} | {:halt, {:stop, term(), t()}}
  defp change(row, state = %__MODULE__{module: module, mstate: mstate}) do
    state = since(state, row["seq"])

    case module.handle_change(row, mstate) do
      {:ok, mstate} -> {:cont, {:noreply, %{state | mstate: mstate}}}
      {:ok, mstate, timeout} -> {:cont, {:noreply, %{state | mstate: mstate}, timeout}}
      {:stop, reason, mstate} -> {:halt, {:stop, reason, %{state | mstate: mstate}}}
    end
  end

  @spec since(t(), term()) :: t()
  defp since(state = %__MODULE__{query: query, fallback: fallback}, seq) do
    # a newly delivered sequence supersedes the fallback, which may then be re-armed
    fallback = if seq == fallback, do: fallback, else: nil
    %{state | query: Query.since(query, seq), fallback: fallback}
  end

  defp log_error(%{"error" => error, "reason" => reason}, acc) do
    Logger.warning("Sofa.Changes: error object in feed, skipping: #{error} - #{reason}")
    acc
  end

  ## errors

  @spec handle_error(t(), error()) :: {:noreply, t()} | {:stop, term(), t()}
  defp handle_error(state = %__MODULE__{module: module, mstate: mstate}, error) do
    case module.handle_error(error, mstate) do
      {:retry, mstate} ->
        {:noreply, schedule(%{state | mstate: mstate}, 0)}

      {:retry, :infinity, mstate} ->
        {:noreply, %{state | mstate: mstate, retry: :infinity}}

      {:retry, wait, mstate} when is_integer(wait) ->
        {:noreply, schedule(%{state | mstate: mstate}, wait)}

      {:stop, reason, mstate} ->
        {:stop, reason, %{state | mstate: mstate}}
    end
  end

  @spec reason(pos_integer() | Exception.t()) :: error() | term()
  defp reason(401), do: :unauthorized
  defp reason(403), do: :forbidden
  defp reason(404), do: :not_found
  defp reason(500), do: :internal_server_error
  defp reason(status) when is_integer(status), do: {:status_code, status}
  defp reason(%{reason: reason}), do: reason
  defp reason(exception), do: exception

  # wraps the callback module's state back into ours for noreply-style replies
  @spec noreply(term(), t()) ::
          {:noreply, t()} | {:noreply, t(), timeout()} | {:stop, term(), t()}
  defp noreply({:noreply, mstate}, state), do: {:noreply, %{state | mstate: mstate}}

  defp noreply({:noreply, mstate, timeout}, state),
    do: {:noreply, %{state | mstate: mstate}, timeout}

  defp noreply({:stop, reason, mstate}, state), do: {:stop, reason, %{state | mstate: mstate}}
end
