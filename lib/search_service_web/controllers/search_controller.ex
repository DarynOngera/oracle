defmodule SearchServiceWeb.SearchController do
  @moduledoc """
  Handles search queries.
  """

  use Phoenix.Controller, formats: [:json]

  alias SearchService.IndexServer

  def search(conn, params) do
    query = params["q"] || ""
    limit = String.to_integer(params["limit"] || "50")

    results = IndexServer.search(query, limit: limit)

    json(conn, %{
      query: query,
      count: length(results),
      results:
        Enum.map(results, fn {id, score, meta} ->
          %{
            id: id,
            score: Float.round(score, 4),
            field: meta[:field],
            distance: meta[:distance],
            tfidf: Float.round(meta[:tfidf] || 0.0, 4)
          }
        end)
    })
  end

  def prefix(conn, params) do
    query = params["q"] || ""
    limit = String.to_integer(params["limit"] || "50")

    results = IndexServer.prefix_search(query, limit: limit)

    json(conn, %{
      query: query,
      count: length(results),
      results:
        Enum.map(results, fn {id, score, meta} ->
          %{
            id: id,
            score: Float.round(score, 4),
            field: meta[:field]
          }
        end)
    })
  end
end
