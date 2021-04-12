import Config

if config_env() == :test do
  config :tesla, Sofa, adapter: Tesla.Mock
end
