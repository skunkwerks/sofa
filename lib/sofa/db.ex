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
