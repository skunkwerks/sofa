defmodule SofaMangoTest do
  @moduledoc "`Sofa.Mango` against a Bypass fake serving the documented movies examples."

  use ExUnit.Case, async: true

  import Plug.Conn, only: [put_resp_content_type: 2, resp: 3]
  import Sofa.BypassHelpers, only: [start: 0, json: 3, json_body: 1, fixture: 1, empty: 2]

  alias Sofa.Mango

  setup do
    %{bypass: bypass, sofa: sofa} = start()
    test = self()
    Bypass.stub(bypass, "GET", "/", &json(&1, 200, "init_200.json"))
    Bypass.stub(bypass, "HEAD", "/movies", &empty(&1, 200))

    Bypass.stub(bypass, "POST", "/movies/_find", fn conn ->
      {conn, body} = json_body(conn)
      send(test, {:find, body})

      cond do
        body["selector"] == %{"nope" => true} ->
          json(conn, 400, "put_doc_400.json")

        # a paged search: three docs, two per page, the bookmark being the page
        body["selector"] == %{"paged" => true} ->
          page = body["bookmark"] || "p1"
          docs = if page == "p1", do: [%{"_id" => "a"}, %{"_id" => "b"}], else: [%{"_id" => "c"}]

          conn
          |> put_resp_content_type("application/json")
          |> resp(200, Jason.encode!(%{"docs" => docs, "bookmark" => "p2"}))

        true ->
          json(conn, 200, "find_movies_200.json")
      end
    end)

    Bypass.stub(bypass, "POST", "/movies/_explain", fn conn ->
      {conn, body} = json_body(conn)
      send(test, {:explain, body})

      conn
      |> put_resp_content_type("application/json")
      |> resp(
        200,
        ~s({"dbname": "movies", "index": {"ddoc": "_design/0d61d9177426b1e2aa8d0fe732ec6e506f5d443c", "name": "0d61d9177426b1e2aa8d0fe732ec6e506f5d443c", "type": "json", "def": {"fields": [{"year": "asc"}]}}, "selector": {"year": {"$gt": 2010}}, "opts": {}, "limit": 2, "skip": 0, "fields": ["_id", "_rev", "year", "title"], "covering": false})
      )
    end)

    Bypass.stub(bypass, "POST", "/movies/_index", fn conn ->
      {conn, body} = json_body(conn)
      send(test, {:index, body})

      conn
      |> put_resp_content_type("application/json")
      |> resp(
        200,
        ~s({"result": "created", "id": "_design/a5f4711fc9448864a13c81dc71e660b524d7410c", "name": "foo-index"})
      )
    end)

    Bypass.stub(bypass, "GET", "/movies/_index", fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> resp(
        200,
        ~s({"total_rows": 2, "indexes": [{"ddoc": null, "name": "_all_docs", "type": "special", "def": {"fields": [{"_id": "asc"}]}}, {"ddoc": "_design/a5f4711fc9448864a13c81dc71e660b524d7410c", "name": "foo-index", "type": "json", "def": {"fields": [{"foo": "asc"}]}}]})
      )
    end)

    Bypass.stub(
      bypass,
      "DELETE",
      "/movies/_index/_design/a5f4711fc9448864a13c81dc71e660b524d7410c/json/foo-index",
      fn conn ->
        conn |> put_resp_content_type("application/json") |> resp(200, ~s({"ok": true}))
      end
    )

    Bypass.stub(
      bypass,
      "DELETE",
      "/movies/_index/_design/nothing/json/missing",
      &json(&1, 404, "get_doc_404.json")
    )

    %{db: Sofa.connect!(sofa) |> Sofa.DB.open!("movies")}
  end

  describe "find/3" do
    test "POSTs the selector with its options and parses the documented response", %{db: db} do
      selector = %{"year" => %{"$gt" => 2010}}

      assert {:ok, result} =
               Mango.find(db, selector,
                 fields: ["_id", "_rev", "year", "title"],
                 sort: [%{"year" => "asc"}],
                 limit: 2,
                 skip: 0,
                 execution_stats: true,
                 bookmark: nil
               )

      assert_receive {:find, body}

      assert body == %{
               "selector" => selector,
               "fields" => ["_id", "_rev", "year", "title"],
               "sort" => [%{"year" => "asc"}],
               "limit" => 2,
               "skip" => 0,
               "execution_stats" => true
             }

      assert %Mango{
               bookmark: "g1AAAA" <> _,
               warning: nil,
               execution_stats: %{"results_returned" => 2}
             } = result

      assert [
               %Sofa.Doc{
                 id: "176694",
                 rev: "1-" <> _,
                 body: %{"year" => 2011, "title" => "The Tragedy of Man"}
               },
               %Sofa.Doc{id: "780504"}
             ] = result.docs
    end

    test "a bad selector is :bad_request, and find! raises", %{db: db} do
      assert {:error, :bad_request} = Mango.find(db, %{"nope" => true})

      assert_raise Sofa.Error, ~r/unable to find documents: :bad_request/, fn ->
        Mango.find!(db, %{"nope" => true})
      end

      assert %Mango{docs: [_, _]} = Mango.find!(db, %{"year" => %{"$gt" => 2010}})
    end

    test "documents without an _id, as with fields, stay maps" do
      assert %Mango{docs: [%{"title" => "Drive"}]} =
               Mango.from_map(%{"docs" => [%{"title" => "Drive"}]})
    end
  end

  describe "stream/3" do
    test "follows bookmarks until a short page", %{db: db} do
      ids = Mango.stream(db, %{"paged" => true}, limit: 2) |> Enum.map(& &1.id)
      assert ids == ["a", "b", "c"]

      assert_receive {:find, %{"limit" => 2} = first}
      refute Map.has_key?(first, "bookmark")
      assert_receive {:find, %{"limit" => 2, "bookmark" => "p2"}}
      refute_receive {:find, _}
    end

    test "raises mid-stream on failure", %{db: db} do
      assert_raise Sofa.Error, ~r/unable to stream documents/, fn ->
        Mango.stream(db, %{"nope" => true}) |> Enum.to_list()
      end
    end
  end

  describe "explain/3" do
    test "returns the documented plan", %{db: db} do
      assert {:ok, %{"index" => %{"type" => "json"}, "covering" => false}} =
               Mango.explain(db, %{"year" => %{"$gt" => 2010}}, limit: 2)

      assert_receive {:explain, %{"selector" => %{"year" => %{"$gt" => 2010}}, "limit" => 2}}
    end
  end

  describe "indexes" do
    test "index/3 creates one, indexes/1 lists them, delete_index/3 removes one", %{db: db} do
      assert {:ok,
              %{
                result: :created,
                ddoc: "_design/a5f4711fc9448864a13c81dc71e660b524d7410c",
                name: "foo-index"
              }} =
               Mango.index(db, ["foo"],
                 name: "foo-index",
                 ddoc: "a5f4711fc9448864a13c81dc71e660b524d7410c"
               )

      assert_receive {:index,
                      %{
                        "index" => %{"fields" => ["foo"]},
                        "name" => "foo-index",
                        "ddoc" => "a5f4711fc9448864a13c81dc71e660b524d7410c"
                      }}

      assert {:ok,
              [
                %{"name" => "_all_docs", "type" => "special"},
                %{"name" => "foo-index", "def" => %{"fields" => [%{"foo" => "asc"}]}}
              ]} =
               Mango.indexes(db)

      assert :ok =
               Mango.delete_index(
                 db,
                 "_design/a5f4711fc9448864a13c81dc71e660b524d7410c",
                 "foo-index"
               )

      assert :ok = Mango.delete_index(db, "a5f4711fc9448864a13c81dc71e660b524d7410c", "foo-index")
      assert {:error, :not_found} = Mango.delete_index(db, "nothing", "missing")
    end
  end
end
