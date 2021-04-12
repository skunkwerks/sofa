defmodule SofaTest do
  use ExUnit.Case, async: true

  import Tesla.Mock

  @sofa Sofa.init()

  doctest Sofa

  test "init returns expected struct" do
    assert @sofa == %Sofa{
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
end
