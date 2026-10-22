defmodule SofaChangesLiveTest do
  @moduledoc """
  `Sofa.Changes` against a real CouchDB, driving the same behaviour the
  fake-backed suites specify. Excluded by default, see
  test/integration/README.md. Every test creates its own throwaway database
  and deletes it afterwards.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag capture_log: true
  @moduletag timeout: 60_000

  import Sofa.Design, only: [sigil_JS: 2]

  alias Sofa.{Changes, TestFollower}

  @couchdb_uri System.get_env("COUCHDB_URI", "http://admin:passwd@localhost:5984/")

  setup do
    admin = Sofa.init(@couchdb_uri) |> Sofa.client() |> Sofa.connect!()
    name = "sofa_changes_#{System.unique_integer([:positive])}_#{:rand.uniform(1_000_000)}"
    {:ok, db, _resp} = Sofa.DB.create(admin, name)
    on_exit(fn -> {:ok, _, _} = Sofa.DB.delete(admin, name) end)
    %{admin: admin, db: db, name: name}
  end

  defp follow(db, opts \\ []) do
    {:ok, pid} = Changes.start_link(TestFollower, %{db: db, opts: opts, pid: self()})
    pid
  end

  defp save!(db, id, body \\ %{}) do
    {:ok, doc = %Sofa.Doc{}} = Sofa.Doc.put(db, Sofa.Doc.new(%{id: id, body: body}))
    doc
  end

  defp update!(db, doc = %Sofa.Doc{}, body) do
    {:ok, doc = %Sofa.Doc{}} = Sofa.Doc.put(db, %Sofa.Doc{doc | body: body})
    doc
  end

  defp last_seq(db) do
    {:ok, _, %Sofa.Response{body: %{"update_seq" => seq}}} = Sofa.DB.info(db, db.database)
    seq
  end

  defp current_ref(pid), do: :sys.get_state(pid).ref

  test "server is reachable and recent", %{admin: admin} do
    assert Version.match?(admin.version, ">= 3.0.0")
  end

  describe "continuous feed" do
    test "creates, updates and deletes arrive in order with opaque sequences", %{db: db} do
      follow(db)
      # the feed is open before any change is made
      Process.sleep(200)

      doc = save!(db, "alpha", %{"n" => 1})

      assert_receive {:change, %{"id" => "alpha", "seq" => seq1, "changes" => [%{"rev" => rev1}]},
                      1},
                     5000

      assert rev1 == doc.rev
      assert String.starts_with?(seq1, "1-")

      doc = update!(db, doc, %{"n" => 2})
      assert_receive {:change, %{"id" => "alpha", "changes" => [%{"rev" => rev2}]}, 2}, 5000
      assert rev2 == doc.rev
      assert String.starts_with?(rev2, "2-")

      :ok = Sofa.Doc.delete(db, doc)
      assert_receive {:change, %{"id" => "alpha", "deleted" => true}, 3}, 5000
    end

    test "include_docs delivers the winning revision as a Sofa.Doc", %{db: db} do
      follow(db, include_docs: true)
      Process.sleep(200)

      save!(db, "recipe", %{"title" => "Spaghetti with meatballs", "servings" => 4})

      assert_receive {:change, %{"id" => "recipe", "doc" => %Sofa.Doc{} = doc}, 1}, 5000
      assert doc.id == "recipe"
      assert doc.body == %{"title" => "Spaghetti with meatballs", "servings" => 4}
    end

    test "since skips earlier changes and since: :now skips everything so far", %{db: db} do
      save!(db, "old-1")
      save!(db, "old-2")
      seq_after_old = last_seq(db)

      # changes across documents are only partially ordered on a sharded
      # database, so old-1 and old-2 may arrive in either order
      everything = follow(db)
      assert_receive {:change, %{"id" => "old-" <> _}, 1}, 5000
      assert_receive {:change, %{"id" => "old-" <> _}, 2}, 5000
      Changes.stop(everything)

      from_seq = follow(db, since: seq_after_old)
      Process.sleep(300)
      refute_received {:change, _, _}
      Changes.stop(from_seq)

      follow(db, since: :now)
      Process.sleep(300)
      save!(db, "new-1")
      assert_receive {:change, %{"id" => "new-1"}, 1}, 5000
      refute_received {:change, %{"id" => "old-" <> _}, _}
    end

    test "doc_ids filter only delivers the named documents", %{db: db} do
      follow(db, doc_ids: ["wanted"])
      Process.sleep(200)

      save!(db, "unwanted")
      save!(db, "wanted")
      save!(db, "also-unwanted")

      assert_receive {:change, %{"id" => "wanted"}, 1}, 5000
      refute_receive {:change, _, _}, 500
    end

    test "a selector filter only delivers matching documents", %{db: db} do
      follow(db, selector: %{"important" => true})
      Process.sleep(200)

      save!(db, "noise", %{"important" => false})
      save!(db, "signal", %{"important" => true})

      assert_receive {:change, %{"id" => "signal"}, 1}, 5000
      refute_receive {:change, _, _}, 500
    end

    test "filter=_design only delivers design documents", %{db: db} do
      follow(db, filter: "_design")
      Process.sleep(200)

      save!(db, "plain")
      save!(db, "_design/app", %{"views" => %{}})

      assert_receive {:change, %{"id" => "_design/app"}, 1}, 5000
      refute_receive {:change, _, _}, 500
    end

    test "filter=design_doc/name runs the filter function", %{db: db} do
      save!(db, "_design/filters", %{
        "filters" => %{"important" => ~JS"function(doc, req) { return doc.important === true; }"}
      })

      follow(db, filter: "filters/important", since: :now)
      Process.sleep(300)

      save!(db, "noise", %{"important" => false})
      save!(db, "signal", %{"important" => true})

      assert_receive {:change, %{"id" => "signal"}, 1}, 5000
      refute_receive {:change, _, _}, 500
    end

    test "server heartbeats keep a quiet feed open without reconnecting", %{db: db} do
      pid = follow(db, heartbeat: 300)
      Process.sleep(300)
      ref = current_ref(pid)

      Process.sleep(1500)
      assert current_ref(pid) == ref

      save!(db, "still-here")
      assert_receive {:change, %{"id" => "still-here"}, 1}, 5000
      refute_received {:error, _}
    end

    test "heartbeat overrides timeout, so the feed is held open indefinitely", %{db: db} do
      pid = follow(db, timeout: 500, heartbeat: 200)
      Process.sleep(300)
      ref = current_ref(pid)

      Process.sleep(1500)
      assert current_ref(pid) == ref
      refute_received {:error, _}
    end

    test "without a heartbeat the server times out and the follower resumes from its seq", %{
      db: db
    } do
      save!(db, "before")
      pid = follow(db, timeout: 500, heartbeat: nil)
      assert_receive {:change, %{"id" => "before"}, 1}, 5000
      first = current_ref(pid)

      Process.sleep(1500)
      %Changes{ref: second, query: %{since: since}} = :sys.get_state(pid)
      assert second != first
      assert String.starts_with?(since, "1-")

      save!(db, "after")
      assert_receive {:change, %{"id" => "after"}, 2}, 5000
      refute_received {:change, %{"id" => "before"}, _}
      refute_received {:error, _}
    end
  end

  describe "longpoll and normal feeds" do
    test "longpoll delivers a batch per response and keeps polling", %{db: db} do
      save!(db, "one")
      save!(db, "two")

      follow(db, longpoll: true)
      assert_receive {:change, %{"id" => _}, 1}, 5000
      assert_receive {:change, %{"id" => _}, 2}, 5000

      Process.sleep(300)
      save!(db, "three")
      assert_receive {:change, %{"id" => "three"}, 3}, 5000
    end

    test "normal delivers everything so far and then stays idle", %{db: db} do
      save!(db, "one")
      save!(db, "two")

      pid = follow(db, feed: :normal)
      assert_receive {:change, %{"id" => _}, 1}, 5000
      assert_receive {:change, %{"id" => _}, 2}, 5000

      Process.sleep(300)
      save!(db, "three")
      refute_receive {:change, _, _}, 500
      assert %Changes{worker: nil} = :sys.get_state(pid)
    end
  end

  describe "errors" do
    test "anonymous access reaches handle_error/2 as :unauthorized", %{name: name} do
      # deliberately anonymous rather than a wrong password: CouchDB 3.5 locks
      # an account after repeated authentication failures
      uri = URI.parse(@couchdb_uri)

      anonymous =
        %URI{uri | userinfo: nil, authority: nil}
        |> URI.to_string()
        |> Sofa.init()
        |> Sofa.client()

      db = %Sofa{anonymous | database: name}

      {:ok, pid} = Changes.start(TestFollower, %{db: db, pid: self(), on_error: {:stop, :bye}})
      ref = Process.monitor(pid)

      assert_receive {:error, :unauthorized}, 5000
      assert_receive {:DOWN, ^ref, :process, ^pid, :bye}, 5000
    end

    test "a missing database reaches handle_error/2 as :not_found", %{admin: admin = %Sofa{}} do
      db = %Sofa{admin | database: "sofa_changes_does_not_exist"}

      {:ok, pid} = Changes.start(TestFollower, %{db: db, pid: self(), on_error: {:stop, :bye}})
      ref = Process.monitor(pid)

      assert_receive {:error, :not_found}, 5000
      assert_receive {:DOWN, ^ref, :process, ^pid, :bye}, 5000
    end

    test "a malformed since with nothing to fall back to is fatal", %{db: db} do
      {:ok, pid} = Changes.start(TestFollower, %{db: db, opts: [since: "garbage"], pid: self()})
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :bad_request}, 5000
    end
  end
end
