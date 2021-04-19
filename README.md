# sofa

yet another Elixir CouchDB client

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `sofa` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:sofa, "~> 0.1.0"}
  ]
end
```

## Functionality

- [x] server:   `Sofa.*`
- [x] raw HTTP: `Sofa.Raw.*`
- [ ] database: `Sofa.DB.*`
- [ ] document: `Sofa.Doc.*`
- [ ] view:     `Sofa.View.*`
- [ ] changes:  `Sofa.Changes.*`
- [ ] timeouts for requests and inactivity
- [ ] bearer token authorisation

## Usage

```elixir
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
>
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/sofa](https://hexdocs.pm/sofa).
