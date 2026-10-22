defmodule Sofa.Design do
  @moduledoc """
  Design documents: the `_design/` documents that hold views, filters and
  validation functions.

  > If the only tool you have is CouchDB, then
  > everything looks like `{:ok, :relax}`

  For now this module holds the `~JS` sigil, which keeps the JavaScript
  inside a design document readable.
  """

  @doc ~S'''
  A JavaScript function as a string, for views, filters, updates and
  validation. Nothing is interpolated or escaped, so the function reads
  exactly as CouchDB will store it.

      import Sofa.Design, only: [sigil_JS: 2]

      ~JS"""
      function(doc) {
        if (doc.title) emit(doc.title, null);
      }
      """

  The single-line form `~JS"function(doc) { emit(doc._id, 1); }"` suits
  short functions. The sigil takes no modifiers.
  '''
  @spec sigil_JS(String.t(), []) :: String.t()
  def sigil_JS(javascript, []) when is_binary(javascript), do: javascript
end
