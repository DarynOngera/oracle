defmodule SearchServiceWeb.FallbackController do
  @moduledoc """
  Handles unmatched routes by returning a JSON 404.
  """

  use Phoenix.Controller, formats: [:json]

  def not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Not found"})
  end
end
