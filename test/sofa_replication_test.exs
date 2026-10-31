defmodule SofaReplicationTest do
  @moduledoc "`Sofa.Replication` against a Bypass fake serving the documented examples."

  use ExUnit.Case, async: true

  import Plug.Conn, only: [put_resp_content_type: 2, resp: 3, fetch_query_params: 1]
  import Sofa.BypassHelpers, only: [start: 1, admin: 0, json: 3, json_body: 1]

  alias Sofa.Replication

  doctest Replication

  @history ~s([{"doc_write_failures": 0, "docs_read": 10, "docs_written": 10, "end_last_seq": 28, "end_time": "Sun, 11 Aug 2013 20:38:50 GMT", "missing_checked": 10, "missing_found": 10, "recorded_seq": 28, "session_id": "142a35854a08e205c47174d91b1f9628", "start_last_seq": 1, "start_time": "Sun, 11 Aug 2013 20:38:50 GMT"}])

  setup do
    %{bypass: bypass, sofa: sofa} = start(admin())
    test = self()
    Bypass.stub(bypass, "GET", "/", &json(&1, 200, "init_200.json"))

    Bypass.stub(bypass, "POST", "/_replicate", fn conn ->
      {conn, body} = json_body(conn)
      send(test, {:replicate, body})
      conn = put_resp_content_type(conn, "application/json")

      cond do
        body["source"] == "http://nowhere/db" ->
          json(conn, 404, "get_db_404.json")

        body["cancel"] == true ->
          resp(
            conn,
            200,
            ~s({"ok": true, "_local_id": "0a81b645497e6687c7dbe7b0d2c8bd30+continuous"})
          )

        body["continuous"] == true ->
          resp(
            conn,
            202,
            ~s({"ok": true, "_local_id": "0a81b645497e6687c7dbe7b0d2c8bd30+continuous"})
          )

        true ->
          resp(
            conn,
            200,
            ~s({"history": #{@history}, "ok": true, "replication_id_version": 3, "session_id": "142a35854a08e205c47174d91b1f9628", "source_last_seq": 28})
          )
      end
    end)

    Bypass.stub(bypass, "GET", "/_scheduler/jobs", fn conn ->
      conn = fetch_query_params(conn)
      send(test, {:jobs, conn.query_params})

      conn
      |> put_resp_content_type("application/json")
      |> resp(
        200,
        ~s({"jobs": [{"database": "_replicator", "doc_id": "cdyno-0000001-0000003", "id": "8f5b1bd0be6f9166ccfd36fc8be8fc22+continuous", "node": "node1@127.0.0.1", "pid": "<0.1850.0>", "source": "http://myserver.com/foo", "target": "http://adm:*****@localhost:15984/cdyno-0000003/", "start_time": "2017-04-29T05:01:37Z", "user": null, "history": [{"timestamp": "2017-04-29T05:01:37Z", "type": "started"}], "info": {"changes_pending": 0, "docs_read": 113, "docs_written": 113}}], "offset": 0, "total_rows": 1})
      )
    end)

    for path <- ["/_scheduler/docs", "/_scheduler/docs/_replicator"] do
      Bypass.stub(bypass, "GET", path, fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> resp(
          200,
          ~s({"docs": [{"database": "_replicator", "doc_id": "cdyno-0000001-0000002", "id": "e327d79214831ca4c11550b4a453c9ba+continuous", "node": "node2@127.0.0.1", "source": "http://myserver.com/foo", "target": "http://adm:*****@localhost:15984/cdyno-0000002/", "state": "running", "start_time": "2017-04-29T05:01:37Z", "last_updated": "2017-04-29T05:01:37Z", "error_count": 0, "info": {"changes_pending": 15}}], "offset": 0, "total_rows": 1})
        )
      end)
    end

    Bypass.stub(bypass, "GET", "/_scheduler/docs/_replicator/cdyno-0000001-0000002", fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> resp(
        200,
        ~s({"database": "_replicator", "doc_id": "cdyno-0000001-0000002", "id": "e327d79214831ca4c11550b4a453c9ba+continuous", "state": "running", "error_count": 0, "info": {"changes_pending": 15}, "node": "node2@127.0.0.1", "source": "http://myserver.com/foo", "target": "http://adm:*****@localhost:15984/cdyno-0000002/", "start_time": "2017-04-29T05:01:37Z", "last_updated": "2017-04-29T05:01:37Z"})
      )
    end)

    Bypass.stub(
      bypass,
      "GET",
      "/_scheduler/docs/_replicator/nothing",
      &json(&1, 404, "get_doc_404.json")
    )

    %{server: Sofa.connect!(sofa)}
  end

  test "replicate/4 posts the endpoints with the options and returns the history", %{
    server: server
  } do
    db_b = %Sofa{server | database: "db_b"}

    assert {:ok, %{"ok" => true, "history" => [%{"docs_written" => 10}], "source_last_seq" => 28}} =
             Replication.replicate(server, "http://adm:pass@127.0.0.1:5984/db_a", db_b,
               create_target: true,
               filter: nil
             )

    assert_receive {:replicate,
                    %{
                      "source" => "http://adm:pass@127.0.0.1:5984/db_a",
                      "target" => "http://admin:passwd@127.0.0.1:" <> _,
                      "create_target" => true
                    } = body}

    refute Map.has_key?(body, "filter")
    assert String.ends_with?(body["target"], "/db_b")
  end

  test "a continuous replication is accepted, and cancelled with the same parameters", %{
    server: server
  } do
    assert {:ok, %{"ok" => true, "_local_id" => id}} =
             Replication.replicate(server, "http://a/db", "http://b/db", continuous: true)

    assert String.ends_with?(id, "+continuous")

    assert {:ok, %{"ok" => true}} =
             Replication.cancel(server, "http://a/db", "http://b/db", continuous: true)

    assert_receive {:replicate, %{"cancel" => true, "continuous" => true}}
  end

  test "a missing source is :not_found", %{server: server} do
    assert {:error, :not_found} =
             Replication.replicate(server, "http://nowhere/db", "http://b/db")
  end

  test "new/3 builds a _replicator document" do
    doc =
      Replication.new("http://a/db", %{"url" => "http://b/db", "headers" => %{}},
        continuous: true,
        id: "a-to-b"
      )

    assert %Sofa.Doc{
             id: "a-to-b",
             body: %{
               "source" => "http://a/db",
               "target" => %{"url" => "http://b/db", "headers" => %{}},
               "continuous" => true
             }
           } = doc

    assert %Sofa.Doc{id: <<_::binary-size(32)>>} = Replication.new("http://a/db", "http://b/db")
  end

  test "jobs/2, docs/3 and doc/3 read the scheduler", %{server: server} do
    assert {:ok, [%{"doc_id" => "cdyno-0000001-0000003", "info" => %{"docs_written" => 113}}]} =
             Replication.jobs(server, limit: 10)

    assert_receive {:jobs, %{"limit" => "10"}}

    assert {:ok, [%{"state" => "running", "error_count" => 0}]} = Replication.docs(server)

    assert {:ok, [%{"doc_id" => "cdyno-0000001-0000002"}]} =
             Replication.docs(server, "_replicator")

    assert {:ok, %{"doc_id" => "cdyno-0000001-0000002", "state" => "running"}} =
             Replication.doc(server, "_replicator", "cdyno-0000001-0000002")

    assert {:error, :not_found} = Replication.doc(server, "_replicator", "nothing")
  end
end
