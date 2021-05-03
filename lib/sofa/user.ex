defmodule Sofa.User do
  @moduledoc """
  Documentation for `Sofa.User`, a test-driven idiomatic Apache CouchDB client.

  > If the only tool you have is CouchDB, then
  > everything looks like {:ok, :relax}

  The User module provides simple wrappers around the usual Sofa.DB and
  Sofa.Doc functions, specifically for the `_users` DB.

  You need appropriate permissions for this to work - either as administrator,
  or alternatively, if your user/group have permissions *and* your `local.ini`
  has `users_db_security_editable = true` set in `[couchdb]` section. If you
  use a group to assign permissions, `users_db` is a good choice.
  """

  # the doc _id prefix used everywhere by CouchDB
  @prefix "org.couchdb.user:"
  @doc_type "user"
  @user_db "_users"
  @doc """
  Create a new _user Sofa.Doc with the usual attributes per

    # https://docs.couchdb.org/en/stable/intro/security.html?highlight=_users#creating-a-new-user

  { _id: "org.couchdb.user:jan",
  "name": "jan",
  "password": "apple",
  "roles": ["chair"],
  "type": "user"
  }


  ## Examples
  iex> Sofa.User.new("jan", "apple", ["pointy_hat", "users_db"])
  %Sofa.Doc{
    attachments: %{},
    body: %{name: "jan", password: "apple", roles: ["pointy_hat", "users_db"]},
    id: "org.couchdb.user:jan",
    rev: nil,
    type: :user
  }

  """
  @spec new(String.t(), String.t(), [String.t()]) :: Sofa.Doc.t()
  def new(name, password \\ "", roles \\ [])
      when is_binary(name) and is_binary(password) and is_list(roles) do
    %Sofa.Doc{
      Sofa.Doc.new(@prefix <> name)
      | type: :user,
        body: %{
          name: name,
          password:
            case password do
              "" -> generate_random_secret()
              _ -> password
            end,
          roles: roles
        }
    }
  end

  @doc """
  PUT a valid Sofa.Doc with user attributes into the `/_users` DB.
  """
  @spec put(Sofa.t(), Sofa.Doc.t()) :: {:ok, Sofa.Doc.t()} | {:error, any()}
  def put(
        sofa = %Sofa{},
        doc = %Sofa.Doc{
          type: :user,
          body: %{password: _password, roles: [_roles], name: user_name},
          id: @prefix <> user_name
        }
      ),
      do: Sofa.Doc.put(%Sofa{sofa | database: @user_db}, doc)

  @doc """
  GET doc and returns standard HTTP status codes, or the user doc

  - {:error, :not_found}  # doc doesn't exist
  - %Sofa.Doc{}           # doc exists and has metadata
  """
  @spec get(Sofa.t(), String.t()) :: {:error, any()} | Sofa.Doc.t()
  def get(sofa = %Sofa{}, name) when is_binary(name) do
    path = @prefix <> name
    user_db = %Sofa{sofa | database: @user_db}

    case resp = Sofa.Doc.get(user_db, path) do
      %Sofa.Doc{type: :user, id: ^path, body: %{"name" => ^name}} -> resp
      {:error, _reason} -> resp
    end
  end

  @doc """
  Generate small, random secret of length 16-64 characters inclusive,
  using base64 encoding, suitable for CouchDB default user passwords.

  ## Examples

      > Sofa.User.generate_random_secret()
      "E3gZtvNhF7pkHpeyoPjMnfRJidI5nRHD/MeRPR11jMKBxcMUXl75U8msnRj1bG/R"

  """
  @spec generate_random_secret(integer) :: String.t()
  def generate_random_secret(length \\ 64) when length > 15 and length < 65 do
    :crypto.strong_rand_bytes(length) |> Base.encode64() |> String.slice(0, length)
  end
end
