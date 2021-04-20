defmodule SofaDbTest do
  use ExUnit.Case, async: true

  @plain_url "http://localhost:5984/"
  @plain_sofa Sofa.init(@plain_url) |> Sofa.client()
  @admin_password "admin:passwd"
  @admin_url "http://" <> @admin_password <> "@localhost:5984/"
  @admin_sofa Sofa.init(@admin_url) |> Sofa.client()
  @admin_header [{"authorization", "Basic " <> Base.encode64(@admin_password)}]

  import Tesla.Mock

  setup do
    mock(fn
      # required for Sofa.connect!/1 in all tests
      %{method: :get, url: @plain_url} ->
        %Tesla.Env{status: 200, body: fixture("init_200.json")}

      %{method: :get, url: @plain_url <> "missing"} ->
        %Tesla.Env{method: :get, status: 404, body: fixture("get_db_404.json")}

      %{method: :get, url: @plain_url <> "exists"} ->
        %Tesla.Env{method: :get, status: 200, body: fixture("get_db_200.json")}

      %{method: :put, url: @plain_url <> "newdb", headers: @admin_header} ->
        %Tesla.Env{method: :put, status: 200, body: fixture("put_db_200.json")}

      %{method: :put, url: @plain_url <> "already"} ->
        %Tesla.Env{method: :put, status: 412, body: fixture("put_db_412.json")}

      %{method: :delete, url: @plain_url <> "trash"} ->
        %Tesla.Env{method: :delete, status: 202, body: fixture("delete_db_202.json")}
    end)

    :ok
  end

  test "GET /missing db returns 404 Not Found" do
    expected = fixture("get_db_404.json")
    response = Sofa.connect!(@plain_sofa) |> Sofa.DB.info("missing")

    assert {:error,
            %Sofa.Response{
              method: :get,
              status: 404,
              body: ^expected
            }} = response
  end

  test "GET /exists returns 200 OK" do
    expected = fixture("get_db_200.json")
    response = Sofa.connect!(@plain_sofa) |> Sofa.DB.info("exists")

    assert {:ok, %Sofa{},
            %Sofa.Response{
              method: :get,
              status: 200,
              body: ^expected
            }} = response
  end

  test "PUT /newdb returns 200 OK" do
    expected = fixture("put_db_200.json")
    response = Sofa.connect!(@admin_sofa) |> Sofa.DB.create("newdb")

    assert {:ok, %Sofa{},
            %Sofa.Response{
              method: :put,
              status: 200,
              body: ^expected
            }} = response
  end

  test "PUT /already returns 412 File Exists" do
    expected = fixture("put_db_412.json")
    response = Sofa.connect!(@admin_sofa) |> Sofa.DB.create("already")

    assert {:error,
            %Sofa.Response{
              method: :put,
              status: 412,
              body: ^expected
            }} = response
  end

  test "DELETE /trash returns 202 OK" do
    expected = fixture("delete_db_202.json")
    response = Sofa.connect!(@admin_sofa) |> Sofa.DB.delete("trash")

    assert {:ok, %Sofa{},
            %Sofa.Response{
              method: :delete,
              status: 202,
              body: ^expected
            }} = response
  end

  defp fixture(f), do: File.read!("test/fixtures/" <> f) |> Jason.decode!()
end
