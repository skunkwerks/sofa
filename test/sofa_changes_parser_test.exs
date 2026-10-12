defmodule SofaChangesParserTest do
  use ExUnit.Case, async: true

  alias Sofa.Changes.Parser

  doctest Parser

  # wire-format examples from the CouchDB _changes documentation
  defp seq(n), do: "#{n}-g1AAAAF9eJzLYWBg4MhgTmHgz8tPSTV0MDQy1zMAQsMcoARTIkOS"
  defp row(id, n, rev), do: %{"seq" => seq(n), "id" => id, "changes" => [%{"rev" => rev}]}
  defp line(map), do: Jason.encode!(map) <> "\n"

  describe "feed/2" do
    test "one JSON object per line becomes one change each, in order" do
      rows = [
        row("fresh", 1, "1-a"),
        row("updated", 3, "2-b"),
        Map.put(row("gone", 5, "2-c"), "deleted", true)
      ]

      chunk = Enum.map_join(rows, &line/1)

      assert {events, ""} = Parser.feed("", chunk)
      assert events == Enum.map(rows, &{:change, &1})
      assert {:change, %{"id" => "gone", "deleted" => true}} = List.last(events)
    end

    test "a line split across chunks is buffered until complete" do
      {first, second} = row("split", 9, "1-s") |> Jason.encode!() |> String.split_at(20)

      assert {[], ^first} = Parser.feed("", first)
      assert {[{:change, %{"id" => "split"}}], ""} = Parser.feed(first, second <> "\n")
    end

    test "CRLF line endings are accepted" do
      chunk = Jason.encode!(row("crlf", 1, "1-c")) <> "\r\n"
      assert {[{:change, %{"id" => "crlf"}}], ""} = Parser.feed("", chunk)
    end

    test "empty lines are heartbeats, not events" do
      assert {[], ""} = Parser.feed("", "\n\n\n")

      assert {[{:change, %{"id" => "real"}}], ""} =
               Parser.feed("", "\n" <> line(row("real", 1, "1-r")) <> "\n")
    end

    test "a bare last_seq object ends a feed that reached its limit" do
      chunk = line(row("one", 1, "1-a")) <> line(%{"last_seq" => seq(2), "pending" => 0})
      assert {[{:change, %{"id" => "one"}}, {:last_seq, last}], ""} = Parser.feed("", chunk)
      assert last == seq(2)
    end

    test "error objects and invalid JSON are reported, not raised" do
      error = %{
        "error" => "bad request",
        "reason" => "Selector must be specified in POST payload"
      }

      chunk = line(error) <> "not json\n" <> line(row("after", 2, "1-a"))

      assert {[
                {:error, ^error},
                {:error, %{"error" => "invalid_json"}},
                {:change, %{"id" => "after"}}
              ], ""} =
               Parser.feed("", chunk)
    end

    test "objects that are neither rows, last_seq nor errors are reported" do
      assert {[{:error, %{"error" => "unexpected_object"}}], ""} =
               Parser.feed("", ~s({"hello": "world"}\n))
    end
  end

  describe "flush/1" do
    test "decodes a final unterminated line, and nothing for an empty buffer" do
      assert Parser.flush("") == []
      assert [{:last_seq, 7}] = Parser.flush(~s({"last_seq": 7}))
    end
  end

  describe "batch/1" do
    test "a normal or longpoll body yields its rows then last_seq" do
      body = %{
        "results" => [row("a", 1, "1-a"), row("b", 2, "1-b")],
        "last_seq" => seq(5),
        "pending" => 0
      }

      assert [{:change, %{"id" => "a"}}, {:change, %{"id" => "b"}}, {:last_seq, last}] =
               Parser.batch(body)

      assert last == seq(5)
    end

    test "an empty batch (longpoll timeout) still carries last_seq" do
      assert [{:last_seq, "now"}] =
               Parser.batch(%{"results" => [], "last_seq" => "now", "pending" => 0})
    end

    test "error and unexpected bodies are reported" do
      assert [{:error, %{"error" => "not_found"}}] =
               Parser.batch(%{"error" => "not_found", "reason" => "missing"})

      assert [{:error, %{"error" => "unexpected_body"}}] = Parser.batch("")
    end
  end
end
