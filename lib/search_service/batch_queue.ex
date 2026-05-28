defmodule SearchService.BatchQueue do
  @moduledoc """
  Accumulates document changes (inserts, updates, deletes) for batch processing.
  """

  use GenServer

  require Logger

  alias SearchService.Engine

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

  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def insert(doc) do
    GenServer.cast(__MODULE__, {:queue, {:insert, doc}})
  end

  def update(doc) do
    GenServer.cast(__MODULE__, {:queue, {:update, doc}})
  end

  def delete(doc_id) do
    GenServer.cast(__MODULE__, {:queue, {:delete, doc_id}})
  end

  def dequeue_all do
    GenServer.call(__MODULE__, :dequeue_all)
  end

  def size do
    GenServer.call(__MODULE__, :size)
  end

  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

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

  defp deduplicate_changes(changes) do
    changes
    |> Enum.group_by(&extract_doc_id/1)
    |> Enum.map(fn {_doc_id, ops} ->
      List.last(ops)
    end)
  end

  defp extract_doc_id({:insert, %{id: id}}), do: id
  defp extract_doc_id({:update, %{id: id}}), do: id
  defp extract_doc_id({:delete, id}), do: id
end
