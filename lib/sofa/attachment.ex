defmodule Sofa.Attachment do
  @moduledoc """
  A document attachment: the metadata CouchDB keeps in a document's
  `_attachments` stubs, plus the content once fetched or supplied.

  > If the only tool you have is CouchDB, then
  > everything looks like `{:ok, :relax}`

  CouchDB describes attachments in two places, see
  https://docs.couchdb.org/en/stable/api/document/attachments.html and
  the `_attachments` section of the document API:

  - inside the document, as stubs with the content type, size, digest and
    the revision number (`revpos`) they were added in, or inline with the
    content base64 encoded under `data`
  - at `/{db}/{docid}/{attname}`, as raw bytes with their own HTTP verbs

  This struct covers both. `data` is `nil` for a stub and a binary once
  the content is known. `Sofa.Doc` keeps its `attachments` as a map of
  name to `%Sofa.Attachment{}` and converts to and from the wire format,
  so a document built with `Sofa.Doc.attach/4` saves its attachments
  inline in one request.

  ## Examples

      iex> att = Sofa.Attachment.new("recipe.txt", "1. Cook spaghetti\\n")
      iex> {att.content_type, att.length}
      {"text/plain", 18}

      iex> Sofa.Attachment.new("recipe.txt", "...") |> Sofa.Attachment.to_stub()
      %{"content_type" => "text/plain", "data" => "Li4u"}
  """

  @typedoc "A content digest as CouchDB reports it: `md5-` and the base64 hash"
  @type digest :: String.t()

  @type t :: %__MODULE__{
          name: String.t(),
          content_type: String.t(),
          digest: digest() | nil,
          length: non_neg_integer() | nil,
          revpos: pos_integer() | nil,
          encoding: String.t() | nil,
          encoded_length: non_neg_integer() | nil,
          data: binary() | term() | nil
        }

  @enforce_keys [:name, :content_type]
  defstruct [:name, :content_type, :digest, :length, :revpos, :encoding, :encoded_length, :data]

  @doc """
  An attachment with content, ready to be attached to a document.

  The content type comes from the name via `MIME.from_path/1`, falling back
  to `application/octet-stream`, unless given as `content_type:`. The
  length is computed from the content. The digest is left to CouchDB,
  which computes it over the bytes it stores, compressed or not.
  """
  @spec new(String.t(), binary(), keyword()) :: t()
  def new(name, data, opts \\ []) when is_binary(name) and is_binary(data) and is_list(opts) do
    %__MODULE__{
      name: name,
      content_type: Keyword.get(opts, :content_type) || MIME.from_path(name),
      length: byte_size(data),
      data: data
    }
  end

  @doc """
  The `md5-` digest CouchDB reports for content.

  CouchDB computes it over the bytes as stored, so for attachments it
  stored compressed (see `encoding`) it matches the compressed form, not
  the original content.

      iex> Sofa.Attachment.digest("My hovercraft is full of eels!")
      "md5-uoLJeG8NfCWNzP/3AI2Ytw=="
  """
  @spec digest(binary()) :: digest()
  def digest(data) when is_binary(data), do: "md5-" <> Base.encode64(:crypto.hash(:md5, data))

  @doc """
  Whether the content matches the digest. `false` when either is missing,
  or when CouchDB stored the content compressed, as the digest is then of
  the compressed bytes. `get/4` verifies those as they arrive.

      iex> att = Sofa.Attachment.new("a.txt", "eels")
      iex> %Sofa.Attachment{att | digest: Sofa.Attachment.digest("eels")} |> Sofa.Attachment.verified?()
      true
      iex> %Sofa.Attachment{name: "a", content_type: "text/plain"} |> Sofa.Attachment.verified?()
      false
  """
  @spec verified?(t()) :: boolean()
  def verified?(%__MODULE__{data: data, digest: digest, encoding: nil})
      when is_binary(data) and is_binary(digest),
      do: digest(data) == digest

  def verified?(%__MODULE__{}), do: false

  @doc """
  Builds an attachment from one entry of a document's `_attachments`.

  Inline `data` is base64 decoded. A stub keeps `data` as `nil`.
  """
  @spec from_stub(String.t(), map()) :: t()
  def from_stub(name, stub = %{"content_type" => content_type}) when is_binary(name) do
    data = decode(stub["data"])

    %__MODULE__{
      name: name,
      content_type: content_type,
      digest: stub["digest"],
      length: stub["length"] || (data && byte_size(data)),
      revpos: stub["revpos"],
      encoding: stub["encoding"],
      encoded_length: stub["encoded_length"],
      data: data
    }
  end

  @doc """
  The `_attachments` entry for an attachment: inline, with the content
  base64 encoded, when it has content, otherwise a stub that tells CouchDB
  to keep the attachment it already has. Keys CouchDB did not report are
  left out.
  """
  @spec to_stub(t()) :: map()
  def to_stub(%__MODULE__{content_type: content_type, data: data}) when is_binary(data) do
    %{"content_type" => content_type, "data" => Base.encode64(data)}
  end

  def to_stub(att = %__MODULE__{content_type: content_type}) do
    %{
      "content_type" => content_type,
      "digest" => att.digest,
      "length" => att.length,
      "revpos" => att.revpos,
      "encoding" => att.encoding,
      "encoded_length" => att.encoded_length,
      "stub" => true
    }
    |> Map.reject(fn {_key, value} -> value == nil end)
  end

  @spec decode(String.t() | nil) :: binary() | nil
  defp decode(nil), do: nil
  defp decode(base64) when is_binary(base64), do: Base.decode64!(base64)
end
