defmodule Sofa.Cushion do
  @moduledoc """
  Internal Helpers for Sofa, with a vanity naming convention.

  > If the only tool you have is CouchDB, everything is very
  > uncomfortable without a Cushion.
  """

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
  @spec untaint_headers(Tesla.Env.headers()) :: map()
  def untaint_headers(h) when is_list(h) do
    untaint_headers(h, %{})
  end

  @spec untaint_headers(Tesla.Env.headers(), map()) :: map()
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

  defp untaint_headers([{"x-couchdb-body-time", v} | t], m) do
    untaint_headers(t, Map.put(m, :couch_body_time, String.to_integer(v)))
  end

  # try just this header in lower-case; otherwise dump it
  defp untaint_headers([{k, v} | t], m) do
    m = untaint_headers(t, m)

    case String.downcase(k) do
      ^k -> untaint_headers(t, m)
      l -> untaint_headers([{l, v}], m)
    end
  end
end
