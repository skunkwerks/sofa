# Integration tests

These tests run against a real CouchDB 3.x, and are excluded by default.

    podman run -d --name sofa-couchdb -p 5984:5984 \
        -e COUCHDB_USER=admin -e COUCHDB_PASSWORD=passwd docker.io/library/couchdb:3
    make test-integration

Set `COUCHDB_URI` to point elsewhere; it must carry server admin credentials.
Each run creates and removes its own uniquely named database.
