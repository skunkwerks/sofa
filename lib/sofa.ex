defmodule Sofa do
  @moduledoc """
  Documentation for `Sofa`, a test-driven idiomatic Apache CouchDB client.

  > If the only tool you have is CouchDB, then
  > everything looks like `{:ok, :relax}`

  ## Examples

      iex> Sofa.init() |> Sofa.client() |> Sofa.connect!()

      %{
        "couchdb" => "Welcome",
        "features" => ["access-ready", "partitioned", "pluggable-storage-engines",
          "reshard", "scheduler"],
        "git_sha" => "ce596c65d",
        "uuid" => "59c032d3a6adcd5b44315137a124bf69",
        "vendor" => %{"name" => "FreeBSD"},
        "version" => "3.1.1"
      }
  """

  @derive {Inspect, except: [:auth]}
  defstruct [
    # auth specific headers such as Bearer, Basic
    :auth,
    # re-usable tesla HTTP client
    :client,
    # optional database field
    :database,
    # feature response as returned from CouchDB `GET /`
    :features,
    # optional timeout for CouchDB-specific responses
    :timeout,
    # %URI parsed
    :uri,
    # uuid as reported from CouchDB `GET /`
    :uuid,
    # vendor-specific info as reported from CouchDB `GET /`
    :vendor,
    # CouchDB's API version
    :version
  ]

  @type t :: %__MODULE__{
          auth: any,
          client: nil | Tesla.Client.t(),
          database: nil | binary,
          features: nil | list,
          timeout: nil | integer,
          uri: nil | URI.t(),
          uuid: nil | binary,
          vendor: nil | map,
          version: nil | binary
        }

  require Logger

  # these default credentials are also used in CouchDB integration tests
  # because CouchDB3+ no longer accepts "admin party" blank credentials
  @default_uri "http://admin:passwd@localhost:5984/"
  # a long timeout allows transient issues to be concealed by haproxy
  @default_timeout 15_000

  @doc """
  Takes an optional parameter, the CouchDB uri, and returns a struct
  containing the usual CouchDB server properties. The URI may be given
  as a string or as a %URI struct.

  This should be piped into `Sofa.client/1` to create the HTTP client,
  which is stored inside the struct with correct authentication information.

  ## Examples

      iex> Sofa.init("https://very:Secure@foreignho.st:6984/")

      %Sofa{
        auth: "very:Secure",
        features: nil,
        uri: %URI{
          authority: "very:Secure@foreignho.st:6984",
          fragment: nil,
          host: "foreignho.st",
          path: "/",
          port: 6984,
          query: nil,
          scheme: "https",
          userinfo: "very:Secure"
        },
        uuid: nil,
        vendor: nil,
        version: nil
      }

  """
  @spec init(uri :: String.t() | URI.t()) :: Sofa.t()
  def init(uri \\ @default_uri) do
    uri = URI.parse(uri)

    %Sofa{
      auth: uri.userinfo,
      uri: uri
    }
  end

  @doc """
  Builds Telsa runtime client, with appropriate middleware header credentials,
  from supplied %Sofa{} struct.
  """
  @spec client(Sofa.t()) :: Sofa.t()
  def client(couch = %Sofa{uri: uri}) do
    couch_url = uri.scheme <> "://" <> uri.host <> ":#{uri.port}/"

    middleware = [
      {Tesla.Middleware.BaseUrl, couch_url},
      Tesla.Middleware.JSON,
      {Tesla.Middleware.BasicAuth, auth_info(uri.userinfo)}
    ]

    client = Tesla.client(middleware)
    %Sofa{couch | client: client, timeout: @default_timeout}
  end

  @doc """
  Returns user & password credentials extracted from a typical %URI{} userinfo
  field, as a Tesla-compatible authorization header. Currently only supports
  BasicAuth user:password combination.

  ## Examples

      iex> Sofa.auth_info("admin:password")
      %{username: "admin", password: "password"}

      iex> Sofa.auth_info("blank:")
      %{username: "blank", password: ""}

      iex> Sofa.auth_info("garbage")
      %{}
  """
  @spec auth_info(nil | String.t()) :: %{} | %{user: String.t(), password: String.t()}
  def auth_info(nil), do: %{}

  def auth_info(info) when is_binary(info) do
    case String.split(info, ":", parts: 2) do
      [""] -> %{}
      ["", _] -> %{}
      [user, password] -> %{username: user, password: password}
      _ -> %{}
    end
  end

  @doc """
  Given an existing %Sofa{} struct, or a prepared URI, attempts to connect
  to the CouchDB instance, and returns an updated %Sofa{} to use in future
  connections to this server, using the same HTTP credentials.

  Returns an updated `{:ok, %Sofa{}}` on success, or `{:error, reason}`, if
  for example, the URL is unreachable, times out, supplied credentials are
  rejected by CouchDB, or returns unexpected HTTP status codes.
  """
  @spec connect(String.t() | Sofa.t()) :: {:ok, Sofa.t()} | {:error, any()}
  def connect(sofa) when is_binary(sofa) do
    init(sofa) |> client() |> connect()
  end

  def connect(couch = %Sofa{}) do
    case result = Tesla.get(couch.client, "/") do
      {:error, _} ->
        result

      {:ok, resp = %{body: %{"error" => _error, "reason" => _reason}}} ->
        {:error, resp}

      {:ok, resp} ->
        {:ok,
         %Sofa{
           couch
           | features: resp.body["features"],
             uuid: resp.body["uuid"],
             vendor: resp.body["vendor"],
             version: resp.body["version"]
         }}
    end
  end

  @doc """
  Bang! wrapper around Sofa.connect/1; raises exceptions on error.
  """
  @spec connect!(String.t() | Sofa.t()) :: Sofa.t()
  def connect!(sofa) when is_binary(sofa) do
    init(sofa) |> client() |> connect!()
  end

  def connect!(sofa = %Sofa{}) when is_struct(sofa, Sofa) do
    url = sofa.uri.host <> ":" <> to_string(sofa.uri.port)

    case connect(sofa) do
      {:error, :econnrefused} ->
        raise Sofa.Error, "connection refused to " <> url

      {:ok, resp} ->
        resp

      _ ->
        raise Sofa.Error, "unhandled error from " <> url
    end
  end

  @doc """
  List all databases. Only available to admin users.
  """
  @spec all_dbs(Sofa.t()) :: {:error, any()} | {:ok, Sofa.t(), [String.t()]}
  def all_dbs(sofa = %Sofa{}) do
    case raw(sofa, "_all_dbs") do
      {:error, reason} -> {:error, reason}
      {:ok, _sofa, resp} -> {:ok, resp.body}
    end
  end

  @doc """
  Get _active_tasks. Only available to admin users.
  """
  @spec active_tasks(Sofa.t()) :: {:error, any()} | {:ok, Sofa.t(), [String.t()]}
  def active_tasks(sofa = %Sofa{}) do
    case raw(sofa, "active_tasks") do
      {:error, reason} -> {:error, reason}
      {:ok, _sofa, resp} -> {:ok, resp.body}
    end
  end

  @doc """
  Minimal wrapper around native CouchDB HTTP API, allowing an escape hatch
  for raw functionality, and as the core abstraction layer for Sofa itself.
  """
  @spec raw(
          Sofa.t(),
          Tesla.Env.url(),
          Tesla.Env.method(),
          Tesla.Env.opts(),
          Tesla.Env.body(),
          Tesla.Env.headers()
        ) ::
          {:error, any()} | {:ok, Sofa.t(), Sofa.Response.t()}
  def raw(
        sofa = %Sofa{timeout: timeout},
        path \\ "",
        method \\ :get,
        query \\ [],
        body \\ "",
        headers \\ []
      ) do
    # each Tesla adapter handles "empty" options differently - some
    # expect nil, others "", and some expect the key:value to be missing
    case Tesla.request(sofa.client,
           url: path,
           method: method,
           query: query,
           headers: headers,
           body: body,
           opts: [adapter: [timeout: timeout]]
         ) do
      {:ok, resp = %{body: %{"error" => _error, "reason" => _reason}}} ->
        {:error,
         %Sofa.Response{
           body: resp.body,
           url: resp.url,
           query: resp.query,
           method: resp.method,
           headers: Sofa.Cushion.untaint_headers(resp.headers),
           status: resp.status
         }}

      {:ok, %{} = resp} ->
        {:ok, sofa,
         %Sofa.Response{
           body: resp.body,
           url: resp.url,
           query: resp.query,
           method: resp.method,
           headers: Sofa.Cushion.untaint_headers(resp.headers),
           status: resp.status
         }}

      error ->
        Logger.debug("unhandled error in #{method} #{path} #{inspect(error)}")
        raise Sofa.Error, "unhandled error in #{method} #{path}"
    end
  end

  @doc """
  Bang! wrapper around Sofa.raw/1; raises exceptions on error.
  """
  @spec raw!(
          Sofa.t(),
          Tesla.Env.url(),
          Tesla.Env.method(),
          Tesla.Env.opts(),
          Tesla.Env.body()
        ) :: Sofa.Response.t()
  def raw!(sofa = %Sofa{}, path \\ "", method \\ :get, query \\ [], body \\ %{}) do
    case raw(sofa, path, method, query, body) do
      {:ok, %Sofa{}, response = %Sofa.Response{}} ->
        response

      {:error, _reason} = error ->
        raise(Sofa.Error, "unhandled error in #{method} #{path}")

        Logger.debug("unhandled error in #{method} #{path} #{inspect(error)}")
    end
  end
end
