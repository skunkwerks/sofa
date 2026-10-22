defmodule SofaAttachmentTest do
  use ExUnit.Case, async: true

  alias Sofa.Attachment

  doctest Attachment

  test "new/3 derives the content type from the name, or takes one, and leaves the digest to CouchDB" do
    assert %Attachment{content_type: "image/png", digest: nil} =
             Attachment.new("helmet.png", <<137>>)

    assert %Attachment{content_type: "application/octet-stream"} = Attachment.new("blob", "?")

    assert %Attachment{content_type: "text/x-sofa"} =
             Attachment.new("x.png", "", content_type: "text/x-sofa")
  end

  test "from_stub/2 reads every documented key, and to_stub/1 writes them back" do
    stub = %{
      "content_type" => "text/plain",
      "digest" => "md5-lSvsN0hwDhFKO2929yUNDg==",
      "length" => 86,
      "encoded_length" => 60,
      "encoding" => "gzip",
      "revpos" => 2,
      "stub" => true
    }

    att = Attachment.from_stub("recipe.txt", stub)

    assert %Attachment{
             name: "recipe.txt",
             length: 86,
             encoding: "gzip",
             encoded_length: 60,
             data: nil
           } = att

    assert Attachment.to_stub(att) == stub
  end

  test "inline data is base64 decoded, with the length taken from it" do
    att =
      Attachment.from_stub("a.txt", %{
        "content_type" => "text/plain",
        "data" => Base.encode64("eels")
      })

    assert %Attachment{data: "eels", length: 4} = att
    assert Attachment.to_stub(att) == %{"content_type" => "text/plain", "data" => "ZWVscw=="}
  end

  test "verified?/1 compares plain content against the digest" do
    att = %Attachment{Attachment.new("a.bin", "eels") | digest: Attachment.digest("eels")}
    assert Attachment.verified?(att)
    refute Attachment.verified?(%Attachment{att | data: "eel"})
    refute Attachment.verified?(%Attachment{att | digest: nil})
    # a digest of gzipped bytes cannot be checked against plain content
    refute Attachment.verified?(%Attachment{att | encoding: "gzip"})
  end
end
