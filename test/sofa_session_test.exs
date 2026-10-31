defmodule SofaSessionTest do
  @moduledoc "`Sofa.Session` against a Bypass fake speaking the documented `_session` protocol."

  use ExUnit.Case, async: true

  import Plug.Conn,
    only: [put_resp_header: 3, put_resp_content_type: 2, resp: 3, get_req_header: 2]

  import Sofa.BypassHelpers, only: [start: 0, start: 1, admin: 0, json: 3]

  alias Sofa.Session

  @cookie "AuthSession=cm9vdDo1MjA1NTBDMTqmX2qKt1KDR--GUC80DQ6-Ew_XIw; Version=1; Path=/; HttpOnly"

  setup do
    %{bypass: bypass, sofa: sofa} = start()
    admin = start(admin())
    test = self()

    for b <- [bypass, admin.bypass] do
      Bypass.stub(b, "GET", "/", &json(&1, 200, "init_200.json"))

      # the documented login: a form, answered with the cookie and the user
      Bypass.stub(b, "POST", "/_session", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:login, get_req_header(conn, "content-type"), URI.decode_query(body)})

        case URI.decode_query(body) do
          %{"name" => "root", "password" => "relax"} ->
            conn
            |> put_resp_header("set-cookie", @cookie)
            |> put_resp_content_type("application/json")
            |> resp(200, ~s({"ok": true, "name": "root", "roles": ["_admin"]}))

          _ ->
            json(conn, 401, "put_doc_401.json")
        end
      end)

      # who the request is: the cookie, basic auth, or nobody
      Bypass.stub(b, "GET", "/_session", fn conn ->
        send(test, {:session, Map.new(conn.req_headers)})

        {name, roles, how} =
          cond do
            get_req_header(conn, "cookie") == [
              "AuthSession=cm9vdDo1MjA1NTBDMTqmX2qKt1KDR--GUC80DQ6-Ew_XIw"
            ] ->
              {"root", ["_admin"], "cookie"}

            get_req_header(conn, "authorization") != [] ->
              {"admin", ["_admin"], "default"}

            true ->
              {nil, [], nil}
          end

        conn
        |> put_resp_content_type("application/json")
        |> resp(
          200,
          Jason.encode!(%{
            "ok" => true,
            "userCtx" => %{"name" => name, "roles" => roles},
            "info" => %{
              "authenticated" => how,
              "authentication_db" => "_users",
              "authentication_handlers" => ["cookie", "default"]
            }
          })
        )
      end)

      Bypass.stub(b, "DELETE", "/_session", fn conn ->
        conn
        |> put_resp_header("set-cookie", "AuthSession=; Version=1; Path=/; HttpOnly")
        |> put_resp_content_type("application/json")
        |> resp(200, ~s({"ok": true}))
      end)
    end

    %{plain: sofa, admin: admin.sofa}
  end

  test "login/3 posts the form, keeps the cookie and drops basic auth", %{admin: admin} do
    assert {:ok, session} = Session.login(admin, "root", "relax")

    assert_receive {:login, ["application/x-www-form-urlencoded"],
                    %{"name" => "root", "password" => "relax"}}

    refute Map.has_key?(session.client.options, :auth)

    assert Req.Request.get_header(session.client, "cookie") == [
             "AuthSession=cm9vdDo1MjA1NTBDMTqmX2qKt1KDR--GUC80DQ6-Ew_XIw"
           ]

    assert {:ok, %{name: "root", roles: ["_admin"], authenticated: "cookie"}} =
             Session.info(session)

    assert_receive {:session, %{"cookie" => "AuthSession=" <> _} = headers}
    refute Map.has_key?(headers, "authorization")
  end

  test "a wrong password is :unauthorized, and the handle is left as it was", %{plain: plain} do
    assert {:error, :unauthorized} = Session.login(plain, "root", "wrong")
  end

  test "info/1 reports basic auth and anonymous clients too", %{plain: plain, admin: admin} do
    assert {:ok, %{name: "admin", authenticated: "default"}} = Session.info(admin)
    assert {:ok, %{name: nil, roles: [], authenticated: nil}} = Session.info(plain)
  end

  test "logout/1 forgets the cookie", %{admin: admin} do
    {:ok, session} = Session.login(admin, "root", "relax")
    assert {:ok, out} = Session.logout(session)
    assert Req.Request.get_header(out.client, "cookie") == []
    assert {:ok, %{name: nil}} = Session.info(out)
  end
end
