defmodule SofaTest do
  use ExUnit.Case, async: true

  import Sofa.BypassHelpers

  setup do
    %{bypass: bypass} = plain = start()
    admin = start(admin())

    # the same fake CouchDB answers both the anonymous and the admin client
    for b <- [bypass, admin.bypass] do
      Bypass.stub(b, "GET", "/", &json(&1, 200, "init_200.json"))
      Bypass.stub(b, "GET", "/_up", &json(&1, 200, "up_200.json"))

      Bypass.stub(b, "GET", "/_active_tasks", fn conn ->
        true = anonymous?(conn)
        json(conn, 401, "active_tasks_401.json")
      end)

      Bypass.stub(b, "GET", "/_all_dbs", fn conn ->
        if basic_auth?(conn, admin()),
          do: json(conn, 200, "all_dbs_200.json"),
          else: json(conn, 401, "active_tasks_401.json")
      end)
    end

    # a non-JSON body, for the raw Req options
    Bypass.stub(bypass, "GET", "/plain", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.resp(200, "eels")
    end)

    %{plain: plain.sofa, admin: admin.sofa, url: plain.url, bypass: bypass}
  end

  test "init returns expected struct" do
    assert Sofa.init() == %Sofa{
             auth: "admin:passwd",
             features: nil,
             uri: %URI{
               authority: "admin:passwd@localhost:5984",
               fragment: nil,
               host: "localhost",
               path: "/",
               port: 5984,
               query: nil,
               scheme: "http",
               userinfo: "admin:passwd"
             },
             uuid: nil,
             vendor: nil,
             version: nil
           }
  end

  test "auth_info/1 splits userinfo into credentials, or gives none" do
    assert Sofa.auth_info("admin:password") == %{username: "admin", password: "password"}
    assert Sofa.auth_info("blank:") == %{username: "blank", password: ""}
    assert Sofa.auth_info("with:colon:inside") == %{username: "with", password: "colon:inside"}
    assert Sofa.auth_info("garbage") == %{}
    assert Sofa.auth_info(":nouser") == %{}
    assert Sofa.auth_info(nil) == %{}
  end

  test "client/2 omits basic auth when no credentials are supplied", %{plain: plain} do
    refute Map.has_key?(plain.client.options, :auth)
    assert plain.client.options[:retry] == false
    assert plain.client.options[:inet6] == true
  end

  test "client/2 includes basic auth when credentials are supplied", %{admin: admin} do
    assert admin.client.options[:auth] == {:basic, "admin:passwd"}
  end

  test "client/2 accepts Req options which override the defaults" do
    sofa = Sofa.init() |> Sofa.client(receive_timeout: 1, retry: :transient)
    assert sofa.client.options[:receive_timeout] == 1
    assert sofa.client.options[:retry] == :transient
  end

  test "connect accepts plain URI and returns %Sofa{}", %{url: url} do
    assert Sofa.connect!(url) |> is_struct(Sofa)
  end

  test "returns valid updated %Sofa{} on GET / 200 OK", %{url: url} do
    expected = fixture("init_200.json")
    sofa = Sofa.connect!(url)
    assert is_struct(sofa, Sofa)
    assert expected["version"] == sofa.version
    assert expected["uuid"] == sofa.uuid
    assert is_list(expected["features"])
  end

  test "GET /_up returns 200 OK and %Sofa.Response{}", %{plain: plain, url: url} do
    expected = fixture("up_200.json")
    response = Sofa.connect!(plain) |> Sofa.raw!("_up")
    assert %Sofa.Response{method: :get, status: 200, url: ^url <> "_up"} = response
    assert response.body == expected
    assert response.headers.content_type =~ "application/json"
  end

  test "GET /_active_tasks without credentials returns 401 Unauthorized", %{plain: plain} do
    expected = fixture("active_tasks_401.json")
    response = Sofa.connect!(plain) |> Sofa.raw("_active_tasks")

    assert {:error,
            %Sofa.Response{
              method: :get,
              status: 401,
              body: ^expected
            }} = response
  end

  test "GET /_all_dbs with admin credentials returns 200 OK", %{admin: admin} do
    expected = fixture("all_dbs_200.json")
    response = Sofa.connect!(admin) |> Sofa.raw("_all_dbs")

    assert {:ok, %Sofa{},
            %Sofa.Response{
              method: :get,
              status: 200,
              body: ^expected
            }} = response
  end

  test "all_dbs/1 returns {:ok, list} with admin credentials", %{admin: admin} do
    expected = fixture("all_dbs_200.json")
    assert {:ok, ^expected} = Sofa.connect!(admin) |> Sofa.all_dbs()
  end

  test "all_dbs/1 is refused without credentials", %{plain: plain} do
    assert {:error, %Sofa.Response{status: 401}} = Sofa.connect!(plain) |> Sofa.all_dbs()
  end

  test "active_tasks/1 requests /_active_tasks", %{plain: plain} do
    expected = fixture("active_tasks_401.json")

    assert {:error, %Sofa.Response{status: 401, body: ^expected}} =
             Sofa.connect!(plain) |> Sofa.active_tasks()
  end

  test "raw/7 passes Req options through, such as raw: true and into:", %{plain: plain} do
    sofa = Sofa.connect!(plain)

    assert {:ok, _, %Sofa.Response{body: "eels", headers: %{content_type: "text/plain" <> _}}} =
             Sofa.raw(sofa, "plain", :get, [], "", [], raw: true)

    # JSON stays bytes with raw: true, and is decoded without it
    assert {:ok, _, %Sofa.Response{body: "{" <> _}} =
             Sofa.raw(sofa, "_up", :get, [], "", [], raw: true)

    assert {:ok, _, %Sofa.Response{body: %{"status" => _}}} = Sofa.raw(sofa, "_up")

    collect = fn {:data, data}, {req, resp} ->
      {:cont, {req, %{resp | body: resp.body <> data}}}
    end

    assert {:ok, _, %Sofa.Response{body: "eels"}} =
             Sofa.raw(sofa, "plain", :get, [], "", [], into: collect)
  end

  test "raw/2 returns {:error, reason} on transport errors", %{plain: plain, bypass: bypass} do
    sofa = Sofa.connect!(plain)
    Bypass.down(bypass)
    assert {:error, %Req.TransportError{reason: :econnrefused}} = Sofa.raw(sofa, "_down")
  end

  test "raw!/2 raises Sofa.Error on transport errors", %{plain: plain, bypass: bypass} do
    sofa = Sofa.connect!(plain)
    Bypass.down(bypass)

    assert_raise Sofa.Error, ~r/unhandled error in get _down/, fn ->
      Sofa.raw!(sofa, "_down")
    end
  end

  test "connect!/1 raises Sofa.Error on connection refused", %{url: url, bypass: bypass} do
    Bypass.down(bypass)
    assert_raise Sofa.Error, ~r/connection refused to 127.0.0.1/, fn -> Sofa.connect!(url) end
  end
end
