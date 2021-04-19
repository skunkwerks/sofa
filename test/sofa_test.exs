defmodule SofaTest do
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
      %{method: :get, url: @plain_url} ->
        %Tesla.Env{status: 200, body: fixture("init_200.json")}

      %{method: :get, url: @plain_url <> "_up"} ->
        %Tesla.Env{method: :get, status: 200, body: fixture("up_200.json")}

      %{method: :get, url: @plain_url <> "_active_tasks"} ->
        %Tesla.Env{method: :get, status: 401, body: fixture("active_tasks_401.json")}

      %{method: :get, url: @plain_url <> "_all_dbs", headers: @admin_header} ->
        %Tesla.Env{method: :get, status: 200, body: fixture("all_dbs_200.json")}
    end)

    :ok
  end

  # doctest Sofa

  test "init returns expected struct" do
    assert Sofa.init() == %Sofa{
             auth: "admin:passwd",
             features: nil,
             uri: %URI{
               authority: "admin:passwd@localhost:5984",
               fragment: nil,
               host: "localhost",
               path: "/",
               port: 5984,
               query: nil,
               scheme: "http",
               userinfo: "admin:passwd"
             },
             uuid: nil,
             vendor: nil,
             version: nil
           }
  end

  test "connect accepts plain URI and returns %Sofa{}" do
    assert Sofa.connect!(@plain_url) |> is_struct(Sofa)
  end

  test "returns valid updated %Sofa{} on GET / 200 OK" do
    expected = fixture("init_200.json")
    sofa = Sofa.connect!(@plain_url)
    assert is_struct(sofa, Sofa)
    assert expected["version"] == sofa.version
    assert expected["uuid"] == sofa.uuid
    assert is_list(expected["features"])
  end

  test "GET /_up returns 200 OK and %Sofa.Response{}" do
    expected = fixture("up_200.json")
    response = Sofa.connect!(@plain_url) |> Sofa.raw!("_up")
    assert %Sofa.Response{method: :get, status: 200} = response
    assert response.body == expected
  end

  test "GET /_active_tasks without credentials returns 401 Unauthorized" do
    expected = fixture("active_tasks_401.json")
    response = Sofa.connect!(@plain_sofa) |> Sofa.raw("_active_tasks")

    assert {:error,
            %Sofa.Response{
              method: :get,
              status: 401,
              body: ^expected
            }} = response
  end

  test "GET /_all_dbs with admin credentials returns 200 OK" do
    expected = fixture("all_dbs_200.json")
    response = Sofa.connect!(@admin_sofa) |> Sofa.raw("_all_dbs")

    assert {:ok, %Sofa{},
            %Sofa.Response{
              method: :get,
              status: 200,
              body: ^expected
            }} = response
  end

  defp fixture(f), do: File.read!("test/fixtures/" <> f) |> Jason.decode!()
end
