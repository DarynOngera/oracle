defmodule SearchServiceWeb.Plugs.ApiAuth do
  @moduledoc """
  Optional API key authentication for mutation endpoints.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:search_service, :api_key) do
      nil ->
        conn

      expected_key ->
        provided = List.first(get_req_header(conn, "x-api-key"))

        if provided == expected_key do
          conn
        else
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))
          |> halt()
        end
    end
  end
end
