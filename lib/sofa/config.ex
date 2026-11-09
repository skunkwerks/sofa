defmodule Sofa.Config do
  @moduledoc """
  The server configuration of a node, via `_node/{node}/_config`.

  > If the only tool you have is CouchDB, then
  > everything looks like `{:ok, :relax}`

  See https://docs.couchdb.org/en/stable/api/server/configuration.html.
  Values are strings, as in the ini files. Sections and keys are the
  familiar `[couchdb] database_dir` ones. The node defaults to `_local`,
  the one answering the request. Admin only.

  ## Examples

      {:ok, "true"} = Sofa.Config.get(server, "chttpd", "require_valid_user")
      {:ok, old} = Sofa.Config.put(server, "log", "level", "debug")
      {:ok, _} = Sofa.Config.delete(server, "log", "level")
  """

  alias Sofa.{Cushion, Response}

  @type error :: Response.error() | term()

  @doc "The whole configuration, a map of sections to maps of keys to values."
  @spec all(Sofa.t(), String.t()) :: {:ok, %{optional(String.t()) => map()}} | {:error, error()}
  def all(sofa = %Sofa{}, node \\ "_local") when is_binary(node) do
    case Sofa.raw(sofa, path(node, []), :get) do
      {:ok, _sofa, %Response{status: 200, body: config}} when is_map(config) -> {:ok, config}
      other -> error(other)
    end
  end

  @doc "One section, as a map of keys to values."
  @spec section(Sofa.t(), String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def section(sofa = %Sofa{}, section, node \\ "_local")
      when is_binary(section) and is_binary(node) do
    case Sofa.raw(sofa, path(node, [section]), :get) do
      {:ok, _sofa, %Response{status: 200, body: values}} when is_map(values) -> {:ok, values}
      other -> error(other)
    end
  end

  @doc "One value. `{:error, :not_found}` for a key that is not set."
  @spec get(Sofa.t(), String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def get(sofa = %Sofa{}, section, key, node \\ "_local")
      when is_binary(section) and is_binary(key) and is_binary(node) do
    case Sofa.raw(sofa, path(node, [section, key]), :get, [], "", [], decode_body: false) do
      {:ok, _sofa, %Response{status: 200, body: json}} -> {:ok, Jason.decode!(json)}
      other -> error(other)
    end
  end

  @doc """
  Sets a value and returns the previous one, `""` when there was none.
  CouchDB writes it to its local ini file, so it survives restarts.
  """
  @spec put(Sofa.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, error()}
  def put(sofa = %Sofa{}, section, key, value, node \\ "_local")
      when is_binary(section) and is_binary(key) and is_binary(value) and is_binary(node) do
    headers = [{"content-type", "application/json"}]

    case Sofa.raw(sofa, path(node, [section, key]), :put, [], Jason.encode!(value), headers,
           decode_body: false
         ) do
      {:ok, _sofa, %Response{status: 200, body: json}} -> {:ok, Jason.decode!(json)}
      other -> error(other)
    end
  end

  @doc "Removes a value and returns what it was."
  @spec delete(Sofa.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, error()}
  def delete(sofa = %Sofa{}, section, key, node \\ "_local")
      when is_binary(section) and is_binary(key) and is_binary(node) do
    case Sofa.raw(sofa, path(node, [section, key]), :delete, [], "", [], decode_body: false) do
      {:ok, _sofa, %Response{status: 200, body: json}} -> {:ok, Jason.decode!(json)}
      other -> error(other)
    end
  end

  @doc "Reloads the configuration from the ini files, without a restart."
  @spec reload(Sofa.t(), String.t()) :: :ok | {:error, error()}
  def reload(sofa = %Sofa{}, node \\ "_local") when is_binary(node) do
    case Sofa.raw(sofa, path(node, ["_reload"]), :post, [], "", [
           {"content-type", "application/json"}
         ]) do
      {:ok, _sofa, %Response{status: 200}} -> :ok
      other -> error(other)
    end
  end

  @spec path(String.t(), [String.t()]) :: String.t()
  defp path(node, rest), do: Cushion.path(["_node", node, "_config" | rest])

  @spec error({:ok, Sofa.t(), Response.t()} | {:error, term()}) :: {:error, error()}
  defp error({:ok, _sofa, response = %Response{status: 404}}),
    do: {:error, Response.error(response)}

  defp error({:ok, _sofa, response = %Response{body: json}}) when is_binary(json),
    do: {:error, Response.error(%Response{response | body: Jason.decode!(json)})}

  defp error({:ok, _sofa, response = %Response{}}), do: {:error, Response.error(response)}
  defp error({:error, response = %Response{}}), do: {:error, Response.error(response)}
  defp error({:error, reason}), do: {:error, reason}
end
