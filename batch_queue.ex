defmodule SmartKioskCore.Search.BatchQueue do
  @moduledoc """
  Accumulates document changes (inserts, updates, deletes) for batch processing.

  This module maintains an in-memory queue of changes that are processed
  every 30 seconds by the SearchIndexBatchWorker. This decouples database
  transactions from search index updates, improving write performance.
  """

  use GenServer

  require Logger

  alias SmartKioskCore.Search.Engine

  @typedoc "A change operation to be applied to the search index"
  @type change ::
          {:insert, Engine.document()}
          | {:update, Engine.document()}
          | {:delete, doc_id :: term()}

  @typedoc "The queue state"
  @type state :: %{
          changes: [change()],
          last_processed: DateTime.t() | nil
        }

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Starts the BatchQueue GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Adds a document insertion to the queue.

  ## Examples

      iex> SmartKioskCore.Search.BatchQueue.insert(%{id: 1, text: "iPhone"})
      :ok
  """
  @spec insert(Engine.document()) :: :ok
  def insert(doc) do
    GenServer.cast(__MODULE__, {:queue, {:insert, doc}})
  end

  @doc """
  Adds a document update to the queue.
  """
  @spec update(Engine.document()) :: :ok
  def update(doc) do
    GenServer.cast(__MODULE__, {:queue, {:update, doc}})
  end

  @doc """
  Adds a document deletion to the queue.
  """
  @spec delete(term()) :: :ok
  def delete(doc_id) do
    GenServer.cast(__MODULE__, {:queue, {:delete, doc_id}})
  end

  @doc """
  Retrieves all queued changes and clears the queue.

  Returns the list of changes that need to be processed.
  """
  @spec dequeue_all() :: [change()]
  def dequeue_all do
    GenServer.call(__MODULE__, :dequeue_all)
  end

  @doc """
  Gets the current queue size.
  """
  @spec size() :: non_neg_integer()
  def size do
    GenServer.call(__MODULE__, :size)
  end

  @doc """
  Clears all pending changes without processing them.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{changes: [], last_processed: nil}}
  end

  @impl true
  def handle_cast({:queue, change}, state) do
    new_state = %{state | changes: [change | state.changes]}
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:clear, state) do
    {:noreply, %{state | changes: [], last_processed: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:dequeue_all, _from, state) do
    # Deduplicate: keep only the last operation per document ID
    # Reverse to get chronological order, then dedupe by keeping last
    changes =
      state.changes
      |> Enum.reverse()
      |> deduplicate_changes()

    new_state = %{state | changes: [], last_processed: DateTime.utc_now()}
    {:reply, changes, new_state}
  end

  @impl true
  def handle_call(:size, _from, state) do
    {:reply, length(state.changes), state}
  end

  # ── Private Functions ───────────────────────────────────────────────────────

  # Deduplicate changes by keeping only the last operation per document ID
  # If a doc is inserted then updated, we only need to insert with final data
  # If a doc is updated multiple times, we only need the last update
  # If a doc is deleted, we can skip any previous operations
  defp deduplicate_changes(changes) do
    changes
    |> Enum.group_by(&extract_doc_id/1)
    |> Enum.map(fn {_doc_id, ops} ->
      # Get the last operation for this doc_id
      List.last(ops)
    end)
  end

  # Extract document ID from a change operation
  defp extract_doc_id({:insert, %{id: id}}), do: id
  defp extract_doc_id({:update, %{id: id}}), do: id
  defp extract_doc_id({:delete, id}), do: id
end
