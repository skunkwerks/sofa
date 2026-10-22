defmodule SofaAttachmentLiveTest do
  @moduledoc """
  `Sofa.Attachment` and the attachment side of `Sofa.Doc` against a real
  CouchDB. Excluded by default, see test/integration/README.md. Every test
  creates its own throwaway database and deletes it afterwards.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 60_000

  alias Sofa.Attachment

  @couchdb_uri System.get_env("COUCHDB_URI", "http://admin:passwd@localhost:5984/")
  @recipe "1. Cook spaghetti\n2. Cook meatballs\n3. Mix them\n4. Add tomato sauce\n5. ...\n6. PROFIT!\n"
  @eels "My hovercraft is full of eels!"

  setup do
    admin = Sofa.init(@couchdb_uri) |> Sofa.client() |> Sofa.connect!()
    name = "sofa_att_#{System.unique_integer([:positive])}_#{:rand.uniform(1_000_000)}"
    {:ok, db, _resp} = Sofa.DB.create(admin, name)
    on_exit(fn -> {:ok, _, _} = Sofa.DB.delete(admin, name) end)
    %{db: db}
  end

  test "inline attachments save with the document and come back with attachments: true", %{db: db} do
    doc =
      Sofa.Doc.new(%{id: "SpaghettiWithMeatballs", body: %{"servings" => 4}})
      |> Sofa.Doc.attach("recipe.txt", @recipe)
      |> Sofa.Doc.attach("pixel", <<137, 80, 78, 71>>, content_type: "image/png")
      |> Sofa.Doc.save!(db)

    assert "1-" <> _ = doc.rev

    # stubs only by default. Text/plain is compressible, so CouchDB stored it
    # gzipped and digested that, while the png is stored and digested as-is
    fetched = Sofa.Doc.get!(db, "SpaghettiWithMeatballs", att_encoding_info: true)

    assert %Attachment{
             data: nil,
             length: 86,
             revpos: 1,
             content_type: "text/plain",
             encoding: "gzip"
           } =
             fetched.attachments["recipe.txt"]

    assert %Attachment{encoding: nil, digest: digest} = fetched.attachments["pixel"]
    assert digest == Attachment.digest(<<137, 80, 78, 71>>)

    # content with attachments: true
    inline =
      Sofa.Doc.get!(db, "SpaghettiWithMeatballs", attachments: true, att_encoding_info: true)

    assert %Attachment{data: @recipe, content_type: "text/plain"} =
             inline.attachments["recipe.txt"]

    assert %Attachment{data: <<137, 80, 78, 71>>, content_type: "image/png"} =
             inline.attachments["pixel"]

    assert Attachment.verified?(inline.attachments["pixel"])
    refute Attachment.verified?(inline.attachments["recipe.txt"])

    # saving a fetched document keeps its attachments via their stubs, and
    # detaching one removes it
    kept =
      fetched
      |> Map.update!(:body, &Map.put(&1, "servings", 6))
      |> Sofa.Doc.detach("pixel")
      |> Sofa.Doc.save!(db)

    assert "2-" <> _ = kept.rev
    assert Map.keys(Sofa.Doc.get!(db, "SpaghettiWithMeatballs").attachments) == ["recipe.txt"]
  end

  test "standalone put, head, get and delete, with compression handled", %{db: db} do
    doc = Sofa.Doc.new("film") |> Sofa.Doc.save!(db)

    doc = Attachment.put!(doc, db, "recipe.txt", @recipe)
    assert "2-" <> _ = doc.rev
    assert %Attachment{revpos: 2, length: 86, digest: nil} = doc.attachments["recipe.txt"]

    assert {:ok, head} = Attachment.head(db, doc, "recipe.txt")
    assert %Attachment{content_type: "text/plain", encoding: "gzip", length: nil} = head
    assert is_integer(head.encoded_length)

    # the bytes are verified against the digest as stored, then decompressed
    assert {:ok, got} = Attachment.get(db, doc, "recipe.txt")
    assert %Attachment{data: @recipe, length: 86, encoding: "gzip", digest: digest} = got
    assert got.encoded_length == head.encoded_length
    assert digest == head.digest

    # conditional get with the digest CouchDB handed out
    assert {:ok, :not_modified} = Attachment.get(db, doc, "recipe.txt", if_none_match: got.digest)

    # a stale rev conflicts, the current one deletes
    stale = %Sofa.Doc{doc | rev: "1-" <> String.slice(doc.rev, 2..-1//1)}
    assert {:error, :conflict} = Attachment.put(stale, db, "recipe.txt", "nope")

    doc = Attachment.delete!(doc, db, "recipe.txt")
    assert "3-" <> _ = doc.rev
    assert doc.attachments == %{}
    assert {:error, :not_found} = Attachment.head(db, doc, "recipe.txt")
  end

  @tag :tmp_dir
  test "files stream up and down, and octet-streams support ranges", %{db: db, tmp_dir: dir} do
    up = Path.join(dir, "file.txt")
    File.write!(up, @eels)

    doc =
      "doc"
      |> Attachment.put!(db, "file.txt", {:file, up}, content_type: "application/octet-stream")

    assert "1-" <> _ = doc.rev

    assert %Attachment{length: 30, content_type: "application/octet-stream"} =
             doc.attachments["file.txt"]

    assert {:ok, %Attachment{data: "My hovercraft", length: 13}} =
             Attachment.get(db, doc, "file.txt", range: 0..12)

    # octet-streams are stored as-is, so the digest is of the plain bytes
    assert {:ok, whole} = Attachment.get(db, doc, "file.txt")
    assert %Attachment{data: @eels, encoding: nil} = whole
    assert Attachment.verified?(whole)

    down = Path.join(dir, "download.txt")

    assert {:ok, %Attachment{data: %File.Stream{}}} =
             Attachment.get(db, doc, "file.txt", into: File.stream!(down))

    assert File.read!(down) == @eels

    # an enumerable body, chunked
    doc = Attachment.put!(doc, db, "parts.txt", Stream.map(["My ", "hover", "craft"], & &1))
    assert Attachment.get!(db, doc, "parts.txt").data == "My hovercraft"
  end

  test "a document created by an upload can then be fetched and extended", %{db: db} do
    doc =
      "SpaghettiWithMeatballs"
      |> Attachment.put!(db, "recipe.txt", @recipe)
      |> Attachment.put!(db, "eels.bin", @eels, content_type: "application/octet-stream")

    assert "2-" <> _ = doc.rev

    assert Map.keys(Sofa.Doc.get!(db, "SpaghettiWithMeatballs").attachments) == [
             "eels.bin",
             "recipe.txt"
           ]

    assert {:error, :not_found} = Attachment.get(db, "nobody", "recipe.txt")
    assert {:error, :not_found} = Attachment.get(db, doc, "nothing.txt")
  end
end
