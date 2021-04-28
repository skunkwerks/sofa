defmodule SofaDocTest do
  use ExUnit.Case, async: true

  @plain_url "http://localhost:5984/"
  @plain_sofa Sofa.init(@plain_url) |> Sofa.client()
  @admin_password "admin:passwd"
  @admin_url "http://" <> @admin_password <> "@localhost:5984/"
  @admin_sofa Sofa.init(@admin_url) |> Sofa.client()
  @etag_header {"ETag", ~s("1-leet")}
  @ifmatch_header {"If-Match", ~s("1-leet")}

  import Tesla.Mock

  setup do
    mock(fn
      # required for Sofa.connect!/1 in all tests
      %{method: :get, url: @plain_url} ->
        %Tesla.Env{status: 200, body: fixture("init_200.json")}

      # fake a DB so we can open!/2 it
      %{method: :get, url: @plain_url <> "mydb"} ->
        %Tesla.Env{method: :get, status: 200, body: fixture("get_db_200.json")}

      %{method: :head, url: @plain_url <> "mydb"} ->
        %Tesla.Env{method: :head, status: 200, body: ""}

      # actual doc tests start here
      # https://docs.couchdb.org/en/stable/api/document/common.html

      # HEAD doc
      %{method: :head, url: @plain_url <> "mydb/missing"} ->
        %Tesla.Env{method: :head, status: 404, body: ""}

      %{method: :head, url: @plain_url <> "mydb/exists"} ->
        %Tesla.Env{method: :head, status: 200, headers: [@etag_header]}

      # GET doc
      %{method: :get, url: @plain_url <> "mydb/missing"} ->
        %Tesla.Env{method: :get, status: 404, body: ""}

      %{method: :get, url: @plain_url <> "mydb/exists"} ->
        %Tesla.Env{method: :get, status: 200, body: fixture("get_doc_200.json")}

      # DELETE doc
      %{method: :delete, url: @plain_url <> "mydb/missing"} ->
        %Tesla.Env{
          method: :delete,
          status: 404,
          headers: [@ifmatch_header],
          body: fixture("delete_doc_404.json")
        }

      %{method: :delete, url: @plain_url <> "mydb/wrong_rev"} ->
        %Tesla.Env{
          method: :delete,
          status: 409,
          headers: [],
          body: fixture("delete_doc_409.json")
        }

      %{method: :delete, url: @plain_url <> "mydb/exists"} ->
        %Tesla.Env{
          method: :delete,
          status: 200,
          headers: [@ifmatch_header],
          body: fixture("delete_doc_200.json")
        }

      # PUT doc
      %{method: :put, url: @plain_url <> "mydb/new"} ->
        %Tesla.Env{
          method: :put,
          status: 201,
          body: fixture("put_doc_201.json")
        }

      %{method: :put, url: @plain_url <> "mydb/underscore"} ->
        %Tesla.Env{
          method: :put,
          status: 400,
          body: fixture("put_doc_400.json")
        }

      %{method: :put, url: @plain_url <> "mydb/denied"} ->
        %Tesla.Env{
          method: :put,
          status: 401,
          body: fixture("put_doc_401.json")
        }

      %{method: :put, url: @plain_url <> "mydb/invalid_user_doc"} ->
        %Tesla.Env{
          method: :put,
          status: 403,
          body: fixture("put_doc_403.json")
        }

      %{method: :put, url: @plain_url <> "mydb/wrong_rev"} ->
        %Tesla.Env{
          method: :put,
          status: 409,
          headers: [@ifmatch_header],
          body: fixture("put_doc_409.json")
        }
    end)

    :ok
  end

  test "GET /mydb returns 200 OK" do
    expected = fixture("get_db_200.json")
    response = Sofa.connect!(@plain_sofa) |> Sofa.DB.info("mydb")

    assert {:ok, %Sofa{},
            %Sofa.Response{
              method: :get,
              status: 200,
              body: ^expected
            }} = response
  end

  test "HEAD /mydb/missing returns :false" do
    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.exists?("missing")

    assert !response
  end

  test "HEAD /mydb/exists returns 200 OK" do
    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.exists?("exists")

    assert response
  end

  # DELETE doc
  # https://docs.couchdb.org/en/stable/api/document/common.html
  test "DELETE /mydb/missing returns 404 Not Found" do
    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.delete!("missing")

    assert {:error, :not_found} = response
  end

  test "DELETE /mydb/wrong_rev returns 409 Conflict" do
    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.delete!("wrong_rev")

    assert {:error, :conflict} = response
  end

  test "DELETE /mydb/exists returns 200 OK" do
    expected = fixture("delete_doc_200.json")

    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.delete!("exists")

    assert :ok = response
  end

  # GET doc
  @tag :wip
  test "GET /mydb/missing returns {:error, :not_found}" do
    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.get("missing")

    assert {:error, :not_found} = response
  end

  test "GET /mydb/exists returns %Sofa.Doc{} struct" do
    expected = fixture("get_doc_200.json") |> Sofa.Doc.from_map()

    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.get("exists")

    assert Map.equal?(expected, response)
  end

  test "PUT /mydb/new returns 201 Created and updated doc" do
    new = Sofa.Doc.from_map(%{"_id" => "new", "shiny" => true})

    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.put(new)

    assert {:ok, %Sofa.Doc{id: "new", rev: "1-leet"}} = response
  end

  test "PUT /mydb/underscore returns 400 Bad Request" do
    expected = fixture("put_doc_400.json")

    invalid = Sofa.Doc.from_map(%{"_id" => "underscore", "_invalid" => true})

    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.put(invalid)

    assert {:error, :bad_request} = response
  end

  test "PUT /mydb/denied returns 401 Unauthorized" do
    expected = fixture("put_doc_401.json")

    denied = Sofa.Doc.new("denied")

    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.put(denied)

    assert {:error, :unauthorized} = response
  end

  test "PUT /mydb/invalid_user_doc returns 403 Forbidden" do
    expected = fixture("put_doc_403.json")

    invalid = Sofa.Doc.new("invalid_user_doc")

    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.put(invalid)

    assert {:error, :forbidden} = response
  end

  test "PUT /mydb/wrong_rev returns 409 Conflict" do
    expected = fixture("put_doc_409.json")

    wrong_rev =
      Sofa.Doc.from_map(%{"_id" => "wrong_rev", "shiny" => true}) |> Map.put(:rev, "1-badcafe")

    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.put(wrong_rev)

    assert {:error, :conflict} = response
  end

  test "from_map doesn't leak forbidden keys into doc.body" do
    bad_keys = ["_rev", "_attachments", :_id, :_rev, :_attachments]
    good_map = %{"_id" => "toasty", "key" => "important"}

    pruned_map =
      Enum.reduce(bad_keys, good_map, fn x, a -> Map.put(a, x, "blah") end)
      |> Sofa.Doc.from_map()
      |> Map.from_struct()

    assert Map.equal?(pruned_map, %{
             attachments: "blah",
             body: %{"key" => "important"},
             id: "toasty",
             rev: "blah",
             type: nil
           })
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
