defmodule SofaBulkLiveTest do
  @moduledoc "`Sofa.Bulk` against a real CouchDB."

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 60_000

  alias Sofa.{Bulk, Doc}

  @couchdb_uri System.get_env("COUCHDB_URI", "http://admin:passwd@localhost:5984/")

  setup do
    admin = Sofa.init(@couchdb_uri) |> Sofa.client() |> Sofa.connect!()
    name = "sofa_bulk_#{System.unique_integer([:positive])}_#{:rand.uniform(1_000_000)}"
    {:ok, db, _resp} = Sofa.DB.create(admin, name)
    on_exit(fn -> {:ok, _, _} = Sofa.DB.delete(admin, name) end)
    %{db: db}
  end

  test "save, update with a conflict, get with revisions, and delete", %{db: db} do
    docs =
      for id <- ["FishStew", "LambStew", "BeefStew"],
          do: Doc.new(%{id: id, body: %{"servings" => 4}})

    assert {:ok, results} = Bulk.save(db, docs)
    assert Enum.all?(results, &match?({:ok, %Doc{rev: "1-" <> _}}, &1))
    saved = Enum.map(results, fn {:ok, doc} -> doc end)

    # one updated with its rev, one with a stale rev, one new
    [fish = %Doc{}, lamb = %Doc{}, _beef] = saved
    stale = %Doc{lamb | rev: "1-0786321986194c92dd3b57dfbfc741ce"}

    assert {:ok,
            [
              {:ok, %Doc{id: "FishStew", rev: "2-" <> _}},
              {:error, :conflict, ^stale},
              {:ok, %Doc{id: "PorkStew", rev: "1-" <> _}}
            ]} =
             Bulk.save(db, [%Doc{fish | body: %{"servings" => 6}}, stale, Doc.new("PorkStew")])

    assert {:ok,
            [
              {:ok,
               %Doc{
                 id: "FishStew",
                 rev: "2-" <> _,
                 body: %{"servings" => 6, "_revisions" => %{"start" => 2}}
               }},
              {:ok, %Doc{id: "FishStew", rev: "1-" <> _, body: %{"servings" => 4}}},
              {:error, :not_found, "nobody"}
            ]} =
             Bulk.get(db, ["FishStew", {"FishStew", fish.rev}, "nobody"], revs: true)

    assert {:ok, [{:ok, %Doc{id: "LambStew", rev: "2-" <> _}}]} = Bulk.delete(db, [lamb])
    assert {:error, :not_found} = Doc.get(db, "LambStew")
  end
end
