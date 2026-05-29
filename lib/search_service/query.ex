defmodule SearchService.Query do
  @moduledoc """
  Handles search query execution and result ranking with TF-IDF.
  """

  require Logger

  alias SearchService.Engine

  @typedoc "Search options"
  @type options :: [
          max_typos: non_neg_integer(),
          limit: pos_integer(),
          field_weights: map()
        ]

  @typedoc "Ranked search result"
  @type ranked_result :: {
          doc_id :: term(),
          score :: float(),
          metadata :: map()
        }

  @default_limit 50
  @default_field_weights %{
    product_name: 1.0,
    shop_name: 1.0,
    name: 1.0,
    description: 0.3
  }

  def execute(index, query, opts \\ []) do
    start_time = System.monotonic_time(:microsecond)

    index = Engine.ensure_finalized(index)

    if query == nil or String.trim(query) == "" do
      log_metrics(0, 0, start_time)
      []
    else
      results = do_execute(index, query, opts)
      log_metrics(length(results), 1, start_time)
      results
    end
  end

  def prefix_search(index, query, opts \\ []) do
    limit = opts[:limit] || @default_limit
    index = Engine.ensure_finalized(index)

    index
    |> Engine.prefix_search(query, limit: limit)
    |> Enum.map(fn {doc_id, distance, field} -> {doc_id, distance, %{field: field}} end)
    |> rank_results(index, [], opts[:field_weights] || @default_field_weights)
    |> Enum.take(limit)
  end

  def calculate_score(tfidf, distance, _field, field_weight) do
    tfidf_component = tfidf * 0.6
    field_component = field_weight * 0.25
    distance_penalty = distance * 0.15

    tfidf_component + field_component - distance_penalty
  end

  defp do_execute(index, query, opts) do
    max_typos = opts[:max_typos] || Engine.calculate_typo_budget(query)
    limit = opts[:limit] || @default_limit
    field_weights = opts[:field_weights] || @default_field_weights
    tokens = Engine.tokenize(query)

    token_results =
      Enum.map(tokens, fn token ->
        if max_typos == 0 do
          Engine.prefix_search(index, token, limit: limit * 2)
        else
          Engine.search(index, token, max_typos: max_typos, limit: limit * 2)
        end
      end)

    case token_results do
      [] ->
        []

      [single] ->
        single
        |> Enum.map(fn {doc_id, distance, field} -> {doc_id, distance, %{field: field}} end)
        |> rank_results(index, tokens, field_weights)
        |> Enum.take(limit)

      multiple ->
        doc_matches = intersect_token_results(multiple)

        doc_matches
        |> Enum.map(fn {doc_id, {avg_distance, field}} ->
          {doc_id, avg_distance, %{field: field}}
        end)
        |> rank_results(index, tokens, field_weights)
        |> Enum.take(limit)
    end
  end

  defp intersect_token_results(token_results) do
    [first | rest] = token_results

    first_map =
      Map.new(first, fn {id, dist, field} ->
        {id, %{distances: [dist], field: field}}
      end)

    Enum.reduce(rest, first_map, fn results, acc ->
      result_map = Map.new(results, fn {id, dist, _field} -> {id, dist} end)

      acc
      |> Map.filter(fn {id, _} -> Map.has_key?(result_map, id) end)
      |> Map.new(fn {id, data} ->
        {id, %{data | distances: [Map.get(result_map, id) | data.distances]}}
      end)
    end)
    |> Map.new(fn {id, data} ->
      avg_dist = Enum.sum(data.distances) / length(data.distances)
      {id, {avg_dist, data.field}}
    end)
  end

  defp rank_results(results, index, tokens, field_weights) do
    Enum.map(results, fn {doc_id, distance, metadata} ->
      field = metadata[:field] || :name
      field_weight = Map.get(field_weights, field, 1.0)

      tfidf =
        if tokens == [] do
          1.0
        else
          Engine.tfidf_score(index, doc_id, tokens)
        end

      score = calculate_score(tfidf, distance, field, field_weight)

      metadata =
        Map.merge(metadata, %{
          distance: distance,
          field: field,
          field_weight: field_weight,
          tfidf: tfidf
        })

      {doc_id, score, metadata}
    end)
    |> Enum.sort_by(fn {_id, score, _meta} -> score end, :desc)
  end

  defp log_metrics(result_count, token_count, start_time) do
    duration_ms = (System.monotonic_time(:microsecond) - start_time) / 1000

    :telemetry.execute(
      [:search_service, :search, :query],
      %{duration_ms: duration_ms, results: result_count},
      %{tokens: token_count}
    )

    if duration_ms > 50 do
      Logger.warning("Search.Query: Slow query detected (#{duration_ms}ms)")
    end
  end
end
