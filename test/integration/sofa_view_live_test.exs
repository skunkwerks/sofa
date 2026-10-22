defmodule SofaViewLiveTest do
  @moduledoc "`Sofa.View` against a real CouchDB, with the documented recipes design document."

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 60_000

  import Sofa.Design, only: [sigil_JS: 2]

  alias Sofa.View
  alias Sofa.View.Row

  @couchdb_uri System.get_env("COUCHDB_URI", "http://admin:passwd@localhost:5984/")

  # the design document from the CouchDB views documentation, plus a reduce
  @by_ingredient ~JS"""
  function(doc) {
    if (doc.ingredients) doc.ingredients.forEach(function(i) { emit(i, 1); });
  }
  """

  @by_title ~JS"""
  function(doc) {
    if (doc.title) emit(doc.title, doc.servings);
  }
  """

  @recipes %{
    "views" => %{
      "by_ingredient" => %{"map" => @by_ingredient, "reduce" => "_sum"},
      "by_title" => %{"map" => @by_title}
    }
  }

  setup do
    admin = Sofa.init(@couchdb_uri) |> Sofa.client() |> Sofa.connect!()
    name = "sofa_view_#{System.unique_integer([:positive])}_#{:rand.uniform(1_000_000)}"
    {:ok, db, _resp} = Sofa.DB.create(admin, name)
    on_exit(fn -> {:ok, _, _} = Sofa.DB.delete(admin, name) end)

    Sofa.Doc.new(%{id: "_design/recipes", body: @recipes}) |> Sofa.Doc.save!(db)

    Sofa.Doc.new(%{
      id: "SpaghettiWithMeatballs",
      body: %{
        "title" => "Spaghetti with meatballs",
        "servings" => 4,
        "ingredients" => ["meatballs", "spaghetti", "tomato sauce"]
      }
    })
    |> Sofa.Doc.save!(db)

    Sofa.Doc.new(%{
      id: "LasagneAlForno",
      body: %{
        "title" => "Lasagne al forno",
        "servings" => 6,
        "ingredients" => ["pasta", "tomato sauce"]
      }
    })
    |> Sofa.Doc.save!(db)

    %{db: db}
  end

  test "a map view returns rows in key order, with keys and docs on request", %{db: db} do
    assert {:ok, %View{total_rows: 5, rows: rows}} =
             View.query(db, "recipes", "by_ingredient", reduce: false)

    assert Enum.map(rows, & &1.key) == [
             "meatballs",
             "pasta",
             "spaghetti",
             "tomato sauce",
             "tomato sauce"
           ]

    assert {:ok,
            %View{
              rows: [%Row{id: "SpaghettiWithMeatballs", doc: %Sofa.Doc{body: %{"servings" => 4}}}]
            }} =
             View.query(db, "recipes", "by_ingredient",
               key: "meatballs",
               reduce: false,
               include_docs: true
             )

    assert {:ok, %View{rows: rows}} =
             View.query(db, "recipes", "by_ingredient",
               keys: ["pasta", "meatballs"],
               reduce: false
             )

    assert Enum.map(rows, & &1.key) == ["pasta", "meatballs"]
  end

  test "a reduce view sums, overall and per group", %{db: db} do
    assert {:ok, %View{rows: [%Row{key: nil, value: 5}]}} =
             View.query(db, "recipes", "by_ingredient")

    assert {:ok, %View{rows: rows}} = View.query(db, "recipes", "by_ingredient", group: true)

    assert Map.new(rows, &{&1.key, &1.value}) == %{
             "meatballs" => 1,
             "pasta" => 1,
             "spaghetti" => 1,
             "tomato sauce" => 2
           }
  end

  test "all_docs, design_docs, queries and a stream of pages", %{db: db} do
    assert {:ok, %View{total_rows: 3, rows: rows}} = View.all_docs(db, startkey: "L", endkey: "T")
    assert Enum.map(rows, & &1.id) == ["LasagneAlForno", "SpaghettiWithMeatballs"]
    assert %Row{value: %{"rev" => "1-" <> _}} = hd(rows)

    assert {:ok, %View{rows: [%Row{id: "_design/recipes"}]}} = View.design_docs(db)

    assert {:ok,
            [
              %View{rows: [%Row{value: 2}]},
              %View{rows: [%Row{key: "Lasagne al forno", value: 6}]}
            ]} =
             View.queries(db, "recipes", "by_ingredient", [[key: "tomato sauce"], []])
             |> then(fn {:ok, [sum, _]} ->
               {:ok, [sum, View.query!(db, "recipes", "by_title", limit: 1)]}
             end)

    titles = View.stream(db, "recipes", "by_title", limit: 1) |> Enum.map(& &1.key)
    assert titles == ["Lasagne al forno", "Spaghetti with meatballs"]
    assert View.stream(db, :all_docs, nil, limit: 2) |> Enum.count() == 3
  end
end
