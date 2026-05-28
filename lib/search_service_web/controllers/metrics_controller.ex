defmodule SearchServiceWeb.MetricsController do
  @moduledoc """
  Exposes health and metrics endpoints.
  """

  use Phoenix.Controller, formats: [:json]

  alias SearchService.{IndexServer, MetricsAggregator}

  def health(conn, _params) do
    ready = IndexServer.ready?()
    stats = IndexServer.stats()

    conn
    |> put_status(if ready, do: :ok, else: :service_unavailable)
    |> json(%{
      ready: ready,
      document_count: stats[:documents] || 0
    })
  end

  def metrics(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(MetricsAggregator.stats())
  end
end
