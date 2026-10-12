# Integration tests

These tests run against a real CouchDB 3.x, and are excluded by default.

    make test-integration

By default they talk to the live development CouchDB at
`http://admin:passwd@localhost:5984/`. Set `COUCHDB_URI` to point
elsewhere.

The URI must have server admin credentials. Each run creates and removes
its own uniquely named database and user.

[Bypass]: https://hexdocs.pm/bypass
