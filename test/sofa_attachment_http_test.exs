defmodule SofaAttachmentHttpTest do
  @moduledoc "`Sofa.Attachment` against a Bypass fake serving raw bytes."

  use ExUnit.Case, async: true

  import Plug.Conn, only: [put_resp_header: 3, get_req_header: 2, fetch_query_params: 1, resp: 3]
  import Sofa.BypassHelpers

  alias Sofa.Attachment

  @recipe "1. Cook spaghetti\n2. Cook meatballs\n3. Mix them\n"
  @recipe_etag @recipe |> Attachment.digest() |> String.replace_prefix("md5-", "")

  setup do
    %{bypass: bypass, sofa: sofa} = start()
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

    %{db: Sofa.connect!(sofa) |> Sofa.DB.open!("recipes")}
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
end
