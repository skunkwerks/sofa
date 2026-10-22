defmodule SofaDocTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [put_resp_header: 3, get_req_header: 2]
  import Sofa.BypassHelpers

  @etag ~s("1-leet")

  setup do
    %{bypass: bypass, sofa: sofa} = start()

    # required for Sofa.connect!/1 and Sofa.DB.open!/2 in all tests
    Bypass.stub(bypass, "GET", "/", &json(&1, 200, "init_200.json"))
    Bypass.stub(bypass, "GET", "/mydb", &json(&1, 200, "get_db_200.json"))
    Bypass.stub(bypass, "HEAD", "/mydb", &empty(&1, 200))

    # actual doc tests start here
    # https://docs.couchdb.org/en/stable/api/document/common.html

    # HEAD doc
    Bypass.stub(bypass, "HEAD", "/mydb/missing", &empty(&1, 404))

    Bypass.stub(bypass, "HEAD", "/mydb/exists", fn conn ->
      conn |> put_resp_header("etag", @etag) |> empty(200)
    end)

    # GET doc, including ids that need URL encoding
    Bypass.stub(bypass, "GET", "/mydb/missing", &json(&1, 404, "get_doc_404.json"))
    # Bypass matches on the raw request path, so register the encoded form
    for path <- ["/mydb/sp%20ace", "/mydb/org.couchdb.user:jan", "/mydb/_design/app"] do
      Bypass.stub(bypass, "HEAD", path, fn conn ->
        conn |> put_resp_header("etag", @etag) |> empty(200)
      end)
    end

    Bypass.stub(bypass, "GET", "/mydb/exists", &json(&1, 200, "get_doc_200.json"))

    # DELETE doc, which must carry the rev as an If-Match header
    Bypass.stub(bypass, "DELETE", "/mydb/missing", fn conn ->
      assert get_req_header(conn, "if-match") == ["stuff"]
      json(conn, 404, "delete_doc_404.json")
    end)

    Bypass.stub(bypass, "DELETE", "/mydb/wrong_rev", &json(&1, 409, "delete_doc_409.json"))
    Bypass.stub(bypass, "DELETE", "/mydb/denied", &json(&1, 401, "put_doc_401.json"))

    Bypass.stub(bypass, "DELETE", "/mydb/exists", fn conn ->
      assert get_req_header(conn, "if-match") == ["stuff"]
      json(conn, 200, "delete_doc_200.json")
    end)

    # PUT doc, which must carry a JSON body with the matching _id
    Bypass.stub(bypass, "PUT", "/mydb/new", fn conn ->
      {conn, body} = json_body(conn)
      assert %{"_id" => "new", "shiny" => true} = body
      refute Map.has_key?(body, "_rev")
      json(conn, 201, "put_doc_201.json")
    end)

    Bypass.stub(bypass, "PUT", "/mydb/underscore", &json(&1, 400, "put_doc_400.json"))
    Bypass.stub(bypass, "PUT", "/mydb/denied", &json(&1, 401, "put_doc_401.json"))
    Bypass.stub(bypass, "PUT", "/mydb/invalid_user_doc", &json(&1, 403, "put_doc_403.json"))

    Bypass.stub(bypass, "PUT", "/mydb/wrong_rev", fn conn ->
      {conn, body} = json_body(conn)
      assert body["_rev"] == "1-badcafe"
      json(conn, 409, "put_doc_409.json")
    end)

    %{db: Sofa.connect!(sofa) |> Sofa.DB.open!("mydb"), sofa: sofa}
  end

  test "GET /mydb returns 200 OK", %{sofa: sofa} do
    expected = fixture("get_db_200.json")
    response = Sofa.connect!(sofa) |> Sofa.DB.info("mydb")

    assert {:ok, %Sofa{},
            %Sofa.Response{
              method: :get,
              status: 200,
              body: ^expected
            }} = response
  end

  test "HEAD /mydb/missing returns :false", %{db: db} do
    refute Sofa.Doc.exists?(db, "missing")
    assert {:error, :not_found} = Sofa.Doc.exists(db, "missing")
  end

  test "HEAD /mydb/exists returns 200 OK with rev from ETag", %{db: db} do
    assert Sofa.Doc.exists?(db, "exists")
    assert {:ok, %Sofa.Doc{id: "exists", rev: "1-leet"}} = Sofa.Doc.exists(db, "exists")
  end

  # DELETE doc
  # https://docs.couchdb.org/en/stable/api/document/common.html
  test "DELETE /mydb/missing returns 404 Not Found", %{db: db} do
    doc = Sofa.Doc.from_map(%{"_id" => "missing", "_rev" => "stuff"})
    assert {:error, :not_found} = Sofa.Doc.delete(db, doc)
  end

  test "DELETE /mydb/wrong_rev returns 409 Conflict", %{db: db} do
    doc = Sofa.Doc.from_map(%{"_id" => "wrong_rev", "_rev" => "wrong_rev"})
    assert {:error, :conflict} = Sofa.Doc.delete(db, doc)
  end

  test "DELETE /mydb/denied returns 401 Unauthorized", %{db: db} do
    doc = Sofa.Doc.from_map(%{"_id" => "denied", "_rev" => "stuff"})
    assert {:error, :unauthorized} = Sofa.Doc.delete(db, doc)
  end

  test "DELETE /mydb/exists returns 200 OK", %{db: db} do
    doc = Sofa.Doc.from_map(%{"_id" => "exists", "_rev" => "stuff"})
    assert :ok = Sofa.Doc.delete(db, doc)
  end

  # GET doc
  test "GET /mydb/missing returns {:error, :not_found}", %{db: db} do
    assert {:error, :not_found} = Sofa.Doc.get(db, "missing")
  end

  test "document ids are URL encoded, keeping _design/ and pchar such as ':'", %{db: db} do
    assert Sofa.Doc.exists?(db, "sp ace")
    assert Sofa.Doc.exists?(db, "_design/app")
    assert Sofa.Doc.exists?(db, "org.couchdb.user:jan")
  end

  test "GET /mydb/exists returns %Sofa.Doc{} struct", %{db: db} do
    expected = fixture("get_doc_200.json") |> Sofa.Doc.from_map()
    assert Map.equal?(expected, Sofa.Doc.get(db, "exists"))
  end

  # PUT doc
  test "PUT /mydb/new returns 201 Created and updated doc", %{db: db} do
    new = Sofa.Doc.from_map(%{"_id" => "new", "shiny" => true})
    assert {:ok, %Sofa.Doc{id: "new", rev: "1-leet"}} = Sofa.Doc.put(db, new)
  end

  test "PUT /mydb/underscore returns 400 Bad Request", %{db: db} do
    invalid = Sofa.Doc.from_map(%{"_id" => "underscore", "_invalid" => true})
    assert {:error, :bad_request} = Sofa.Doc.put(db, invalid)
  end

  test "PUT /mydb/denied returns 401 Unauthorized", %{db: db} do
    assert {:error, :unauthorized} = Sofa.Doc.put(db, Sofa.Doc.new("denied"))
  end

  test "PUT /mydb/invalid_user_doc returns 403 Forbidden", %{db: db} do
    assert {:error, :forbidden} = Sofa.Doc.put(db, Sofa.Doc.new("invalid_user_doc"))
  end

  test "PUT /mydb/wrong_rev returns 409 Conflict", %{db: db} do
    wrong_rev =
      Sofa.Doc.from_map(%{"_id" => "wrong_rev", "shiny" => true}) |> Map.put(:rev, "1-badcafe")

    assert {:error, :conflict} = Sofa.Doc.put(db, wrong_rev)
  end

  test "save/2 is put/2 with the document first, for pipelines", %{db: db} do
    assert {:ok, %Sofa.Doc{id: "new", rev: "1-leet"}} =
             Sofa.Doc.new(%{id: "new", body: %{"shiny" => true}}) |> Sofa.Doc.save(db)
  end

  test "save!/2 returns the saved document or raises", %{db: db} do
    assert %Sofa.Doc{id: "new", rev: "1-leet"} =
             Sofa.Doc.new(%{id: "new", body: %{"shiny" => true}}) |> Sofa.Doc.save!(db)

    stale = Sofa.Doc.from_map(%{"_id" => "wrong_rev", "_rev" => "1-badcafe", "shiny" => true})

    assert_raise Sofa.Error, ~r/unable to save document wrong_rev: :conflict/, fn ->
      Sofa.Doc.save!(stale, db)
    end
  end

  # pure functions, no HTTP involved
  test "new/1 accepts id string, %{id: id} and %{id: id, body: body}" do
    assert %Sofa.Doc{id: "a", body: %{}} = Sofa.Doc.new("a")
    assert %Sofa.Doc{id: "b", body: %{}} = Sofa.Doc.new(%{id: "b"})
    assert %Sofa.Doc{id: "c", body: %{"k" => 1}} = Sofa.Doc.new(%{id: "c", body: %{"k" => 1}})
  end

  test "from_map doesn't leak forbidden keys into doc.body" do
    bad_keys = ["_rev", "_attachments", :_id, :_rev, :_attachments, :__struct__, "__struct__"]
    good_map = %{"_id" => "toasty", "key" => "important", "type" => "Sofa"}

    pruned_map =
      Enum.reduce(bad_keys, good_map, fn x, a -> Map.put(a, x, "blah") end)
      |> Sofa.Doc.from_map()
      |> Map.from_struct()

    # a malformed _attachments value is dropped rather than passed through
    assert Map.equal?(pruned_map, %{
             attachments: %{},
             body: %{"key" => "important"},
             id: "toasty",
             rev: "blah",
             type: Sofa
           })
  end

  test "to_map coerces Elixir module types to JSON strings" do
    doc = Sofa.Doc.new("Hellvetica")
    m = %{doc | type: Sofa.Doc} |> Sofa.Doc.to_map()
    assert "Sofa.Doc" == m["type"]

    assert !Map.has_key?(Sofa.Doc.to_map(doc), "type")
  end

  test "from_map coerces type strings to Elixir types" do
    m = %{"_rev" => "1-leet", "_id" => "abc123", "type" => "Sofa.Doc"}

    assert Map.equal?(Sofa.Doc.from_map(m), %Sofa.Doc{
             attachments: %{},
             body: %{},
             id: "abc123",
             rev: "1-leet",
             type: Sofa.Doc
           })
  end

  test "from_map handles type-as-atom correctly" do
    with_type = %Sofa.Doc{Sofa.Doc.new("whatever") | type: :ok}
    assert with_type.type == :ok
  end

  test "attachment stubs become structs and back again" do
    doc = fixture("get_doc_with_attachment_stubs_200.json") |> Sofa.Doc.from_map()

    assert %Sofa.Attachment{
             name: "helmet.png",
             content_type: "image/png",
             revpos: 4,
             digest: "md5-hCzUwAJpP8b6cq+SvEFfTQ==",
             length: 159_877,
             data: nil
           } = doc.attachments["helmet.png"]

    assert Map.keys(doc.attachments) == ["helmet.png", "the_hun.json", "the_hun.txt"]

    assert Sofa.Doc.to_map(doc)["_attachments"] ==
             fixture("get_doc_with_attachment_stubs_200.json")["_attachments"]
  end

  test "attach/4 and detach/2 build inline attachments that save as base64" do
    doc =
      Sofa.Doc.new("recipe")
      |> Sofa.Doc.attach("recipe.txt", "1. Cook spaghetti")
      |> Sofa.Doc.attach("photo", <<255, 216>>, content_type: "image/jpeg")
      |> Sofa.Doc.attach("old.txt", "gone")
      |> Sofa.Doc.detach("old.txt")

    assert %{"recipe.txt" => %Sofa.Attachment{content_type: "text/plain", length: 17}} =
             doc.attachments

    assert Sofa.Doc.to_map(doc)["_attachments"] == %{
             "recipe.txt" => %{
               "content_type" => "text/plain",
               "data" => Base.encode64("1. Cook spaghetti")
             },
             "photo" => %{"content_type" => "image/jpeg", "data" => Base.encode64(<<255, 216>>)}
           }

    # inline content survives the round trip, as CouchDB returns it with attachments=true
    assert Sofa.Doc.to_map(doc) |> Sofa.Doc.from_map() == doc
  end

  test "a document without attachments has no _attachments key" do
    refute Map.has_key?(Sofa.Doc.to_map(Sofa.Doc.new("plain")), "_attachments")
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
end
