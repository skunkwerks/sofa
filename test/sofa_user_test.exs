defmodule SofaUserTest do
  use ExUnit.Case, async: true

  @plain_url "http://localhost:5984/"
  @plain_sofa Sofa.init(@plain_url) |> Sofa.client()
  @user_password "nommy:passwd"
  @user_url "http://" <> @user_password <> "@localhost:5984/"
  @user_sofa Sofa.init(@user_url) |> Sofa.client()

  import Tesla.Mock

  setup do
    mock(fn
      # required for Sofa.connect!/1 in all tests
      %{method: :get, url: @plain_url} ->
        %Tesla.Env{status: 200, body: fixture("init_200.json")}

      # fake a DB so we can open!/2 it
      %{method: :get, url: @plain_url <> "_users"} ->
        %Tesla.Env{method: :get, status: 200, body: fixture("get_db_200.json")}

      %{method: :head, url: @plain_url <> "_users"} ->
        %Tesla.Env{method: :head, status: 200, body: ""}

        # actual doc tests start here
        # https://docs.couchdb.org/en/stable/api/document/common.html
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
  # GET doc
  # test "GET /_users/missing returns {:error, :not_found}" do
  #   response =
  #     Sofa.connect!(@plain_sofa)
  #     |> Sofa.DB.open!("_users")
  #     |> Sofa.User.get("missing")

  #   assert {:error, :not_found} = response
  # end

  # test "GET /_users/nommy returns %Sofa.Doc{} struct" do
  #   expected = fixture("get_doc_200.json") |> Sofa.Doc.from_map()

  #   response =
  #     Sofa.connect!(@user_sofa)
  #     |> Sofa.DB.open!("_users")
  #     |> Sofa.User.get("nommy")

  #   assert Map.equal?(expected, response)
  # end

  # test "PUT /_users/new returns 201 Created and updated doc" do
  #   new = Sofa.Doc.from_map(%{"_id" => "new", "shiny" => true})

  #   response =
  #     Sofa.connect!(@plain_sofa)
  #     |> Sofa.DB.open!("_users")
  #     |> Sofa.Doc.put(new)

  #   assert {:ok, %Sofa.Doc{id: "new", rev: "1-leet"}} = response
  # end

  # test "PUT /_users/underscore returns 400 Bad Request" do
  #   expected = fixture("put_doc_400.json")

  #   invalid = Sofa.Doc.from_map(%{"_id" => "underscore", "_invalid" => true})

  #   response =
  #     Sofa.connect!(@plain_sofa)
  #     |> Sofa.DB.open!("_users")
  #     |> Sofa.Doc.put(invalid)

  #   assert {:error, :bad_request} = response
  # end

  # test "PUT /_users/denied returns 401 Unauthorized" do
  #   expected = fixture("put_doc_401.json")

  #   denied = Sofa.Doc.new("denied")

  #   response =
  #     Sofa.connect!(@plain_sofa)
  #     |> Sofa.DB.open!("_users")
  #     |> Sofa.Doc.put(denied)

  #   assert {:error, :unauthorized} = response
  # end

  # test "PUT /_users/invalid_user_doc returns 403 Forbidden" do
  #   expected = fixture("put_doc_403.json")

  #   invalid = Sofa.Doc.new("invalid_user_doc")

  #   response =
  #     Sofa.connect!(@plain_sofa)
  #     |> Sofa.DB.open!("_users")
  #     |> Sofa.Doc.put(invalid)

  #   assert {:error, :forbidden} = response
  # end

  # test "PUT /_users/wrong_rev returns 409 Conflict" do
  #   expected = fixture("put_doc_409.json")

  #   wrong_rev =
  #     Sofa.Doc.from_map(%{"_id" => "wrong_rev", "shiny" => true}) |> Map.put(:rev, "1-badcafe")

  #   response =
  #     Sofa.connect!(@plain_sofa)
  #     |> Sofa.DB.open!("_users")
  #     |> Sofa.Doc.put(wrong_rev)

  #   assert {:error, :conflict} = response
  # end

  ## helper function tests
  test "passwords are generated with requested length" do
    length = :crypto.rand_uniform(16, 64)
    assert length == String.length(Sofa.User.generate_random_secret(length))
  end

  test "docs round trip cleanly from map->struct->map again" do
    ["get_doc_200.json", "get_doc_with_attachment_stubs_200.json"]
    |> Enum.map(fn t -> assert round_trip(fixture(t)) end)
  end

  defp round_trip(m),
    do:
      Map.equal?(
        m,
        m
        |> Sofa.Doc.from_map()
        |> Sofa.Doc.to_map()
        |> Sofa.Doc.from_map()
        |> Sofa.Doc.to_map()
      )

  defp fixture(f), do: File.read!("test/fixtures/" <> f) |> Jason.decode!()
end
