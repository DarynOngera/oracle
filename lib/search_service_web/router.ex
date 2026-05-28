defmodule SearchServiceWeb.Router do
  @moduledoc """
  Router for SearchService HTTP API.
  """

  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :api_auth do
    plug(SearchServiceWeb.Plugs.ApiAuth)
  end

  scope "/api", SearchServiceWeb do
    pipe_through(:api)

    get("/health", MetricsController, :health)
    get("/metrics", MetricsController, :metrics)
    get("/search", SearchController, :search)
    get("/prefix", SearchController, :prefix)

    pipe_through(:api_auth)
    post("/documents", DocumentController, :create)
    delete("/documents/:id", DocumentController, :delete)
    post("/rebuild", DocumentController, :rebuild)
  end
end
