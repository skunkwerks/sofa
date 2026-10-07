# integration tests need a real CouchDB, see test/integration/README.md
ExUnit.configure(exclude: [:integration])
ExUnit.start()
