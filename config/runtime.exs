import Config

if config_env() == :prod do
  config :search_service, SearchServiceWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4000")],
    secret_key_base: System.get_env("SECRET_KEY_BASE") || "change-me-for-production"
end

config :search_service, :persist_path, System.get_env("PERSIST_PATH") || "priv/search_index.bin"

config :search_service,
       :snapshot_interval_ms,
       String.to_integer(System.get_env("SNAPSHOT_INTERVAL_MS") || "86400000")

config :search_service, :api_key, System.get_env("SEARCH_API_KEY")
