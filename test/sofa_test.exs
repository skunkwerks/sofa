defmodule SofaTest do
  use ExUnit.Case
  doctest Sofa

  test "greets the world" do
    assert Sofa.hello() == :world
  end
end
