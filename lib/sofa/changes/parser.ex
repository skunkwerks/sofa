defmodule Sofa.Changes.Parser do
  @moduledoc """
  Decodes `_changes` responses into events, using pure functions.

  A continuous feed is one JSON object per line, arriving in chunks that
  may split a line or have several. Empty lines are heartbeats. The
  normal and longpoll feeds are a single JSON body with `results` and
  `last_seq`. Both end up as the same formatted stream of events:

  - `{:change, row}` for a document change, a map with `"id"`, `"seq"`,
    `"changes"` and optionally `"deleted"` and `"doc"`
  - `{:last_seq, seq}` for the bare `{"last_seq": ...}` object a feed ends
    with, or the `last_seq` of a batch
  - `{:error, map}` for `{"error": ..., "reason": ...}` objects, which
    CouchDB can emit inside a stream, and for lines that are not JSON

  Sequences are opaque and are passed through untouched.

  ## Examples

      iex> {events, rest} = Sofa.Changes.Parser.feed("", ~s({"seq": 1, "id": "a", "changes": []}\\n\\n{"last_))
      iex> events
      [{:change, %{"seq" => 1, "id" => "a", "changes" => []}}]
      iex> rest
      ~s({"last_)
      iex> Sofa.Changes.Parser.feed(rest, ~s(seq": 1}\\n))
      {[{:last_seq, 1}], ""}
  """

  @type row :: %{required(String.t()) => term()}
  @type event :: {:change, row()} | {:last_seq, term()} | {:error, map()}

  @doc """
  Appends `chunk` to the buffered partial line, returns the events for every
  complete line, and the remaining partial line as the new buffer.
  """
  @spec feed(binary(), binary()) :: {[event()], binary()}
  def feed(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    {lines, [rest]} = (buffer <> chunk) |> String.split("\n") |> Enum.split(-1)
    {Enum.flat_map(lines, &line/1), rest}
  end

  @doc """
  Decodes whatever is left in the buffer once the response has ended. A
  well-behaved server ends with a newline, leaving nothing. Anything else
  is decoded as a final line.
  """
  @spec flush(binary()) :: [event()]
  def flush(buffer) when is_binary(buffer), do: line(buffer)

  @doc """
  The events for a normal or longpoll body. The rows come first, in order,
  followed by the batch's `last_seq`.
  """
  @spec batch(map()) :: [event()]
  def batch(%{"results" => rows, "last_seq" => seq}) when is_list(rows) do
    Enum.map(rows, &{:change, &1}) ++ [{:last_seq, seq}]
  end

  def batch(error = %{"error" => _, "reason" => _}), do: [{:error, error}]
  def batch(other), do: [{:error, %{"error" => "unexpected_body", "reason" => inspect(other)}}]

  # one line of a continuous feed: "\r\n" endings leave a trailing "\r"
  @spec line(binary()) :: [event()]
  defp line(line) do
    case String.trim_trailing(line, "\r") do
      "" ->
        []

      json ->
        case Jason.decode(json) do
          {:ok, object} -> [classify(object)]
          {:error, _} -> [{:error, %{"error" => "invalid_json", "reason" => json}}]
        end
    end
  end

  @spec classify(term()) :: event()
  defp classify(error = %{"error" => _, "reason" => _}), do: {:error, error}
  defp classify(row = %{"id" => _, "seq" => _}), do: {:change, row}
  defp classify(%{"last_seq" => seq}), do: {:last_seq, seq}

  defp classify(other),
    do: {:error, %{"error" => "unexpected_object", "reason" => inspect(other)}}
end
