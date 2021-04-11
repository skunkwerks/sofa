defmodule Sofa do
  @moduledoc """
  Documentation for `Sofa`, a test-driven idiomatic Apache CouchDB client.

  > If the only tool you have is CouchDB, then
  > everything looks like {:ok, :relax}

  """

  defstruct [
    # auth specific headers such as Bearer, Basic
    :auth,
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

  # these default credentials are also used in CouchDB integration tests
  # because CouchDB3+ no longer accepts "admin party" blank credentials
  @default_uri "http://admin:passwd@localhost:5984/"

  @doc """
  Takes an optional parameter, the CouchDB uri, and returns a struct
  containing the usual CouchDB server properties. The URI may be given
  as a string or as a %URI struct.

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
end
