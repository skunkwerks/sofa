defmodule SofaConfigTest do
  @moduledoc "`Sofa.Config` against a Bypass fake of `_node/_local/_config`."

  use ExUnit.Case, async: true

  import Plug.Conn, only: [put_resp_content_type: 2, resp: 3, read_body: 1]
  import Sofa.BypassHelpers, only: [start: 1, start: 0, admin: 0, json: 3, basic_auth?: 2]

  alias Sofa.Config

  setup do
    %{bypass: bypass, sofa: sofa} = start(admin())
    plain = start()
    test = self()

    for b <- [bypass, plain.bypass] do
      Bypass.stub(b, "GET", "/", &json(&1, 200, "init_200.json"))

      Bypass.stub(b, "GET", "/_node/_local/_config", fn conn ->
        if basic_auth?(conn, admin()),
          do:
            conn
            |> put_resp_content_type("application/json")
            |> resp(
              200,
              ~s({"log": {"level": "info", "writer": "stderr"}, "couchdb": {"database_dir": "/var/db/couchdb3"}})
            ),
          else: json(conn, 401, "active_tasks_401.json")
      end)

      Bypass.stub(b, "GET", "/_node/_local/_config/log", fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> resp(200, ~s({"level": "info", "writer": "stderr"}))
      end)

      Bypass.stub(b, "GET", "/_node/_local/_config/log/level", fn conn ->
        conn |> put_resp_content_type("application/json") |> resp(200, ~s("info"))
      end)

      Bypass.stub(
        b,
        "GET",
        "/_node/_local/_config/log/nothing",
        &json(&1, 404, "get_doc_404.json")
      )

      Bypass.stub(b, "PUT", "/_node/_local/_config/log/level", fn conn ->
        {:ok, body, conn} = read_body(conn)
        send(test, {:put, Map.new(conn.req_headers)["content-type"], body})
        conn |> put_resp_content_type("application/json") |> resp(200, ~s("info"))
      end)

      Bypass.stub(b, "DELETE", "/_node/_local/_config/log/level", fn conn ->
        conn |> put_resp_content_type("application/json") |> resp(200, ~s("debug"))
      end)

      Bypass.stub(b, "GET", "/_node/couchdb@other/_config/log/level", fn conn ->
        conn |> put_resp_content_type("application/json") |> resp(200, ~s("warning"))
      end)

      Bypass.stub(b, "POST", "/_node/_local/_config/_reload", fn conn ->
        conn |> put_resp_content_type("application/json") |> resp(200, ~s({"ok": true}))
      end)
    end

    %{server: Sofa.connect!(sofa), plain: Sofa.connect!(plain.sofa)}
  end

  test "all/2 and section/3 read maps, for admins", %{server: server, plain: plain} do
    assert {:ok, %{"log" => %{"level" => "info"}, "couchdb" => %{"database_dir" => _}}} =
             Config.all(server)

    assert {:error, :unauthorized} = Config.all(plain)
    assert {:ok, %{"level" => "info", "writer" => "stderr"}} = Config.section(server, "log")
  end

  test "get/4, put/5 and delete/4 handle single JSON string values", %{server: server} do
    assert {:ok, "info"} = Config.get(server, "log", "level")
    assert {:error, :not_found} = Config.get(server, "log", "nothing")
    assert {:ok, "warning"} = Config.get(server, "log", "level", "couchdb@other")

    assert {:ok, "info"} = Config.put(server, "log", "level", "debug")
    assert_receive {:put, "application/json", ~s("debug")}

    assert {:ok, "debug"} = Config.delete(server, "log", "level")
    assert :ok = Config.reload(server)
  end
end
