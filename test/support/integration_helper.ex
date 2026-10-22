defmodule Sofa.IntegrationHelper do
  @moduledoc """
  Helpers for the live integration suite that runs against a real CouchDB,
  see `test/integration/README.md`.

  CouchDB may take a moment to come up after the CI runner starts it, so
  `connect!/1` polls the HTTP endpoint with Req until it returns a JSON body.
  """

  @doc """
  Like `Sofa.connect!/1`, but polls CouchDB's root endpoint with Req until it
  responds with JSON or `timeout_ms` elapses. Every integration `setup_all`
  uses this so a not-yet-started CouchDB is waited on rather than reported as
  a connection error.
  """
  @spec connect!(Sofa.t(), pos_integer()) :: Sofa.t()
  def connect!(sofa = %Sofa{uri: %URI{} = uri}, timeout_ms \\ 60_000) do
    url = URI.to_string(%URI{uri | path: "/"})
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    if ready?(url) do
      Sofa.connect!(sofa)
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining > 0 do
        Process.sleep(min(remaining, 500))
        connect!(sofa, remaining)
      else
        raise Sofa.Error, "CouchDB did not become reachable within #{timeout_ms}ms"
      end
    end
  end

  defp ready?(url) do
    case Req.get(url, receive_timeout: 1_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
