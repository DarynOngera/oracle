defmodule SearchServiceWeb.Endpoint do
  @moduledoc """
  Phoenix Endpoint for SearchService.
  """

  use Phoenix.Endpoint, otp_app: :search_service

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(SearchServiceWeb.Router)
end
