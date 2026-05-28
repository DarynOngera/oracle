defmodule SmartKioskCore.Search.IndexServer do
  @moduledoc """
  GenServer managing the in-memory search index with ETS and file backing.

  This is the central coordinator for:
  - In-memory inverted-index storage (ETS table for concurrent reads)
  - Disk persistence (compressed file for recovery)
  - Change batching and processing
  - Snapshot management

  ## Architecture

  ```
  [Web Requests] → [ETS Table] → (fast concurrent reads)
                      ↓
              [GenServer] → (single-writer for updates)
                      ↓
              [File] → (disk persistence)
  ```

  ## Configuration

      config :smart_kiosk_core, SmartKioskCore.Search.IndexServer,
        persist_path: "priv/search_index.bin",
        snapshot_interval_ms: 86_400_000  # 24 hours
  """

  use GenServer

  require Logger

  alias SmartKioskCore.Search.{BatchQueue, Engine, Persistence}

  @typedoc "Index server state"
  @type state :: %{
          ets_table: :ets.table(),
          persist_path: String.t(),
          snapshot_timer: reference() | nil,
          last_snapshot: DateTime.t() | nil,
          stats: map(),
          doc_count: non_neg_integer()
        }

  @ets_table :search_index

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Starts the IndexServer.

  ## Options

    * `:persist_path` - Path to persisted index file (default: priv/search_index.bin)
    * `:snapshot_interval_ms` - Auto-save interval (default: 24 hours)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Searches the index with the given query.
  """
  @spec search(String.t(), keyword()) :: [Query.ranked_result()]
  def search(query, opts \\ []) do
    case lookup_index() do
      nil ->
        Logger.warning("IndexServer: Search attempted but index not loaded")
        []

      index ->
        SmartKioskCore.Search.Query.execute(index, query, opts)
    end
  end

  @doc """
  Performs a prefix search (exact match only, no typos).
  """
  @spec prefix_search(String.t(), keyword()) :: [Query.ranked_result()]
  def prefix_search(query, opts \\ []) do
    case lookup_index() do
      nil -> []
      index -> SmartKioskCore.Search.Query.prefix_search(index, query, opts)
    end
  end

  @doc """
  Inserts a document into the index.

  This is an async operation - the change is queued and applied in batch.
  """
  @spec insert(Engine.document()) :: :ok
  def insert(doc) do
    BatchQueue.insert(doc)
  end

  @doc """
  Updates a document in the index.
  """
  @spec update(Engine.document()) :: :ok
  def update(doc) do
    BatchQueue.update(doc)
  end

  @doc """
  Removes a document from the index.
  """
  @spec delete(term()) :: :ok
  def delete(doc_id) do
    BatchQueue.delete(doc_id)
  end

  @doc """
  Rebuilds the entire index from the given documents.

  The index is built in the caller process (not the GenServer) to avoid
  blocking concurrent reads. Only the atomic swap into ETS happens
  inside the GenServer.
  """
  @spec rebuild([Engine.document()]) :: :ok | {:error, term()}
  def rebuild(documents) do
    index = Engine.build_index(documents)
    swap_index(index, map_size(index.docs))
  end

  @doc """
  Atomically swaps the current in-memory index for a pre-built one.
  """
  @spec swap_index(Engine.index(), non_neg_integer()) :: :ok
  def swap_index(index, doc_count) do
    GenServer.call(__MODULE__, {:swap_index, index, doc_count})
  end

  @doc """
  Triggers a manual snapshot to disk.
  """
  @spec snapshot() :: :ok | {:error, term()}
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc """
  Returns current index statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Returns the estimated memory size of the search index.
  """
  @spec memory_estimate() :: non_neg_integer()
  def memory_estimate do
    GenServer.call(__MODULE__, :memory_estimate, :infinity)
  end

  @doc """
  Checks if the index is ready for queries.
  """
  @spec ready?() :: boolean()
  def ready? do
    lookup_index() != nil
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    persist_path = opts[:persist_path] || default_persist_path()
    snapshot_interval = opts[:snapshot_interval_ms] || 86_400_000

    ets_table =
      :ets.new(@ets_table, [
        :set,
        :protected,
        :named_table,
        read_concurrency: true
      ])

    state = %{
      ets_table: ets_table,
      persist_path: persist_path,
      snapshot_timer: nil,
      last_snapshot: nil,
      stats: %{documents: 0, last_rebuild: nil},
      doc_count: 0
    }

    # Try to load from disk; schedule rebuild either way to verify freshness
    state =
      case Persistence.load(persist_path) do
        {:ok, index} ->
          :ets.insert(ets_table, {:index, index})

          count = map_size(index.docs)

          %{
            state
            | stats: %{documents: count, last_rebuild: DateTime.utc_now()},
              doc_count: count
          }

        {:error, reason} ->
          Logger.warning("IndexServer: Could not load index (#{reason}), will rebuild")
          state
      end

    Process.send_after(self(), :trigger_rebuild, 5_000)

    timer = Process.send_after(self(), :scheduled_snapshot, snapshot_interval)
    state = %{state | snapshot_timer: timer}

    Logger.info("IndexServer: Initialized with persist_path=#{persist_path}")
    {:ok, state}
  end

  @impl true
  def handle_call({:swap_index, index, doc_count}, _from, state) do
    :ets.insert(state.ets_table, {:index, index})

    new_stats = %{
      documents: doc_count,
      last_rebuild: DateTime.utc_now()
    }

    Logger.info("IndexServer: Swapped index with #{doc_count} documents")

    {:reply, :ok, %{state | stats: new_stats, doc_count: doc_count}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    result =
      case lookup_index() do
        nil ->
          {:error, :no_index}

        index ->
          Persistence.save(index, state.persist_path)
      end

    new_state =
      case result do
        :ok -> %{state | last_snapshot: DateTime.utc_now()}
        _ -> state
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      case lookup_index() do
        nil ->
          state.stats

        _index ->
          Map.merge(state.stats, %{
            documents_in_index: state.doc_count,
            ready: true
          })
      end

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:memory_estimate, _from, state) do
    result =
      case lookup_index() do
        nil -> 0
        index -> :erlang.external_size(index)
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:scheduled_snapshot, state) do
    if state.snapshot_timer do
      Process.cancel_timer(state.snapshot_timer)
    end

    case lookup_index() do
      nil ->
        :ok

      index ->
        Task.start(fn ->
          try do
            Persistence.save(index, state.persist_path)
          catch
            _type, reason ->
              Logger.warning("IndexServer: Snapshot failed: #{inspect(reason)}")
          end
        end)
    end

    interval = 86_400_000
    timer = Process.send_after(self(), :scheduled_snapshot, interval)

    {:noreply, %{state | snapshot_timer: timer, last_snapshot: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(:trigger_rebuild, state) do
    Logger.info("IndexServer: Triggering async index rebuild")

    %{}
    |> SmartKioskCore.Workers.SearchRebuildWorker.new()
    |> Oban.insert()

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    case lookup_index() do
      nil ->
        :ok

      index ->
        try do
          Persistence.save(index, state.persist_path)
        rescue
          e -> Logger.warning("IndexServer: Shutdown save failed: #{inspect(e)}")
        end
    end

    :ok
  end

  # ── Private Functions ───────────────────────────────────────────────────────

  defp lookup_index do
    case :ets.lookup(@ets_table, :index) do
      [{:index, index}] -> index
      [] -> nil
    end
  end

  defp default_persist_path do
    Path.join(["apps", "smart_kiosk_core", "priv", "search_index.bin"])
  end
end
