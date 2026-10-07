defmodule SofaCushionTest do
  use ExUnit.Case, async: true

  alias Sofa.Cushion

  test "known headers are normalised into atom keys" do
    headers = [
      {"Server", "CouchDB/3.1.1 (Erlang OTP/22)"},
      {"X-Couch-Request-Id", "F5B74B7038"},
      {"X-Couchdb-Body-Time", "0"},
      {"Cache-Control", "Must-Revalidate"},
      {"Content-Length", "443"},
      {"Content-Type", "application/JSON"},
      {"Date", "Sun, 25 Apr 2021 18:43:36 GMT"},
      {"Etag", ~s("4-322add00c33cab838bf9d7909f18d4f5")}
    ]

    assert Cushion.untaint_headers(headers) == %{
             server: "CouchDB/3.1.1 (Erlang OTP/22)",
             couch_request_id: "f5b74b7038",
             couch_body_time: 0,
             cache_control: "must-revalidate",
             content_length: 443,
             content_type: "application/json",
             date: "Sun, 25 Apr 2021 18:43:36 GMT",
             etag: "4-322add00c33cab838bf9d7909f18d4f5"
           }
  end

  test "already lower-cased headers are accepted as-is" do
    assert Cushion.untaint_headers([{"etag", ~s("1-leet")}, {"content-length", "2"}]) ==
             %{etag: "1-leet", content_length: 2}
  end

  test "unknown headers are dropped regardless of case" do
    headers = [
      {"x-frame-options", "deny"},
      {"X-Content-Type-Options", "nosniff"},
      {"etag", ~s("1-leet")},
      {"strict-transport-security", "max-age=31536000"}
    ]

    assert Cushion.untaint_headers(headers) == %{etag: "1-leet"}
  end

  test "many unknown headers are handled in linear time" do
    # before the fix this recursed into the tail twice per unknown header,
    # so 40 of them would take ~2^40 steps and this test would never finish
    unknown = for i <- 1..40, do: {"x-unknown-#{i}", "value"}
    headers = unknown ++ [{"etag", ~s("1-leet")}] ++ unknown

    assert Cushion.untaint_headers(headers) == %{etag: "1-leet"}
  end
end
