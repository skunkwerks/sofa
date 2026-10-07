import Config

if config_env() == :test do
  config :tesla, adapter: Tesla.Mock
else
  # support *both* IPv6 and IPv4 connections with a mix of transport options
  # from Mint and gen_tcp
  # https://www.erlang.org/doc/apps/kernel/gen_tcp.html#connect/4-opts-connect-options
  # https://mint.hexdocs.pm/Mint.HTTP.html#connect/4-transport-options

  # dualstack: tries ipv6 first
  # ipv6 only: works
  # ipv4 only: works
  # ipv6 dead: works
  config :tesla, adapter: {Tesla.Adapter.Mint, transport_opts: [inet6: true, inet4: true]}

  # dualstack: tries ipv6 first
  # ipv6 only: fails
  # ipv4 only: works
  # ipv6 dead: works
  # config :tesla, adapter: {Tesla.Adapter.Mint, transport_opts: []}

  # dualstack: tries ipv6 first
  # ipv6 only: works
  # ipv4 only: works
  # ipv6 dead: works
  # config :tesla, adapter: {Tesla.Adapter.Mint, transport_opts: [inet6: true]}

  # dualstack: fails ipv6
  # ipv6 only: fails
  # ipv4 only: works
  # ipv6 dead: works
  # config :tesla, adapter: {Tesla.Adapter.Mint, transport_opts: [inet4: true]}
end
