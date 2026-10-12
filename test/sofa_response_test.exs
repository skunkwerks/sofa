defmodule SofaResponseTest do
  use ExUnit.Case, async: true

  alias Sofa.Response

  doctest Response, except: [:moduledoc]

  test "error/1 maps the documented statuses to atoms and keeps the rest" do
    for {status, reason} <- [
          {400, :bad_request},
          {401, :unauthorized},
          {403, :forbidden},
          {404, :not_found},
          {409, :conflict},
          {412, :precondition_failed}
        ] do
      assert Response.error(%Response{status: status, method: :get, body: nil}) == reason
    end

    assert %Response{status: 503} =
             Response.error(%Response{status: 503, method: :get, body: nil})
  end
end
