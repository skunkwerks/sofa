defmodule SofaDbTest do
  use ExUnit.Case, async: true

  import Sofa.BypassHelpers

  setup do
    %{bypass: bypass} = plain = start()
    admin = start(admin())

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
