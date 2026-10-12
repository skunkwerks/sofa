Mix.install([
  {:sofa, path: Path.expand("..", __DIR__)}
])

defmodule Follower do
  use Sofa.Changes

  require Logger
  alias Sofa.Doc

  def start_link(db), do: Sofa.Changes.start_link(__MODULE__, db)

  @impl true
  def init(db), do: {:ok, db, [include_docs: true], nil}

  @impl true
  def handle_change(%{"id" => id, "deleted" => true}, state) do
    Logger.warning("deleted: #{id}")
    {:ok, state}
  end

  def handle_change(%{"doc" => %Doc{id: id, rev: rev, body: body}}, state) do
    keys = body |> Map.keys() |> Enum.sort() |> Enum.join(", ")
    Logger.info("doc #{id} rev=#{rev} fields: #{keys}")
    {:ok, state}
  end

  def handle_change(change, state) do
    Logger.error("unhandled change: #{inspect(change)}")
    {:ok, state}
  end
end

db =
  (System.get_env("COUCHDB_URI") || "http://admin:passwd@localhost:5984/")
  |> Sofa.init()
  |> Sofa.client()
  |> Sofa.connect!()
  |> Sofa.DB.open!(System.get_env("COUCHDB_DB") || "mydb")

{:ok, _pid} = Follower.start_link(db)

Process.sleep(:infinity)
