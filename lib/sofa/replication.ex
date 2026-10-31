defmodule Sofa.Replication do
  @moduledoc """
  Replication: one-off and continuous jobs via `_replicate`, persistent
  ones as documents in `_replicator`, and the scheduler that runs them.

  > If the only tool you have is CouchDB, then
  > everything looks like `{:ok, :relax}`

  See `_replicate` and `_scheduler` at
  https://docs.couchdb.org/en/stable/api/server/common.html. A source or
  target is a database URL with credentials, or a `%Sofa{}` handle with
  its `database` set, which `endpoint/1` turns into one. The documented
  options go along as given: `continuous`, `create_target`, `doc_ids`,
  `filter`, `selector`, `winning_revs_only`, `source_proxy`,
  `target_proxy`, `create_target_params`.

  ## Examples

      {:ok, %{"ok" => true, "history" => [_ | _]}} = Sofa.Replication.replicate(server, db_a, db_b, create_target: true)

      {:ok, %{"ok" => true, "_local_id" => id}} = Sofa.Replication.replicate(server, db_a, db_b, continuous: true)
      {:ok, jobs} = Sofa.Replication.jobs(server)
      {:ok, _} = Sofa.Replication.cancel(server, db_a, db_b, continuous: true)

      Sofa.Replication.new(db_a, db_b, continuous: true) |> Sofa.Doc.save(%Sofa{server | database: "_replicator"})
  """

  alias Sofa.{Cushion, Doc, Response}

  @type endpoint :: String.t() | Sofa.t() | map()
  @type error :: Response.error() | term()

  @doc """
  Starts a replication and, for a one-off one, waits for it: the reply is
  the documented result with its `"history"`. A `continuous: true`
  replication is accepted instead, with a `"_local_id"` to cancel it by.
  Server admin only.
  """
  @spec replicate(Sofa.t(), endpoint(), endpoint(), keyword()) :: {:ok, map()} | {:error, error()}
  def replicate(sofa = %Sofa{}, source, target, opts \\ []) when is_list(opts) do
    case Sofa.raw(sofa, "_replicate", :post, [], body(source, target, opts)) do
      {:ok, _sofa, %Response{status: status, body: body = %{"ok" => true}}}
      when status in [200, 202] ->
        {:ok, body}

      other ->
        error(other)
    end
  end

  @doc """
  Cancels a replication started with `replicate/4`, given the same source,
  target and options, as CouchDB identifies it by them.
  """
  @spec cancel(Sofa.t(), endpoint(), endpoint(), keyword()) :: {:ok, map()} | {:error, error()}
  def cancel(sofa = %Sofa{}, source, target, opts \\ []) when is_list(opts) do
    replicate(sofa, source, target, Keyword.put(opts, :cancel, true))
  end

  @doc """
  A replication document for the `_replicator` database, where CouchDB
  keeps persistent replications: save it with `Sofa.Doc.save/2` on a
  handle opened on `_replicator`, delete it to stop. The id is random
  unless given as `id:`.
  """
  @spec new(endpoint(), endpoint(), keyword()) :: Doc.t()
  def new(source, target, opts \\ []) when is_list(opts) do
    {id, opts} =
      Keyword.pop_lazy(opts, :id, fn ->
        :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      end)

    Doc.new(%{id: id, body: body(source, target, opts)})
  end

  @doc """
  The replication jobs the scheduler is running, as the documented job
  objects. Options: `limit:` and `skip:`.
  """
  @spec jobs(Sofa.t(), keyword()) :: {:ok, [map()]} | {:error, error()}
  def jobs(sofa = %Sofa{}, opts \\ []) do
    case Sofa.raw(sofa, "_scheduler/jobs", :get, Keyword.take(opts, [:limit, :skip])) do
      {:ok, _sofa, %Response{status: 200, body: %{"jobs" => jobs}}} -> {:ok, jobs}
      other -> error(other)
    end
  end

  @doc """
  The state of every replication document the scheduler knows, across all
  replicator databases or for one, as the documented objects with their
  `"state"`, `"info"` and `"error_count"`. Options: `limit:` and `skip:`.
  """
  @spec docs(Sofa.t(), String.t() | nil, keyword()) :: {:ok, [map()]} | {:error, error()}
  def docs(sofa = %Sofa{}, replicator_db \\ nil, opts \\ []) do
    path =
      if replicator_db,
        do: Cushion.path(["_scheduler", "docs", replicator_db]),
        else: "_scheduler/docs"

    case Sofa.raw(sofa, path, :get, Keyword.take(opts, [:limit, :skip])) do
      {:ok, _sofa, %Response{status: 200, body: %{"docs" => docs}}} -> {:ok, docs}
      other -> error(other)
    end
  end

  @doc "The scheduler's state for one replication document."
  @spec doc(Sofa.t(), String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def doc(sofa = %Sofa{}, replicator_db, id) when is_binary(replicator_db) and is_binary(id) do
    case Sofa.raw(sofa, Cushion.path(["_scheduler", "docs", replicator_db, id]), :get) do
      {:ok, _sofa, %Response{status: 200, body: doc = %{"doc_id" => _}}} -> {:ok, doc}
      other -> error(other)
    end
  end

  @doc """
  A replication endpoint for a handle: its server URL with the
  credentials and database, as CouchDB wants them. Strings and maps are
  passed through.

      iex> Sofa.init("http://admin:passwd@couch.example:5984/") |> Map.put(:database, "recipes") |> Sofa.Replication.endpoint()
      "http://admin:passwd@couch.example:5984/recipes"
  """
  @spec endpoint(endpoint()) :: String.t() | map()
  def endpoint(%Sofa{uri: uri = %URI{}, database: db}) when is_binary(db),
    do: URI.to_string(%URI{uri | path: "/" <> db})

  def endpoint(url) when is_binary(url), do: url
  def endpoint(map) when is_map(map), do: map

  @spec body(endpoint(), endpoint(), keyword()) :: map()
  defp body(source, target, opts) do
    opts
    |> Enum.reject(fn {_key, value} -> value == nil end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.merge(%{"source" => endpoint(source), "target" => endpoint(target)})
  end

  @spec error({:ok, Sofa.t(), Response.t()} | {:error, term()}) :: {:error, error()}
  defp error({:ok, _sofa, response = %Response{}}), do: {:error, Response.error(response)}
  defp error({:error, response = %Response{}}), do: {:error, Response.error(response)}
  defp error({:error, reason}), do: {:error, reason}
end
