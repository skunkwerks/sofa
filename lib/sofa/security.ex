defmodule Sofa.Security do
  @moduledoc """
  A database's security object: who its admins and members are, by user
  name and by role.

  > If the only tool you have is CouchDB, then
  > everything looks like `{:ok, :relax}`

  See https://docs.couchdb.org/en/stable/api/database/security.html. An
  empty object means every server admin is an admin and everyone else,
  including anonymous users, is a member. CouchDB 3 creates databases
  admin-only instead, with the `_admin` role on both grants, unless its
  `default_security` setting says otherwise. Users and roles are those of
  `Sofa.User` documents in `_users`.

  Read and write it with `Sofa.DB.security/1` and `Sofa.DB.set_security/2`.

  ## Examples

      Sofa.Security.new()
      |> Sofa.Security.admin("jan")
      |> Sofa.Security.member(role: "users")
      |> then(&Sofa.DB.set_security(db, &1))

      iex> Sofa.Security.new() |> Sofa.Security.member("jan") |> Sofa.Security.member(role: "users") |> Sofa.Security.to_map()
      %{"admins" => %{"names" => [], "roles" => []}, "members" => %{"names" => ["jan"], "roles" => ["users"]}}
  """

  @typedoc "User names and roles granted a level of access"
  @type grant :: %{names: [String.t()], roles: [String.t()]}

  @type t :: %__MODULE__{admins: grant(), members: grant()}

  defstruct admins: %{names: [], roles: []}, members: %{names: [], roles: []}

  @doc "An empty security object, as a new database has."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Grants admin access to a user name, or with `role:` to a role."
  @spec admin(t(), String.t() | [role: String.t()]) :: t()
  def admin(security = %__MODULE__{}, who), do: grant(security, :admins, who)

  @doc "Grants member access to a user name, or with `role:` to a role."
  @spec member(t(), String.t() | [role: String.t()]) :: t()
  def member(security = %__MODULE__{}, who), do: grant(security, :members, who)

  @doc "Whether the object grants nothing, which leaves the database open to all."
  @spec empty?(t()) :: boolean()
  def empty?(security = %__MODULE__{}), do: to_map(security) == to_map(%__MODULE__{})

  @doc "From the JSON object CouchDB returns. Missing parts are empty."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{admins: grant_from_map(map["admins"]), members: grant_from_map(map["members"])}
  end

  @doc "To the JSON object CouchDB expects."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{admins: admins, members: members}) do
    %{"admins" => grant_to_map(admins), "members" => grant_to_map(members)}
  end

  @spec grant(t(), :admins | :members, String.t() | keyword()) :: t()
  defp grant(security, level, name) when is_binary(name),
    do: Map.update!(security, level, &%{&1 | names: Enum.uniq(&1.names ++ [name])})

  defp grant(security, level, role: role) when is_binary(role),
    do: Map.update!(security, level, &%{&1 | roles: Enum.uniq(&1.roles ++ [role])})

  @spec grant_from_map(map() | nil) :: grant()
  defp grant_from_map(nil), do: %{names: [], roles: []}
  defp grant_from_map(map), do: %{names: map["names"] || [], roles: map["roles"] || []}

  @spec grant_to_map(grant()) :: map()
  defp grant_to_map(%{names: names, roles: roles}), do: %{"names" => names, "roles" => roles}
end
