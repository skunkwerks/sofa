## Sofa: idiomatic Elixir module for [Apache CouchDB]

Sofa is yet another Elixir CouchDB client. Its sole claim to fame is
that it's written by a rather average developer with no delusions of
grandeur. You should have no trouble understanding it.

The intention is to provide an idiomatic Elixir client, that can play
nicely with Ecto, Maps, and in particular, Structs and Protocols. You
should be able to store a Struct in CouchDB, and have it come back to
you as a Struct again, assuming you're not doing anything too messy,
such as nested structs, or trying to store pids, refs, and other
distinctly non-JSON things.

## Installation

It is recommended to use a `Tesla.Adapter`. While in principle these are
all equivalent, in practice, their patterns for handling query
parameters, headers, empty HTTP bodies, IPv6, and generally dealing with
`nil`, `true`, `false` and so forth mean that they are not created
equal. This library should work, in most cases transparently, and if
not, we welcome tests and converters to address any shortcomings.

Sofa makes no guarantees about specific HTTP modules, but should run
with:

- default Erlang `httpc` "no dependencies!"
- Mint and Finch

The package can be installed by adding `sofa` to your list of
dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:sofa, "~> 0.1.0"}
  ]
end
```

```elixir
# config/config.exs
import Config

if config_env() == :test do
  config :tesla, adapter: Tesla.Mock
else
  config :tesla, adapter: Tesla.Adapter.Mint
end
```

## Docs, Functionality and Road Map

- [hexdocs] as usual has all the goodies
- the [CouchDB API] should map very closely to Sofa

Sofa really only has 2 important abstractions that live above the
CouchDB API:

- `%Sofa{}` aka `Sofa.t()` which is a struct that wraps your HTTP API
    connection, along with any custom headers & settings you may
    require, and the returned data from the CouchDB server you connect
    to, including feature flags and vendor settings. As a convenience,
    it also doubles as your "database" struct, as that's really only a
    single additional field to be inserted into the CouchDB URL
- `%Sofa.Doc{}` aka `Sofa.Doc.t()` which is the main struct you'll work
    with. We've tried to keep it as close to the [CouchDB API] as possible,
    so aside from `id`, `rev`, and the `attachments` stubs, all the
    JSON is contained in a `body` and Sofa keeps out of your way.

While not yet implemented, Sofa wants to support "native" Elixir struct
usage, where you implement the Protocol to convert your custom Struct
to/from Sofa, and Sofa will use the `type` key that is commonly used in
CouchDB to detect & marshall your Struct directly to/from CouchDB's JSON
API transparently.

- [x] server:   `Sofa.*`
- [x] raw HTTP: `Sofa.Raw.*`
- [x] database: `Sofa.DB.*`
- [x] document: `Sofa.Doc.*`
- [x] user:     `Sofa.User.*`
- [ ] attachments
- [ ] transparent Struct API
- [ ] view:     `Sofa.View.*`
- [ ] changes:  `Sofa.Changes.*`
- [ ] timeouts for requests and inactivity
- [ ] bearer token authorisation
- [ ] runtime tracing filterable by method & URL
- [ ] embeddable within CouchDB BEAM runtime
- [ ] native CouchDB erlang term support

## Usage

### Connecting to CouchDB

`Sofa.init/1` and `Sofa.client/1` are effectively static structures, so
you can build them at compile time, or store them efficiently in ETS
tables, or `persistent_term` for faster access.

`Sofa.connect!/1` needs access to the CouchDB server, to verify that
your credentials are sufficient, and to retrieve feature flags and
vendor settings.

> Exactly how you use this, is dependent on your `Tesla.Adapter` and
> supervision trees. Make sure that you're not opening a new TCP
> connection for every call to the database, and then leave them
> dangling until your app or the server runs of of connections!

The `Sofa.DB.open!/2` call also does similar checks, ensuring you have
at least permissions to access the database, in some form. There is
nothing that changes over time within this struct, so feel free to cache
it "for a while" in your processes if that helps.

```elixir
# connect to CouchDB and ensure our credentials are valid
iex> sofa = Sofa.init("http://admin:passwd@localhost:5984/")
        |> Sofa.client()
        |> Sofa.connect!()
    #Sofa<
    client: %Tesla.Client{
        adapter: nil,
        fun: nil,
        post: [],
        pre: [{Tesla.Middleware.BaseUrl, ...}, {...}, ...]
    },
    features: ["access-ready", "partitioned", "pluggable-storage-engines",
    "reshard", "scheduler"],
    timeout: nil,
    uri: %URI{
        authority: "admin:passwd@localhost:5984",
        fragment: nil,
        host: "localhost",
        ...
    },
    uuid: "092b8cafefcaeef659beef7b60a5a9",
    vendor: %{"name" => "FreeBSD", ...},
    version: "3.2.0",
    ...
