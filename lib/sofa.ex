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
    # re-usable Req HTTP client
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
          client: nil | Req.Request.t(),
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
  Builds a reusable `Req.Request` HTTP client, with basic auth credentials
  taken from the URI, and stores it in the supplied `%Sofa{}` struct.

  Any `Req.new/1` options may be passed to override the defaults, for example
  `receive_timeout: 5_000`, `plug: MyPlug` for `Req.Test`, or `inet6: false`
  to disable the default IPv6-first, IPv4-fallback connection behaviour.

  Retries are disabled, as CouchDB responses are expected to be fast and
  callers typically want to see errors immediately.
  """
  @spec client(Sofa.t(), keyword()) :: Sofa.t()
  def client(couch = %Sofa{uri: uri}, opts \\ []) when is_list(opts) do
    couch_url = uri.scheme <> "://" <> uri.host <> ":#{uri.port}/"

    # only send credentials when they are actually present, otherwise an
    # empty `Basic Og==` header is rejected by CouchDB instead of being
    # treated as an anonymous request
    auth =
      case auth_info(uri.userinfo) do
        %{username: user, password: password} -> [auth: {:basic, user <> ":" <> password}]
        _ -> []
      end

    defaults = [
      base_url: couch_url,
      # CouchDB only replies with application/json when asked to
      headers: [accept: "application/json"],
      receive_timeout: @default_timeout,
      retry: false,
      # try IPv6 first, falling back to IPv4. Req merges this into the Mint
      # transport options, so `connect_options` stays free for callers
      inet6: true
    ]

    client = Req.new(Keyword.merge(defaults ++ auth, opts))
    %Sofa{couch | client: client, timeout: @default_timeout}
  end

  @doc """
  Returns user & password credentials extracted from a typical %URI{} userinfo
  field, as basic auth credentials. Currently only supports
  BasicAuth user:password combination.

  ## Examples

      iex> Sofa.auth_info("admin:password")
      %{username: "admin", password: "password"}

      iex> Sofa.auth_info("blank:")
      %{username: "blank", password: ""}

      iex> Sofa.auth_info("garbage")
      %{}
  """
  @spec auth_info(nil | String.t()) :: %{} | %{username: String.t(), password: String.t()}
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
    case raw(couch, "/") do
      {:error, reason} ->
        {:error, reason}

      {:ok, _sofa, resp} ->
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
  Bang! wrapper around Sofa.connect/1. Raises exceptions on error.
  """
  @spec connect!(String.t() | Sofa.t()) :: Sofa.t()
  def connect!(sofa) when is_binary(sofa) do
    init(sofa) |> client() |> connect!()
  end

  def connect!(sofa = %Sofa{}) when is_struct(sofa, Sofa) do
    url = sofa.uri.host <> ":" <> to_string(sofa.uri.port)

    case connect(sofa) do
      {:ok, resp} ->
        resp

      {:error, %{reason: :econnrefused}} ->
        raise Sofa.Error, "connection refused to " <> url

      {:error, reason} ->
        Logger.debug("unhandled error from #{url} #{inspect(reason)}")
        raise Sofa.Error, "unhandled error from " <> url
    end
  end

  @doc """
  List all databases. Only available to admin users.
  """
  @spec all_dbs(Sofa.t()) :: {:error, any()} | {:ok, [String.t()]}
  def all_dbs(sofa = %Sofa{}) do
    case raw(sofa, "_all_dbs") do
      {:error, reason} -> {:error, reason}
      {:ok, _sofa, resp} -> {:ok, resp.body}
    end
  end

  @doc """
  Get _active_tasks. Only available to admin users.
  """
  @spec active_tasks(Sofa.t()) :: {:error, any()} | {:ok, [map()]}
  def active_tasks(sofa = %Sofa{}) do
    case raw(sofa, "_active_tasks") do
      {:error, reason} -> {:error, reason}
      {:ok, _sofa, resp} -> {:ok, resp.body}
    end
  end

  @doc """
  Minimal wrapper around native CouchDB HTTP API, allowing an escape hatch
  for raw functionality, and as the core abstraction layer for Sofa itself.

  A map `body` is sent as JSON, a binary body is sent as-is. JSON responses
  are decoded into maps, and CouchDB error responses, those with both an
  `error` and a `reason` key, are returned as `{:error, %Sofa.Response{}}`.
  Transport failures such as `:econnrefused` or `:timeout` are returned as
  `{:error, %Req.TransportError{}}`.
  """
  @spec raw(
          Sofa.t(),
          String.t(),
          atom(),
          keyword() | map(),
          map() | binary(),
          [{String.t(), String.t()}] | map()
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
    request =
      Req.merge(
        sofa.client,
        [
          url: "/" <> String.trim_leading(path, "/"),
          method: method,
          params: query,
          headers: headers,
          receive_timeout: timeout || @default_timeout
        ] ++ body_opts(body)
      )

    case Req.Request.run_request(request) do
      {request, %Req.Response{} = resp} ->
        response = %Sofa.Response{
          body: resp.body,
          url: URI.to_string(request.url),
          query: query,
          method: method,
          headers: Sofa.Cushion.untaint_headers(resp.headers),
          status: resp.status
        }

        case resp.body do
          %{"error" => _error, "reason" => _reason} -> {:error, response}
          _ -> {:ok, sofa, response}
        end

      {_request, exception} ->
        # transport-level failures such as :econnrefused, :timeout, or a
        # closed connection. The bang! variants raise on these instead
        Logger.debug("transport error in #{method} #{path} #{inspect(exception)}")
        {:error, exception}
    end
  end

  # a map is sent as JSON. An empty binary means no body at all
  defp body_opts(""), do: []
  defp body_opts(body) when is_map(body), do: [json: body]
  defp body_opts(body) when is_binary(body), do: [body: body]

  @doc """
  Bang! wrapper around Sofa.raw/1 raises exceptions on error.
  """
  @spec raw!(
          Sofa.t(),
          String.t(),
          atom(),
          keyword() | map(),
          map() | binary()
        ) :: Sofa.Response.t()
  def raw!(sofa = %Sofa{}, path \\ "", method \\ :get, query \\ [], body \\ "") do
    case raw(sofa, path, method, query, body) do
      {:ok, %Sofa{}, response = %Sofa.Response{}} ->
        response

      {:error, reason} ->
        Logger.debug("unhandled error in #{method} #{path} #{inspect(reason)}")
        raise Sofa.Error, "unhandled error in #{method} #{path}"
    end
  end
end
