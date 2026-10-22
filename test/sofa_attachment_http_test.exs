defmodule SofaAttachmentHttpTest do
  @moduledoc "`Sofa.Attachment` against a Bypass fake serving raw bytes."

  use ExUnit.Case, async: true

  import Plug.Conn, only: [put_resp_header: 3, get_req_header: 2, fetch_query_params: 1, resp: 3]
  import Sofa.BypassHelpers, only: [start: 0, json: 3, empty: 2]

  alias Sofa.Attachment

  @recipe "1. Cook spaghetti\n2. Cook meatballs\n3. Mix them\n"
  @recipe_etag @recipe |> Attachment.digest() |> String.replace_prefix("md5-", "")

  setup do
    %{bypass: bypass, sofa: sofa} = start()
    test = self()
    Bypass.stub(bypass, "GET", "/", &json(&1, 200, "init_200.json"))
    Bypass.stub(bypass, "HEAD", "/recipes", &empty(&1, 200))

    # the documented example, with a real MD5 as the ETag
    for method <- ["HEAD", "GET"] do
      Bypass.stub(bypass, method, "/recipes/SpaghettiWithMeatballs/recipe.txt", fn conn ->
        conn = fetch_query_params(conn)

        conn =
          conn
          |> put_resp_header("etag", ~s("#{@recipe_etag}"))
          |> put_resp_header("content-type", "text/plain")
          |> put_resp_header("accept-ranges", "bytes")
          |> put_resp_header("x-rev", conn.query_params["rev"] || "none")

        cond do
          get_req_header(conn, "if-none-match") == [~s("#{@recipe_etag}")] ->
            resp(conn, 304, "")

          get_req_header(conn, "range") == ["bytes=0-12"] ->
            conn
            |> put_resp_header("content-range", "bytes 0-12/#{byte_size(@recipe)}")
            |> resp(206, binary_part(@recipe, 0, 13))

          # Cowboy drops the body of a HEAD response but keeps its length
          true ->
            resp(conn, 200, @recipe)
        end
      end)
    end

    # stored gzipped, as CouchDB does for its compressible types: the ETag is
    # the digest of the gzipped bytes, and the length their size
    gzipped = :zlib.gzip(@recipe)

    for method <- ["HEAD", "GET"] do
      Bypass.stub(bypass, method, "/recipes/SpaghettiWithMeatballs/zipped.txt", fn conn ->
        conn
        |> put_resp_header(
          "etag",
          ~s("#{Attachment.digest(gzipped) |> String.replace_prefix("md5-", "")}")
        )
        |> put_resp_header("content-type", "text/plain")
        |> put_resp_header("content-encoding", "gzip")
        |> resp(200, gzipped)
      end)
    end

    Bypass.stub(bypass, "GET", "/recipes/SpaghettiWithMeatballs/corrupt.txt", fn conn ->
      conn |> put_resp_header("etag", ~s("#{@recipe_etag}")) |> resp(200, "not the recipe")
    end)

    Bypass.stub(bypass, "GET", "/recipes/SpaghettiWithMeatballs/the_hun.json", fn conn ->
      conn
      |> put_resp_header("content-type", "application/json")
      |> resp(200, ~s({"attila": true}))
    end)

    Bypass.stub(
      bypass,
      "GET",
      "/recipes/SpaghettiWithMeatballs/missing.txt",
      &json(&1, 404, "get_doc_404.json")
    )

    Bypass.stub(bypass, "HEAD", "/recipes/SpaghettiWithMeatballs/missing.txt", &empty(&1, 404))

    # writes: report what arrived, answer with the next revision
    Bypass.stub(bypass, "PUT", "/recipes/:doc/:name", fn conn ->
      {conn, body} = read_all(conn)
      send(test, {:put, conn.request_path, Map.new(conn.req_headers), body})

      case get_req_header(conn, "if-match") do
        ["9-stale"] -> json(conn, 409, "put_doc_409.json")
        [] -> resp(conn, 201, ~s({"ok": true, "id": "fresh", "rev": "1-new"}))
        ["1-abc"] -> resp(conn, 201, ~s({"ok": true, "id": "doc", "rev": "2-def"}))
      end
      |> put_resp_header("content-type", "application/json")
    end)

    Bypass.stub(bypass, "DELETE", "/recipes/:doc/:name", fn conn ->
      conn = fetch_query_params(conn)
      send(test, {:delete, conn.request_path, Map.new(conn.req_headers), conn.query_params})

      case get_req_header(conn, "if-match") do
        ["2-def"] ->
          conn
          |> put_resp_header("content-type", "application/json")
          |> resp(200, ~s({"ok": true, "id": "doc", "rev": "3-ghi"}))

        _ ->
          json(conn, 404, "get_doc_404.json")
      end
    end)

    %{db: Sofa.connect!(sofa) |> Sofa.DB.open!("recipes")}
  end

  defp read_all(conn, acc \\ "") do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {conn, acc <> body}
      {:more, body, conn} -> read_all(conn, acc <> body)
    end
  end

  describe "head/4" do
    test "reads the metadata from the headers", %{db: db} do
      assert {:ok, att} = Attachment.head(db, "SpaghettiWithMeatballs", "recipe.txt")

      assert %Attachment{
               name: "recipe.txt",
               content_type: "text/plain",
               length: 48,
               digest: "md5-" <> @recipe_etag,
               encoding: nil,
               data: nil
             } = att
    end

    test "accepts a document, a rev and a digest to compare", %{db: db} do
      doc = Sofa.Doc.new("SpaghettiWithMeatballs")
      assert {:ok, %Attachment{}} = Attachment.head(db, doc, "recipe.txt", rev: "1-abc")

      assert {:ok, :not_modified} =
               Attachment.head(db, doc, "recipe.txt", if_none_match: "md5-" <> @recipe_etag)

      assert {:error, :not_found} = Attachment.head(db, doc, "missing.txt")
    end
  end

  describe "get/4" do
    test "returns the bytes with their metadata, verifiable against the digest", %{db: db} do
      assert {:ok, att} = Attachment.get(db, "SpaghettiWithMeatballs", "recipe.txt")
      assert %Attachment{data: @recipe, length: 48, content_type: "text/plain"} = att
      assert Attachment.verified?(att)
    end

    test "leaves JSON attachments as bytes", %{db: db} do
      assert {:ok, %Attachment{data: ~s({"attila": true})}} =
               Attachment.get(db, "SpaghettiWithMeatballs", "the_hun.json")
    end

    test "a gzipped attachment is verified as stored, then decompressed", %{db: db} do
      assert {:ok, att} = Attachment.get(db, "SpaghettiWithMeatballs", "zipped.txt")
      assert %Attachment{data: @recipe, length: 48, encoding: "gzip"} = att
      assert att.encoded_length == byte_size(:zlib.gzip(@recipe))
      assert att.digest == Attachment.digest(:zlib.gzip(@recipe))

      assert {:ok, head} = Attachment.head(db, "SpaghettiWithMeatballs", "zipped.txt")
      assert %Attachment{encoding: "gzip", length: nil, data: nil} = head
      assert head.encoded_length == byte_size(:zlib.gzip(@recipe))
    end

    test "bytes that do not match the digest are refused", %{db: db} do
      assert {:error, :digest_mismatch} =
               Attachment.get(db, "SpaghettiWithMeatballs", "corrupt.txt")
    end

    test "fetches a byte range", %{db: db} do
      assert {:ok, %Attachment{data: "1. Cook spagh", length: 13}} =
               Attachment.get(db, "SpaghettiWithMeatballs", "recipe.txt", range: 0..12)
    end

    @tag :tmp_dir
    test "streams into a sink", %{db: db, tmp_dir: dir} do
      path = Path.join(dir, "recipe.txt")

      assert {:ok, %Attachment{data: %File.Stream{}}} =
               Attachment.get(db, "SpaghettiWithMeatballs", "recipe.txt",
                 into: File.stream!(path)
               )

      assert File.read!(path) == @recipe
    end

    test "conditional and missing attachments", %{db: db} do
      assert {:ok, :not_modified} =
               Attachment.get(db, "SpaghettiWithMeatballs", "recipe.txt",
                 if_none_match: "md5-" <> @recipe_etag
               )

      assert {:error, :not_found} = Attachment.get(db, "SpaghettiWithMeatballs", "missing.txt")
    end
  end

  describe "get!/4" do
    test "returns the attachment or raises", %{db: db} do
      assert %Attachment{data: @recipe} =
               Attachment.get!(db, "SpaghettiWithMeatballs", "recipe.txt")

      assert_raise Sofa.Error,
                   ~r/unable to get attachment missing.txt of SpaghettiWithMeatballs: :not_found/,
                   fn ->
                     Attachment.get!(db, "SpaghettiWithMeatballs", "missing.txt")
                   end
    end
  end

  describe "put/5 and put!/5" do
    test "uploads with the content type and If-Match, returning the doc with its stub", %{db: db} do
      doc = %Sofa.Doc{Sofa.Doc.new("doc") | rev: "1-abc"}
      assert {:ok, doc} = Attachment.put(doc, db, "recipe.txt", @recipe)

      assert_receive {:put, "/recipes/doc/recipe.txt", headers, @recipe}
      assert headers["content-type"] == "text/plain"
      assert headers["if-match"] == "1-abc"

      assert %Sofa.Doc{rev: "2-def", attachments: %{"recipe.txt" => stub}} = doc

      assert %Attachment{
               content_type: "text/plain",
               revpos: 2,
               length: 48,
               data: nil,
               digest: nil
             } = stub
    end

    test "a bare id creates the document, with an explicit content type", %{db: db} do
      assert {:ok, %Sofa.Doc{id: "fresh", rev: "1-new"}} =
               Attachment.put("fresh", db, "blob", <<0, 1>>, content_type: "application/x-sofa")

      assert_receive {:put, "/recipes/fresh/blob",
                      %{"content-type" => "application/x-sofa"} = headers, <<0, 1>>}

      refute Map.has_key?(headers, "if-match")
    end

    @tag :tmp_dir
    test "files and enumerables are streamed as chunked uploads", %{db: db, tmp_dir: dir} do
      path = Path.join(dir, "recipe.txt")
      File.write!(path, @recipe)
      doc = %Sofa.Doc{Sofa.Doc.new("doc") | rev: "1-abc"}

      assert {:ok, %Sofa.Doc{attachments: %{"recipe.txt" => %Attachment{length: 48}}}} =
               Attachment.put(doc, db, "recipe.txt", {:file, path})

      # the stream arrives whole. Cowboy hides the transfer-encoding it used
      assert_receive {:put, "/recipes/doc/recipe.txt", _headers, @recipe}

      assert {:ok, %Sofa.Doc{attachments: %{"parts.txt" => %Attachment{length: nil}}}} =
               Attachment.put(doc, db, "parts.txt", ["1. Cook ", "spaghetti"])

      assert_receive {:put, "/recipes/doc/parts.txt", _headers, "1. Cook spaghetti"}
    end

    test "a stale revision is a conflict, and put! raises on it", %{db: db} do
      stale = %Sofa.Doc{Sofa.Doc.new("doc") | rev: "9-stale"}
      assert {:error, :conflict} = Attachment.put(stale, db, "recipe.txt", @recipe)

      assert_raise Sofa.Error, ~r/unable to put attachment recipe.txt on doc: :conflict/, fn ->
        Attachment.put!(stale, db, "recipe.txt", @recipe)
      end

      assert %Sofa.Doc{rev: "2-def"} =
               Attachment.put!(
                 %Sofa.Doc{Sofa.Doc.new("doc") | rev: "1-abc"},
                 db,
                 "recipe.txt",
                 @recipe
               )
    end
  end

  describe "delete/4 and delete!/4" do
    test "sends If-Match and returns the doc without the stub", %{db: db} do
      doc =
        %Sofa.Doc{Sofa.Doc.new("doc") | rev: "1-abc"}
        |> Attachment.put!(db, "recipe.txt", @recipe)

      assert {:ok, doc} = Attachment.delete(doc, db, "recipe.txt", batch: :ok)

      assert_receive {:delete, "/recipes/doc/recipe.txt", %{"if-match" => "2-def"},
                      %{"batch" => "ok"}}

      assert %Sofa.Doc{rev: "3-ghi", attachments: %{}} = doc
    end

    test "needs a revision, and delete! raises on failure", %{db: db} do
      assert_raise ArgumentError, ~r/revision is required/, fn ->
        Attachment.delete("doc", db, "recipe.txt")
      end

      assert {:error, :not_found} = Attachment.delete("doc", db, "recipe.txt", rev: "1-abc")

      assert_raise Sofa.Error,
                   ~r/unable to delete attachment recipe.txt of doc: :not_found/,
                   fn ->
                     Attachment.delete!("doc", db, "recipe.txt", rev: "1-abc")
                   end
    end
  end
end
