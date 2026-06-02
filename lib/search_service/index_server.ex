defmodule SearchService.IndexServer do
  @moduledoc """
  GenServer managing the in-memory search index with persistent_term and file backing.
  """

  use GenServer

  require Logger

  alias SearchService.{BatchQueue, Engine, Persistence}

  @typedoc "Index server state"
  @type state :: %{
          persist_path: String.t(),
          snapshot_timer: reference() | nil,
          last_snapshot: DateTime.t() | nil,
          stats: map(),
          doc_count: non_neg_integer()
        }

  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def search(query, opts \\ []) do
    cache_key = {:search, query, opts[:limit] || 50}

    case :ets.lookup(:search_cache, cache_key) do
      [{^cache_key, results}] ->
        results

      [] ->
        case lookup_index() do
          nil ->
            Logger.warning("IndexServer: Search attempted but index not loaded")
            []

          index ->
            results = SearchService.Query.execute(index, query, opts)
            :ets.insert(:search_cache, {cache_key, results})
            results
        end
    end
  end

  def prefix_search(query, opts \\ []) do
    cache_key = {:prefix, query, opts[:limit] || 50}

    case :ets.lookup(:search_cache, cache_key) do
      [{^cache_key, results}] ->
        results

      [] ->
        case lookup_index() do
          nil ->
            []

          index ->
            results = SearchService.Query.prefix_search(index, query, opts)
            :ets.insert(:search_cache, {cache_key, results})
            results
        end
    end
  end

  def insert(doc) do
    BatchQueue.insert(doc)
  end

  def update(doc) do
    BatchQueue.update(doc)
  end

  def delete(doc_id) do
    BatchQueue.delete(doc_id)
  end

  def rebuild(documents) do
    index = Engine.build_index(documents)
    swap_index(index, map_size(index.docs))
  end

  def swap_index(index, doc_count) do
    GenServer.call(__MODULE__, {:swap_index, index, doc_count})
  end

  def snapshot do
    GenServer.call(__MODULE__, :snapshot, :infinity)
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  def memory_estimate do
    GenServer.call(__MODULE__, :memory_estimate, :infinity)
  end

  def ready? do
    lookup_index() != nil
  end

  def apply_batch_changes do
    changes = BatchQueue.dequeue_all()
    GenServer.call(__MODULE__, {:apply_changes, changes}, :infinity)
  end

  @impl true
  def init(opts) do
    persist_path = opts[:persist_path] || default_persist_path()
    snapshot_interval = opts[:snapshot_interval_ms] || 86_400_000

    :ets.new(:search_cache, [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    state = %{
      persist_path: persist_path,
      snapshot_timer: nil,
      last_snapshot: nil,
      stats: %{documents: 0, last_rebuild: nil},
      doc_count: 0
    }

    state =
      case Persistence.load(persist_path) do
        {:ok, index} ->
          index = Engine.ensure_finalized(index)
          :persistent_term.put(:search_index, index)
          count = map_size(index.docs)

          %{
            state
            | stats: %{documents: count, last_rebuild: DateTime.utc_now()},
              doc_count: count
          }

        {:error, reason} ->
          Logger.warning("IndexServer: Could not load index (#{reason}), starting empty")
          :persistent_term.put(:search_index, Engine.empty_index())
          state
      end

    timer = Process.send_after(self(), :scheduled_snapshot, snapshot_interval)
    state = %{state | snapshot_timer: timer}

    Logger.info("IndexServer: Initialized with persist_path=#{persist_path}")
    {:ok, state}
  end

  @impl true
  def handle_call({:swap_index, index, doc_count}, _from, state) do
    :persistent_term.put(:search_index, index)
    :ets.delete_all_objects(:search_cache)

    new_stats = %{
      documents: doc_count,
      last_rebuild: DateTime.utc_now()
    }

    Logger.info("IndexServer: Swapped index with #{doc_count} documents")

    {:reply, :ok, %{state | stats: new_stats, doc_count: doc_count}}
  end

  @impl true
  def handle_call({:apply_changes, changes}, _from, state) when changes == [] do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:apply_changes, changes}, _from, state) do
    case lookup_index() do
      nil ->
        Logger.warning("IndexServer: No index to apply changes to")
        {:reply, {:error, :no_index}, state}

      index ->
        {new_index, count_delta} = apply_changes(index, changes)
        :persistent_term.put(:search_index, new_index)
        :ets.delete_all_objects(:search_cache)

        new_count = max(state.doc_count + count_delta, 0)

        new_stats = %{
          state.stats
          | documents: new_count,
            last_rebuild: DateTime.utc_now()
        }

        Logger.info("IndexServer: Applied #{length(changes)} changes")
        {:reply, :ok, %{state | stats: new_stats, doc_count: new_count}}
    end
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

  defp lookup_index do
    :persistent_term.get(:search_index, nil)
  end

  defp default_persist_path do
    Application.get_env(:search_service, :persist_path) || "priv/search_index.bin"
  end

  defp apply_changes(index, changes) do
    {dirty_index, count_delta} =
      Enum.reduce(changes, {index, 0}, fn change, {acc_index, delta} ->
        case change do
          {:insert, doc} ->
            {Engine.insert(
               acc_index,
               doc.text,
               doc.id,
               doc[:field] || :name,
               doc[:weight] || 1.0
             ), delta + 1}

          {:update, doc} ->
            idx = Engine.remove(acc_index, doc.id)

            {Engine.insert(idx, doc.text, doc.id, doc[:field] || :name, doc[:weight] || 1.0),
             delta}

          {:delete, doc_id} ->
            {Engine.remove(acc_index, doc_id), delta - 1}
        end
      end)

    {Engine.finalize_index(dirty_index), count_delta}
  end
end