# re-use the same struct, and confirm we can access a specific database
iex> db = Sofa.DB.open!("mydb")
    #Sofa<
    client: %Tesla.Client{ ... },
    database: "mydb",
    ...
    version: "3.2.0"
    >
```

### Basic Doc Usage

There shouldn't be any surprises here - an Elixir `Map %{}` becomes the
`body` of the `%Sofa.Doc{}` struct, and the usual CouchDB internal
fields are available as additional atom fields off the struct:

```elixir
iex>  doc = %{"_id" => "smol", "cute" => true} |> Sofa.Doc.from_map()
    %Sofa.Doc{
    attachments: nil,
    body: %{
        "cute" => true
    },
    id: "smol",
    rev: nil,
    type: nil
    }
iex> doc |> Sofa.Doc.to_map()
    %{
        "_id" => "smol",
        "cute" => true
    }
# fetch and retrieve documents works like you'd expect
iex> Sofa.Doc.exists?(db,"missing")
    false
```

### Raw Mode

Sometimes you just want to re-upholster the Couch yourself. That's fine,
raw mode is here to help you:

```elixir
# raw mode gives you direct access to CouchDB API, with JSONification
iex> db = Sofa.init("http://admin:passwd@localhost:5984/")
        |> Sofa.client()
        |> Sofa.connect!()
        |> Sofa.raw("/_membership")
{:ok,
 #Sofa<
   client: %Tesla.Client{...},
   database: nil,
   features: ["access-ready",... "reshard", "scheduler"],
   timeout: nil,
   uri: %URI{...},
   uuid: "092b8cafefcaeef659beef7b60a5a9",
   vendor: %{"name" => "FreeBSD", ...},
   version: "3.2.0",
   ...
 >,
 %Sofa.Response{
   body: %{
     "all_nodes" => ["couchdb@127.0.0.1"],
     "cluster_nodes" => ["couchdb@127.0.0.1"]
   },
   headers: %{
     cache_control: "must-revalidate",
     content_length: 74,
     content_type: "application/json",
     date: "Wed, 28 Apr 2021 14:11:10 GMT",
     server: "CouchDB/3.2.0 (Erlang OTP/22)"
   },
   method: :get,
   query: [],
   status: 200,
   url: "http://localhost:5984/_membership"
 }}
```

## Development and Testing

If raw mode can't do it, send a PR, and we'll `make it so`. If you find
yourself reaching for raw mode often, consider a PR that extends Sofa
itself?

Sofa should pass reasonable credo, and also respect dialyzer. If you run
`make lint` you may wish to softlink `./.mix/plts` somewhere permanent, so
that your PLT creation is preserved across runs.

## Thanks

- the CouchDB team, who have been a part of my life for more than a
    decade. Relax.

[hex]: https://hex.pm/packages/sofa
[Apache CouchDB]: https://couchdb.org/
[hexdocs]: https://hexdocs.pm/sofa
[CouchDB API]: https://docs.couchdb.org/
