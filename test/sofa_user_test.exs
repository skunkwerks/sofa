defmodule SofaUserTest do
  use ExUnit.Case, async: true

  import Sofa.BypassHelpers

  setup do
    %{bypass: bypass, sofa: sofa} = start()

    # required for Sofa.connect!/1 and Sofa.DB.open!/2 in all tests
    Bypass.stub(bypass, "GET", "/", &json(&1, 200, "init_200.json"))
    Bypass.stub(bypass, "GET", "/_users", &json(&1, 200, "get_db_200.json"))
    Bypass.stub(bypass, "HEAD", "/_users", &empty(&1, 200))

    # https://docs.couchdb.org/en/stable/api/document/common.html
    # NB Bypass compiles paths as Plug router patterns, so the `:name` part of
    # a CouchDB user id would become a wildcard. Dispatch on the real path instead
    Bypass.stub(bypass, "GET", "/_users/:user", fn conn ->
      assert conn.request_path == "/_users/org.couchdb.user:dch"
      json(conn, 200, "get_user_200.json")
    end)

    Bypass.stub(bypass, "PUT", "/_users/:user", fn conn ->
      {conn, body} = json_body(conn)

      case conn.request_path do
        "/_users/org.couchdb.user:dch" ->
          assert %{"_id" => "org.couchdb.user:dch", "type" => "user", "name" => "dch"} = body
          json(conn, 201, "put_user_201.json")

        # a password reset must not carry stale hash fields back to CouchDB
        "/_users/org.couchdb.user:reset" ->
          stale = ["derived_key", "salt", "iterations", "password_scheme"]

          if Map.has_key?(body, "password") and not Enum.any?(stale, &Map.has_key?(body, &1)),
            do: json(conn, 201, "put_user_201.json"),
            else: json(conn, 400, "put_doc_400.json")
      end
    end)

    %{users: Sofa.connect!(sofa) |> Sofa.DB.open!("_users"), sofa: sofa}
  end

  doctest Sofa.User

  test "GET /_users returns 200 OK", %{sofa: sofa} do
    expected = fixture("get_db_200.json")
    response = Sofa.connect!(sofa) |> Sofa.DB.info("_users")

    assert {:ok, %Sofa{},
            %Sofa.Response{
              method: :get,
              status: 200,
              body: ^expected
            }} = response
  end

  ## actual User tests
  # PUT user
  test "PUT /_users/org.couchdb.user:dch returns 201 Created & updated doc", %{users: users} do
    user = Sofa.User.new("dch", "orange", ["pointy_hat", "users"])

    assert {:ok,
            %Sofa.Doc{
              attachments: %{},
              body: %{
                "name" => "dch",
                "password" => "orange",
                "roles" => ["pointy_hat", "users"]
              },
              id: "org.couchdb.user:dch",
              rev: "1-296e5d3ca9b27b883afef165c53eab9e",
              type: :user
            }} = Sofa.User.put(users, user)
  end

  # GET user
  test "GET /_users/org.couchdb.user:dch returns 200 OK with correct body", %{users: users} do
    assert Map.equal?(Sofa.User.get(users, "dch"), %Sofa.Doc{
             attachments: nil,
             body: %{
               "derived_key" => "36aa712d1e64c356feefca0e75f915d5b917a8f5",
               "iterations" => 20_000,
               "name" => "dch",
               "password_scheme" => "pbkdf2",
               "roles" => ["pointy_hat", "users"],
               "salt" => "1bde3b313a02cb8dac1c83e61e0e13e6"
             },
             id: "org.couchdb.user:dch",
             rev: "1-296e5d3ca9b27b883afef165c53eab9e",
             type: :user
           })
  end

  test ":user type is correctly converted to `user` JSON string" do
    doc = Sofa.User.new("jabberwocky")
    map = Sofa.Doc.to_map(doc)

    assert map["type"] == "user"
  end

  test ":user type round-trips through JSON correctly" do
    doc = Sofa.User.new("jabberwocky")
    map = Sofa.Doc.to_map(doc)

    assert Map.equal?(doc, Sofa.Doc.from_map(map))
  end

  test "password field is removed & converted to salted hashed form on GET after PUT",
       %{users: users} do
    response = Sofa.User.get(users, "dch")

    assert !Map.has_key?(response.body, "password")
    assert Map.get(response.body, "password_scheme") == "pbkdf2"
    assert is_integer(Map.get(response.body, "iterations"))
  end

  test "reset_password/2 stores the new password under a string key" do
    doc = Sofa.User.new("reset", "old") |> Sofa.User.reset_password("new")

    assert doc.body["password"] == "new"
    refute Map.has_key?(doc.body, :password)
  end

  test "reset_password/2 followed by put/2 strips stale password hash fields", %{users: users} do
    doc = Sofa.User.get(users, "dch")

    # pretend the fetched user was "reset" so the stub can validate the body
    reset =
      %Sofa.Doc{doc | id: "org.couchdb.user:reset", body: %{doc.body | "name" => "reset"}}
      |> Sofa.User.reset_password("fresh")

    assert Map.has_key?(reset.body, "derived_key")
    assert {:ok, %Sofa.Doc{body: body}} = Sofa.User.put(users, reset)

    assert body["password"] == "fresh"
    refute Map.has_key?(body, "derived_key")
    refute Map.has_key?(body, "salt")
  end

  ## helper function tests
  test "passwords are generated with requested length" do
    length = :rand.uniform(48) + 16
    assert length == String.length(Sofa.User.generate_random_secret(length))
  end
end
