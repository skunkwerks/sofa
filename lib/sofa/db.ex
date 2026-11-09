defmodule Sofa.DB do
  @moduledoc """
  Documentation for `Sofa.DB`, a test-driven idiomatic Apache CouchDB client.

  > If the only tool you have is CouchDB, then
  > everything looks like `{:ok, :relax}`

  ## Examples

      iex>  sofa = Sofa.init("http://admin:passwd@localhost:5984/")
            |> Sofa.client()
            |> Sofa.connect!()
          #Sofa<"...">

      iex> Sofa.DB.create(sofa, "testy")
          {:ok,
          #Sofa<
            client: %Req.Request{},
            database: "testy7",
            uri: %URI{},
            ...
          >,
          %Sofa.Response{
            body: %{"ok" => true},
            headers: %{
              cache_control: "must-revalidate",
              content_length: 95,
              content_type: "application/json",
              couch_body_time: 0,
              couch_request_id: "aa6cc50741",
              date: "Sun, 25 Apr 2021 20:04:34 GMT",
              server: "CouchDB/3.1.1 (Erlang OTP/22)"
            },
            method: :put,
            query: [],
            status: 201,
            url: "http://localhost:5984/testy7"
          }}

      iex> Sofa.DB.open!(sofa, "testy")
        #Sofa<
          database: "testy",
          client: %Req.Request{},
        ...>

  """

  @doc """
  create DB. Only available to cluster admin users.
  """
  @spec create(Sofa.t(), String.t()) :: {:error, any()} | {:ok, Sofa.t(), any()}
  def create(sofa = %Sofa{}, db) when is_binary(db) do
    case Sofa.raw(sofa, Sofa.Cushion.path([db]), :put) do
      {:error, reason} ->
        {:error, reason}

      {:ok, _sofa, resp} ->
        {:ok, %Sofa{sofa | database: db},
         %Sofa.Response{
           body: resp.body,
           url: resp.url,
           query: resp.query,
           method: resp.method,
           headers: resp.headers,
           status: resp.status
         }}
    end
  end

  @doc """
  Get DB info. Only available to database & cluster admin users.
  """
  @spec info(Sofa.t(), String.t()) :: {:error, any()} | {:ok, Sofa.t(), any()}
  def info(sofa = %Sofa{}, db) when is_binary(db) do
    case Sofa.raw(sofa, Sofa.Cushion.path([db]), :get) do
      {:error, reason} ->
        {:error, reason}

      {:ok, sofa, resp} ->
        {:ok, %Sofa{sofa | database: db},
         %Sofa.Response{
           body: resp.body,
           url: resp.url,
           query: resp.query,
           method: resp.method,
           headers: resp.headers,
           status: resp.status
         }}
    end
  end

  @doc """
  Delete DB. Only available to cluster admin users.
  """
  @spec delete(Sofa.t(), String.t()) :: {:error, any()} | {:ok, Sofa.t(), any()}
  def delete(sofa = %Sofa{}, db) when is_binary(db) do
    case Sofa.raw(sofa, Sofa.Cushion.path([db]), :delete) do
      {:error, reason} ->
        {:error, reason}

      {:ok, _sofa, resp} ->
        {:ok, sofa,
         %Sofa.Response{
           body: resp.body,
           url: resp.url,
           query: resp.query,
           method: resp.method,
           headers: resp.headers,
           status: resp.status
         }}
    end
  end

  @doc """
  The security object of the opened database, see `Sofa.Security`.
  """
  @spec security(Sofa.t()) :: {:ok, Sofa.Security.t()} | {:error, Sofa.Response.error() | any()}
  def security(sofa = %Sofa{database: db}) when is_binary(db) do
    case Sofa.raw(sofa, Sofa.Cushion.path([db, "_security"]), :get) do
      {:ok, _sofa, %Sofa.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, Sofa.Security.from_map(body)}

      other ->
        security_error(other)
    end
  end

  @doc """
  Replaces the security object of the opened database. Server admin only.

      Sofa.Security.new() |> Sofa.Security.member(role: "users") |> then(&Sofa.DB.set_security(db, &1))
  """
  @spec set_security(Sofa.t(), Sofa.Security.t()) :: :ok | {:error, Sofa.Response.error() | any()}
  def set_security(sofa = %Sofa{database: db}, security = %Sofa.Security{}) when is_binary(db) do
    case Sofa.raw(
           sofa,
           Sofa.Cushion.path([db, "_security"]),
           :put,
           [],
           Sofa.Security.to_map(security)
         ) do
      {:ok, _sofa, %Sofa.Response{status: 200, body: %{"ok" => true}}} -> :ok
      other -> security_error(other)
    end
  end

  @doc """
  Starts compaction of the opened database, or with a design document
  name of its view indexes. CouchDB accepts the request and compacts in
  the background. `info/2` reports `compact_running`. Admin only.
  """
  @spec compact(Sofa.t(), String.t() | nil) :: :ok | {:error, Sofa.Response.error() | any()}
  def compact(sofa = %Sofa{database: db}, ddoc \\ nil) when is_binary(db) do
    path =
      if ddoc,
        do: Sofa.Cushion.path([db, "_compact", ddoc]),
        else: Sofa.Cushion.path([db, "_compact"])

    accepted(Sofa.raw(sofa, path, :post, [], "", json_header()))
  end

  @doc "Removes view index files no design document refers to any more. Admin only."
  @spec view_cleanup(Sofa.t()) :: :ok | {:error, Sofa.Response.error() | any()}
  def view_cleanup(sofa = %Sofa{database: db}) when is_binary(db) do
    accepted(
      Sofa.raw(sofa, Sofa.Cushion.path([db, "_view_cleanup"]), :post, [], "", json_header())
    )
  end

  @doc "How many revisions of a document the database keeps track of, 1000 by default."
  @spec revs_limit(Sofa.t()) :: {:ok, pos_integer()} | {:error, Sofa.Response.error() | any()}
  def revs_limit(sofa = %Sofa{database: db}) when is_binary(db) do
    case Sofa.raw(sofa, Sofa.Cushion.path([db, "_revs_limit"]), :get) do
      {:ok, _sofa, %Sofa.Response{status: 200, body: limit}} when is_integer(limit) ->
        {:ok, limit}

      other ->
        security_error(other)
    end
  end

  @doc "Sets the revision limit. Admin only."
  @spec set_revs_limit(Sofa.t(), pos_integer()) :: :ok | {:error, Sofa.Response.error() | any()}
  def set_revs_limit(sofa = %Sofa{database: db}, limit)
      when is_binary(db) and is_integer(limit) and limit > 0 do
    case Sofa.raw(
           sofa,
           Sofa.Cushion.path([db, "_revs_limit"]),
           :put,
           [],
           Integer.to_string(limit),
           json_header()
         ) do
      {:ok, _sofa, %Sofa.Response{status: 200, body: %{"ok" => true}}} -> :ok
      other -> security_error(other)
    end
  end

  @doc """
  Purges revisions for good, as opposed to deleting them: a map of
  document ids to lists of revisions. Returns the purge sequence and what
  was purged, as documented. Admin only, and best used with care.
  """
  @spec purge(Sofa.t(), %{optional(String.t()) => [String.t()]}) ::
          {:ok, map()} | {:error, Sofa.Response.error() | any()}
  def purge(sofa = %Sofa{database: db}, revisions) when is_binary(db) and is_map(revisions) do
    case Sofa.raw(sofa, Sofa.Cushion.path([db, "_purge"]), :post, [], revisions) do
      {:ok, _sofa, %Sofa.Response{status: status, body: body = %{"purged" => _}}}
      when status in [201, 202] ->
        {:ok, body}

      other ->
        security_error(other)
    end
  end

  @doc """
  Which of the given revisions the database does not have, for a map of
  document ids to revision lists, as a map of ids to `"missing"` lists
  and `"possible_ancestors"`. What replicators ask before sending.
  """
  @spec revs_diff(Sofa.t(), %{optional(String.t()) => [String.t()]}) ::
          {:ok, map()} | {:error, Sofa.Response.error() | any()}
  def revs_diff(sofa = %Sofa{database: db}, revisions) when is_binary(db) and is_map(revisions) do
    case Sofa.raw(sofa, Sofa.Cushion.path([db, "_revs_diff"]), :post, [], revisions) do
      {:ok, _sofa, %Sofa.Response{status: 200, body: diff}} when is_map(diff) -> {:ok, diff}
      other -> security_error(other)
    end
  end

  @doc "The older form of `revs_diff/2`: a map of document ids to the revisions the database lacks."
  @spec missing_revs(Sofa.t(), %{optional(String.t()) => [String.t()]}) ::
          {:ok, map()} | {:error, Sofa.Response.error() | any()}
  def missing_revs(sofa = %Sofa{database: db}, revisions)
      when is_binary(db) and is_map(revisions) do
    case Sofa.raw(sofa, Sofa.Cushion.path([db, "_missing_revs"]), :post, [], revisions) do
      {:ok, _sofa, %Sofa.Response{status: 200, body: %{"missing_revs" => missing}}} ->
        {:ok, missing}

      other ->
        security_error(other)
    end
  end

  # CouchDB insists on a JSON content type for these bodiless POSTs
  @spec json_header() :: [{String.t(), String.t()}]
  defp json_header, do: [{"content-type", "application/json"}]

  @spec accepted({:ok, Sofa.t(), Sofa.Response.t()} | {:error, term()}) :: :ok | {:error, any()}
  defp accepted({:ok, _sofa, %Sofa.Response{status: 202, body: %{"ok" => true}}}), do: :ok
  defp accepted(other), do: security_error(other)

  @spec security_error({:ok, Sofa.t(), Sofa.Response.t()} | {:error, term()}) :: {:error, any()}
  defp security_error({:ok, _sofa, response = %Sofa.Response{}}),
    do: {:error, Sofa.Response.error(response)}

  defp security_error({:error, response = %Sofa.Response{}}),
    do: {:error, Sofa.Response.error(response)}

  defp security_error({:error, reason}), do: {:error, reason}

  @doc """
  Open DB. Checks if supplied credentials have access to the DB, and returns
  updated `%Sofa{}` struct with DB. Ideal for subsequent use to read/write Docs.
  """
  @spec open(Sofa.t(), String.t()) :: {:error, any()} | {:ok, Sofa.t(), any()}
  def open(sofa = %Sofa{}, db) when is_binary(db) do
    case Sofa.raw(sofa, Sofa.Cushion.path([db]), :head) do
      {:ok, sofa, %Sofa.Response{status: 200}} ->
        {:ok, %Sofa{sofa | database: db}}

      {:ok, _sofa, resp} ->
        {:error, resp}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Bang! version of open/2. Opens DB and raises on failure. Ideal for piping
  directly into reading and writing Docs.
  """
  @spec open!(Sofa.t(), String.t()) :: Sofa.t()
  def open!(sofa = %Sofa{}, db) when is_binary(db) do
    case Sofa.raw(sofa, Sofa.Cushion.path([db]), :head) do
      {:ok, sofa, %Sofa.Response{status: 200}} ->
        %Sofa{sofa | database: db}

      _ ->
        raise Sofa.Error, "unable to open database #{db}"
    end
  end
end
