defmodule SofaTest do
  use ExUnit.Case, async: true

  @sofa Sofa.init() |> Sofa.client()

  import Tesla.Mock
  import Jason

  setup do
    mock(fn
      %{method: :get, url: "http://localhost:5984/"} ->
        %Tesla.Env{status: 200, body: File.read!("test/fixtures/init_200.json") |> decode!()}
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

  test "returns updated Sofa on GET / 200 OK" do
    sofa = Sofa.connect!(@sofa)
    assert "1.2.3" == sofa.version
    assert "5b08a751c82f9e217e14ef11d2704c2fd" == sofa.uuid
  end
end
