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

  @typedoc "A document, or just its id where no revision is involved"
  @type doc_ref :: Sofa.Doc.t() | String.t()

  @typedoc "Why a request failed, as the usual atoms, or the response for anything else"
  @type error ::
          :not_found
          | :unauthorized
          | :forbidden
          | :conflict
          | :bad_request
          | :digest_mismatch
          | Sofa.Response.t()
          | term()

  alias Sofa.Cushion

  # without it CouchDB decompresses on the way out, and the digest no longer fits
  @accept_gzip {"accept-encoding", "gzip"}

  ## Reading, with the database handle first as elsewhere in Sofa

  @doc """
  Fetches an attachment's metadata from the headers of a `HEAD` request:
  content type, size and the digest CouchDB uses as the ETag.

  For an attachment CouchDB stored compressed, `encoding` is set,
  `encoded_length` is the compressed size and `length` is `nil`, as the
  original size is not in the headers.

  ## Options

  - `rev:` a document revision, otherwise the current one is used
  - `if_none_match:` a digest. `{:ok, :not_modified}` is returned when it
    still matches

  ## Examples

      Sofa.Attachment.head(db, "SpaghettiWithMeatballs", "recipe.txt")
      #=> {:ok, %Sofa.Attachment{name: "recipe.txt", content_type: "text/plain", length: 86, ...}}
  """
  @spec head(Sofa.t(), doc_ref(), String.t(), keyword()) ::
          {:ok, t() | :not_modified} | {:error, error()}
  def head(sofa = %Sofa{database: db}, doc, name, opts \\ [])
      when is_binary(db) and is_binary(name) do
    headers = [@accept_gzip | headers(opts)]

    case Sofa.raw(sofa, path(db, doc, name), :head, params(opts), "", headers, decode_body: false) do
      {:ok, _sofa, %Sofa.Response{status: 200, headers: headers}} ->
        {:ok, from_headers(name, headers)}

      {:ok, _sofa, %Sofa.Response{status: 304}} ->
        {:ok, :not_modified}

      other ->
        error(other)
    end
  end

  @doc """
  Fetches an attachment's content, as the raw bytes CouchDB stored, with
  the metadata from the response headers. The whole content is checked
  against the digest as stored, and `{:error, :digest_mismatch}` returned
  when it differs. Compressed attachments are then decompressed, with
  `length` the original size and `encoded_length` the stored one.

  ## Options

  - `rev:` and `if_none_match:` as for `head/4`
  - `range:` a `first..last` byte range, fetched with a `Range` header.
    `length` is then the size of the part, which is not verified
  - `into:` a `Req` sink, such as `File.stream!(path)` or a function, for
    content too large to hold in memory. `data` is then whatever the sink
    returns, and the content arrives decompressed but is not verified

  ## Examples

      {:ok, att} = Sofa.Attachment.get(db, doc, "recipe.txt")
      att.data
      #=> "1. Cook spaghetti\\n2. Cook meatballs\\n..."

      Sofa.Attachment.get(db, doc, "video.mp4", into: File.stream!("/tmp/video.mp4"))
      #=> {:ok, %Sofa.Attachment{data: %File.Stream{}, ...}}
  """
  @spec get(Sofa.t(), doc_ref(), String.t(), keyword()) ::
          {:ok, t() | :not_modified} | {:error, error()}
  def get(sofa = %Sofa{database: db}, doc, name, opts \\ [])
      when is_binary(db) and is_binary(name) do
    req_opts = [raw: true] ++ Keyword.take(opts, [:into])

    # whole content comes as stored, so it can be verified. Parts and sinks as plain bytes
    headers =
      if Keyword.has_key?(opts, :range) or Keyword.has_key?(opts, :into),
        do: headers(opts),
        else: [@accept_gzip | headers(opts)]

    case Sofa.raw(sofa, path(db, doc, name), :get, params(opts), "", headers, req_opts) do
      {:ok, _sofa, %Sofa.Response{status: status, headers: headers, body: body}}
      when status in [200, 206] ->
        name |> from_headers(headers) |> content(status, body)

      {:ok, _sofa, %Sofa.Response{status: 304}} ->
        {:ok, :not_modified}

      other ->
        error(other)
    end
  end

  @doc "Bang! version of `get/4`. Returns the attachment or raises `Sofa.Error`."
  @spec get!(Sofa.t(), doc_ref(), String.t(), keyword()) :: t()
  def get!(sofa = %Sofa{}, doc, name, opts \\ []) do
    case get(sofa, doc, name, opts) do
      {:ok, att = %__MODULE__{}} ->
        att

      {:ok, :not_modified} ->
        raise Sofa.Error, "attachment #{name} of #{id(doc)} is unmodified"

      {:error, reason} ->
        raise Sofa.Error, "unable to get attachment #{name} of #{id(doc)}: #{inspect(reason)}"
    end
  end

  ## request plumbing

  @spec path(String.t(), doc_ref(), String.t()) :: String.t()
  defp path(db, doc, name), do: Cushion.path([db, id(doc), name])

  @spec id(doc_ref()) :: String.t()
  defp id(%Sofa.Doc{id: id}), do: id
  defp id(id) when is_binary(id), do: id

  @spec params(keyword()) :: keyword()
  defp params(opts), do: Keyword.take(opts, [:rev])

  @spec headers(keyword()) :: [{String.t(), String.t()}]
  defp headers(opts) do
    Enum.flat_map(opts, fn
      {:if_none_match, digest} ->
        [{"if-none-match", ~s("#{String.replace_prefix(digest, "md5-", "")}")}]

      {:range, first..last//_} ->
        [{"range", "bytes=#{first}-#{last}"}]

      _other ->
        []
    end)
  end

  # the ETag is the base64 MD5, which the stubs carry with an md5- prefix.
  # For compressed content the length is the stored size, so it is encoded_length
  @spec from_headers(String.t(), map()) :: t()
  defp from_headers(name, headers) do
    encoding = headers[:content_encoding]

    %__MODULE__{
      name: name,
      content_type: headers[:content_type] || "application/octet-stream",
      digest: headers[:etag] && "md5-" <> headers[:etag],
      length: if(encoding, do: nil, else: headers[:content_length]),
      encoding: encoding,
      encoded_length: encoding && headers[:content_length]
    }
  end

  # whole content is verified as stored, then decompressed. Parts and sinks are taken as-is
  @spec content(t(), 200 | 206, term()) :: {:ok, t()} | {:error, :digest_mismatch}
  defp content(att = %__MODULE__{digest: digest}, 200, body) when is_binary(body) do
    if digest in [nil, digest(body)],
      do: {:ok, inflate(att, body)},
      else: {:error, :digest_mismatch}
  end

  defp content(att, _status, body) when is_binary(body),
    do: {:ok, %{att | data: body, length: byte_size(body)}}

  defp content(att, _status, sink), do: {:ok, %{att | data: sink}}

  @spec inflate(t(), binary()) :: t()
  defp inflate(att = %__MODULE__{encoding: "gzip"}, body) do
    data = :zlib.gunzip(body)
    %{att | data: data, length: byte_size(data), encoded_length: byte_size(body)}
  end

  defp inflate(att, body), do: %{att | data: body, length: byte_size(body)}

  # the usual atoms for the documented statuses. Anything else is returned whole
  @spec error({:ok, Sofa.t(), Sofa.Response.t()} | {:error, term()}) :: {:error, error()}
  defp error({:ok, _sofa, response = %Sofa.Response{}}), do: {:error, status(response)}
  defp error({:error, response = %Sofa.Response{}}), do: {:error, status(response)}
  defp error({:error, reason}), do: {:error, reason}

  @spec status(Sofa.Response.t()) :: error()
  defp status(%Sofa.Response{status: 400}), do: :bad_request
  defp status(%Sofa.Response{status: 401}), do: :unauthorized
  defp status(%Sofa.Response{status: 403}), do: :forbidden
  defp status(%Sofa.Response{status: 404}), do: :not_found
  defp status(%Sofa.Response{status: 409}), do: :conflict
  defp status(response = %Sofa.Response{}), do: response

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
