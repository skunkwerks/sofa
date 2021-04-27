defmodule Sofa.DB do
  @moduledoc """
  Documentation for `Sofa.DB`, a test-driven idiomatic Apache CouchDB client.

  > If the only tool you have is CouchDB, then
  > everything looks like {:ok, :relax}

  ## Examples

  iex>  sofa = Sofa.init("http://admin:passwd@localhost:5984/") |> Sofa.client() |> Sofa.connect!()
      #Sofa<"...">

  iex> Sofa.DB.create(sofa, "testy")
      {:ok,
      #Sofa<
        client: %Tesla.Client{},
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
      client: %Tesla.Client{},
    ...>

  """

  @doc """
  create DB. Only available to cluster admin users.
  """
  @spec create(Sofa.t(), String.t()) :: {:error, any()} | {:ok, Sofa.t(), any()}
  def create(sofa = %Sofa{}, db) when is_binary(db) do
    case Sofa.raw(sofa, db, :put) do
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
    case Sofa.raw(sofa, db, :get) do
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
    case Sofa.raw(sofa, db, :delete) do
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
  Open DB. Checks if supplied credentials have access to the DB, and returns
  updated %Sofa{} struct with DB. Ideal for subsequent use to read/write Docs.
  """
  @spec open(Sofa.t(), String.t()) :: {:error, any()} | {:ok, Sofa.t(), any()}
  def open(sofa = %Sofa{}, db) when is_binary(db) do
    case Sofa.raw(sofa, db, :head) do
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
    case Sofa.raw(sofa, db, :head) do
      {:ok, sofa, %Sofa.Response{status: 200}} ->
        %Sofa{sofa | database: db}

      _ ->
        raise Sofa.Error, "unable to open database #{db}"
    end
  end
end
