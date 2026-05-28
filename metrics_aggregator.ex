defmodule SmartKioskCore.Search.MetricsAggregator do
  @moduledoc """
  In-memory metrics aggregator for search performance monitoring.

  Collects telemetry events and maintains rolling statistics:
  - Query latency percentiles (p50, p95, p99)
  - Query throughput (1m, 5m counts)
  - Index health (document count, freshness)
  - Relevance stats (avg results, zero-result rate)

  Publicly accessible via `SmartKioskCore.Search.MetricsAggregator.stats/0`
  and the `/api/search/metrics` HTTP endpoint.
  """

  use GenServer

  require Logger

  @window_size 1_000
  @minute_ms 60_000
  @five_minute_ms 300_000

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns current aggregated search metrics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Records a query event directly (used by telemetry handler).
  """
  @spec record_query(float(), non_neg_integer(), non_neg_integer()) :: :ok
  def record_query(duration_ms, result_count, token_count) do
    GenServer.cast(__MODULE__, {:query, duration_ms, result_count, token_count})
  end

  @doc """
  Records an index rebuild event.
  """
  @spec record_rebuild(non_neg_integer(), non_neg_integer()) :: :ok
  def record_rebuild(doc_count, duration_ms) do
    GenServer.cast(__MODULE__, {:rebuild, doc_count, duration_ms})
  end

  @doc """
  Records current index state.
  """
  @spec record_index_state(non_neg_integer(), non_neg_integer()) :: :ok
  def record_index_state(doc_count, memory_bytes) do
    GenServer.cast(__MODULE__, {:index_state, doc_count, memory_bytes})
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Attach to telemetry events
    :telemetry.attach_many(
      "search-aggregator",
      [
        [:smart_kiosk, :search, :query],
        [:smart_kiosk, :search, :index, :rebuild]
      ],
      &handle_telemetry/4,
      nil
    )

    state = %{
      # Query latency circular buffer: [{duration_ms, timestamp}, ...]
      query_latencies: [],
      # Query result counts: [{count, timestamp}, ...]
      query_results: [],
      # Counters for time windows
      queries_1m: 0,
      queries_5m: 0,
      # Index state
      index_doc_count: 0,
      index_memory_bytes: 0,
      last_rebuild_at: nil,
      last_rebuild_duration_ms: 0,
      # Derived stats
      total_queries: 0,
      zero_result_queries: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    now = System.monotonic_time(:millisecond)

    # Filter to recent windows
    recent_1m = filter_recent(state.query_latencies, now, @minute_ms)
    recent_5m = filter_recent(state.query_latencies, now, @five_minute_ms)

    latencies = Enum.map(recent_1m, fn {dur, _ts} -> dur end)

    stats = %{
      query_latency: %{
        p50_ms: percentile(latencies, 0.50),
        p95_ms: percentile(latencies, 0.95),
        p99_ms: percentile(latencies, 0.99),
        min_ms: min_value(latencies),
        max_ms: max_value(latencies),
        count_1m: length(recent_1m),
        count_5m: length(recent_5m)
      },
      index: %{
        document_count: state.index_doc_count,
        memory_bytes: state.index_memory_bytes,
        last_rebuild_at: format_datetime(state.last_rebuild_at),
        freshness_seconds:
          if state.last_rebuild_at do
            div(System.monotonic_time(:second) - state.last_rebuild_at, 1)
          else
            nil
          end,
        build_duration_ms: state.last_rebuild_duration_ms
      },
      relevance: %{
        avg_results_per_query: avg_results(state.query_results, now, @minute_ms),
        zero_result_rate: zero_result_rate(state),
        total_queries: state.total_queries
      }
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:query, duration_ms, result_count, _token_count}, state) do
    now = System.monotonic_time(:millisecond)

    latencies = trim_window([{duration_ms, now} | state.query_latencies], @window_size)
    results = trim_window([{result_count, now} | state.query_results], @window_size)

    zero_results =
      if result_count == 0, do: state.zero_result_queries + 1, else: state.zero_result_queries

    {:noreply,
     %{
       state
       | query_latencies: latencies,
         query_results: results,
         total_queries: state.total_queries + 1,
         zero_result_queries: zero_results
     }}
  end

  @impl true
  def handle_cast({:rebuild, doc_count, duration_ms}, state) do
    now = System.monotonic_time(:second)

    {:noreply,
     %{
       state
       | index_doc_count: doc_count,
         last_rebuild_at: now,
         last_rebuild_duration_ms: duration_ms
     }}
  end

  @impl true
  def handle_cast({:index_state, doc_count, memory_bytes}, state) do
    {:noreply,
     %{
       state
       | index_doc_count: doc_count,
         index_memory_bytes: memory_bytes
     }}
  end

  # ── Telemetry Handler ────────────────────────────────────────────────────────

  defp handle_telemetry([:smart_kiosk, :search, :query], measurements, _metadata, _config) do
    record_query(measurements.duration_ms, measurements.results, 1)
  end

  defp handle_telemetry(
         [:smart_kiosk, :search, :index, :rebuild],
         measurements,
         _metadata,
         _config
       ) do
    record_rebuild(measurements.documents, measurements.duration_ms)
  end

  # ── Private Helpers ──────────────────────────────────────────────────────────

  defp filter_recent(list, now, window_ms) do
    Enum.filter(list, fn {_val, ts} -> now - ts <= window_ms end)
  end

  defp trim_window(list, max_size) do
    if length(list) > max_size do
      Enum.take(list, max_size)
    else
      list
    end
  end

  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    idx = (length(sorted) - 1) * p
    lower = floor(idx)
    upper = ceil(idx)

    if lower == upper do
      Enum.at(sorted, lower)
    else
      frac = idx - lower
      a = Enum.at(sorted, lower)
      b = Enum.at(sorted, upper)
      a + (b - a) * frac
    end
  end

  defp min_value([]), do: nil
  defp min_value(values), do: Enum.min(values)

  defp max_value([]), do: nil
  defp max_value(values), do: Enum.max(values)

  defp avg_results(results, now, window_ms) do
    recent = filter_recent(results, now, window_ms)

    if recent == [] do
      0.0
    else
      sum = Enum.sum(Enum.map(recent, fn {count, _ts} -> count end))
      sum / length(recent)
    end
  end

  defp zero_result_rate(state) do
    if state.total_queries == 0 do
      0.0
    else
      state.zero_result_queries / state.total_queries
    end
  end

  defp format_datetime(nil), do: nil

  defp format_datetime(timestamp) do
    DateTime.from_unix!(timestamp)
    |> DateTime.to_iso8601()
  end
end
