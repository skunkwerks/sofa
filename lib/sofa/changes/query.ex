defmodule Sofa.Changes.Query do
  @moduledoc """
  Turns follower options into the request for `GET|POST /{db}/_changes`.

  The CouchDB changes API takes its parameters in the query string, with two
  exceptions that need a `POST` and a JSON body: the `_doc_ids` and
  `_selector` filters. This module encodes the documented parameters the way
  CouchDB expects them, see
  https://docs.couchdb.org/en/stable/api/database/changes.html

  ## Options

  Every option is sent as the query parameter of the same name, encoded as:

  - booleans, integers and atoms become their string form (`true`, `5`,
    `all_docs`, `now`)
  - strings are sent verbatim, so `style: "all_docs"` works as well
  - `nil` drops the parameter, so `heartbeat: nil` lets the server side
    `timeout` end the response. Dropping both is refused, as nothing would
    ever end a quiet feed and a dead connection would go unnoticed

  A few options are special:

  - `:feed` defaults to `:continuous`. `:longpoll` and `:normal` are the
    alternatives
  - `longpoll: true` is shorthand for `feed: :longpoll`
  - `:heartbeat` defaults to 60 000 ms and `:timeout` to 7 200 000 ms
  - `:since` is kept on the struct so the follower can advance it between
    reconnects. It is sent verbatim and never parsed. Only `:now` or an
    opaque sequence string are accepted. Anything else raises an
    `ArgumentError`. Omitting it leaves `since` as `nil` and drops the
    parameter, which begins at the start of the feed
  - `doc_ids: [...]` switches to `POST` with `filter=_doc_ids` and the ids in
    the body, overriding any `:filter`
  - `selector: %{...}` does the same with `filter=_selector`
  - `query_params: [k: v]` adds raw parameters, as used for filter function
    arguments

  ## Examples

      iex> Sofa.Changes.Query.new([]) |> Sofa.Changes.Query.params()
      [{"feed", "continuous"}, {"heartbeat", "60000"}, {"timeout", "7200000"}]

      iex> Sofa.Changes.Query.new(longpoll: true, since: "42", heartbeat: nil)
      ...> |> Sofa.Changes.Query.params()
      [{"feed", "longpoll"}, {"timeout", "7200000"}, {"since", "42"}]

      iex> %Sofa.Changes.Query{method: :post, body: body} =
      ...>   Sofa.Changes.Query.new(doc_ids: ["a", "b"], filter: "ignored")
      iex> body
      %{"doc_ids" => ["a", "b"]}
  """

  @type feed :: :continuous | :longpoll | :normal
  @type since :: String.t() | :now | nil

  @type t :: %__MODULE__{
          method: :get | :post,
          feed: feed(),
          since: since(),
          heartbeat: pos_integer() | nil,
          timeout: pos_integer() | nil,
          params: [{String.t(), String.t()}],
          body: map() | nil
        }

  defstruct method: :get,
            feed: :continuous,
            since: nil,
            heartbeat: 60_000,
            timeout: 7_200_000,
            params: [],
            body: nil

  @defaults [heartbeat: 60_000, timeout: 7_200_000]

  @doc """
  Builds a query from follower options, see the module documentation.

  Raises `ArgumentError` on an unknown `:feed`, or when both `:heartbeat`
  and `:timeout` are `nil`.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts = Keyword.merge(@defaults, opts)
    {longpoll, opts} = Keyword.pop(opts, :longpoll, false)
    {feed, opts} = Keyword.pop(opts, :feed, :continuous)
    {since, opts} = Keyword.pop(opts, :since)
    {doc_ids, opts} = Keyword.pop(opts, :doc_ids)
    {selector, opts} = Keyword.pop(opts, :selector)
    {extra, opts} = Keyword.pop(opts, :query_params, [])

    feed = if longpoll, do: :longpoll, else: feed!(feed)
    since = since!(since)

    if opts[:heartbeat] == nil and opts[:timeout] == nil do
      raise ArgumentError, "at least one of heartbeat: and timeout: is needed, both were nil"
    end

    {method, body, opts} =
      cond do
        doc_ids != nil ->
          {:post, %{"doc_ids" => doc_ids}, Keyword.put(opts, :filter, "_doc_ids")}

        selector != nil ->
          {:post, %{"selector" => selector}, Keyword.put(opts, :filter, "_selector")}

        true ->
          {:get, nil, opts}
      end

    %__MODULE__{
      method: method,
      feed: feed,
      since: since,
      heartbeat: opts[:heartbeat],
      timeout: opts[:timeout],
      params: encode([{:feed, feed} | opts] ++ extra),
      body: body
    }
  end

  @doc """
  The query string parameters for the next request, with `since` included
  when known. The order is stable: `feed`, then the remaining options in
  the order given, then `since`.
  """
  @spec params(t()) :: [{String.t(), String.t()}]
  def params(%__MODULE__{params: params, since: nil}), do: params
  def params(%__MODULE__{params: params, since: since}), do: params ++ [{"since", value(since)}]

  @doc """
  Whether rows will carry the document under `"doc"`.

  ## Examples

      iex> Sofa.Changes.Query.new(include_docs: true) |> Sofa.Changes.Query.include_docs?()
      true
      iex> Sofa.Changes.Query.new([]) |> Sofa.Changes.Query.include_docs?()
      false
  """
  @spec include_docs?(t()) :: boolean()
  def include_docs?(%__MODULE__{params: params}), do: {"include_docs", "true"} in params

  @doc "Advances `since`, as after a delivered row or a `last_seq`."
  @spec since(t(), since()) :: t()
  def since(query = %__MODULE__{}, since), do: %{query | since: since}

  # `since` is only meaningful as a sequence, so unlike the generic
  # `value/1` encoding, arbitrary atoms and strings are rejected rather than
  # passed through verbatim. Omitting it, `:now`, or an opaque sequence
  # string are the only accepted forms.
  @spec since!(since()) :: since()
  defp since!(nil), do: nil
  defp since!(:now), do: :now
  defp since!(since) when is_binary(since), do: since

  defp since!(since),
    do:
      raise(
        ArgumentError,
        "since must be :now or an opaque string, got: #{inspect(since)}"
      )

  @spec feed!(feed() | String.t()) :: feed()
  defp feed!(feed) when feed in [:continuous, :longpoll, :normal], do: feed

  defp feed!(feed) when feed in ["continuous", "longpoll", "normal"],
    do: String.to_existing_atom(feed)

  defp feed!(feed),
    do:
      raise(
        ArgumentError,
        "feed must be :continuous, :longpoll or :normal, got: #{inspect(feed)}"
      )

  @spec encode(keyword()) :: [{String.t(), String.t()}]
  defp encode(opts) do
    for {key, v} <- opts, v != nil, do: {to_string(key), value(v)}
  end

  @spec value(term()) :: String.t()
  defp value(v) when is_binary(v), do: v
  defp value(v) when is_boolean(v) or is_atom(v) or is_integer(v), do: to_string(v)

  defp value(v),
    do:
      raise(
        ArgumentError,
        "changes parameters must be strings, atoms or integers, got: #{inspect(v)}"
      )
end
