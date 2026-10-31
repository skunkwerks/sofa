# Sofa

A straightforwards, idiomatic [CouchDB] client.

The intention is to provide an idiomatic Elixir client, that can play
nicely with Ecto, Maps, and in particular, Structs and Protocols. You
should be able to store a Struct in CouchDB, and have it come back to
you as a Struct again, assuming you're not doing anything too messy,
such as nested structs, or trying to store pids, refs, and other
distinctly non-JSON things.

## Installation

Sofa uses [Req] for HTTP, which uses [Finch] and [Mint] underneath, and
[Jason] for JSON. IPv6 is fully supported out of the box. CouchDB's JSON
is decoded into plain maps.

Any `Req.new/1` option can be passed to `Sofa.client/2` when you do need to
tweak things, such as timeouts, a proxy, TLS settings, or a `plug:` for
`Req.Test`.

The package can be installed by adding `sofa` to your list of
dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:sofa, "~> 0.6"}
  ]
end
```

[Req]: https://hexdocs.pm/req
[Finch]: https://hexdocs.pm/finch
[Mint]: https://hexdocs.pm/mint
[Jason]: https://hexdocs.pm/jason

## Docs

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
    so aside from `id`, `rev`, and the `attachments`, all the
    JSON is contained in a `body` and Sofa keeps out of your way.

## Road Map

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
- [x] changes:  `Sofa.Changes.*`
- [x] attachments: `Sofa.Attachment.*`
- [x] views:    `Sofa.View.*`, including `_all_docs` and `_design_docs`
- [x] mango:    `Sofa.Mango.*`
- [x] bulk:     `Sofa.Bulk.*`
- [x] design:   `Sofa.Design.*`
- [x] security: `Sofa.Security.*`
- [ ] transparent Struct API
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

> Req keeps a Finch connection pool per CouchDB host, so building the
> client once and reusing the struct is cheap. There is no need to open
> a new TCP connection for every call to the database.

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
    client: %Req.Request{
        method: :get,
        options: %{base_url: "http://localhost:5984/", ...},
        ...
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
    client: %Req.Request{ ... },
    database: "mydb",
    ...
    version: "3.2.0"
    >
```

### Doc Usage

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

### Attachments

Attachments follow one rule: the first argument is whatever flows through
the pipe. Small attachments are built onto the document and saved inline
with it in a single request:

```elixir
{:ok, doc} =
  Sofa.Doc.new(%{id: "SpaghettiWithMeatballs", body: %{"servings" => 4}})
  |> Sofa.Doc.attach("recipe.txt", File.read!("recipe.txt"))
  |> Sofa.Doc.attach("photo.jpg", File.read!("photo.jpg"))
  |> Sofa.Doc.save(db)
```

`attach/4` takes the content type from the name via MIME, or as an
option. Large files go to the standalone endpoint, streamed from disk,
and because `save!/2` and `put!/5` hand back the document with its new
revision, the pipeline carries on:

```elixir
doc =
  Sofa.Doc.new(%{id: "film", body: %{"title" => "Eels"}})
  |> Sofa.Doc.attach("poster.jpg", File.read!("poster.jpg"))
  |> Sofa.Doc.save!(db)
  |> Sofa.Attachment.put!(db, "video.mp4", {:file, "video.mp4"})
  |> Sofa.Attachment.delete!(db, "draft.mov")
```

Reads take the database handle first, like the rest of Sofa. Bytes are
checked against the digest CouchDB sends as the ETag, and attachments
CouchDB stored gzipped come back decompressed, with `encoding` set:

```elixir
{:ok, att} = Sofa.Attachment.get(db, doc, "recipe.txt")
att.data
#=> "1. Cook spaghetti\n2. Cook meatballs\n..."

# metadata only, a byte range, or a sink for large files
{:ok, %Sofa.Attachment{length: 86}} = Sofa.Attachment.head(db, doc, "recipe.txt")
{:ok, %Sofa.Attachment{data: "My hovercraft"}} = Sofa.Attachment.get(db, doc, "file.txt", range: 0..12)
{:ok, _} = Sofa.Attachment.get(db, doc, "video.mp4", into: File.stream!("/tmp/video.mp4"))

# or fetch the document with its attachments inline, and pipe on from there
Sofa.Doc.get!(db, "SpaghettiWithMeatballs", attachments: true)
|> Sofa.Doc.detach("photo.jpg")
|> Sofa.Doc.save!(db)
```

### Reading with Views

Views, `_all_docs` and `_design_docs` share one shape, a `%Sofa.View{}`
of rows. Keys are JSON values, `keys` goes as a `POST`, `include_docs`
gives each row a `%Sofa.Doc{}`, and `stream/4` pages through results of
any size:

