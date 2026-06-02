# SearchService

A high-performance, standalone Elixir search microservice using an **inverted index** with TF-IDF ranking and fuzzy matching. Optimized for 150k+ documents with sub-50ms query latency.

## Overview

SearchService replaces traditional SQL `ILIKE` pattern matching with an in-memory inverted index combined with Levenshtein distance for typo tolerance and TF-IDF for relevance ranking.

Originally extracted from the SmartKiosk e-commerce platform, this is now a fully standalone Phoenix HTTP microservice.

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   HTTP Client   │────▶│  Phoenix HTTP  │────▶│   IndexServer  │
│  (Any language) │     │   (Bandit)     │     │   (GenServer)   │
└─────────────────┘     └──────────────────┘     └─────────────────┘
                                                          │
                             ┌─────────────────┐           │
                             │   BatchQueue    │◀──────────┘
                             │  (Incremental)  │
                             └─────────────────┘
                                     │
                                     ▼
                         ┌─────────────────────────┐
                         │   :persistent_term       │───▶ Zero-copy reads
                         │   (Immutable Index)      │     (all cores)
                         └─────────────────────────┘
                                     │
                         ┌─────────────────────────┐
                         │   ETS :search_cache      │───▶ Query result cache
                         │   (invalidated on write) │
                         └─────────────────────────┘
                                     │
                                     ▼
                             ┌─────────────────┐     ┌──────────────┐
                             │    Engine       │────▶│   Inverted   │
                             │ (Fuzzy + TF-IDF)│     │    Index     │
                             └─────────────────┘     └──────────────┘
                                     │
                                     ▼
                             ┌─────────────────┐     ┌──────────────┐
                             │  Persistence    │◀───▶│  Disk File   │
                             │  (Snapshot)     │     │(Compressed)  │
                             └─────────────────┘     └──────────────┘
```

## Core Components

### 1. Engine (`SearchService.Engine`)

The inverted index implementation with three key optimizations for scale:

**Postings**: `token → [{doc_id, field, weight}]`
**Vocabulary**: Stored as an Erlang `:array` for true O(1) indexed binary search
**IDF**: Pre-computed inverse document frequency per token
**Length Index**: `token_length → [tokens]` for fast fuzzy filtering
**Doc Metadata**: Token count, name, shop_name per document

#### Optimizations for 150k+ Documents

**1. Batch Finalize (Dirty Flag)**
- `insert` and `remove` are O(1) map operations — they mark the index as `:dirty`
- `finalize_index` rebuilds vocabulary, IDF, and length_index **once** per batch
- Eliminates O(N log N) finalization on every document during bulk ingestion
- Finalization happens eagerly on load, swap, and batch apply — never on the query hot path

**2. Vocabulary as Erlang :array**
- Old implementation used a linked list with `Enum.at`, making binary search O(n log n)
- New implementation uses `:array` with O(1) random access
- Prefix search is now true O(log V + K) where V = vocabulary size, K = matches

**3. Bounded Levenshtein with Early-Exit**
- Old implementation computed the full distance matrix with O(n) list indexing inside the inner loop
- New implementation:
  - Uses **tuple-based row storage** for O(1) random access (`elem/2`)
  - Early-rejects if `abs(len1 - len2) > max_dist` (impossible to be within budget)
  - **Pre-filters candidates by first-character match** before computing any distance
  - Aborts mid-computation if the minimum value in any row exceeds `max_dist`
  - Reduces fuzzy candidate evaluation by 90-99% for non-matching tokens

**4. Exact-Match Gate**
- When a query token exists exactly in the vocabulary, the engine returns prefix hits immediately
- Previously, it would fall back to expensive fuzzy expansion even for perfect matches

**Typo Budget Rules**:
- `< 4 characters`: 0 typos (exact match + prefix)
- `4-8 characters`: 1 typo allowed
- `> 8 characters`: 2 typos allowed

**Search Strategy**:
1. **Prefix matches first**: Exact prefix hits get distance = 0
2. **Fuzzy matches second**: Levenshtein within typo budget (distance ≥ 1)
3. **Result merging**: Keep lowest distance per doc_id

**Example**:
```
"kili" matches "kilimani", "kilimanjaro" via prefix
"iphoen" matches "iphone" via fuzzy (1 typo)
```

### 2. Query (`SearchService.Query`)

Multi-token search with TF-IDF ranking:

**Scoring Formula**:
```
score = (tfidf × 0.6) + (field_weight × 0.25) − (distance × 0.15)
```

Where:
- **tfidf**: Inverse document frequency × term frequency (rare matches rank higher)
- **field_weight**: Importance of matched field
  - `product_name`: 1.0
  - `shop_name`: 1.0
  - `description`: 0.3
- **distance**: Levenshtein edit distance (0 = exact, 1+ = fuzzy)

**Multi-token AND logic**: All tokens must match. Intersection of doc_ids across tokens.

### 3. IndexServer (`SearchService.IndexServer`)

Central coordinator:

- **`:persistent_term`**: Immutable index storage for zero-copy reads across all cores
- **Query Result Cache**: ETS `:search_cache` table caches search/prefix results by query+limit; invalidated on index swaps
- **File Persistence**: Compressed snapshot (`priv/search_index.bin`)
- **Scheduled Snapshots**: Every 24 hours (configurable)
- **Batch Updates**: Queued changes applied on-demand with single finalization

**Data Flow**:
1. Search queries hit the ETS query cache first; cache misses read from `:persistent_term` (sub-10ms)
2. Index updates write a new term to `:persistent_term` and flush the query cache (single writer pattern)
3. Batch changes are applied raw, then finalized once before the persistent_term swap
4. Periodic snapshots save to file (~8MB for 150k documents)

### 4. BatchQueue

Incremental updates:

- **BatchQueue**: Accumulates insert/update/delete operations
- Changes applied via `POST /documents` or manual `apply_batch_changes()`
- Deduplicates: keeps only last operation per document ID

### 5. Persistence (`SearchService.Persistence`)

File-based persistence with integrity checks:

- **Save**: `:erlang.term_to_binary(index, compressed: 9)` → temp file → atomic rename
- **Load**: MD5 checksum validation → deserialization
- **Corruption Detection**: Auto-rebuilds if checksum fails

## HTTP API

### Document Ingestion

```bash
# Add/update documents (accepts array or single doc)
curl -X POST http://localhost:4000/api/documents \
  -H "Content-Type: application/json" \
  -d '{
    "documents": [
      {"id": "prod_1", "text": "iPhone 15 Pro", "field": "product_name", "weight": 1.0},
      {"id": "shop_1", "text": "Kilimani Electronics", "field": "shop_name", "weight": 1.0}
    ]
  }'

