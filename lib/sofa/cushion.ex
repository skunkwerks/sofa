defmodule Sofa.Cushion do
  @moduledoc """
  Internal Helpers for Sofa, with a vanity naming convention.

  > If the only tool you have is CouchDB, everything is very
  > uncomfortable without a Cushion.
  """

  @type headers :: %{optional(binary()) => [binary()]} | [{binary(), binary()}]

  @doc """
  Joins path segments into a request path, URL-encoding each one.

  Database names may contain `/` and `+`, document ids spaces and anything
  else, and attachment names must be URL encoded per the CouchDB docs. The
  `_design/` and `_local/` prefixes of special document ids keep their
  slash, as CouchDB routes on them.

      iex> Sofa.Cushion.path(["recipes", "Spaghetti With Meatballs", "photo 1.jpg"])
      "recipes/Spaghetti%20With%20Meatballs/photo%201.jpg"

      iex> Sofa.Cushion.path(["my/db", "_design/app"])
      "my%2Fdb/_design/app"
  """
  @spec path([String.t()]) :: String.t()
  def path(segments) when is_list(segments), do: Enum.map_join(segments, "/", &segment/1)

  @spec segment(String.t()) :: String.t()
  defp segment("_design/" <> rest), do: "_design/" <> segment(rest)
  defp segment("_local/" <> rest), do: "_local/" <> segment(rest)
  # RFC 3986 pchar: unreserved, sub-delims, ":" and "@" may appear in a path
  # segment as they are, so ids such as org.couchdb.user:jan stay readable
  defp segment(segment) when is_binary(segment), do: URI.encode(segment, &pchar?/1)

  @spec pchar?(byte()) :: boolean()
  defp pchar?(char), do: URI.char_unreserved?(char) or char in ~c":@!$&'()*+,;="

  @doc """
  Sanitise HTTP headers into ones we trust and format, and drop the rest.
  This is necessary because proxies, clients, HTTP1* and HTTP2 all disagree
  about whether headers should be upper, lower, camel, snake, or wtf case.

      Server : CouchDB/3.1.1 (Erlang OTP/22)
      X-Couch-Request-Id : f5b74b7038
      X-Couchdb-Body-Time : 0
      Cache-Control : must-revalidate
      Content-Length : 443
      Content-Type : application/json
      Date : Sun, 25 Apr 2021 18:43:36 GMT
      Etag : "4-322add00c33cab838bf9d7909f18d4f5"

  """
  @spec untaint_headers(headers()) :: map()
  def untaint_headers(headers) when is_map(headers) or is_list(headers) do
    # Req gives a map of lower-cased names to lists of values. Flatten that
    # into the `{name, value}` pairs that older adapters (and tests) use
    headers
    |> Enum.flat_map(fn
      {k, values} when is_list(values) -> Enum.map(values, &{k, &1})
      {k, v} -> [{k, v}]
    end)
    |> untaint_headers(%{})
  end

  @spec untaint_headers([{binary(), binary()}], map()) :: map()
  defp untaint_headers([], map), do: map

  defp untaint_headers([{"etag", v} | t], m) do
    untaint_headers(t, Map.put(m, :etag, String.trim(v, ~s("))))
  end

  defp untaint_headers([{"cache-control", v} | t], m) do
    untaint_headers(t, Map.put(m, :cache_control, String.downcase(v)))
  end

  defp untaint_headers([{"server", v} | t], m) do
    untaint_headers(t, Map.put(m, :server, v))
  end

  defp untaint_headers([{"x-couch-request-id", v} | t], m) do
    untaint_headers(t, Map.put(m, :couch_request_id, String.downcase(v)))
  end

  defp untaint_headers([{"date", v} | t], m) do
    untaint_headers(t, Map.put(m, :date, v))
  end

  defp untaint_headers([{"content-type", v} | t], m) do
    untaint_headers(t, Map.put(m, :content_type, String.downcase(v)))
  end

  defp untaint_headers([{"content-length", v} | t], m) do
    untaint_headers(t, Map.put(m, :content_length, String.to_integer(v)))
  end

  # attachments: compression, range support and the Location of a new one
  defp untaint_headers([{"content-encoding", v} | t], m) do
    untaint_headers(t, Map.put(m, :content_encoding, String.downcase(v)))
  end

  defp untaint_headers([{"content-range", v} | t], m) do
    untaint_headers(t, Map.put(m, :content_range, v))
  end

  defp untaint_headers([{"accept-ranges", v} | t], m) do
    untaint_headers(t, Map.put(m, :accept_ranges, String.downcase(v)))
  end

  defp untaint_headers([{"location", v} | t], m) do
    untaint_headers(t, Map.put(m, :location, v))
  end

  # a response may set several cookies. Keep them all, in order
  defp untaint_headers([{"set-cookie", v} | t], m) do
    untaint_headers(t, Map.update(m, :set_cookie, [v], &(&1 ++ [v])))
  end

  defp untaint_headers([{"x-couchdb-body-time", v} | t], m) do
    untaint_headers(t, Map.put(m, :couch_body_time, String.to_integer(v)))
  end

  # retry this header in lower-case. If it is already lower-case and still
  # unmatched by the clauses above, it's not one we care about, so drop it
  defp untaint_headers([{k, v} | t], m) do
    case String.downcase(k) do
      ^k -> untaint_headers(t, m)
      l -> untaint_headers([{l, v} | t], m)
    end
  end
end
