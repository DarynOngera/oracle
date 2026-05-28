import Config

config :search_service, SearchServiceWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: SearchServiceWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SearchService.PubSub,
  live_view: [signing_salt: "change-me"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
