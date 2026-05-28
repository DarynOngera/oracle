defmodule SmartKioskCore.Search.Metrics do
  @moduledoc """
  Telemetry and metrics collection for the search engine.

  Emits telemetry events consumed by MetricsAggregator for real-time
  performance monitoring and the /api/search/metrics endpoint.
  """

  require Logger

  alias SmartKioskCore.Search.MetricsAggregator

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Attaches telemetry handlers for search metrics.
  Called during application startup.
  """
  @spec attach_handlers() :: :ok
  def attach_handlers do
    events = [
      [:smart_kiosk, :search, :query],
      [:smart_kiosk, :search, :index, :update],
      [:smart_kiosk, :search, :index, :rebuild],
      [:smart_kiosk, :search, :persistence, :save],
      [:smart_kiosk, :search, :persistence, :load]
    ]

    :telemetry.attach_many(
      "search-metrics-handler",
      events,
      &__MODULE__.handle_event/4,
      nil
    )

    Logger.info("Search.Metrics: Telemetry handlers attached")
  end

  @doc """
  Handles telemetry events. Routes to aggregator and logs.
  """
  @spec handle_event(list(atom()), map(), map(), term()) :: :ok
  def handle_event([:smart_kiosk, :search, :query], measurements, metadata, _config) do
    duration_ms = measurements.duration_ms
    result_count = measurements.results
    token_count = metadata[:tokens] || 1

    # Forward to aggregator for percentile tracking
    MetricsAggregator.record_query(duration_ms, result_count, token_count)

    # Log slow queries (> 50ms threshold)
    if duration_ms > 50 do
      Logger.warning(
        "Search.Metrics: Slow query - #{:erlang.float_to_binary(duration_ms, decimals: 1)}ms, " <>
          "#{result_count} results, #{token_count} tokens"
      )
    end

    :ok
  end

  def handle_event([:smart_kiosk, :search, :index, :update], measurements, _metadata, _config) do
    Logger.debug(
      "Search.Metrics: Index updated - " <>
        "#{measurements.changes} changes in #{measurements.duration_ms}ms"
    )

    :ok
  end

  def handle_event([:smart_kiosk, :search, :index, :rebuild], measurements, _metadata, _config) do
    doc_count = measurements.documents
    duration_ms = measurements.duration_ms

    MetricsAggregator.record_rebuild(doc_count, duration_ms)

    Logger.info(
      "Search.Metrics: Index rebuilt - " <>
        "#{doc_count} documents in #{duration_ms}ms"
    )

    :ok
  end

  def handle_event([:smart_kiosk, :search, :persistence, :save], measurements, _metadata, _config) do
    Logger.debug(
      "Search.Metrics: Index saved - " <>
        "#{measurements.bytes} bytes in #{measurements.duration_ms}ms"
    )

    :ok
  end

  def handle_event([:smart_kiosk, :search, :persistence, :load], measurements, metadata, _config) do
    source = metadata[:source] || :unknown

    Logger.info(
      "Search.Metrics: Index loaded from #{source} - " <>
        "#{measurements.bytes} bytes in #{measurements.duration_ms}ms"
    )

    :ok
  end

  @doc """
  Records a custom metric event.
  """
  @spec record(atom(), map(), map()) :: :ok
  def record(event_name, measurements, metadata \\ %{}) do
    :telemetry.execute(
      [:smart_kiosk, :search | List.wrap(event_name)],
      measurements,
      metadata
    )
  end

  @doc """
  Returns current search statistics from the aggregator.
  """
  @spec stats() :: map()
  def stats do
    MetricsAggregator.stats()
  end
end
