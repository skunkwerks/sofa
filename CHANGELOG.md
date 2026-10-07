# Changelog

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