# Delete a document
curl -X DELETE http://localhost:4000/api/documents/prod_1

# Full rebuild (optional: provide documents in body)
curl -X POST http://localhost:4000/api/rebuild \
  -H "Content-Type: application/json" \
  -d '{"documents": [...]}'
```

### Search

```bash
# Fuzzy + TF-IDF search
curl "http://localhost:4000/api/search?q=iphone&limit=20"

# Prefix autocomplete
curl "http://localhost:4000/api/prefix?q=kilim&limit=5"
```

**Search Response**:
```json
{
  "query": "iphone",
  "count": 2,
  "results": [
    {
      "id": "prod_1",
      "score": 0.8234,
      "field": "product_name",
      "distance": 0,
      "tfidf": 1.234
    }
  ]
}
```

### Health & Metrics

```bash
# Health check
curl http://localhost:4000/api/health
# => {"ready": true, "document_count": 150101}

# Performance metrics
curl http://localhost:4000/api/metrics
```

**Metrics Response**:
```json
{
  "query_latency": {
    "p50_ms": 5.2,
    "p95_ms": 12.4,
    "p99_ms": 28.6,
    "min_ms": 1.8,
    "max_ms": 45.3,
    "count_1m": 342,
    "count_5m": 1240
  },
  "index": {
    "document_count": 150101,
    "memory_bytes": 33554432,
    "last_rebuild_at": "2026-05-28T09:32:53Z",
    "freshness_seconds": 1847,
    "build_duration_ms": 15420
  },
  "relevance": {
    "avg_results_per_query": 8.3,
    "zero_result_rate": 0.02,
    "total_queries": 5240
  }
}
```

## Getting Started

### Requirements

- Elixir 1.14+
- Erlang/OTP 24+

### Installation

```bash
mix deps.get
mix compile
```

### Running

```bash
# Development
mix phx.server

# Or explicitly
PORT=4000 mix run --no-halt

# Production
PORT=8080 SEARCH_API_KEY=secret mix run --no-halt
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `4000` | HTTP server port |
| `PERSIST_PATH` | `priv/search_index.bin` | Index snapshot file path |
| `SNAPSHOT_INTERVAL_MS` | `86400000` | Auto-save interval (24h) |
| `SEARCH_API_KEY` | `nil` | Optional API key for mutation endpoints |
| `SECRET_KEY_BASE` | (dev only) | Phoenix secret key |

## Configuration

Runtime configuration is loaded from environment variables via `config/runtime.exs`.

Example production config:
```bash
export PORT=8080
export PERSIST_PATH=/data/search_index.bin
export SNAPSHOT_INTERVAL_MS=3600000  # 1 hour
export SEARCH_API_KEY=your-secret-key-here
```

When `SEARCH_API_KEY` is set, these endpoints require the `X-API-Key` header:
- `POST /api/documents`
- `DELETE /api/documents/:id`
- `POST /api/rebuild`

Read endpoints (`/search`, `/prefix`, `/metrics`, `/health`) remain open.

## Performance Characteristics

| Metric | Target | Actual (150k docs) |
|--------|--------|-------------------|
| Query Latency (p50) | <50ms | ~3-5ms |
| Query Latency (p95) | <80ms | ~8-15ms |
| Query Latency (p99) | <100ms | ~20-30ms |
| Index Build Time | <30s | ~8-12s |
| Memory Usage | <100MB | ~30-40MB |
| Serialized Size | <20MB | ~8MB |
| Concurrent Queries | Unlimited | CPU-bound (zero-copy reads) |
| Bulk Ingest (1k docs) | <5s | ~2-3s |
| Cached Query Hit | <1ms | ~0.5ms |

