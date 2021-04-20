defmodule Sofa.DB do
  @moduledoc """
  Documentation for `Sofa.DB`, a test-driven idiomatic Apache CouchDB client.

  > If the only tool you have is CouchDB, then
  > everything looks like {:ok, :relax}

  ## Examples

  iex> Sofa.DB.create(sofa, "testy")
  {:ok,
    %{"ok" => true}
  }
  """

  @doc """
  create DB. Only available to cluster admin users.
  """
  @spec create(%Sofa{}, String.t()) :: {:error, any()} | {:ok, %Sofa{}, any()}
  def create(sofa = %Sofa{}, db) when is_binary(db) do
    case Sofa.raw(sofa, db, :put) do
      {:error, reason} ->
        {:error, reason}

      {:ok, _sofa, resp} ->
        {:ok, sofa,
         %Sofa.Response{
           body: resp.body,
           url: resp.url,
           query: resp.query,
           method: resp.method,
           headers: resp.headers,
           status: resp.status
         }}
    end
  end

  @doc """
  Get DB info. Only available to cluster admin users.
  """
  @spec info(%Sofa{}, String.t()) :: {:error, any()} | {:ok, %Sofa{}, any()}
  def info(sofa = %Sofa{}, db) when is_binary(db) do
    case Sofa.raw(sofa, db, :get) do
      {:error, reason} ->
        {:error, reason}

      {:ok, _sofa, resp} ->
        {:ok, sofa,
         %Sofa.Response{
           body: resp.body,
           url: resp.url,
           query: resp.query,
           method: resp.method,
           headers: resp.headers,
           status: resp.status
         }}
    end
  end

  @doc """
  Delete DB. Only available to cluster admin users.
  """
  @spec delete(%Sofa{}, String.t()) :: {:error, any()} | {:ok, %Sofa{}, any()}
  def delete(sofa = %Sofa{}, db) when is_binary(db) do
    case Sofa.raw(sofa, db, :delete) do
      {:error, reason} ->
        {:error, reason}

      {:ok, _sofa, resp} ->
        {:ok, sofa,
         %Sofa.Response{
           body: resp.body,
           url: resp.url,
           query: resp.query,
           method: resp.method,
           headers: resp.headers,
           status: resp.status
         }}
    end
  end
end
