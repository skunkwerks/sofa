defmodule Sofa.CouchFixtures do
  @moduledoc """
  Wire-format examples taken from the CouchDB 3.x `/{db}/_changes`
  documentation, trimmed to what a follower needs to parse.

  Sequence tokens in CouchDB 2+ are opaque strings of the form `N-<base64>`.
  `seq/1` builds one so tests do not accidentally depend on integers.
  """

  @doc "An opaque CouchDB 2+ style update sequence."
  @spec seq(non_neg_integer()) :: String.t()
  def seq(n), do: "#{n}-g1AAAAF9eJzLYWBg4MhgTmHgz8tPSTV0MDQy1zMAQsMcoARTIkOS"

  @doc "A row for a created or updated document."
  @spec row(String.t(), non_neg_integer(), String.t()) :: map()
  def row(id, n, rev), do: %{"seq" => seq(n), "id" => id, "changes" => [%{"rev" => rev}]}

  @doc "A row for a deleted document carries `\"deleted\": true`."
  @spec deleted_row(String.t(), non_neg_integer(), String.t()) :: map()
  def deleted_row(id, n, rev), do: row(id, n, rev) |> Map.put("deleted", true)

  @doc "The polling example: `fresh` created, `updated` updated and `deleted` deleted."
  @spec normal_rows() :: [map()]
  def normal_rows do
    [
      row("fresh", 1, "1-967a00dff5e02add41819138abb3284d"),
      row("updated", 3, "2-7051cbe5c8faecd085a3fa619e6e6337"),
      deleted_row("deleted", 5, "2-eec205a9d413992850a6e32678485900")
    ]
  end

  @doc "The polling example as the body of a normal or longpoll response."
  @spec normal_feed() :: map()
  def normal_feed, do: %{"results" => normal_rows(), "last_seq" => seq(5), "pending" => 0}

  @doc "The continuous example: the same three rows, one per line."
  @spec continuous_rows() :: [map()]
  def continuous_rows, do: normal_rows()

  @doc "The update that arrives after the '... tum tee tum ...' pause."
  @spec late_row() :: map()
  def late_row, do: row("updated", 6, "3-825cb35de44c433bfb2df415563a19de")

  @doc "With `style=all_docs` a row lists every leaf revision."
  @spec all_docs_row() :: map()
  def all_docs_row do
    %{
      "seq" => seq(5),
      "id" => "729eb57437745e506b333068fff665ae",
      "changes" => [
        %{"rev" => "6-460637e73a6288cb24d532bf91f32969"},
        %{"rev" => "5-eeaa298781f60b7bcae0c91bdedd1b87"}
      ]
    }
  end

  @doc "With `include_docs=true` the winning revision is embedded under `doc`."
  @spec include_docs_row() :: map()
  def include_docs_row do
    %{
      "seq" => seq(11),
      "id" => "SpaghettiWithMeatballs",
      "changes" => [%{"rev" => "13-bcb9d6388b60fd1e960d9ec4e8e3f29e"}],
      "doc" => %{
        "_id" => "SpaghettiWithMeatballs",
        "_rev" => "13-bcb9d6388b60fd1e960d9ec4e8e3f29e",
        "title" => "Spaghetti with meatballs",
        "servings" => 4
      }
    }
  end

  @doc "A continuous feed that reaches `limit` ends with a bare last_seq object."
  @spec last_seq_line(non_neg_integer()) :: map()
  def last_seq_line(n), do: %{"last_seq" => seq(n)}

  @doc "The error body documented for a `_selector` filter without a selector."
  @spec missing_selector_error() :: map()
  def missing_selector_error,
    do: %{"error" => "bad request", "reason" => "Selector must be specified in POST payload"}
end
