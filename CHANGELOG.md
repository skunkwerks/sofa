# Changelog

## 0.3.0

- Update dependencies (mint 1.11, tesla 1.21)
- Fix `Sofa.client/1` sending an empty `Authorization: Basic` header when no
    credentials are given, which CouchDB rejects rather than treating the
    request as anonymous
- Fix `Sofa.active_tasks/1` requesting `/active_tasks` instead of `/_active_tasks`
- Fix `Sofa.Doc.new/1` silently discarding `body` when given `%{id: id, body: body}`

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
