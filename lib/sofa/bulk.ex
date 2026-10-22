defmodule Sofa.Bulk do
  @moduledoc """
  Writes and reads documents in bulk, via `_bulk_docs` and `_bulk_get`.

  > If the only tool you have is CouchDB, then
  > everything looks like `{:ok, :relax}`

  See the bulk API section of https://docs.couchdb.org/en/stable/api/database/bulk-api.html.
  Both endpoints answer per document rather than per request: a bulk
  write returns 201 even when some documents conflicted, and a bulk read
  returns 200 with the missing ones marked. So the results are a list,
  one entry per requested document and in the same order, each either
  `{:ok, %Sofa.Doc{}}` or `{:error, reason, document_or_id}`, with the
  reason an atom such as `:conflict` or `:not_found`.

  ## Examples

      {:ok, results} = Sofa.Bulk.save(db, [fish, lamb])
      Enum.map(results, fn {:ok, doc} -> doc.rev; {:error, :conflict, doc} -> doc.id end)

      {:ok, [{:ok, fish}, {:error, :not_found, "nobody"}]} = Sofa.Bulk.get(db, ["FishStew", "nobody"])
  """

  alias Sofa.{Cushion, Doc, Response}

  @type reason :: :conflict | :forbidden | :not_found | :bad_request | atom()
  @type result :: {:ok, Doc.t()} | {:error, reason(), Doc.t() | String.t()}
  @type error :: Response.error() | term()

  @doc """
  Saves documents in one request. New documents get a revision, updated
  ones need their current `rev`, and a document saved via `delete/2` or
  with `"_deleted" => true` in its body is deleted.

  With `new_edits: false` the revisions are stored as given, as a
  replicator does. CouchDB then returns no per-document results and every
  document is reported as `{:ok, doc}` unchanged.
  """
  @spec save(Sofa.t(), [Doc.t()], keyword()) :: {:ok, [result()]} | {:error, error()}
  def save(sofa = %Sofa{database: db}, docs, opts \\ []) when is_binary(db) and is_list(docs) do
    body =
      opts
      |> Keyword.take([:new_edits])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("docs", Enum.map(docs, &Doc.to_map/1))

    case Sofa.raw(sofa, Cushion.path([db, "_bulk_docs"]), :post, [], body) do
      {:ok, _sofa, %Response{status: 201, body: results}} when is_list(results) ->
        {:ok, saved(docs, results)}

      other ->
        error(other)
    end
  end

  @doc """
  Deletes documents in one request, each needing its current `rev`. The
  results carry the documents with their deletion revisions.
  """
  @spec delete(Sofa.t(), [Doc.t()]) :: {:ok, [result()]} | {:error, error()}
  def delete(sofa = %Sofa{}, docs) when is_list(docs) do
    docs
    |> Enum.map(fn doc = %Doc{body: body} ->
      %Doc{doc | body: Map.put(body, "_deleted", true)}
    end)
    |> then(&save(sofa, &1))
  end

  @doc """
  Fetches documents in one request, by id or by `{id, rev}` for a specific
  revision. Options are the documented query parameters: `revs: true` adds
  the revision history under `"_revisions"` in each document's body,
  `latest: true` the latest leaf revisions, `attachments: true` inline
  attachment content.
  """
  @spec get(Sofa.t(), [String.t() | {String.t(), String.t()}], keyword()) ::
          {:ok, [result()]} | {:error, error()}
  def get(sofa = %Sofa{database: db}, refs, opts \\ []) when is_binary(db) and is_list(refs) do
    body = %{"docs" => Enum.map(refs, &ref/1)}

    params =
      for {k, v} <- Keyword.take(opts, [:revs, :latest, :attachments]),
          v != nil,
          do: {k, to_string(v)}

    case Sofa.raw(sofa, Cushion.path([db, "_bulk_get"]), :post, params, body) do
      {:ok, _sofa, %Response{status: 200, body: %{"results" => results}}} ->
        {:ok, Enum.flat_map(results, &fetched/1)}

      other ->
        error(other)
    end
  end

  ## results

  # pairs each document with its result, without results (new_edits: false)
  # every document is taken as stored
  @spec saved([Doc.t()], [map()]) :: [result()]
  defp saved(docs, []), do: Enum.map(docs, &{:ok, &1})

  defp saved(docs, results) do
    Enum.zip_with(docs, results, fn
      doc = %Doc{}, %{"ok" => true, "rev" => rev} -> {:ok, %Doc{doc | rev: rev}}
      doc = %Doc{}, %{"error" => error} -> {:error, reason(error), doc}
    end)
  end

  @spec fetched(map()) :: [result()]
  defp fetched(%{"id" => id, "docs" => docs}) do
    Enum.map(docs, fn
      %{"ok" => doc} -> {:ok, Doc.from_map(doc)}
      %{"error" => %{"error" => error}} -> {:error, reason(error), id}
    end)
  end

  @spec ref(String.t() | {String.t(), String.t()}) :: map()
  defp ref(id) when is_binary(id), do: %{"id" => id}
  defp ref({id, rev}) when is_binary(id) and is_binary(rev), do: %{"id" => id, "rev" => rev}

  # CouchDB's error names are its own, the common ones get the usual atoms
  @spec reason(String.t()) :: reason()
  defp reason("conflict"), do: :conflict
  defp reason("forbidden"), do: :forbidden
  defp reason("not_found"), do: :not_found
  defp reason("bad_request"), do: :bad_request
  defp reason("unauthorized"), do: :unauthorized
  defp reason(other), do: String.to_atom(other)

  @spec error({:ok, Sofa.t(), Response.t()} | {:error, term()}) :: {:error, error()}
  defp error({:ok, _sofa, response = %Response{}}), do: {:error, Response.error(response)}
  defp error({:error, response = %Response{}}), do: {:error, Response.error(response)}
  defp error({:error, reason}), do: {:error, reason}
end
