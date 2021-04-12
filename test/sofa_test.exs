defmodule SofaTest do
  use ExUnit.Case, async: true

  @default_uri "http://localhost:5984/"
  @sofa Sofa.init() |> Sofa.client()

  import Tesla.Mock
  import Jason

  setup do
    mock(fn
      %{method: :get, url: @default_uri} ->
        %Tesla.Env{status: 200, body: fixture("init_200.json")}
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
    assert Sofa.connect!(@default_uri) |> is_struct(Sofa)
  end

  test "returns valid updated %Sofa{} on GET / 200 OK" do
    resp = fixture("init_200.json")
    sofa = Sofa.connect!(@sofa)
    assert is_struct(sofa, Sofa)
    assert resp["version"] == sofa.version
    assert resp["uuid"] == sofa.uuid
    assert is_list(resp["features"])
  end

  def fixture(f), do: File.read!("test/fixtures/" <> f) |> Jason.decode!()
end
