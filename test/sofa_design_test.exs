defmodule SofaDesignTest do
  @moduledoc "`Sofa.Design`: the `~JS` sigil."

  use ExUnit.Case, async: true

  import Sofa.Design, only: [sigil_JS: 2]

  test "~JS returns its JavaScript untouched, with no interpolation or escapes" do
    assert ~JS"function(doc) { emit(doc._id, 1); }" == "function(doc) { emit(doc._id, 1); }"

    map = ~JS"""
    function(doc) {
      if (doc.title) emit(doc.title, null);
    }
    """

    assert map == "function(doc) {\n  if (doc.title) emit(doc.title, null);\n}\n"

    raw = ~JS'''
    var re = /\d+/; var s = "#{doc._id}";
    '''

    assert raw == ~S(var re = /\d+/; var s = "#{doc._id}";) <> "\n"
  end
end
