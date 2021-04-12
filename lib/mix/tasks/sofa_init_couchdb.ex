defmodule Mix.Tasks.Sofa.Init.Couch do
  use Mix.Task
  import Sofa
  @default_couchdb_uri "http://admin:passwd@localhost:5984/"
  @couchdb_uri_file "./config/couchdb.uri"

  @shortdoc "Initialise CouchDB for Sofa in dev / test environments"

  def run(_) do
    # at this point in time, no apps are started and we do not have
    # access to parameters stashed in ./config/*.ex
    Application.ensure_all_started(:sofa)

    couchdb_uri = System.get_env("COUCHDB_URI", @default_couchdb_uri)
    couch = connect!(couchdb_uri)

    # add the application db
    _ = Db.assert!(couch, "leftnom")

    # add the jobs db
    db = Db.assert!(couch, "jobs")

    # add the serenity user
    db = Db.assert!(couch, "_users")

    password = :crypto.strong_rand_bytes(35) |> Base.encode32() |> String.downcase()
    # in dev/test save this for later
    # NB in production we use the password via vault
    File.write!(@couchdb_uri_file, "http://serenity:" <> password <> "@127.0.0.1:5984/")

    IO.puts(
      "Your random serenity couchdb user password has been written to " <> @couchdb_uri_file
    )

    doc =
      Doc.new("org.couchdb.user:serenity")
      |> Doc.put("name", "serenity")
      |> Doc.put("password", password)
      |> Doc.put("roles", ["serenity", "leftnom"])
      |> Doc.put("type", "user")

    # dont care if the database/document already exists
    _ = save_doc(db, doc)
  end
end
