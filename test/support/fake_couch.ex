defmodule Sofa.FakeCouch do
  @moduledoc """
  A minimal fake of the CouchDB `GET|POST /{db}/_changes` endpoint built on
  Bypass, for driving a `Sofa.Changes` follower without a real CouchDB.

  It speaks the three wire formats described in the CouchDB documentation:

    * normal / longpoll: one JSON body with `results`, `last_seq`, `pending`
    * continuous: one JSON object per line, empty lines as heartbeats, and
      an optional trailing `{"last_seq": ...}` object

  Every request handled through `report/2` is echoed to the test process as

      {:changes_request, %{method: "GET", query: %{...}, body: "", headers: %{...}}}

  so a test can assert on exactly what the follower sent. A continuous feed
  started with `stream/5` additionally sends `{:feed, handler_pid}`. The
  test then pushes further lines with `push/2` and ends the response with
  `close/1`.
  """

  import Plug.Conn

  defstruct [:bypass, :db]

  @type t :: %__MODULE__{bypass: Bypass.t(), db: Sofa.t()}

  @doc """
  Starts a Bypass instance on a random port and returns it together with a
  `%Sofa{}` database handle pointing at it. No HEAD request is made, so the
  fake only has to implement `_changes`.
  """
  @spec open(keyword()) :: t()
  def open(opts \\ []) do
    bypass = Bypass.open()
    name = Keyword.get(opts, :db, "recipes")

    db =
      Sofa.init("http://127.0.0.1:#{bypass.port}/") |> Sofa.client() |> Map.put(:database, name)

    %__MODULE__{bypass: bypass, db: db}
  end

  @doc "The `/{db}/_changes` path for this fake."
  @spec changes_path(t()) :: String.t()
  def changes_path(%__MODULE__{db: %Sofa{database: name}}), do: "/#{name}/_changes"

  @doc """
  Registers `fun` for the changes endpoint. It must be called at least once
  before the test ends. `method` defaults to `"GET"`.
  """
  @spec expect_changes(t(), String.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def expect_changes(couch, method \\ "GET", fun),
    do: Bypass.expect(couch.bypass, method, changes_path(couch), fun)

  @doc "Like `expect_changes/3` but the handler may be called zero times."
  @spec stub_changes(t(), String.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def stub_changes(couch, method \\ "GET", fun),
    do: Bypass.stub(couch.bypass, method, changes_path(couch), fun)

  @doc """
  Reads the request body and reports method, query, body and headers to
  `pid`. Returns the conn for further handling.
  """
  @spec report(Plug.Conn.t(), pid()) :: Plug.Conn.t()
  def report(conn, pid) do
    {:ok, body, conn} = read_body(conn)
    conn = fetch_query_params(conn)

    send(
      pid,
      {:changes_request,
       %{
         method: conn.method,
         query: conn.query_params,
         body: body,
         headers: Map.new(conn.req_headers)
       }}
    )

    conn
  end

  @doc "Sends a JSON response with the given status."
  @spec json(Plug.Conn.t(), non_neg_integer(), binary() | map()) :: Plug.Conn.t()
  def json(conn, status, body) when is_binary(body) do
    conn
    |> put_resp_content_type("application/json")
    |> resp(status, body)
  end

  def json(conn, status, body), do: json(conn, status, Jason.encode!(body))

  @doc """
  Responds as a normal or longpoll feed does: a single JSON body with
  `results`, `last_seq` and `pending`.
  """
  @spec respond(Plug.Conn.t(), [map()], term(), map()) :: Plug.Conn.t()
  def respond(conn, results, last_seq, extra \\ %{}) do
    body = Map.merge(%{"results" => results, "last_seq" => last_seq, "pending" => 0}, extra)
    json(conn, 200, body)
  end

  @doc "Responds with a CouchDB style error object."
  @spec error(Plug.Conn.t(), non_neg_integer(), String.t(), String.t()) :: Plug.Conn.t()
  def error(conn, status, error, reason),
    do: json(conn, status, %{"error" => error, "reason" => reason})

  @doc """
  Starts a chunked continuous feed, pushes `lines` and then (unless
  `hold: false`) keeps the response open until `close/1` is called or the
  client goes away.

  Each line is a map (encoded as JSON plus newline), `:heartbeat` (an empty
  line) or a raw binary sent as-is, which lets a test split one JSON object
  across chunks.

  Options:

    * `:heartbeat` - milliseconds between automatic heartbeats while held
      open, default 100. `:infinity` sends none.
    * `:hold` - keep the response open after the initial lines, default true.

  Because the follower may drop the connection while the handler is still
  running (restarts, stops), the Bypass instance is marked as passing so a
  handler killed on disconnect is not reported as a failure. Tests assert on
  the reported requests instead.
  """
  @spec stream(Plug.Conn.t(), t(), pid(), [map() | :heartbeat | binary()], keyword()) ::
          Plug.Conn.t()
  def stream(conn, %__MODULE__{bypass: bypass}, pid, lines \\ [], opts \\ []) do
    Bypass.pass(bypass)
    heartbeat = Keyword.get(opts, :heartbeat, 100)
    hold? = Keyword.get(opts, :hold, true)

    conn =
      conn
      |> put_resp_content_type("application/json")
      |> send_chunked(200)

    send(pid, {:feed, self()})

    case push_lines(conn, lines) do
      {:ok, conn} when hold? -> hold(conn, heartbeat)
      {:ok, conn} -> conn
      {:error, conn} -> conn
    end
  end

  @doc "Pushes one or more lines down a feed started with `stream/5`."
  @spec push(pid(), map() | :heartbeat | binary() | list()) :: :ok
  def push(feed, lines) when is_pid(feed) do
    send(feed, {:push, List.wrap(lines)})
    :ok
  end

  @doc "Ends a feed started with `stream/5`, as CouchDB does on `timeout`."
  @spec close(pid()) :: :ok
  def close(feed) when is_pid(feed) do
    send(feed, :close)
    :ok
  end

  defp hold(conn, heartbeat) do
    receive do
      {:push, lines} ->
        case push_lines(conn, lines) do
          {:ok, conn} -> hold(conn, heartbeat)
          {:error, conn} -> conn
        end

      :close ->
        conn
    after
      heartbeat ->
        case push_lines(conn, [:heartbeat]) do
          {:ok, conn} -> hold(conn, heartbeat)
          {:error, conn} -> conn
        end
    end
  end

  defp push_lines(conn, lines) do
    Enum.reduce_while(lines, {:ok, conn}, fn line, {:ok, conn} ->
      case chunk(conn, encode_line(line)) do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, _} -> {:halt, {:error, conn}}
      end
    end)
  end

  defp encode_line(:heartbeat), do: "\n"
  defp encode_line(raw) when is_binary(raw), do: raw
  defp encode_line(map) when is_map(map), do: Jason.encode!(map) <> "\n"
end
