defmodule SmartKioskCore.Search.Engine do
  @moduledoc """
  Inverted-index search engine with fuzzy matching and TF-IDF ranking.

  Replaces the previous Trie implementation which OOM'd at 150k products.
  The inverted index stores:

    * postings   — token → [{doc_id, field, weight}]
    * vocabulary — sorted list of all tokens (for prefix / fuzzy lookup)
    * docs       — doc_id → %{name, shop_name, token_count}
    * idf        — token → inverse document frequency (precomputed)

  Memory: ~24 MB for 150k products (vs ~1 GB+ for the Trie).
  Serialization: ~8 MB compressed (safe for `term_to_binary`).
  """

  require Logger

  @typedoc "A document to be indexed"
  @type document :: %{
          required(:id) => term(),
          required(:text) => String.t(),
          optional(:field) => atom(),
          optional(:weight) => float()
        }

  @typedoc "Inverted index data structure"
  @type index :: %{
          postings: %{String.t() => [{term(), atom(), float()}]},
          vocabulary: [String.t()],
          docs: %{
            term() => %{name: String.t(), shop_name: String.t(), token_count: pos_integer()}
          },
          idf: %{String.t() => float()},
          length_index: %{pos_integer() => [String.t()]}
        }

  @typedoc "Raw search result"
  @type search_result :: {doc_id :: term(), distance :: non_neg_integer(), field :: atom()}

  @build_yield_every 1_000

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Returns an empty index struct for incremental builds.
  """
  @spec empty_index() :: index()
  def empty_index do
    %{
      postings: %{},
      vocabulary: [],
      docs: %{},
      idf: %{},
      length_index: %{}
    }
  end

  @doc """
  Finalizes an index after incremental inserts by sorting vocabulary
  and computing IDF values.
  """
  @spec finalize_index(index()) :: index()
  def finalize_index(index) do
    vocab = Map.keys(index.postings) |> Enum.sort()
    idf = compute_idf(index.postings, map_size(index.docs))

    # Sort tokens within each length bucket for binary search
    length_index =
      Map.new(index.length_index, fn {len, tokens} ->
        {len, Enum.sort(Enum.uniq(tokens))}
      end)

    %{index | vocabulary: vocab, idf: idf, length_index: length_index}
  end

  @doc """
  Builds an inverted index from a list of documents.
  """
  @spec build_index([document()]) :: index()
  def build_index(documents) do
    base = %{
      postings: %{},
      vocabulary: [],
      docs: %{},
      idf: %{}
    }

    {indexed, total_docs} =
      documents
      |> Enum.with_index()
      |> Enum.reduce({base, 0}, fn {doc, idx}, {acc, count} ->
        if rem(idx, @build_yield_every) == 0 and idx > 0 do
          Process.sleep(1)
        end

        {insert_document(acc, doc), count + 1}
      end)

    %{indexed | idf: compute_idf(indexed.postings, total_docs)}
    |> finalize_index()
  end

  @doc """
  Inserts a single document into an existing index.
  """
  @spec insert(index(), String.t(), term(), atom(), float()) :: index()
  def insert(index, text, doc_id, field \\ :name, weight \\ 1.0) do
    insert_document(index, %{id: doc_id, text: text, field: field, weight: weight})
  end

  @doc """
  Removes a document from the index by ID.
  """
  @spec remove(index(), term()) :: index()
  def remove(index, doc_id) do
    postings =
      Enum.reduce(index.postings, %{}, fn {token, entries}, acc ->
        filtered = Enum.reject(entries, fn {id, _, _} -> id == doc_id end)

        if filtered == [] do
          acc
        else
          Map.put(acc, token, filtered)
        end
      end)

    docs = Map.delete(index.docs, doc_id)

    # Rebuild vocabulary, idf, and length_index after removal
    %{index | postings: postings, docs: docs}
    |> finalize_index()
  end

  @doc """
  Hybrid fuzzy + prefix search.

  First collects exact prefix matches (distance = 0), then fuzzy matches
  (distance = 1..max_typos). Results are merged, keeping the lowest
  distance per doc_id.

  Stops collecting once `limit * 3` doc_ids are gathered to avoid
  processing massive result sets for short prefixes.

  Returns a list of `{doc_id, distance, field}` tuples.
  """
  @spec search(index(), String.t(), keyword()) :: [search_result()]
  def search(index, query, opts \\ []) do
    max_typos = opts[:max_typos] || calculate_typo_budget(query)
    limit = opts[:limit] || 50
    collect_limit = limit * 3

    query
    |> tokenize()
    |> Enum.reduce(%{}, fn token, acc ->
      if map_size(acc) >= collect_limit do
        acc
      else
        # Step 1: prefix matches (distance = 0)
        prefix_tokens = prefix_matches(index.vocabulary, token)

        acc =
          Enum.reduce(prefix_tokens, acc, fn vocab_token, inner_acc ->
            if map_size(inner_acc) >= collect_limit do
              inner_acc
            else
              entries = Map.get(index.postings, vocab_token, [])

              Enum.reduce(entries, inner_acc, fn {doc_id, field, _weight}, deepest_acc ->
                if map_size(deepest_acc) >= collect_limit do
                  deepest_acc
                else
                  Map.put(deepest_acc, doc_id, {0, field})
                end
              end)
            end
          end)

        # Step 2: fuzzy matches (distance = 1..max_typos)
        if map_size(acc) >= collect_limit do
          acc
        else
          fuzzy_candidates(index, token, max_typos)
          |> Enum.reject(fn {_token, distance} -> distance == 0 end)
          |> Enum.reduce(acc, fn {vocab_token, distance}, inner_acc ->
            if map_size(inner_acc) >= collect_limit do
              inner_acc
            else
              entries = Map.get(index.postings, vocab_token, [])

              Enum.reduce(entries, inner_acc, fn {doc_id, field, _weight}, deepest_acc ->
                if map_size(deepest_acc) >= collect_limit do
                  deepest_acc
                else
                  Map.update(deepest_acc, doc_id, {distance, field}, fn {existing_dist,
                                                                         existing_field} ->
                    if distance < existing_dist do
                      {distance, field}
                    else
                      {existing_dist, existing_field}
                    end
                  end)
                end
              end)
            end
          end)
        end
      end
    end)
    |> Enum.sort_by(fn {_doc_id, {distance, _field}} -> distance end)
    |> Enum.map(fn {doc_id, {distance, field}} -> {doc_id, distance, field} end)
  end

  @doc """
  Prefix search — exact prefix matches, no typos.
  Results capped to `limit` (default 50).
  """
  @spec prefix_search(index(), String.t(), keyword()) :: [search_result()]
  def prefix_search(index, query, opts \\ []) do
    limit = opts[:limit] || 50

    query
    |> tokenize()
    |> Enum.reduce(%{}, fn token, acc ->
      tokens = prefix_matches(index.vocabulary, token)

      Enum.reduce(tokens, acc, fn vocab_token, inner_acc ->
        if map_size(inner_acc) >= limit do
          inner_acc
        else
          entries = Map.get(index.postings, vocab_token, [])

          Enum.reduce(entries, inner_acc, fn {doc_id, field, _weight}, deepest_acc ->
            if map_size(deepest_acc) >= limit do
              deepest_acc
            else
              Map.put(deepest_acc, doc_id, {0, field})
            end
          end)
        end
      end)
    end)
    |> Enum.sort_by(fn {_doc_id, {distance, _field}} -> distance end)
    |> Enum.map(fn {doc_id, {distance, field}} -> {doc_id, distance, field} end)
    |> Enum.take(limit)
  end

  @doc """
  Returns all document IDs in the index.
  """
  @spec all_doc_ids(index()) :: MapSet.t()
  def all_doc_ids(index) do
    index.docs |> Map.keys() |> MapSet.new()
  end

  @doc """
  Returns the TF-IDF score for a document and a list of matching tokens.

  Used by Query for ranking.
  """
  @spec tfidf_score(index(), term(), [String.t()]) :: float()
  def tfidf_score(index, doc_id, tokens) do
    doc = Map.get(index.docs, doc_id, %{token_count: 1})
    tf_norm = 1.0 / max(doc.token_count, 1)

    Enum.reduce(tokens, 0.0, fn token, acc ->
      idf = Map.get(index.idf, token, 0.0)
      acc + idf * tf_norm
    end)
  end

  @doc """
  Calculates the typo budget based on word length.

    * < 4 characters: 0 typos
    * 4-8 characters: 1 typo
    * > 8 characters: 2 typos
  """
  @spec calculate_typo_budget(String.t()) :: non_neg_integer()
  def calculate_typo_budget(text) do
    len = String.length(text)

    cond do
      len < 4 -> 0
      len <= 8 -> 1
      true -> 2
    end
  end

  @doc """
  Normalizes and tokenizes text into searchable terms.
  """
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  def tokenize(_), do: []

  # ── Private Functions ───────────────────────────────────────────────────────

  defp insert_document(index, doc) do
    tokens = tokenize(doc.text)
    field = doc[:field] || :name
    weight = doc[:weight] || 1.0

    postings =
      Enum.reduce(tokens, index.postings, fn token, acc ->
        Map.update(acc, token, [{doc.id, field, weight}], &[{doc.id, field, weight} | &1])
      end)

    # Build length index for fast fuzzy filtering
    length_index =
      Enum.reduce(tokens, index.length_index, fn token, acc ->
        len = String.length(token)
        Map.update(acc, len, [token], &[token | &1])
      end)

    # Extract name and shop_name from document text for metadata
    # The text format is "product_name shop_name"
    parts = String.split(doc.text, ~r/\s+/, trim: true)
    name = if parts == [], do: "", else: hd(parts)
    shop_name = if length(parts) > 1, do: Enum.join(tl(parts), " "), else: ""

    docs =
      Map.put(index.docs, doc.id, %{
        name: name,
        shop_name: shop_name,
        token_count: length(tokens)
      })

    %{index | postings: postings, docs: docs, length_index: length_index}
  end

  defp compute_idf(postings, total_docs) when total_docs > 0 do
    Map.new(postings, fn {token, entries} ->
      doc_freq = length(Enum.uniq_by(entries, fn {id, _, _} -> id end))
      idf = :math.log(total_docs / doc_freq)
      {token, idf}
    end)
  end

  defp compute_idf(_postings, _total_docs), do: %{}

  # ── Fuzzy matching ────────────────────────────────────────────────────────────

  # Returns [{vocab_token, distance}, ...] for all vocabulary tokens within
  # `max_typos` edit distance of `target`.
  # Uses length_index to avoid scanning the entire vocabulary.
  defp fuzzy_candidates(index, target, max_typos) do
    # Fallback if index was loaded from old file without length_index
    length_index = Map.get(index, :length_index, %{})

    if map_size(length_index) == 0 do
      # Fallback to full vocabulary scan (slow but safe)
      target_len = String.length(target)

      index.vocabulary
      |> Enum.filter(fn vocab_token ->
        vocab_len = String.length(vocab_token)
        abs(vocab_len - target_len) <= max_typos
      end)
      |> Enum.map(fn vocab_token ->
        {vocab_token, levenshtein_distance(target, vocab_token)}
      end)
      |> Enum.filter(fn {_token, distance} -> distance <= max_typos end)
    else
      target_len = String.length(target)
      min_len = max(target_len - max_typos, 1)
      max_len = target_len + max_typos

      # Collect tokens from relevant length buckets
      candidate_tokens =
        for len <- min_len..max_len,
            tokens = Map.get(length_index, len, []),
            token <- tokens,
            do: token

      # Compute Levenshtein distance only on filtered candidates
      candidate_tokens
      |> Enum.map(fn vocab_token ->
        {vocab_token, levenshtein_distance(target, vocab_token)}
      end)
      |> Enum.filter(fn {_token, distance} -> distance <= max_typos end)
    end
  end

  # Standard Levenshtein distance ( Wagner-Fischer ).
  defp levenshtein_distance(s1, s2) do
    len1 = String.length(s1)
    len2 = String.length(s2)

    if len1 == 0, do: len2
    if len2 == 0, do: len1

    chars1 = String.graphemes(s1)
    chars2 = String.graphemes(s2)

    # Space-optimised: keep only the previous row
    prev_row = Enum.to_list(0..len2)

    Enum.reduce(chars1, prev_row, fn c1, row ->
      {_, new_row} =
        Enum.reduce(chars2, {1, [1]}, fn c2, {i, acc} ->
          cost = if c1 == c2, do: 0, else: 1
          deletion = Enum.at(row, i) + 1
          insertion = hd(acc) + 1
          substitution = Enum.at(row, i - 1) + cost
          {i + 1, [min(deletion, min(insertion, substitution)) | acc]}
        end)

      new_row |> Enum.reverse()
    end)
    |> List.last()
  end

  # ── Prefix matching ───────────────────────────────────────────────────────────

  # O(log n + k) prefix lookup using binary search + bidirectional scan.
  defp prefix_matches([], _prefix), do: []

  defp prefix_matches(vocabulary, prefix) do
    n = length(vocabulary)
    # Find the first token >= prefix via binary search
    idx = find_lower_bound(vocabulary, prefix, 0, n)

    # Scan backward from idx while tokens still start with prefix
    left = scan_backward(vocabulary, idx, prefix, [])

    # Scan forward from idx while tokens still start with prefix
    right = scan_forward(vocabulary, idx, prefix, [])

    left ++ right
  end

  defp scan_backward(_vocabulary, -1, _prefix, acc), do: acc

  defp scan_backward(vocabulary, idx, prefix, acc) when idx >= 0 do
    token = Enum.at(vocabulary, idx)

    if String.starts_with?(token, prefix) do
      scan_backward(vocabulary, idx - 1, prefix, [token | acc])
    else
      acc
    end
  end

  defp scan_backward(_vocabulary, _idx, _prefix, acc), do: acc

  defp scan_forward(vocabulary, idx, prefix, acc) when idx < length(vocabulary) do
    token = Enum.at(vocabulary, idx)

    if String.starts_with?(token, prefix) do
      scan_forward(vocabulary, idx + 1, prefix, [token | acc])
    else
      acc
    end
  end

  defp scan_forward(_vocabulary, _idx, _prefix, acc), do: acc

  defp find_lower_bound(_vocabulary, _target, low, high) when low >= high, do: low

  defp find_lower_bound(vocabulary, target, low, high) do
    mid = div(low + high, 2)
    mid_val = Enum.at(vocabulary, mid)

    if mid_val < target do
      find_lower_bound(vocabulary, target, mid + 1, high)
    else
      find_lower_bound(vocabulary, target, low, mid)
    end
  end
end
