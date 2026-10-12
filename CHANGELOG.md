# Changelog

## Unreleased

- Add `Sofa.Response.error/1`, the status-to-atom mapping every module now uses

## 0.5.0

- Use a Firecracker VM in Github Actions
- Add `Sofa.Attachment` and attachment support in `Sofa.Doc`
- `attachments` is now a map of name to `%Sofa.Attachment{}`,
    round-tripping CouchDB's stubs and inline content
- `Sofa.Doc.attach/4` and `detach/2` build documents that save their
    attachments in one request
- `Sofa.Doc.get/3` now takes `attachments: true`,
    `att_encoding_info: true` and `atts_since:`
- `Sofa.Attachment.head/4`, `get/4`, `put/5` and `delete/4` cover the
    standalone endpoint with ranges, conditional gets, file and enumerable
    uploads, sinks for downloads, and digest verification
- Add `Sofa.Doc.save/2`, `save!/2` and `get!/3`, to support Elixir pipelines
- `Sofa.raw/7` takes trailing `Req` options, and every request path is now
    URL-encoded, so ids and attachment names with spaces or slashes work
- Add `mime` as a dependency, for attachment content types

## 0.4.0

- Switch the HTTP client from Tesla and Mint to [Req](https://hexdocs.pm/req),
    with JSON via Jason
- `Sofa.client/2` now takes `Req.new/1` options instead of a Tesla adapter
- `%Sofa{}.client` is a `Req.Request`
- Connections try IPv6 first and fall back to IPv4 by default automatically
- Transport errors are `%Req.TransportError{}`
- Unit tests fake CouchDB with [Bypass](https://hexdocs.pm/bypass) instead of
    `Tesla.Mock` as it provides better support for testing `_changes` feeds
- Integration tests default to the live development CouchDB unless
    `COUCHDB_URI` is set, as CI does
- Add `Sofa.Changes`, a GenServer behaviour following a database's `_changes`
    feed, built on [Req]'s streaming responses, via 3 modules
- Supports heartbeat & reconnection
- `Sofa.Changes.Query` builds the HTTP connection
- `Sofa.Changes.Parser` converts the raw feed into a stream of events
- `Sofa.Changes.Worker` handles a single request
- `include_docs` returns rows as a `%Sofa.Doc{}`
- `doc_id` and `selector` filters

[Req]: https://hex.pm/packages/req

## 0.3.0

- Update dependencies (mint 1.11, tesla 1.21)
- Fix `Sofa.client/1` sending an empty `Authorization: Basic` header when no
    credentials are given, which CouchDB rejects rather than treating the
    request as anonymous
- Fix `Sofa.active_tasks/1` requesting `/active_tasks` instead of `/_active_tasks`
- Fix `Sofa.Doc.new/1` silently discarding `body` when given `%{id: id, body: body}`
- Fix `Sofa.User.reset_password/2` storing the new password under an atom key,
    so `Sofa.User.put/2` did not strip the stale fields
- Fix `Sofa.Cushion.untaint_headers/1` being exponential in the number of
    unrecognised response headers
- `Sofa.raw/6` now returns `{:error, reason}` for transport errors such as
    `:econnrefused` or `:timeout` instead of raising. NB `Sofa.raw!/5` still raises
- `Sofa.connect!/1` recognises `%Mint.TransportError{reason: :econnrefused}`
- Correct typespecs for `Sofa.all_dbs/1`, `Sofa.auth_info/1`, `Sofa.Doc.exists/2`
    and `Sofa.Doc.delete/2`, the `:unathorized` typo in `Sofa.Doc.delete/2`,
    and an ex_doc markup warning in `Sofa.Doc.get/2`
- Use `+` instead of the deprecated `,` separator for `mix do` in the Makefile,
    bump the README install snippet to `~> 0.2`, and format `config/config.exs`
- Add `mix precommit` alias (compile with warnings as errors, drop unused lock
    entries, format, test), a `.dialyzer_ignore.exs` file, and `--format dialyxir`
    in `make lint`
- `Sofa.client/2` accepts an optional Tesla adapter, overriding the configured one
- Add integration tests against a real CouchDB, excluded by default, and run them
    in a GitHub Actions workflow alongside `make lint`; see `make integration`
- Add a sourcehut FreeBSD 15 build manifest running the same lint, unit and
    CouchDB integration tests against the `databases/couchdb3` package

## 0.2.0

- Configure Mint transport options to support dual stack inet6/inet configs
    https://mint.hexdocs.pm/Mint.HTTP.html#connect/4-transport-options
- Add docs targets to Makefile

## 0.1.4

- Minor dependencies bump for 2026

## 0.1.3

- Fix module doc `iex>` DocTest indentation to make HexDocs look pretty

## 0.1.2

- Initial release
