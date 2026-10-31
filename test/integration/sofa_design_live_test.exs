defmodule SofaDesignLiveTest do
  @moduledoc "`Sofa.Design` against a real CouchDB: a built design document, queried, filtered and inspected."

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 60_000

  import Sofa.Design, only: [sigil_JS: 2]

  alias Sofa.{Design, Doc, View}

  @couchdb_uri System.get_env("COUCHDB_URI", "http://admin:passwd@localhost:5984/")

  @by_title ~JS"""
  function(doc) {
    if (doc.title) emit(doc.title, doc.servings);
  }
  """

  # design documents are exempt, so the test can write its own
  @validate ~JS"""
  function(newDoc, oldDoc, userCtx) {
    if (newDoc.title === undefined && !newDoc._deleted && newDoc._id.indexOf('_design/') !== 0) {
      throw({forbidden: 'needs a title'});
    }
  }
  """

  setup do
    admin = Sofa.init(@couchdb_uri) |> Sofa.client() |> Sofa.IntegrationHelper.connect!()
    name = "sofa_design_#{System.unique_integer([:positive])}_#{:rand.uniform(1_000_000)}"
    {:ok, db, _resp} = Sofa.DB.create(admin, name)
    on_exit(fn -> {:ok, _, _} = Sofa.DB.delete(admin, name) end)
    %{db: db}
  end

  test "a built design document serves views, validates writes and reports its index", %{db: db} do
    ddoc =
      Design.new("recipes")
      |> Design.view("by_title", @by_title)
      |> Design.validate(@validate)
      |> Doc.save!(db)

    assert "1-" <> _ = ddoc.rev

    assert %Doc{id: "_design/recipes", body: %{"views" => %{"by_title" => _}}} =
             Design.get!(db, "recipes")

    assert {:ok, [%Doc{id: "_design/recipes"}]} = Design.all(db)

    # the validation function rejects a document without a title
    assert {:error, :forbidden} =
             Doc.new(%{id: "untitled", body: %{"servings" => 1}}) |> Doc.save(db)

    Doc.new(%{id: "Lasagne", body: %{"title" => "Lasagne al forno", "servings" => 6}})
    |> Doc.save!(db)

    assert {:ok, %View{rows: [%View.Row{key: "Lasagne al forno", value: 6}]}} =
             View.query(db, "recipes", "by_title")

    assert {:ok, %{"name" => "recipes", "view_index" => index}} = Design.info(db, "recipes")

    assert %{
             "language" => "javascript",
             "updater_running" => false,
             "signature" => <<_::binary-size(32)>>
           } = index

    assert {:error, :not_found} = Design.info(db, "nothing")
  end
end
