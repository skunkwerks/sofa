defmodule SofaDbTest do
  use ExUnit.Case, async: true

  import Sofa.BypassHelpers

  setup do
    %{bypass: bypass} = plain = start()
    admin = start(admin())
    test = self()

    for b <- [bypass, admin.bypass] do
      # required for Sofa.connect!/1 in all tests
      Bypass.stub(b, "GET", "/", &json(&1, 200, "init_200.json"))

      Bypass.stub(b, "GET", "/missing", &json(&1, 404, "get_db_404.json"))
      Bypass.stub(b, "GET", "/exists", &json(&1, 200, "get_db_200.json"))

      Bypass.stub(b, "PUT", "/newdb", fn conn ->
        true = basic_auth?(conn, admin())
        json(conn, 200, "put_db_200.json")
      end)

      Bypass.stub(b, "PUT", "/already", &json(&1, 412, "put_db_412.json"))
      Bypass.stub(b, "HEAD", "/forbidden", &empty(&1, 403))
      Bypass.stub(b, "HEAD", "/missing", &empty(&1, 404))
      Bypass.stub(b, "HEAD", "/exists", &empty(&1, 200))

      Bypass.stub(b, "HEAD", "/secured", fn conn ->
        if basic_auth?(conn, admin()), do: empty(conn, 200), else: empty(conn, 401)
      end)

      Bypass.stub(b, "DELETE", "/trash", &json(&1, 202, "delete_db_202.json"))

      # maintenance, admin only, with CouchDB's JSON content type demand
      for path <- ["/exists/_compact", "/exists/_compact/recipes", "/exists/_view_cleanup"] do
        Bypass.stub(b, "POST", path, fn conn ->
          send(
            test,
            {:maintenance, conn.request_path, Plug.Conn.get_req_header(conn, "content-type")}
          )

          if basic_auth?(conn, admin()),
            do:
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.resp(202, ~s({"ok": true})),
            else: json(conn, 401, "put_doc_401.json")
        end)
      end

      Bypass.stub(b, "GET", "/exists/_revs_limit", fn conn ->
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "1000")
      end)

      Bypass.stub(b, "PUT", "/exists/_revs_limit", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:revs_limit, body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"ok": true}))
      end)

      Bypass.stub(b, "POST", "/exists/_purge", fn conn ->
        {conn, body} = json_body(conn)
        send(test, {:purge, body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          201,
          ~s({"purge_seq": null, "purged": {"c6114c65e295552ab1019e2b046b10e": ["3-c50a32451890a3f1c3e423334cc92de4"]}})
        )
      end)

      Bypass.stub(b, "POST", "/exists/_revs_diff", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          ~s({"190f721ca3411be7aa9477db5f948bbb": {"missing": ["3-bb72a7682290f94a985f7afac8b27137", "5-067a00dff5e02add41819138abb3284d"], "possible_ancestors": ["4-10265e5a26d807a3cfa459cf1a82ef2e"]}})
        )
      end)

      Bypass.stub(b, "POST", "/exists/_missing_revs", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          ~s({"missing_revs": {"c6114c65e295552ab1019e2b046b10e": ["3-b06fcd1c1c9e0ec7c480ee8aa467bf3b"]}})
        )
      end)

      # the documented security object, writable by admins only
      Bypass.stub(b, "GET", "/exists/_security", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          ~s({"admins": {"names": ["superuser"], "roles": ["admins"]}, "members": {"names": ["user1", "user2"], "roles": ["developers"]}})
        )
      end)

      Bypass.stub(b, "GET", "/missing/_security", &json(&1, 404, "get_db_404.json"))

      Bypass.stub(b, "PUT", "/exists/_security", fn conn ->
        {conn, body} = json_body(conn)
        send(test, {:security, body})

        if basic_auth?(conn, admin()),
          do:
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(200, ~s({"ok": true})),
          else: json(conn, 401, "put_doc_401.json")
      end)
    end

    %{plain: plain.sofa, admin: admin.sofa}
  end

  test "GET /missing db returns 404 Not Found", %{plain: plain} do
    expected = fixture("get_db_404.json")
    response = Sofa.connect!(plain) |> Sofa.DB.info("missing")

    assert {:error,
            %Sofa.Response{
              method: :get,
              status: 404,
              body: ^expected
            }} = response
  end

  test "GET /exists returns 200 OK", %{plain: plain} do
    expected = fixture("get_db_200.json")
    response = Sofa.connect!(plain) |> Sofa.DB.info("exists")

    assert {:ok, %Sofa{},
            %Sofa.Response{
              method: :get,
              status: 200,
              body: ^expected
            }} = response
  end

  test "PUT /newdb returns 200 OK", %{admin: admin} do
    expected = fixture("put_db_200.json")
    response = Sofa.connect!(admin) |> Sofa.DB.create("newdb")

    assert {:ok, %Sofa{database: "newdb"},
            %Sofa.Response{
              method: :put,
              status: 200,
              body: ^expected
            }} = response
  end

  test "PUT /already returns 412 File Exists", %{admin: admin} do
    expected = fixture("put_db_412.json")
    response = Sofa.connect!(admin) |> Sofa.DB.create("already")

    assert {:error,
            %Sofa.Response{
              method: :put,
              status: 412,
              body: ^expected
            }} = response
  end

  test "DELETE /trash returns 202 OK", %{admin: admin} do
    expected = fixture("delete_db_202.json")
    response = Sofa.connect!(admin) |> Sofa.DB.delete("trash")

    assert {:ok, %Sofa{},
            %Sofa.Response{
              method: :delete,
              status: 202,
              body: ^expected
            }} = response
  end

  test "HEAD /secured with authentication returns 200 OK", %{admin: admin} do
    assert {:ok, %Sofa{database: "secured"}} = Sofa.connect!(admin) |> Sofa.DB.open("secured")
  end

  test "HEAD /secured without authentication returns 401", %{plain: plain} do
    assert {:error, %Sofa.Response{status: 401}} = Sofa.connect!(plain) |> Sofa.DB.open("secured")
  end

  test "HEAD /forbidden returns 403 Forbidden", %{plain: plain} do
    response = Sofa.connect!(plain) |> Sofa.DB.open("forbidden")

    assert {:error,
            %Sofa.Response{
              method: :head,
              status: 403,
              body: ""
            }} = response
  end

  test "HEAD /missing returns 404 Object Not Found", %{plain: plain} do
    response = Sofa.connect!(plain) |> Sofa.DB.open("missing")

    assert {:error,
            %Sofa.Response{
              method: :head,
              status: 404,
              body: ""
            }} = response
  end

  test "security/1 reads the documented security object", %{plain: plain} do
    db = Sofa.connect!(plain) |> Sofa.DB.open!("exists")

    assert {:ok, security} = Sofa.DB.security(db)

    assert %Sofa.Security{
             admins: %{names: ["superuser"], roles: ["admins"]},
             members: %{names: ["user1", "user2"], roles: ["developers"]}
           } = security

    refute Sofa.Security.empty?(security)

    assert {:error, :not_found} = Sofa.DB.security(%Sofa{db | database: "missing"})
  end

  test "set_security/2 PUTs the object, for admins only", %{plain: plain, admin: admin} do
    security =
      Sofa.Security.new()
      |> Sofa.Security.admin("superuser")
      |> Sofa.Security.member(role: "developers")

    assert :ok = Sofa.connect!(admin) |> Sofa.DB.open!("exists") |> Sofa.DB.set_security(security)

    assert_receive {:security,
                    %{
                      "admins" => %{"names" => ["superuser"], "roles" => []},
                      "members" => %{"names" => [], "roles" => ["developers"]}
                    }}

    assert {:error, :unauthorized} =
             Sofa.connect!(plain) |> Sofa.DB.open!("exists") |> Sofa.DB.set_security(security)
  end

  test "compact/2 and view_cleanup/1 are accepted for admins, with a JSON content type", %{
    plain: plain,
    admin: admin
  } do
    db = Sofa.connect!(admin) |> Sofa.DB.open!("exists")
    assert :ok = Sofa.DB.compact(db)
    assert_receive {:maintenance, "/exists/_compact", ["application/json"]}
    assert :ok = Sofa.DB.compact(db, "recipes")
    assert_receive {:maintenance, "/exists/_compact/recipes", _}
    assert :ok = Sofa.DB.view_cleanup(db)
    assert_receive {:maintenance, "/exists/_view_cleanup", _}

    assert {:error, :unauthorized} =
             Sofa.connect!(plain) |> Sofa.DB.open!("exists") |> Sofa.DB.compact()
  end

  test "revision limits, purge, revs_diff and missing_revs follow the documented shapes", %{
    admin: admin
  } do
    db = Sofa.connect!(admin) |> Sofa.DB.open!("exists")

    assert {:ok, 1000} = Sofa.DB.revs_limit(db)
    assert :ok = Sofa.DB.set_revs_limit(db, 500)
    assert_receive {:revs_limit, "500"}

    revs = %{"c6114c65e295552ab1019e2b046b10e" => ["3-c50a32451890a3f1c3e423334cc92de4"]}
    assert {:ok, %{"purged" => ^revs}} = Sofa.DB.purge(db, revs)
    assert_receive {:purge, ^revs}

    assert {:ok,
            %{
              "190f721ca3411be7aa9477db5f948bbb" => %{
                "missing" => [_, _],
                "possible_ancestors" => [_]
              }
            }} =
             Sofa.DB.revs_diff(db, %{
               "190f721ca3411be7aa9477db5f948bbb" => ["3-bb72a7682290f94a985f7afac8b27137"]
             })

    assert {:ok, %{"c6114c65e295552ab1019e2b046b10e" => ["3-b06fcd1c1c9e0ec7c480ee8aa467bf3b"]}} =
             Sofa.DB.missing_revs(db, %{
               "c6114c65e295552ab1019e2b046b10e" => ["3-b06fcd1c1c9e0ec7c480ee8aa467bf3b"]
             })
  end

  test "open/2 returns %Sofa{database: dbname}", %{plain: plain} do
    assert {:ok, %Sofa{database: "exists"}} = Sofa.connect!(plain) |> Sofa.DB.open("exists")
  end

  test "open!/2 returns %Sofa{database: dbname} or raises", %{plain: plain} do
    sofa = Sofa.connect!(plain)
    assert %Sofa{database: "exists"} = Sofa.DB.open!(sofa, "exists")

    assert_raise Sofa.Error, ~r/unable to open database missing/, fn ->
      Sofa.DB.open!(sofa, "missing")
    end
  end
end
