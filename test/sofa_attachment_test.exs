defmodule SofaDocAttachmentTest do
  use ExUnit.Case, async: true

  @plain_url "http://localhost:5984/"
  @plain_sofa Sofa.init(@plain_url) |> Sofa.client()

  import Tesla.Mock

  setup do
    mock(fn
      # required for Sofa.connect!/1 in all tests
      %{method: :get, url: @plain_url} ->
        %Tesla.Env{status: 200, body: fixture("init_200.json")}

      # fake a DB so we can open!/2 it
      %{method: :get, url: @plain_url <> "mydb"} ->
        %Tesla.Env{method: :get, status: 200, body: fixture("get_db_200.json")}

      %{method: :head, url: @plain_url <> "mydb"} ->
        %Tesla.Env{method: :head, status: 200, body: ""}

      # GET attachment
      %{method: :get, url: @plain_url <> "mydb/doc_with_attachment/test.txt"} ->
        %Tesla.Env{
          method: :get,
          status: 200,
          headers: [{"content-type", "text/plain"}],
          body: "some content"
        }

      %{method: :get, url: @plain_url <> "mydb/missing_doc/test.txt"} ->
        %Tesla.Env{
          method: :get,
          status: 404,
          body: %{"error" => "not_found", "reason" => "missing"}
        }

#       # HEAD attachment
#       %{method: :head, url: @plain_url <> "mydb/doc_with_attachment/test.txt"} ->
#         %Tesla.Env{method: :head, status: 200, body: ""}

#       %{method: :head, url: @plain_url <> "mydb/doc_with_attachment/missing.txt"} ->
#         %Tesla.Env{method: :head, status: 404, body: ""}

#       # PUT attachment
#       %{method: :put, url: @plain_url <> "mydb/doc_with_attachment/test.txt"} ->
#         %Tesla.Env{
#           method: :put,
#           status: 201,
#           body: fixture("put_attachment_201.json")
#         }

#       %{method: :put, url: @plain_url <> "mydb/doc_with_attachment/conflict.txt"} ->
#         %Tesla.Env{
#           method: :put,
#           status: 409,
#           body: fixture("put_attachment_409.json")
#         }

#       # DELETE attachment
#       %{method: :delete, url: @plain_url <> "mydb/doc_with_attachment/test.txt"} ->
#         %Tesla.Env{
#           method: :delete,
#           status: 200,
#           body: fixture("delete_attachment_200.json")
#         }

#       %{method: :delete, url: @plain_url <> "mydb/doc_with_attachment/missing.txt"} ->
#         %Tesla.Env{method: :delete, status: 404, body: ""}
#     end)
    end)

    :ok
  end

  # Attachment tests
  test "GET attachment returns content" do
    expected = fixture_raw("get_attachment_200.txt")

    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.get_attachment("doc_with_attachment", "test.txt")

    assert {:ok, ^expected} = response
  end

  # test "GET missing attachment returns :not_found" do
  #   response =
  #     Sofa.connect!(@plain_sofa)
  #     |> Sofa.DB.open!("mydb")
  #     |> Sofa.Doc.get_attachment("missing_doc", "test.txt")

  #   assert {:error, :not_found} = response
  # end

  # test "PUT attachment returns new revision" do
  #   content = "Hello, attachment!"

  #   response =
  #     Sofa.connect!(@plain_sofa)
  #     |> Sofa.DB.open!("mydb")
  #     |> Sofa.Doc.put_attachment(
  #       "doc_with_attachment",
  #       "test.txt",
  #       "text/plain",
  #       content,
  #       "1-abc123"
  #     )

  #   assert {:ok, "2-abc123def456"} = response
  # end

  # test "PUT attachment with wrong rev returns :conflict" do
  #   content = "Hello, attachment!"

  #   response =
  #     Sofa.connect!(@plain_sofa)
  #     |> Sofa.DB.open!("mydb")
  #     |> Sofa.Doc.put_attachment(
  #       "doc_with_attachment",
  #       "conflict.txt",
  #       "text/plain",
  #       content,
  #       "wrong-rev"
  #     )

  #   assert {:error, :conflict} = response
  # end

  # test "DELETE attachment returns new revision" do
  #   response =
  #     Sofa.connect!(@plain_sofa)
  #     |> Sofa.DB.open!("mydb")
  #     |> Sofa.Doc.delete_attachment("doc_with_attachment", "test.txt", "2-def456")

  #   assert {:ok, "1-abc123"} = response
  # end

  # test "DELETE missing attachment returns :not_found" do
  #   response =
  #     Sofa.connect!(@plain_sofa)
  #     |> Sofa.DB.open!("mydb")
  #     |> Sofa.Doc.delete_attachment("doc_with_attachment", "missing.txt", "2-def456")

  #   assert {:error, :not_found} = response
  # end

  # test "attachment_exists? returns true for existing attachment" do
  #   response =
  #     Sofa.connect!(@plain_sofa)
  #     |> Sofa.DB.open!("mydb")
  #     |> Sofa.Doc.attachment_exists?("doc_with_attachment", "test.txt")

  #   assert response == true
  # end

  # test "attachment_exists? returns false for missing attachment" do
  #   response =
  #     Sofa.connect!(@plain_sofa)
  #     |> Sofa.DB.open!("mydb")
  #     |> Sofa.Doc.attachment_exists?("doc_with_attachment", "missing.txt")

  #   assert response == false
  # end

  # Helper function for raw fixture content
  defp fixture_raw(f), do: File.read!("test/fixtures/" <> f)

  defp fixture(f), do: File.read!("test/fixtures/" <> f) |> Jason.decode!()
end