```elixir
{:ok, %Sofa.View{rows: rows}} = Sofa.View.query(db, "recipes", "by_ingredient", key: "meatballs")
{:ok, _} = Sofa.View.all_docs(db, startkey: "L", endkey: "T", include_docs: true)

Sofa.View.stream(db, "recipes", "by_title", limit: 100)
|> Stream.map(& &1.key)
|> Enum.take(1000)
```

### Mango

Mango queries take a selector plus the documented options, and page by
bookmark:

```elixir
{:ok, %Sofa.Mango{docs: docs}} = Sofa.Mango.find(db, %{"year" => %{"$gt" => 2010}}, sort: [%{"year" => "asc"}])
{:ok, _} = Sofa.Mango.index(db, ["year"], name: "by_year")
Sofa.Mango.stream(db, %{"type" => "order"}) |> Enum.count()
```

### Bulk

`Sofa.Bulk` saves, deletes or fetches many documents in one request and
answers per document, in order, so conflicts are reported where they
happen rather than failing the batch:

```elixir
{:ok, results} = Sofa.Bulk.save(db, [fish, lamb])
Enum.map(results, fn {:ok, doc} -> doc.rev; {:error, :conflict, doc} -> doc.id end)
```

### Design Documents

Design documents are built as pipelines and saved like any document,
then queried with `Sofa.View` or used as `Sofa.Changes` filters:

The `~JS` sigil holds the JavaScript as written, with no interpolation
or escapes:

```elixir
import Sofa.Design, only: [sigil_JS: 2]

by_title = ~JS"""
function(doc) {
  if (doc.title) emit(doc.title, null);
}
"""

Sofa.Design.new("recipes")
|> Sofa.Design.view("by_title", by_title)
|> Sofa.Design.filter("important", ~JS"function(doc, req) { return doc.important === true; }")
|> Sofa.Doc.save(db)
```

### Security

A database's security object is a `%Sofa.Security{}`, built the same way
and written with `Sofa.DB.set_security/2`. CouchDB 3 creates databases
admin-only. An empty object opens one up for access:

```elixir
Sofa.Security.new() |> Sofa.Security.member(role: "users") |> then(&Sofa.DB.set_security(db, &1))
```

### Following Changes

`Sofa.Changes` is a `GenServer` behaviour for the `_changes` feed. Give it
a database and implement `handle_change/2`. It keeps the connection open,
reconnects from the last sequence when the server ends a response, watches
for missing heartbeats, and asks `handle_error/2` what to do about
failures. Feed options are the documented query parameters, see
`Sofa.Changes.Query`.

```elixir
defmodule Follower do
  use Sofa.Changes

  require Logger

  def start_link(db), do: Sofa.Changes.start_link(__MODULE__, db)

  @impl true
  def init(db), do: {:ok, db, [include_docs: true], nil}

  @impl true
  def handle_change(%{"id" => id, "deleted" => true}, state) do
    Logger.warning("deleted: #{id}")
    {:ok, state}
  end

  def handle_change(%{"doc" => %Sofa.Doc{id: id, rev: rev, body: body}}, state) do
    Logger.info("doc #{id} rev=#{rev} fields: #{inspect(Map.keys(body))}")
    {:ok, state}
  end

  def handle_change(change, state) do
    Logger.error("unhandled change: #{inspect(change)}")
    {:ok, state}
  end
end

iex> Sofa.init("http://admin:passwd@localhost:5984/")
     |> Sofa.client()
     |> Sofa.connect!()
     |> Sofa.DB.open!("mydb")
     |> Follower.start_link()
```

A ready-to-run version of this example is in
[`examples/follower.exs`](examples/follower.exs). Run it with
`COUCHDB_URI=http://admin:passwd@localhost:5984/ elixir examples/follower.exs`.

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
   client: %Req.Request{...},
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

## Contributing

If raw mode can't do it, send a PR, and we'll `make it so`. If you find
yourself reaching for raw mode often, consider a PR that extends Sofa
itself?

Sofa should pass credo, and also respect dialyzer, via `make lint`.

## Thanks

To the CouchDB team, a part of my life for more than a decade. Relax.

To the authors of [ibrowse] and [icouch], whose previous implementation
of the `_changes` feed in another project provided the backbone that
`Sofa.Changes` builds on.

[hex]: https://hex.pm/packages/sofa
[ibrowse]: https://github.com/cmullaparthi/ibrowse/
[icouch]: https://github.com/meetnow/icouch
[CouchDB]: https://couchdb.apache.org/
[hexdocs]: https://hexdocs.pm/sofa
[CouchDB API]: https://docs.couchdb.org/
