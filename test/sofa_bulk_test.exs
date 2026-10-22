defmodule SofaBulkTest do
  @moduledoc "`Sofa.Bulk` against a Bypass fake serving the documented stew examples."

  use ExUnit.Case, async: true

  import Plug.Conn, only: [fetch_query_params: 1, put_resp_content_type: 2, resp: 3]
  import Sofa.BypassHelpers, only: [start: 0, json: 3, json_body: 1, empty: 2]

  alias Sofa.{Bulk, Doc}

  setup do
    %{bypass: bypass, sofa: sofa} = start()
    test = self()
    Bypass.stub(bypass, "GET", "/", &json(&1, 200, "init_200.json"))
    Bypass.stub(bypass, "HEAD", "/db", &empty(&1, 200))

    # the documented example: FishStew created, LambStew deleted, plus a
    # conflicting third document when sent
    Bypass.stub(bypass, "POST", "/db/_bulk_docs", fn conn ->
      {conn, body} = json_body(conn)
      send(test, {:bulk_docs, body})

      results =
        Enum.map(body["docs"], fn
          %{"_id" => "FishStew"} ->
            %{"ok" => true, "id" => "FishStew", "rev" => "1-967a00dff5e02add41819138abb3284d"}

          %{"_id" => "LambStew"} ->
            %{"ok" => true, "id" => "LambStew", "rev" => "3-f9c62b2169d0999103e9f41949090807"}

          %{"_id" => id} ->
            %{"id" => id, "error" => "conflict", "reason" => "Document update conflict."}
        end)

      results = if body["new_edits"] == false, do: [], else: results
      conn |> put_resp_content_type("application/json") |> resp(201, Jason.encode!(results))
    end)

    Bypass.stub(bypass, "POST", "/db/_bulk_get", fn conn ->
      conn = fetch_query_params(conn)
      {conn, body} = json_body(conn)
      send(test, {:bulk_get, conn.query_params, body})

      results =
        Enum.map(body["docs"], fn
          %{"id" => "foo", "rev" => "1-4a7e4ae49c4366eaed8edeaea8f784ad"} ->
            %{
              "id" => "foo",
              "docs" => [
                %{
                  "ok" => %{
                    "_id" => "foo",
                    "_rev" => "1-4a7e4ae49c4366eaed8edeaea8f784ad",
                    "value" => "this is the first revision of foo"
                  }
                }
              ]
            }

          %{"id" => "foo"} ->
            %{
              "id" => "foo",
              "docs" => [
                %{
                  "ok" => %{
                    "_id" => "foo",
                    "_rev" => "4-753875d51501a6b1883a9d62b4d33f91",
                    "value" => "this is foo",
                    "_revisions" => %{
                      "start" => 4,
                      "ids" => [
                        "753875d51501a6b1883a9d62b4d33f91",
                        "4a7e4ae49c4366eaed8edeaea8f784ad"
                      ]
                    }
                  }
                }
              ]
            }

          %{"id" => "bar"} ->
            %{
              "id" => "bar",
              "docs" => [
                %{
                  "ok" => %{
                    "_id" => "bar",
                    "_rev" => "2-9b71d36dfdd9b4815388eb91cc8fb61d",
                    "value" => "this is bar"
                  }
                }
              ]
            }

          %{"id" => id} ->
            %{
              "id" => id,
              "docs" => [
                %{
                  "error" => %{
                    "id" => id,
                    "rev" => "undefined",
                    "error" => "not_found",
                    "reason" => "missing"
                  }
                }
              ]
            }
        end)

      conn
      |> put_resp_content_type("application/json")
      |> resp(200, Jason.encode!(%{"results" => results}))
    end)

    %{db: Sofa.connect!(sofa) |> Sofa.DB.open!("db")}
  end

  describe "save/3 and delete/2" do
    test "POSTs the documents and pairs each with its result, in order", %{db: db} do
      fish = Doc.new("FishStew")
      lamb = %Doc{Doc.new("LambStew") | rev: "2-0786321986194c92dd3b57dfbfc741ce"}
      stale = %Doc{Doc.new("Stale") | rev: "1-old"}

      assert {:ok, results} = Bulk.save(db, [fish, lamb, stale])

      assert_receive {:bulk_docs,
                      %{
                        "docs" => [
                          %{"_id" => "FishStew"},
                          %{"_id" => "LambStew", "_rev" => "2-" <> _},
                          %{"_id" => "Stale"}
                        ]
                      } = body}

      refute Map.has_key?(body, "new_edits")

      assert [
               {:ok, %Doc{id: "FishStew", rev: "1-967a00dff5e02add41819138abb3284d"}},
               {:ok, %Doc{id: "LambStew", rev: "3-" <> _}},
               {:error, :conflict, %Doc{id: "Stale", rev: "1-old"}}
             ] =
               results
    end

    test "delete/2 marks each document deleted", %{db: db} do
      lamb = %Doc{Doc.new("LambStew") | rev: "2-0786321986194c92dd3b57dfbfc741ce"}
      assert {:ok, [{:ok, %Doc{rev: "3-" <> _}}]} = Bulk.delete(db, [lamb])

      assert_receive {:bulk_docs,
                      %{
                        "docs" => [
                          %{"_id" => "LambStew", "_deleted" => true, "_rev" => "2-" <> _}
                        ]
                      }}
    end

    test "new_edits: false stores revisions as given and reports every document as ok", %{db: db} do
      doc = %Doc{Doc.new("FishStew") | rev: "7-replicated"}
      assert {:ok, [{:ok, ^doc}]} = Bulk.save(db, [doc], new_edits: false)
      assert_receive {:bulk_docs, %{"new_edits" => false}}
    end
  end

  describe "get/3" do
    test "fetches by id or revision, with the documented query parameters", %{db: db} do
      assert {:ok, results} =
               Bulk.get(db, [{"foo", "1-4a7e4ae49c4366eaed8edeaea8f784ad"}, "foo", "bar", "baz"],
                 revs: true,
                 latest: nil
               )

      assert_receive {:bulk_get, %{"revs" => "true"} = query,
                      %{
                        "docs" => [
                          %{"id" => "foo", "rev" => "1-" <> _},
                          %{"id" => "foo"},
                          %{"id" => "bar"},
                          %{"id" => "baz"}
                        ]
                      }}

      refute Map.has_key?(query, "latest")

      assert [
               {:ok,
                %Doc{
                  id: "foo",
                  rev: "1-" <> _,
                  body: %{"value" => "this is the first revision of foo"}
                }},
               {:ok, %Doc{id: "foo", rev: "4-" <> _} = latest},
               {:ok, %Doc{id: "bar"}},
               {:error, :not_found, "baz"}
             ] =
               results

      assert %{"_revisions" => %{"start" => 4}} = latest.body
    end
  end
end
