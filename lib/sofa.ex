defmodule Sofa do
  @moduledoc """
  Documentation for `Sofa`, a test-driven idiomatic Apache CouchDB client.

  > If the only tool you have is CouchDB, then
  > everything looks like {:ok, :relax}

  ## Examples

      iex> Sofa.init() |> Sofa.connect!()
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

  require Logger

  # these default credentials are also used in CouchDB integration tests
  # because CouchDB3+ no longer accepts "admin party" blank credentials
  @default_uri "http://admin:passwd@localhost:5984/"

  @doc """
  Takes an optional parameter, the CouchDB uri, and returns a struct
  containing the usual CouchDB server properties. The URI may be given
  as a string or as a %URI struct.

  This should be piped into Sofa.client/1 to create the HTTP client,
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
  @spec init(uri :: String.t() | %URI{}) :: %Sofa{}
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
  @spec client(%Sofa{}) :: %Sofa{}
  def client(couch = %Sofa{uri: uri}) do
    couch_url = uri.scheme <> "://" <> uri.host <> ":#{uri.port}/"

    middleware = [
      {Tesla.Middleware.BaseUrl, couch_url},
      Tesla.Middleware.JSON,
      {Tesla.Middleware.BasicAuth, auth_info(uri.userinfo)}
    ]

    client = Tesla.client(middleware)
    %Sofa{couch | client: client}
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
  Given an existing %Sofa{} struct containing a prepared URI, attempts
  to connect to the CouchDB instance, and returns an updated %Sofa{} to
  use in future connections to this server.

  Returns an updated `{:ok, %Sofa{}}` on success, or `{:error, reason}`, if
  for example, the URL is unreachable, times out, supplied credentials are
  rejected by CouchDB, or returns unexpected HTTP status codes.
  """
  @spec connect(%Sofa{}) :: {:ok, %Sofa{}} | {:error, any()}
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
  @spec connect!(%Sofa{} | String.t()) :: %Sofa{}
  def connect!(sofa) when is_binary(sofa) do
    init(sofa) |> client() |> connect!()
  end

  def connect!(sofa = %Sofa{}) when is_map(sofa) do
    case connect(sofa) do
      {:error, :econnrefused} ->
        raise Sofa.Error, "connection refused to #{sofa.uri.host <> ~s(:) <> sofa.uri.port}"

      {:ok, resp} ->
        resp

      _ ->
        raise Sofa.Error, "unhandled error #{IO.inspect(sofa)}"
    end
  end
end
