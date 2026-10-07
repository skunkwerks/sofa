defmodule SofaCouchDBTest do
  @moduledoc """
  Runs the public Sofa API against a real CouchDB instance, bypassing
  Tesla.Mock. Excluded by default; run with `mix test --include integration`.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  # these match the CouchDB service container in .github/workflows/ci.yaml
  @couchdb_uri System.get_env("COUCHDB_URI", "http://admin:passwd@localhost:5984/")
  @adapter {Tesla.Adapter.Mint, transport_opts: [inet6: true, inet4: true]}

  setup_all do
    admin = Sofa.init(@couchdb_uri) |> Sofa.client(@adapter) |> Sofa.connect!()
    # the couchdb:3 image doesn't create system DBs in single node mode
    ensure_db(admin, "_users")
    db = "sofa_ci_#{System.unique_integer([:positive])}"
    {:ok, admin, _resp} = Sofa.DB.create(admin, db)
    on_exit(fn -> {:ok, _, _} = Sofa.DB.delete(admin, db) end)
    %{admin: admin, db: db}
  end

  defp ensure_db(sofa, db) do
    case Sofa.DB.create(sofa, db) do
      {:ok, _, _} -> :ok
      {:error, %Sofa.Response{status: 412}} -> :ok
    end
  end

  defp anonymous do
    uri = URI.parse(@couchdb_uri)

    %URI{uri | userinfo: nil, authority: nil}
    |> URI.to_string()
    |> Sofa.init()
    |> Sofa.client(@adapter)
  end

  test "connect!/1 reports server version and features", %{admin: admin} do
    assert String.starts_with?(admin.version, "3.")
    assert is_list(admin.features)
    assert is_binary(admin.uuid)
  end

  test "anonymous connect works, but admin-only endpoints are refused" do
    assert %Sofa{version: _} = sofa = Sofa.connect!(anonymous())
    assert {:error, %Sofa.Response{status: 401}} = Sofa.all_dbs(sofa)
    assert {:error, %Sofa.Response{status: 401}} = Sofa.active_tasks(sofa)
  end

  test "all_dbs/1 and active_tasks/1 work for admins", %{admin: admin, db: db} do
    assert {:ok, dbs} = Sofa.all_dbs(admin)
    assert db in dbs
    assert {:ok, tasks} = Sofa.active_tasks(admin)
    assert is_list(tasks)
  end

  test "raw/6 returns a transport error for an unreachable server" do
    sofa = Sofa.init("http://localhost:1/") |> Sofa.client(@adapter)
    assert {:error, %Mint.TransportError{reason: :econnrefused}} = Sofa.raw(sofa, "/")
    assert_raise Sofa.Error, ~r/connection refused/, fn -> Sofa.connect!(sofa) end
  end

  test "DB.info/2, open/2 and open!/2", %{admin: admin, db: db} do
    assert {:ok, %Sofa{database: ^db}, %Sofa.Response{status: 200, body: %{"db_name" => ^db}}} =
             Sofa.DB.info(admin, db)

    assert {:ok, %Sofa{database: ^db}} = Sofa.DB.open(admin, db)
    assert %Sofa{database: ^db} = Sofa.DB.open!(admin, db)
    assert {:error, %Sofa.Response{status: 404}} = Sofa.DB.open(admin, "sofa_ci_missing")
    assert_raise Sofa.Error, fn -> Sofa.DB.open!(admin, "sofa_ci_missing") end
  end

  test "DB.create/2 refuses an existing database", %{admin: admin, db: db} do
    assert {:error, %Sofa.Response{status: 412}} = Sofa.DB.create(admin, db)
  end

  test "documents round trip through put, get, exists and delete", %{admin: admin, db: db} do
    sofa = Sofa.DB.open!(admin, db)
    doc = Sofa.Doc.new(%{id: "couch", body: %{"cute" => true, "legs" => 4}})

    refute Sofa.Doc.exists?(sofa, "couch")
    assert {:error, :not_found} = Sofa.Doc.get(sofa, "couch")

    assert {:ok, %Sofa.Doc{rev: "1-" <> _ = rev} = written} = Sofa.Doc.put(sofa, doc)
    assert Sofa.Doc.exists?(sofa, "couch")
    assert {:ok, %Sofa.Doc{id: "couch", rev: ^rev}} = Sofa.Doc.exists(sofa, "couch")

    assert %Sofa.Doc{id: "couch", rev: ^rev, body: %{"cute" => true, "legs" => 4}} =
             Sofa.Doc.get(sofa, "couch")

    # a stale rev is a conflict, the current rev is an update
    assert {:error, :conflict} = Sofa.Doc.put(sofa, doc)

    assert {:ok, %Sofa.Doc{rev: "2-" <> _}} =
             Sofa.Doc.put(sofa, %{written | body: %{"legs" => 3}})

    assert {:error, :conflict} = Sofa.Doc.delete(sofa, written)
    assert %Sofa.Doc{} = latest = Sofa.Doc.get(sofa, "couch")
    assert :ok = Sofa.Doc.delete(sofa, latest)
    assert {:error, :not_found} = Sofa.Doc.get(sofa, "couch")
  end

  test "underscore-prefixed keys are rejected by CouchDB", %{admin: admin, db: db} do
    sofa = Sofa.DB.open!(admin, db)
    doc = Sofa.Doc.new(%{id: "bad", body: %{"_invalid" => true}})
    assert {:error, :bad_request} = Sofa.Doc.put(sofa, doc)
  end

  test "document type survives a round trip", %{admin: admin, db: db} do
    sofa = Sofa.DB.open!(admin, db)
    doc = %Sofa.Doc{Sofa.Doc.new("typed") | type: Sofa.Doc}
    assert {:ok, _} = Sofa.Doc.put(sofa, doc)
    assert %Sofa.Doc{type: Sofa.Doc, body: body} = Sofa.Doc.get(sofa, "typed")
    refute Map.has_key?(body, "type")
  end

  test "users can be created, fetched, reset and then log in", %{admin: admin} do
    name = "sofa_ci_#{System.unique_integer([:positive])}"
    user = Sofa.User.new(name, "apple", ["users"])

    assert {:ok, %Sofa.Doc{type: :user, rev: "1-" <> _}} = Sofa.User.put(admin, user)

    on_exit(fn ->
      Sofa.Doc.delete(%Sofa{admin | database: "_users"}, Sofa.User.get(admin, name))
    end)

    assert %Sofa.Doc{type: :user, body: body} = fetched = Sofa.User.get(admin, name)
    refute Map.has_key?(body, "password")
    assert body["password_scheme"] == "pbkdf2"
    assert body["roles"] == ["users"]

    # the new user can authenticate with the original password
    assert %Sofa{} = Sofa.connect!(as_user(name, "apple"))

    # reset drops the stale hash fields and CouchDB accepts the new password
    assert {:ok, %Sofa.Doc{rev: "2-" <> _}} =
             Sofa.User.put(admin, Sofa.User.reset_password(fetched, "pear"))

    assert %Sofa{} = Sofa.connect!(as_user(name, "pear"))
    assert_raise Sofa.Error, fn -> Sofa.connect!(as_user(name, "apple")) end
    assert {:error, :not_found} = Sofa.User.get(admin, "sofa_ci_nobody")
  end

  defp as_user(name, password) do
    uri = URI.parse(@couchdb_uri)

    %URI{uri | userinfo: "#{name}:#{password}", authority: nil}
    |> URI.to_string()
    |> Sofa.init()
    |> Sofa.client(@adapter)
  end
end
