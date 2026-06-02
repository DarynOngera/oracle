defmodule SearchService.Engine do
  @moduledoc """
  Inverted-index search engine with fuzzy matching and TF-IDF ranking.

  Optimizations for 150k+ documents:
  - Batch updates: insert/remove are O(1), finalize rebuilds vocab/IDF once.
  - Vocabulary stored as an Erlang :array for true O(log N) prefix binary search.
  - Bounded Levenshtein with early-exit avoids full matrix computation for non-matches.
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
          vocabulary: :array.array(),
          docs: %{
            term() => %{name: String.t(), shop_name: String.t(), token_count: pos_integer()}
          },
          idf: %{String.t() => float()},
          length_index: %{pos_integer() => [String.t()]},
          dirty: boolean()
        }

  @typedoc "Raw search result"
  @type search_result :: {doc_id :: term(), distance :: non_neg_integer(), field :: atom()}

  @build_yield_every 1_000

  def empty_index do
    %{
      postings: %{},
      vocabulary: :array.new(),
      docs: %{},
      idf: %{},
      length_index: %{},
      dirty: false
    }
  end

  @doc """
  Ensures the index is finalized before search.
  If the index is dirty (inserts/removes pending), rebuilds vocabulary, idf, and length_index.
  """
  def ensure_finalized(%{dirty: false} = index), do: index
  def ensure_finalized(index), do: finalize_index(index)

  def finalize_index(index) do
    vocab = Map.keys(index.postings) |> Enum.sort()
    vocab_array = :array.from_list(vocab)
    idf = compute_idf(index.postings, map_size(index.docs))

    length_index =
      Enum.reduce(vocab, %{}, fn token, acc ->
        len = String.length(token)
        Map.update(acc, len, [token], &[token | &1])
      end)
      |> Map.new(fn {len, tokens} ->
        {len, Enum.sort(Enum.uniq(tokens))}
      end)

    %{index | vocabulary: vocab_array, idf: idf, length_index: length_index, dirty: false}
  end

  def build_index(documents) do
    base = empty_index()

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

  def insert(index, text, doc_id, field \\ :name, weight \\ 1.0) do
    insert_document(index, %{id: doc_id, text: text, field: field, weight: weight})
    |> Map.put(:dirty, true)
  end

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

    %{index | postings: postings, docs: docs, dirty: true}
  end

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
        prefix_tokens = prefix_matches(index.vocabulary, token)
        exact_match = vocab_contains?(index.vocabulary, token)

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

        if map_size(acc) >= collect_limit or exact_match do
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

  def all_doc_ids(index) do
    index.docs |> Map.keys() |> MapSet.new()
  end

  def tfidf_score(index, doc_id, tokens) do
    doc = Map.get(index.docs, doc_id, %{token_count: 1})
    tf_norm = 1.0 / max(doc.token_count, 1)

    Enum.reduce(tokens, 0.0, fn token, acc ->
      idf = Map.get(index.idf, token, 0.0)
      acc + idf * tf_norm
    end)
  end

  def calculate_typo_budget(text) do
    len = String.length(text)

    cond do
      len < 4 -> 0
      len <= 8 -> 1
      true -> 2
    end
  end

  def tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  def tokenize(_), do: []

  defp insert_document(index, doc) do
    tokens = tokenize(doc.text)
    field = doc[:field] || :name
    weight = doc[:weight] || 1.0

    postings =
      Enum.reduce(tokens, index.postings, fn token, acc ->
        Map.update(acc, token, [{doc.id, field, weight}], &[{doc.id, field, weight} | &1])
      end)

    parts = String.split(doc.text, ~r/\s+/, trim: true)
    name = if parts == [], do: "", else: hd(parts)
    shop_name = if length(parts) > 1, do: Enum.join(tl(parts), " "), else: ""

    docs =
      Map.put(index.docs, doc.id, %{
        name: name,
        shop_name: shop_name,
        token_count: length(tokens)
      })

    %{index | postings: postings, docs: docs}
  end

  defp compute_idf(postings, total_docs) when total_docs > 0 do
    Map.new(postings, fn {token, entries} ->
      doc_freq = length(Enum.uniq_by(entries, fn {id, _, _} -> id end))
      idf = :math.log(total_docs / doc_freq)
      {token, idf}
    end)
  end

  defp compute_idf(_postings, _total_docs), do: %{}

  defp fuzzy_candidates(index, target, max_typos) do
    length_index = Map.get(index, :length_index, %{}) || %{}
    target_first = String.first(target)

    if map_size(length_index) == 0 do
      vocab = index.vocabulary
      tokens = if is_list(vocab), do: vocab, else: :array.to_list(vocab)
      target_len = String.length(target)

      tokens
      |> Enum.filter(fn vocab_token ->
        vocab_len = String.length(vocab_token)
        abs(vocab_len - target_len) <= max_typos and String.first(vocab_token) == target_first
      end)
      |> Enum.map(fn vocab_token ->
        {vocab_token, bounded_levenshtein(target, vocab_token, max_typos)}
      end)
      |> Enum.filter(fn {_token, distance} -> distance <= max_typos end)
    else
      target_len = String.length(target)
      min_len = max(target_len - max_typos, 1)
      max_len = target_len + max_typos

      candidate_tokens =
        for len <- min_len..max_len,
            tokens = Map.get(length_index, len, []),
            token <- tokens,
            String.first(token) == target_first,
            do: token

      candidate_tokens
      |> Enum.map(fn vocab_token ->
        {vocab_token, bounded_levenshtein(target, vocab_token, max_typos)}
      end)
      |> Enum.filter(fn {_token, distance} -> distance <= max_typos end)
    end
  end

  defp bounded_levenshtein(s1, s2, max_dist) do
    len1 = String.length(s1)
    len2 = String.length(s2)

    cond do
      max_dist < 0 ->
        max_dist + 1

      len1 == 0 ->
        if len2 <= max_dist, do: len2, else: max_dist + 1

      len2 == 0 ->
        if len1 <= max_dist, do: len1, else: max_dist + 1

      abs(len1 - len2) > max_dist ->
        max_dist + 1

      true ->
        do_bounded_levenshtein(String.graphemes(s1), String.graphemes(s2), max_dist)
    end
  end

  defp do_bounded_levenshtein(chars1, chars2, max_dist) do
    len2 = length(chars2)
    prev_row = List.to_tuple(Enum.to_list(0..len2))

    {final_row, exceeded} =
      Enum.reduce(chars1, {prev_row, false}, fn c1, {row, exceeded} ->
        if exceeded do
          {row, true}
        else
          {_, new_row_list} =
            Enum.reduce(chars2, {1, [1]}, fn c2, {i, acc} ->
              cost = if c1 == c2, do: 0, else: 1
              deletion = elem(row, i) + 1
              insertion = hd(acc) + 1
              substitution = elem(row, i - 1) + cost
              {i + 1, [min(deletion, min(insertion, substitution)) | acc]}
            end)

          new_row = List.to_tuple(Enum.reverse(new_row_list))
          min_in_row = Enum.min(new_row_list)

          if min_in_row > max_dist do
            {new_row, true}
          else
            {new_row, false}
          end
        end
      end)

    if exceeded do
      max_dist + 1
    else
      elem(final_row, len2)
    end
  end

  defp prefix_matches(vocab_array, prefix) do
    n = :array.size(vocab_array)

    if n == 0 do
      []
    else
      idx = find_lower_bound(vocab_array, prefix, 0, n)

      left = scan_backward(vocab_array, idx - 1, prefix, [])
      right = scan_forward(vocab_array, idx, prefix, [])

      left ++ right
    end
  end

  defp vocab_contains?(vocab_array, token) do
    n = :array.size(vocab_array)

    if n == 0 do
      false
    else
      idx = find_lower_bound(vocab_array, token, 0, n)
      idx < n and :array.get(idx, vocab_array) == token
    end
  end

  defp scan_backward(_arr, -1, _prefix, acc), do: acc

  defp scan_backward(arr, idx, prefix, acc) when idx >= 0 do
    token = :array.get(idx, arr)

    if String.starts_with?(token, prefix) do
      scan_backward(arr, idx - 1, prefix, [token | acc])
    else
      acc
    end
  end

  defp scan_forward(arr, idx, prefix, acc) do
    n = :array.size(arr)

    if idx < n do
      token = :array.get(idx, arr)

      if String.starts_with?(token, prefix) do
        scan_forward(arr, idx + 1, prefix, [token | acc])
      else
        acc
      end
    else
      acc
    end
  end

  defp find_lower_bound(_arr, _target, low, high) when low >= high, do: low

  defp find_lower_bound(arr, target, low, high) do
    mid = div(low + high, 2)
    mid_val = :array.get(mid, arr)

    if mid_val < target do
      find_lower_bound(arr, target, mid + 1, high)
    else
      find_lower_bound(arr, target, low, mid)
    end
  end
end
