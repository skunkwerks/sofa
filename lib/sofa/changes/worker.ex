defmodule Sofa.Changes.Worker do
  @moduledoc """
  One `_changes` request, run in its own process on behalf of a
  `Sofa.Changes` follower.

  The worker is linked to the follower and reports back with messages
  tagged by the reference it was started with, so a follower can tell a
  stale connection from the current one:

  - `{ref, :data, chunk}` for each chunk of a continuous feed's body,
    sent only when the status is 200
  - `{ref, :done, %Req.Response{}}` once the response ends. For a
    non-continuous feed the body is the decoded JSON batch, for a failed
    request it is the decoded error object
  - `{ref, :error, exception}` when the request could not be made or the
    connection dropped, with a `Req.TransportError`

  The worker then exits with reason `:normal`. Killing it closes the
  connection, which is how a follower stops or restarts a feed.
  """

  alias Sofa.Changes.Query

  @typedoc "A message from the worker to its follower"
  @type message ::
          {reference(), :data, binary()}
          | {reference(), :done, Req.Response.t()}
          | {reference(), :error, Exception.t()}

  @doc """
  Spawns a linked worker that requests `/{db}/_changes` with `query` on
  the database's Req client and reports to `owner` with `ref`.
  """
  @spec start_link(owner :: pid(), reference(), Sofa.t(), Query.t()) :: pid()
  def start_link(owner, ref, db = %Sofa{database: database}, query = %Query{})
      when is_pid(owner) and is_reference(ref) and is_binary(database) do
    spawn_link(fn -> run(owner, ref, db, query) end)
  end

  @doc "The Req request for `query`, without the streaming sink, exposed for inspection."
  @spec request(Sofa.t(), Query.t()) :: Req.Request.t()
  def request(%Sofa{client: client, database: database}, query = %Query{}) do
    Req.merge(
      client,
      [
        url: "/" <> Sofa.Cushion.path([database, "_changes"]),
        method: query.method,
        params: Query.params(query),
        receive_timeout: receive_timeout(query)
      ] ++ if(query.body, do: [json: query.body], else: [])
    )
  end

  @spec run(pid(), reference(), Sofa.t(), Query.t()) :: :ok
  defp run(owner, ref, db, query) do
    request = request(db, query) |> Req.merge(into(query, owner, ref))

    case Req.request(request) do
      {:ok, response} -> send(owner, {ref, :done, response})
      {:error, exception} -> send(owner, {ref, :error, exception})
    end

    :ok
  end

  # a continuous feed streams each chunk to the follower. Anything else is
  # read whole, and so is the error body of a failed continuous request
  @spec into(Query.t(), pid(), reference()) :: keyword()
  defp into(%Query{feed: :continuous}, owner, ref) do
    [
      into: fn
        {:data, data}, {req, resp = %Req.Response{status: 200}} ->
          send(owner, {ref, :data, data})
          {:cont, {req, resp}}

        {:data, data}, {req, resp = %Req.Response{body: body}} ->
          {:cont, {req, %{resp | body: body <> data}}}
      end
    ]
  end

  defp into(%Query{}, _owner, _ref), do: []

  # the server sends a heartbeat or ends the response within these bounds.
  # The follower's own watchdog is stricter, this only catches dead sockets.
  # Query.new/1 refuses a query with neither.
  @spec receive_timeout(Query.t()) :: timeout()
  defp receive_timeout(%Query{heartbeat: nil, timeout: timeout}), do: timeout + 5_000
  defp receive_timeout(%Query{heartbeat: heartbeat}), do: heartbeat * 2 + 5_000
end
