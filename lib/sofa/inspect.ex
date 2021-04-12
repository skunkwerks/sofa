defimpl Inspect, for: Sofa do
  def inspect(sofa = %Sofa{uri: uri}, _opts) do
    # print out a passsword-safe version of URI
    scheme = if uri.scheme, do: uri.scheme, else: "http"
    host = if uri.host, do: uri.host, else: "localhost"
    port = Integer.to_string(if uri.port, do: uri.port, else: 5984)
    path = if uri.path, do: uri.path, else: "/"

    authority =
      if uri.userinfo do
        String.split(uri.userinfo, ":", parts: 2) |> hd()
      else
        ""
      end

    url = scheme <> "://" <> authority <> ":********@" <> host <> ":" <> port <> path

    """
    #Sofa<
    uri: "#{url}"
    features: #{sofa.features}
    timeout: #{sofa.timeout}
    uuid: #{sofa.uuid}
    vendor: #{sofa.vendor}
    version: #{sofa.version}
    >
    """
  end
end
