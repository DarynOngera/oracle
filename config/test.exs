import Config

config :search_service, SearchServiceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-secret-key-base-123456789012345678901234567890"
