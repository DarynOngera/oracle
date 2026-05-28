defmodule SearchService.Application do
  @moduledoc """
  OTP Application for SearchService.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    SearchService.Metrics.attach_handlers()

    children = [
      {Phoenix.PubSub, name: SearchService.PubSub},
      SearchService.MetricsAggregator,
      SearchService.BatchQueue,
      SearchService.IndexServer,
      SearchServiceWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: SearchService.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    SearchServiceWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
