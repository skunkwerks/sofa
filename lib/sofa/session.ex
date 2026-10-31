defmodule Sofa.Session do
  @moduledoc """
  Cookie sessions, via `_session`: log in once and send a cookie instead
  of credentials on every request.

  > If the only tool you have is CouchDB, then
  > everything looks like `{:ok, :relax}`

  See https://docs.couchdb.org/en/stable/api/server/authn.html. Besides
  sparing the server a password check per request, a session is how to
  avoid CouchDB 3's account lockout after repeated failed logins: one
  `login/3` either succeeds or fails, rather than every request failing.

  ## Examples

      {:ok, sofa} = Sofa.init("http://localhost:5984/") |> Sofa.client() |> Sofa.Session.login("jan", "apple")
      Sofa.Session.info(sofa)
      #=> {:ok, %{name: "jan", roles: ["users"], authenticated: "cookie"}}

      {:ok, sofa} = Sofa.Session.logout(sofa)
  """

  alias Sofa.Response

  @type error :: Response.error() | term()

  @typedoc "Who the server takes the client for, from `GET /_session`"
  @type info :: %{name: String.t() | nil, roles: [String.t()], authenticated: String.t() | nil}

  @doc """
  Logs in with a name and password, and returns the handle with the
  session cookie set on its client and basic auth credentials removed,
  so every further request is authenticated by the cookie.
  """
  @spec login(Sofa.t(), String.t(), String.t()) :: {:ok, Sofa.t()} | {:error, error()}
  def login(sofa = %Sofa{client: client}, name, password)
      when is_binary(name) and is_binary(password) do
    case Sofa.raw(sofa, "_session", :post, [], "", [], form: [name: name, password: password]) do
      {:ok, _sofa, %Response{status: 200, body: %{"ok" => true}, headers: %{set_cookie: cookies}}} ->
        case Enum.find(cookies, &String.starts_with?(&1, "AuthSession=")) do
          nil -> {:error, :no_session_cookie}
          cookie -> {:ok, %Sofa{sofa | client: with_cookie(client, cookie)}}
        end

      other ->
        error(other)
    end
  end

  @doc """
  Who the server takes the client for: the user name (`nil` when
  anonymous), roles, and how it was authenticated (`"cookie"`,
  `"default"` for basic auth, or `nil`).
  """
  @spec info(Sofa.t()) :: {:ok, info()} | {:error, error()}
  def info(sofa = %Sofa{}) do
    case Sofa.raw(sofa, "_session") do
      {:ok, _sofa,
       %Response{status: 200, body: %{"ok" => true, "userCtx" => ctx, "info" => info}}} ->
        {:ok,
         %{name: ctx["name"], roles: ctx["roles"] || [], authenticated: info["authenticated"]}}

      other ->
        error(other)
    end
  end

  @doc """
  Ends the session, and returns the handle without the cookie. As the
  docs note, the server keeps no session state, so this only forgets the
  cookie on the client side.
  """
  @spec logout(Sofa.t()) :: {:ok, Sofa.t()} | {:error, error()}
  def logout(sofa = %Sofa{client: client}) do
    case Sofa.raw(sofa, "_session", :delete) do
      {:ok, _sofa, %Response{status: 200}} -> {:ok, %Sofa{sofa | client: without_cookie(client)}}
      other -> error(other)
    end
  end

  # the AuthSession cookie, without its attributes, replaces basic auth
  @spec with_cookie(Req.Request.t(), String.t()) :: Req.Request.t()
  defp with_cookie(client, cookie) do
    [pair | _attributes] = String.split(cookie, ";")

    client
    |> Req.Request.delete_option(:auth)
    |> Req.Request.put_header("cookie", String.trim(pair))
  end

  @spec without_cookie(Req.Request.t()) :: Req.Request.t()
  defp without_cookie(client), do: Req.Request.delete_header(client, "cookie")

  @spec error({:ok, Sofa.t(), Response.t()} | {:error, term()}) :: {:error, error()}
  defp error({:ok, _sofa, response = %Response{}}), do: {:error, Response.error(response)}
  defp error({:error, response = %Response{}}), do: {:error, Response.error(response)}
  defp error({:error, reason}), do: {:error, reason}
end
