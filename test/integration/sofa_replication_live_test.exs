defmodule SofaReplicationLiveTest do
  @moduledoc "`Sofa.Replication` against a real CouchDB, between two throwaway databases."

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  alias Sofa.{Doc, Replication}

  @couchdb_uri System.get_env("COUCHDB_URI", "http://admin:passwd@localhost:5984/")

  setup do
    admin = Sofa.init(@couchdb_uri) |> Sofa.client() |> Sofa.connect!()
    stamp = "#{System.unique_integer([:positive])}_#{:rand.uniform(1_000_000)}"
    {:ok, source, _} = Sofa.DB.create(admin, "sofa_repl_src_#{stamp}")
    target = "sofa_repl_tgt_#{stamp}"

    on_exit(fn ->
      {:ok, _, _} = Sofa.DB.delete(admin, source.database)
      Sofa.DB.delete(admin, target)
    end)

    for id <- ["one", "two", "three"],
        do: Doc.new(%{id: id, body: %{"n" => 1}}) |> Doc.save!(source)

    %{admin: admin, source: source, target: target}
  end

  test "a one-off replication copies the documents and reports its history", %{
    admin: admin,
    source: source,
    target: target
  } do
    assert {:ok, result} =
             Replication.replicate(admin, source, %Sofa{admin | database: target},
               create_target: true
             )

    assert %{"ok" => true, "history" => [%{"docs_written" => 3, "doc_write_failures" => 0} | _]} =
             result

    assert {:ok, %Sofa.View{total_rows: 3}} = Sofa.View.all_docs(Sofa.DB.open!(admin, target))
    assert %Doc{id: "two", body: %{"n" => 1}} = Doc.get!(Sofa.DB.open!(admin, target), "two")
  end

  test "a continuous replication shows in the scheduler until cancelled", %{
    admin: admin,
    source: source,
    target: target
  } do
    tgt = %Sofa{admin | database: target}

    assert {:ok, %{"ok" => true, "_local_id" => id}} =
             Replication.replicate(admin, source, tgt, continuous: true, create_target: true)

    assert {:ok, jobs} = Replication.jobs(admin)
    assert Enum.any?(jobs, &(&1["id"] == id))

    assert {:ok, %{"ok" => true}} =
             Replication.cancel(admin, source, tgt, continuous: true, create_target: true)

    Process.sleep(500)
    assert {:ok, jobs} = Replication.jobs(admin)
    refute Enum.any?(jobs, &(&1["id"] == id))
  end

  test "a _replicator document is scheduled and reported", %{
    admin: admin,
    source: source,
    target: target
  } do
    replicator = Sofa.DB.open!(admin, "_replicator")

    doc =
      Replication.new(source, %Sofa{admin | database: target},
        create_target: true,
        id: "sofa_ci_#{target}"
      )
      |> Doc.save!(replicator)

    on_exit(fn -> Doc.delete(replicator, Doc.get!(replicator, doc.id)) end)

    assert {:ok, %{"doc_id" => doc_id, "state" => state}} =
             eventually(fn -> Replication.doc(admin, "_replicator", doc.id) end)

    assert doc_id == doc.id
    assert state in ["initializing", "running", "completed"]
    assert {:ok, docs} = Replication.docs(admin, "_replicator")
    assert Enum.any?(docs, &(&1["doc_id"] == doc.id))
  end

  # the scheduler picks a document up asynchronously
  defp eventually(fun, attempts \\ 20) do
    case fun.() do
      {:ok, result} -> {:ok, result}
      {:error, _} when attempts > 1 -> Process.sleep(250) && eventually(fun, attempts - 1)
      other -> other
    end
  end
end
