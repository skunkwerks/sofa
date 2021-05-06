defmodule Sofa.User do
  @moduledoc """
  Documentation for `Sofa.User`, a test-driven idiomatic Apache CouchDB client.

  > If the only tool you have is CouchDB, then
  > everything looks like {:ok, :relax}

  The User module provides simple wrappers around the usual Sofa.DB and
  Sofa.Doc functions, specifically for the `_users` DB.

  You need appropriate permissions for this to work - either as administrator,
  or alternatively, if your user/group have permissions *and* your `local.ini`
  has `users_security_editable = true` set in `[couchdb]` section. If you
  use a group to assign permissions, `users` is a good choice.
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
  iex> Sofa.User.new("jan", "apple", ["pointy_hat", "users"])
  %Sofa.Doc{
    attachments: %{},
    body: %{"name" => "jan", "password" => "apple", "roles" => ["pointy_hat", "users"]},
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
          "name" => name,
          "password" =>
            case password do
              "" -> generate_random_secret()
              _ -> password
            end,
          "roles" => roles
        }
    }
  end

  @doc """
  PUT a valid Sofa.Doc with user attributes into the `/_users` DB.

  If `doc.body.password` is supplied, remove hash info and update password.
  """
  @spec put(Sofa.t(), Sofa.Doc.t()) :: {:ok, Sofa.Doc.t()} | {:error, any()}
  def put(
        sofa = %Sofa{},
        doc = %Sofa.Doc{
          type: :user,
          body:
            %{
              "roles" => _roles,
              "name" => user_name
            } = body,
          id: @prefix <> user_name
        }
      ) do
    # update password if requested by stripping out old fields
    # This ensures that passwords are regenerated with best possible
    # algorithm, as defined in local.ini settings
    body =
      case Map.has_key?(body, "password") do
        true ->
          Map.delete(body, "derived_key")
          |> Map.delete("salt")
          |> Map.delete("iterations")
          |> Map.delete("password_scheme")

        false ->
          body
      end

    Sofa.Doc.put(
      %Sofa{sofa | database: @user_db},
      %Sofa.Doc{doc | body: body}
    )
  end

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
  Resets user password. NB you still need to write this doc to CouchDB.
  """
  @spec reset_password(Sofa.Doc.t(), String.t()) :: Sofa.Doc.t()
  def reset_password(
        %Sofa.Doc{type: :user, id: @prefix <> name, body: %{"name" => name}} = doc,
        password \\ ""
      )
      when is_binary(password) do
    %Sofa.Doc{
      doc
      | type: :user,
        body:
          Map.put(
            doc.body,
            :password,
            case password do
              "" -> generate_random_secret()
              _ -> password
            end
          )
    }
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
