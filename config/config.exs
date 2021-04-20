import Config

if config_env() == :test do
  config :tesla, adapter: Tesla.Mock
else
  config :tesla, adapter: Tesla.Adapter.Gun
end
