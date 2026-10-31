defmodule SofaSecurityTest do
  use ExUnit.Case, async: true

  alias Sofa.Security

  doctest Security

  test "new/0 is empty, and grants build it up without duplicates" do
    assert Security.empty?(Security.new())

    security =
      Security.new()
      |> Security.admin("superuser")
      |> Security.admin(role: "admins")
      |> Security.member("user1")
      |> Security.member("user2")
      |> Security.member("user1")
      |> Security.member(role: "developers")

    refute Security.empty?(security)

    assert Security.to_map(security) == %{
             "admins" => %{"names" => ["superuser"], "roles" => ["admins"]},
             "members" => %{"names" => ["user1", "user2"], "roles" => ["developers"]}
           }
  end

  test "from_map/1 tolerates the partial objects CouchDB may return" do
    assert Security.from_map(%{}) == Security.new()

    assert %Security{admins: %{names: ["a"], roles: []}, members: %{names: [], roles: ["r"]}} =
             Security.from_map(%{
               "admins" => %{"names" => ["a"]},
               "members" => %{"roles" => ["r"]}
             })

    assert Security.from_map(Security.to_map(Security.new() |> Security.member("x"))) ==
             Security.new() |> Security.member("x")
  end
end
