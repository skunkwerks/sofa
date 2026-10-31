defmodule SofaMangoLiveTest do
  @moduledoc "`Sofa.Mango` against a real CouchDB."

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 60_000

  alias Sofa.Mango

  @couchdb_uri System.get_env("COUCHDB_URI", "http://admin:passwd@localhost:5984/")

  @movies [
    {"176694", %{"year" => 2011, "title" => "The Tragedy of Man"}},
    {"780504", %{"year" => 2011, "title" => "Drive"}},
    {"1", %{"year" => 1999, "title" => "The Matrix"}},
    {"2", %{"year" => 2014, "title" => "Interstellar"}}
  ]

  setup do
    admin = Sofa.init(@couchdb_uri) |> Sofa.client() |> Sofa.IntegrationHelper.connect!()
    name = "sofa_mango_#{System.unique_integer([:positive])}_#{:rand.uniform(1_000_000)}"
    {:ok, db, _resp} = Sofa.DB.create(admin, name)
    on_exit(fn -> {:ok, _, _} = Sofa.DB.delete(admin, name) end)
    for {id, body} <- @movies, do: Sofa.Doc.new(%{id: id, body: body}) |> Sofa.Doc.save!(db)
    %{db: db}
  end

  test "find, with sort and fields, against an index, and explain", %{db: db} do
    assert {:ok, %{result: :created, ddoc: "_design/movies", name: "by_year"}} =
             Mango.index(db, ["year"], ddoc: "movies", name: "by_year")

    assert {:ok, %{result: :exists}} = Mango.index(db, ["year"], ddoc: "movies", name: "by_year")

    assert {:ok, result} =
             Mango.find(db, %{"year" => %{"$gt" => 2010}},
               sort: [%{"year" => "asc"}],
               fields: ["_id", "year", "title"],
               execution_stats: true
             )

    assert Enum.map(result.docs, & &1.id) |> Enum.sort() == ["176694", "2", "780504"]

    assert %Sofa.Doc{rev: nil, body: %{"year" => 2014, "title" => "Interstellar"}} =
             List.last(result.docs)

    assert %{"results_returned" => 3} = result.execution_stats
    assert result.warning == nil

    assert {:ok, %{"index" => %{"ddoc" => "_design/movies", "name" => "by_year"}}} =
             Mango.explain(db, %{"year" => %{"$gt" => 2010}})

    assert {:ok, indexes} = Mango.indexes(db)
    assert Enum.map(indexes, & &1["name"]) |> Enum.sort() == ["_all_docs", "by_year"]
    assert :ok = Mango.delete_index(db, "movies", "by_year")
    assert {:error, :not_found} = Mango.delete_index(db, "movies", "by_year")
  end

  test "stream pages through every match by bookmark", %{db: db} do
    # sorting needs an index on the sort field
    {:ok, _} = Mango.index(db, ["year"])

    titles =
      Mango.stream(db, %{"year" => %{"$gt" => 0}}, limit: 3, sort: [%{"year" => "asc"}])
      |> Enum.map(& &1.body["title"])

    assert length(titles) == 4
    assert hd(titles) == "The Matrix"
    assert Mango.stream(db, %{"year" => 1850}) |> Enum.to_list() == []
  end
end
