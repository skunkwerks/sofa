defmodule SofaViewTest do
  @moduledoc "`Sofa.View` against a Bypass fake serving the documented examples."

  use ExUnit.Case, async: true

  import Plug.Conn, only: [fetch_query_params: 1, put_resp_content_type: 2, resp: 3]
  import Sofa.BypassHelpers, only: [start: 0, json: 3, json_body: 1, fixture: 1, empty: 2]

  alias Sofa.View
  alias Sofa.View.Row

  doctest View

  setup do
    %{bypass: bypass, sofa: sofa} = start()
    test = self()
    Bypass.stub(bypass, "GET", "/", &json(&1, 200, "init_200.json"))
    Bypass.stub(bypass, "HEAD", "/recipes", &empty(&1, 200))

    # the documented by_ingredient view, reporting its query
    for method <- ["GET", "POST"] do
      Bypass.stub(bypass, method, "/recipes/_design/recipes/_view/by_ingredient", fn conn ->
        conn = fetch_query_params(conn)
        {conn, body} = if conn.method == "POST", do: json_body(conn), else: {conn, nil}
        send(test, {:view, conn.method, conn.query_params, body})
        json(conn, 200, "view_by_ingredient_200.json")
      end)
    end

    Bypass.stub(bypass, "POST", "/recipes/_design/recipes/_view/by_ingredient/queries", fn conn ->
      {conn, body} = json_body(conn)
      send(test, {:queries, body})
      results = Enum.map(body["queries"], fn _ -> fixture("view_by_ingredient_200.json") end)

      conn
      |> put_resp_content_type("application/json")
      |> resp(200, Jason.encode!(%{"results" => results}))
    end)

    Bypass.stub(bypass, "GET", "/recipes/_all_docs", fn conn ->
      conn = fetch_query_params(conn)
      send(test, {:all_docs, conn.query_params})
      json(conn, 200, "all_docs_200.json")
    end)

    Bypass.stub(bypass, "GET", "/recipes/_design_docs", fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> resp(
        200,
        ~s({"total_rows": 1, "offset": 0, "rows": [{"id": "_design/recipes", "key": "_design/recipes", "value": {"rev": "1-a"}}]})
      )
    end)

    Bypass.stub(
      bypass,
      "GET",
      "/recipes/_design/recipes/_view/missing",
      &json(&1, 404, "get_doc_404.json")
    )

    # a paged index of five rows, keyed 1..5, for stream/4
    Bypass.stub(bypass, "GET", "/recipes/_design/recipes/_view/paged", fn conn ->
      conn = fetch_query_params(conn)
      send(test, {:page, conn.query_params})

      from =
        if conn.query_params["startkey"],
          do: Jason.decode!(conn.query_params["startkey"]),
          else: 1

      limit = String.to_integer(conn.query_params["limit"])

      rows =
        for k <- from..5//1,
            k - from < limit,
            do: %{"id" => "doc#{k}", "key" => k, "value" => nil}

      conn
      |> put_resp_content_type("application/json")
      |> resp(200, Jason.encode!(%{"total_rows" => 5, "offset" => from - 1, "rows" => rows}))
    end)

    %{db: Sofa.connect!(sofa) |> Sofa.DB.open!("recipes")}
  end

  describe "query/4" do
    test "GETs the view and parses the documented response", %{db: db} do
      assert {:ok, view} = View.query(db, "recipes", "by_ingredient")
      assert_receive {:view, "GET", %{}, nil}

      assert %View{total_rows: 3, offset: 0, update_seq: nil} = view

      assert [%Row{id: "SpaghettiWithMeatballs", key: "meatballs", value: 1, doc: nil} | _] =
               view.rows

      assert Enum.map(view.rows, & &1.key) == ["meatballs", "spaghetti", "tomato sauce"]
    end

    test "encodes keys as JSON and the rest as strings", %{db: db} do
      {:ok, _} =
        View.query(db, "recipes", "by_ingredient",
          key: "meatballs",
          limit: 5,
          descending: true,
          skip: nil
        )

      assert_receive {:view, "GET",
                      %{"key" => ~s("meatballs"), "limit" => "5", "descending" => "true"} = query,
                      nil}

      refute Map.has_key?(query, "skip")

      {:ok, _} =
        View.query(db, "recipes", "by_ingredient",
          startkey: ["a", 1],
          endkey: ["a", %{}],
          group_level: 1
        )

      assert_receive {:view, "GET",
                      %{
                        "startkey" => ~s(["a",1]),
                        "endkey" => ~s(["a",{}]),
                        "group_level" => "1"
                      }, nil}
    end

    test "POSTs keys as a body", %{db: db} do
      {:ok, %View{rows: [_ | _]}} =
        View.query(db, "recipes", "by_ingredient",
          keys: ["meatballs", "spaghetti"],
          reduce: false
        )

      assert_receive {:view, "POST", %{"reduce" => "false"},
                      %{"keys" => ["meatballs", "spaghetti"]}}
    end

    test "a missing view is :not_found, and query! raises", %{db: db} do
      assert {:error, :not_found} = View.query(db, "recipes", "missing")

      assert_raise Sofa.Error, ~r{unable to query view recipes/missing: :not_found}, fn ->
        View.query!(db, "recipes", "missing")
      end

      assert %View{total_rows: 3} = View.query!(db, "recipes", "by_ingredient")
    end
  end

  describe "all_docs/2 and design_docs/2" do
    test "list documents by id with their revs", %{db: db} do
      assert {:ok, %View{total_rows: 3, rows: rows}} = View.all_docs(db, include_docs: false)
      assert_receive {:all_docs, %{"include_docs" => "false"}}
      assert %Row{id: "16e458537602f5ef2a710089dffd9453", value: %{"rev" => "1-" <> _}} = hd(rows)

      assert {:ok, %View{rows: [%Row{id: "_design/recipes"}]}} = View.design_docs(db)
    end
  end

  describe "queries/4" do
    test "runs several queries in one request, one result each", %{db: db} do
      assert {:ok, [%View{}, %View{}]} =
               View.queries(db, "recipes", "by_ingredient", [
                 [key: "meatballs"],
                 [key: "tomato sauce", limit: 1]
               ])

      assert_receive {:queries,
                      %{
                        "queries" => [
                          %{"key" => "meatballs"},
                          %{"key" => "tomato sauce", "limit" => 1}
                        ]
                      }}
    end
  end

  describe "stream/4" do
    test "pages through the rows by continuing from the row past each page", %{db: db} do
      rows = View.stream(db, "recipes", "paged", limit: 2) |> Enum.to_list()
      assert Enum.map(rows, & &1.key) == [1, 2, 3, 4, 5]

      # three requests: two full pages plus the last one, each asking for one row more
      assert_receive {:page, %{"limit" => "3"} = first}
      refute Map.has_key?(first, "startkey")
      assert_receive {:page, %{"limit" => "3", "startkey" => "3", "startkey_docid" => "doc3"}}
      assert_receive {:page, %{"limit" => "3", "startkey" => "5", "startkey_docid" => "doc5"}}
      refute_receive {:page, _}
    end

    test "is lazy", %{db: db} do
      assert [%Row{key: 1}] = View.stream(db, "recipes", "paged", limit: 2) |> Enum.take(1)
      assert_receive {:page, _}
      refute_receive {:page, _}
    end

    test "raises mid-stream on failure", %{db: db} do
      assert_raise Sofa.Error, ~r/unable to stream view/, fn ->
        View.stream(db, "recipes", "missing") |> Enum.to_list()
      end
    end
  end

  test "rows with include_docs carry a Sofa.Doc, and error rows their error" do
    row =
      Row.from_map(%{
        "id" => "a",
        "key" => "a",
        "value" => %{"rev" => "1-x"},
        "doc" => %{"_id" => "a", "_rev" => "1-x", "n" => 1}
      })

    assert %Row{doc: %Sofa.Doc{id: "a", rev: "1-x", body: %{"n" => 1}}} = row

    assert %Row{key: "missing", error: "not_found", doc: nil} =
             Row.from_map(%{"key" => "missing", "error" => "not_found"})
  end
end
