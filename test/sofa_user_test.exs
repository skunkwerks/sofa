defmodule SofaUserTest do
  use ExUnit.Case, async: true

  @plain_url "http://localhost:5984/"
  @plain_sofa Sofa.init(@plain_url) |> Sofa.client()

  import Tesla.Mock

  setup do
    mock(fn
      # required for Sofa.connect!/1 in all tests
      %{method: :get, url: @plain_url} ->
        %Tesla.Env{status: 200, body: fixture("init_200.json")}

      # fake _users DB so we can open!/2 it
      %{method: :get, url: @plain_url <> "_users"} ->
        %Tesla.Env{method: :get, status: 200, body: fixture("get_db_200.json")}

      # fake _users DB so we can open!/2 it
      %{method: :head, url: @plain_url <> "_users"} ->
        %Tesla.Env{method: :head, status: 200, body: ""}

      # actual doc tests start here
      # https://docs.couchdb.org/en/stable/api/document/common.html
      %{method: :put, url: @plain_url <> "_users/org.couchdb.user:dch"} ->
        %Tesla.Env{method: :put, status: 201, body: fixture("put_user_201.json")}

      %{method: :get, url: @plain_url <> "_users/org.couchdb.user:dch"} ->
        %Tesla.Env{method: :get, status: 200, body: fixture("get_user_200.json")}
    end)

    :ok
  end

  doctest Sofa.User

  test "GET /_users returns 200 OK" do
    expected = fixture("get_db_200.json")
    response = Sofa.connect!(@plain_sofa) |> Sofa.DB.info("_users")

    assert {:ok, %Sofa{},
            %Sofa.Response{
              method: :get,
              status: 200,
              body: ^expected
            }} = response
  end

  ## actual User tests
  # PUT user
  test "PUT /_users/org.couchdb.user:dch returns 201 Created & updated doc" do
    user = Sofa.User.new("dch", "orange", ["pointy_hat", "users"])

    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("_users")
      |> Sofa.User.put(user)

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
            }} = response
  end

  # GET user
  test "GET /_users/org.couchdb.user:dch returns 200 OK with correct body" do
    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("_users")
      |> Sofa.User.get("dch")

    assert Map.equal?(response, %Sofa.Doc{
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

  test "password field is removed & converted to salted hashed form on GET after PUT" do
    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("_users")
      |> Sofa.User.get("dch")

    assert !Map.has_key?(response.body, "password")
    assert Map.get(response.body, "password_scheme") == "pbkdf2"
    assert is_integer(Map.get(response.body, "iterations"))
  end

  ## helper function tests
  test "passwords are generated with requested length" do
    length = :crypto.rand_uniform(16, 64)
    assert length == String.length(Sofa.User.generate_random_secret(length))
  end

  defp fixture(f), do: File.read!("test/fixtures/" <> f) |> Jason.decode!()
end
