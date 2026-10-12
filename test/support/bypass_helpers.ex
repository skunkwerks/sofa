defmodule Sofa.BypassHelpers do
  @moduledoc """
  Shared helpers for unit tests that stand up a fake CouchDB with Bypass.
  Fixtures in `test/fixtures` are real CouchDB responses, served verbatim.
  """

  import Plug.Conn

  @fixtures "test/fixtures/"
  @admin "admin:passwd"

  @doc "A fresh Bypass server plus a client pointed at it, for use in `setup`"
  @spec start(String.t() | nil) :: %{bypass: Bypass.t(), sofa: Sofa.t(), url: String.t()}
  def start(userinfo \\ nil) do
    bypass = Bypass.open()
    url = "http://" <> if(userinfo, do: userinfo <> "@", else: "") <> "127.0.0.1:#{bypass.port}/"
    %{bypass: bypass, sofa: Sofa.init(url) |> Sofa.client(), url: url}
  end

  @doc "Admin credentials matching the CouchDB integration setup"
  @spec admin() :: String.t()
  def admin, do: @admin

  @doc "Decoded JSON fixture, for asserting against"
  @spec fixture(String.t()) :: map() | list()
  def fixture(f), do: File.read!(@fixtures <> f) |> Jason.decode!()

  @doc "Respond with a JSON fixture and the given status"
  @spec json(Plug.Conn.t(), non_neg_integer(), String.t()) :: Plug.Conn.t()
  def json(conn, status, f) do
    conn
    |> put_resp_content_type("application/json")
    |> resp(status, File.read!(@fixtures <> f))
  end

  @doc "Respond with an empty body, as CouchDB does for HEAD requests"
  @spec empty(Plug.Conn.t(), non_neg_integer()) :: Plug.Conn.t()
  def empty(conn, status), do: resp(conn, status, "")

  @doc "True when the request carries basic auth for the given `user:password`"
  @spec basic_auth?(Plug.Conn.t(), String.t()) :: boolean()
  def basic_auth?(conn, userinfo) do
    get_req_header(conn, "authorization") == ["Basic " <> Base.encode64(userinfo)]
  end

  @doc "True when the request carries no authorization header at all"
  @spec anonymous?(Plug.Conn.t()) :: boolean()
  def anonymous?(conn), do: get_req_header(conn, "authorization") == []

  @doc "The decoded JSON request body"
  @spec json_body(Plug.Conn.t()) :: {Plug.Conn.t(), map()}
  def json_body(conn) do
    {:ok, body, conn} = read_body(conn)
    {conn, Jason.decode!(body)}
  end
end
