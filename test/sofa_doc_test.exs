defmodule SofaDocTest do
  use ExUnit.Case, async: true

  @plain_url "http://localhost:5984/"
  @plain_sofa Sofa.init(@plain_url) |> Sofa.client()
  @admin_password "admin:passwd"
  @admin_url "http://" <> @admin_password <> "@localhost:5984/"
  @admin_sofa Sofa.init(@admin_url) |> Sofa.client()
  @etag_header {"ETag", ~s("1-leet")}
  @ifmatch_header {"If-Match", ~s("1-leet")}

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

      # actual doc tests start here
      # https://docs.couchdb.org/en/stable/api/document/common.html

      # HEAD doc
      %{method: :head, url: @plain_url <> "mydb/missing"} ->
        %Tesla.Env{method: :head, status: 404, body: ""}

      %{method: :head, url: @plain_url <> "mydb/exists"} ->
        %Tesla.Env{method: :head, status: 200, headers: [@etag_header]}

      # GET doc
      %{method: :get, url: @plain_url <> "mydb/missing"} ->
        %Tesla.Env{method: :get, status: 404, body: ""}

      %{method: :get, url: @plain_url <> "mydb/exists"} ->
        %Tesla.Env{method: :get, status: 200, headers: [@etag_header]}

      # DELETE doc
      %{method: :delete, url: @plain_url <> "mydb/missing"} ->
        %Tesla.Env{
          method: :delete,
          status: 404,
          headers: [@ifmatch_header],
          body: fixture("delete_doc_404.json")
        }

      %{method: :delete, url: @plain_url <> "mydb/wrong_rev"} ->
        %Tesla.Env{
          method: :delete,
          status: 409,
          headers: [],
          body: fixture("delete_doc_409.json")
        }

      %{method: :delete, url: @plain_url <> "mydb/exists"} ->
        %Tesla.Env{
          method: :delete,
          status: 200,
          headers: [@ifmatch_header],
          body: fixture("delete_doc_200.json")
        }

        # put
    end)

    :ok
  end

  test "GET /mydb returns 200 OK" do
    expected = fixture("get_db_200.json")
    response = Sofa.connect!(@plain_sofa) |> Sofa.DB.info("mydb")

    assert {:ok, %Sofa{},
            %Sofa.Response{
              method: :get,
              status: 200,
              body: ^expected
            }} = response
  end

  test "HEAD /mydb/missing returns :false" do
    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.exists?("missing")

    assert !response
  end

  test "HEAD /mydb/exists returns 200 OK" do
    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.exists?("exists")

    assert response
  end

  # DELETE doc
  # https://docs.couchdb.org/en/stable/api/document/common.html
  # %{method: :delete, url: @plain_url <> "mydb/missing"} ->
  #   %Tesla.Env{method: :delete, status: 404, headers: [@ifmatch_header], body: fixture("delete_doc_404.json")}

  # %{method: :delete, url: @plain_url <> "mydb/wrong_rev"} ->
  #   %Tesla.Env{method: :delete, status: 409, headers: [],body: fixture("delete_doc_409.json") }

  # %{method: :delete, url: @plain_url <> "mydb/exists"} ->
  #   %Tesla.Env{method: :delete, status: 200, headers: [@ifmatch_header], body: fixture("delete_doc_200.json")}

  test "DELETE /mydb/missing returns 404 Not Found" do
    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.delete!("missing")

    assert {:error, :not_found} = response
  end

  test "DELETE /mydb/wrong_rev returns 409 Conflict" do
    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.delete!("wrong_rev")
    assert {:error, :conflict} = response
  end

  test "DELETE /mydb/exists returns 200 OK" do
    expected = fixture("delete_doc_200.json")

    response =
      Sofa.connect!(@plain_sofa)
      |> Sofa.DB.open!("mydb")
      |> Sofa.Doc.delete!("exists")

    assert :ok = response
  end

  defp fixture(f), do: File.read!("test/fixtures/" <> f) |> Jason.decode!()
end
