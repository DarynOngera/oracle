defmodule SmartKioskCore.Search.Persistence do
  @moduledoc """
  Manages disk persistence of the search index using plain files.

  The inverted index serialises to ~8 MB for 150k products, well within
  safe limits for `:erlang.term_to_binary/2`.

  Approach:
  - Serialise with `:erlang.term_to_binary/2` (compressed)
  - Write to a temp file, then rename atomically
  - Verify with an MD5 checksum stored alongside the data
  """

  require Logger

  alias SmartKioskCore.Search.Engine

  @typedoc "Persistence result"
  @type result :: :ok | {:error, term()}

  @checksum_key :__checksum__
  @data_key :__trie_data__

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Saves the index to disk with a checksum for corruption detection.
  """
  @spec save(Engine.index(), String.t()) :: result()
  def save(index, path) do
    serialized = :erlang.term_to_binary(index, compressed: 9)
    checksum = :erlang.md5(serialized)
    payload = :erlang.term_to_binary({@checksum_key, checksum, @data_key, serialized})

    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, payload),
         :ok <- File.rename(tmp, path) do
      Logger.info(
        "Search.Persistence: Saved index (#{byte_size(serialized)} bytes serialized, " <>
          "#{byte_size(payload)} bytes on disk)"
      )

      :ok
    else
      {:error, reason} ->
        Logger.error("Search.Persistence: Failed to save index: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Loads the index from disk and verifies checksum.
  """
  @spec load(String.t()) :: {:ok, Engine.index()} | {:error, atom()}
  def load(path) do
    case File.read(path) do
      {:ok, payload} ->
        do_load(payload, path)

      {:error, :enoent} ->
        {:error, :empty}

      {:error, reason} ->
        Logger.error("Search.Persistence: Failed to read file: #{inspect(reason)}")
        {:error, :read_error}
    end
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(path), do: File.exists?(path)

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(path) do
    case File.rm(path) do
      :ok ->
        Logger.info("Search.Persistence: Deleted index file at #{path}")
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error("Search.Persistence: Failed to delete file: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec stats(String.t()) :: {:ok, map()} | {:error, term()}
  def stats(path) do
    case File.stat(path) do
      {:ok, info} -> {:ok, %{size: info.size, mtime: info.mtime}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Private Functions ───────────────────────────────────────────────────────

  defp do_load(payload, path) do
    with {@checksum_key, stored_checksum, @data_key, serialized} <-
           :erlang.binary_to_term(payload),
         computed_checksum = :erlang.md5(serialized),
         true <- computed_checksum == stored_checksum do
      index = :erlang.binary_to_term(serialized)
      Logger.info("Search.Persistence: Loaded index from file")
      {:ok, index}
    else
      false ->
        Logger.error("Search.Persistence: Checksum mismatch - index corrupted")
        delete(path)
        {:error, :corrupted}

      _ ->
        Logger.error("Search.Persistence: Unexpected file format")
        {:error, :unknown}
    end
  rescue
    e ->
      Logger.error("Search.Persistence: Failed to deserialize: #{inspect(e)}")
      {:error, :deserialization_failed}
  end
end
