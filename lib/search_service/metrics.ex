defmodule SearchService.Metrics do
  @moduledoc """
  Telemetry and metrics collection for the search engine.
  """

  require Logger

  alias SearchService.MetricsAggregator

  def attach_handlers do
    events = [
      [:search_service, :search, :query],
      [:search_service, :search, :index, :update],
      [:search_service, :search, :index, :rebuild],
      [:search_service, :search, :persistence, :save],
      [:search_service, :search, :persistence, :load]
    ]

    :telemetry.attach_many(
      "search-metrics-handler",
      events,
      &__MODULE__.handle_event/4,
      nil
    )

    Logger.info("Search.Metrics: Telemetry handlers attached")
  end

  def handle_event([:search_service, :search, :query], measurements, metadata, _config) do
    duration_ms = measurements.duration_ms
    result_count = measurements.results
    token_count = metadata[:tokens] || 1

    MetricsAggregator.record_query(duration_ms, result_count, token_count)

    if duration_ms > 50 do
      Logger.warning(
        "Search.Metrics: Slow query - #{:erlang.float_to_binary(duration_ms, decimals: 1)}ms, " <>
          "#{result_count} results, #{token_count} tokens"
      )
    end

    :ok
  end

  def handle_event([:search_service, :search, :index, :update], measurements, _metadata, _config) do
    Logger.debug(
      "Search.Metrics: Index updated - " <>
        "#{measurements.changes} changes in #{measurements.duration_ms}ms"
    )

    :ok
  end

  def handle_event([:search_service, :search, :index, :rebuild], measurements, _metadata, _config) do
    doc_count = measurements.documents
    duration_ms = measurements.duration_ms

    MetricsAggregator.record_rebuild(doc_count, duration_ms)

    Logger.info(
      "Search.Metrics: Index rebuilt - " <>
        "#{doc_count} documents in #{duration_ms}ms"
    )

    :ok
  end

  def handle_event(
        [:search_service, :search, :persistence, :save],
        measurements,
        _metadata,
        _config
      ) do
    Logger.debug(
      "Search.Metrics: Index saved - " <>
        "#{measurements.bytes} bytes in #{measurements.duration_ms}ms"
    )

    :ok
  end

  def handle_event(
        [:search_service, :search, :persistence, :load],
        measurements,
        metadata,
        _config
      ) do
    source = metadata[:source] || :unknown

    Logger.info(
      "Search.Metrics: Index loaded from #{source} - " <>
        "#{measurements.bytes} bytes in #{measurements.duration_ms}ms"
    )

    :ok
  end

  def record(event_name, measurements, metadata \\ %{}) do
    :telemetry.execute(
      [:search_service, :search | List.wrap(event_name)],
      measurements,
      metadata
    )
  end

  def stats do
    MetricsAggregator.stats()
  end
end