## Scaling to 150k+ Documents

### What Changed

**Before**: Each `insert`/`remove` triggered O(N log N) `finalize_index()` (sort vocabulary + compute IDF + rebuild length_index). At 150k docs, a batch of 1,000 updates took minutes.

**After**:
1. **Raw inserts/removes** mark the index as `:dirty` — O(1) map operations
2. **Single finalize** after the batch — one O(V log V) sort where V = unique tokens
3. **Vocabulary as `:array`** — prefix search goes from O(N log N) to O(log V + K)
4. **Bounded Levenshtein** — aborts early when distance exceeds budget, saving 80-95% of matrix computations

### Memory Considerations

With 150k documents averaging 4-5 words each:
- **Postings**: ~500k-1M entries (token → doc_id mappings)
- **Vocabulary**: ~50k-200k unique tokens stored as `:array`
- **Total RAM**: ~30-60MB for the index map
- **`:persistent_term`**: Zero-copy reads — the same immutable term is referenced directly by every process
- **Query Cache**: Small ETS table holding recent search results (invalidated on writes)

### Ingestion Patterns

**Bulk Rebuild**: Use `POST /api/rebuild` for full re-indexing. Build time is ~8-12s for 150k docs.

**Trickle Updates**: Use `POST /api/documents` for incremental changes. The dirty-flag ensures:
- 1 insert = O(1) (no finalization)
- 1,000 inserts = O(1000) raw ops + 1 finalization
- Finalization happens eagerly on batch apply, never during search

### When to Scale Further

If you need **millions of documents** or **sub-10ms at 99th percentile**:
- **Sharding**: Partition by doc_id hash into N `IndexServer` processes (parallel search)
- **WAL + Lazy Snapshots**: Append-only write-ahead log instead of full snapshots
- **External Engine**: Consider Typesense, Meilisearch, or Elasticsearch

## Comparison: Search vs ILIKE

### ILIKE
```sql
SELECT * FROM products WHERE name ILIKE '%iphone%'
-- Pros: Simple, no extra infrastructure
-- Cons: No typo tolerance, slow on large tables, linear scan
```

### Inverted Index (SearchService)
```bash
curl "http://localhost:4000/api/search?q=ipone"
# Returns: ["iPhone 15"] (auto-corrected 1 typo)

curl "http://localhost:4000/api/search?q=iphone+15"
# Returns: docs with BOTH "iphone" AND "15" tokens
```
**Pros**: Typo tolerance, TF-IDF ranking, sub-50ms, prefix autocomplete, scales to 150k+ docs
**Cons**: Memory-only (persisted to disk), eventual consistency for updates

## Project Structure

```
lib/
├── search_service/
│   ├── application.ex          # OTP supervisor
│   ├── engine.ex               # Inverted index + fuzzy matching + :array vocab
│   ├── query.ex                # TF-IDF ranking
│   ├── index_server.ex         # GenServer + :persistent_term + query cache
│   ├── batch_queue.ex          # Async doc updates
│   ├── persistence.ex          # File snapshot
│   ├── metrics.ex              # Telemetry events
│   └── metrics_aggregator.ex   # Rolling statistics
└── search_service_web/
    ├── endpoint.ex
    ├── router.ex
    ├── error_json.ex
    ├── plugs/
    │   └── api_auth.ex         # Optional API key auth
    └── controllers/
        ├── document_controller.ex
        ├── search_controller.ex
        └── metrics_controller.ex
```

## Troubleshooting

### Issue: Search returns empty results
**Cause**: Index not built yet (first boot after deploy)
**Solution**:
```bash
curl -X POST http://localhost:4000/api/rebuild \
  -H "Content-Type: application/json" \
  -d '{"documents": [...]}'
```

### Issue: Search crashes on short queries
**Cause**: Stale index file from old version
**Solution**:
```bash
rm priv/search_index.bin
curl -X POST http://localhost:4000/api/rebuild \
  -H "Content-Type: application/json" \
  -d '{"documents": [...]}'
```

### Issue: High memory usage
**Cause**: Large document set loaded into memory
**Solution**: Monitor with metrics endpoint:
```bash
curl http://localhost:4000/api/metrics | jq '.index.memory_bytes'
```

### Issue: Slow queries (>100ms)
**Cause**: Very short prefixes (e.g., "a") matching thousands of tokens
**Solution**: Already mitigated — `Engine.search` caps results at `limit * 3`

### Issue: Slow bulk ingestion
**Cause**: Not using batch mode — each doc triggers a separate finalize
**Solution**: Use `POST /api/documents` with an array of documents. The engine applies all changes then finalizes once.

## See Also

- `SearchService.Engine` — Inverted index + fuzzy matching + :array vocabulary
- `SearchService.Query` — TF-IDF ranking
- `SearchService.IndexServer` — `:persistent_term` storage + query cache + persistence coordinator
- `SearchService.MetricsAggregator` — Performance metrics
- `SearchServiceWeb.Router` — HTTP routing
