# SmartKiosk Search Engine

A high-performance, native Elixir search engine for product and shop discovery using an **inverted index** with TF-IDF ranking and fuzzy matching.

## Overview

This search engine replaces traditional SQL `ILIKE` pattern matching with an in-memory inverted index combined with Levenshtein distance for typo tolerance and TF-IDF for relevance ranking. It provides sub-10ms query response times for 150k+ products.

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   Web Request   │────▶│   IndexServer    │────▶│   ETS Table     │
│   (HomeLive)    │     │   (GenServer)    │     │  (In-Memory)    │
└─────────────────┘     └──────────────────┘     └─────────────────┘
                               │                           │
                               ▼                           ▼
                        ┌──────────────┐           ┌──────────────┐
                        │    Query     │           │   Inverted   │
                        │  (TF-IDF     │           │    Index     │
                        │   Ranking)   │           │              │
                        └──────────────┘           └──────────────┘
                               │                           │
                               ▼                           ▼
                        ┌──────────────┐           ┌──────────────┐
                        │  Persistence │◀─────────▶│     File     │
                        │  (Snapshot)  │           │  (Disk File) │
                        └──────────────┘           └──────────────┘
```

## Core Components

### 1. Engine (`engine.ex`)

The inverted index implementation:

- **Postings**: `token → [{doc_id, field, weight}]`
- **Vocabulary**: Sorted list of all unique tokens
- **IDF**: Pre-computed inverse document frequency per token
- **Length Index**: `token_length → [tokens]` for fast fuzzy filtering
- **Doc Metadata**: Token count, name, shop_name per document

**Typo Budget Rules**:
- `< 4 characters`: 0 typos (exact match + prefix)
- `4-8 characters`: 1 typo allowed
- `> 8 characters`: 2 typos allowed

**Search Strategy**:
1. **Prefix matches first**: Exact prefix hits get distance = 0
2. **Fuzzy matches second**: Levenshtein within typo budget (distance ≥ 1)
3. **Result merging**: Keep lowest distance per doc_id

**Example**:
```elixir
# "kili" matches "kilimani", "kilimanjaro" via prefix
# "iphoen" matches "iphone" via fuzzy (1 typo)
```

### 2. Query (`query.ex`)

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

### 3. IndexServer (`index_server.ex`)

Central coordinator:

- **ETS Table**: Concurrent read access for web requests
- **File Persistence**: Compressed snapshot (`priv/search_index.bin`)
- **Automatic Rebuild**: Triggers rebuild on startup if stale/missing
- **Scheduled Snapshots**: Every 24 hours (configurable)

**Data Flow**:
1. Search queries read from ETS (sub-10ms)
2. Index updates write to ETS (single writer pattern)
3. Periodic snapshots save to file (~8MB for 150k products)

### 4. BatchQueue + BatchWorker

Incremental updates:

- **BatchQueue**: Accumulates insert/update/delete operations
- **SearchIndexBatchWorker** (Oban, every minute): Applies queued changes to index
- Changes trigger `Engine.finalize_index/1` to rebuild vocabulary + IDF

### 5. Persistence (`persistence.ex`)

File-based persistence with integrity checks:

- **Save**: `:erlang.term_to_binary(index, compressed: 9)` → temp file → atomic rename
- **Load**: MD5 checksum validation → deserialization
- **Corruption Detection**: Auto-rebuilds if checksum fails

## Data Flow

### Indexing Flow

```
Product/Shop Created/Updated
         │
         ▼
┌─────────────────┐
│   enqueue/1     │───▶ Adds to BatchQueue
└─────────────────┘
         │
         ▼ (every minute)
┌─────────────────┐
│  BatchWorker    │───▶ Processes all queued changes
└─────────────────┘
         │
         ▼
┌─────────────────┐
│  Update ETS     │───▶ Index updated atomically
└─────────────────┘
         │
         ▼ (every 24h)
┌─────────────────┐
│  File Snapshot  │───▶ Persist to disk (~8MB)
└─────────────────┘
```

### Search Flow

```
User Types Query
         │
         ▼
┌─────────────────┐
│  Tokenize Query │───▶ "iPhone 15" → ["iphone", "15"]
└─────────────────┘
         │
         ▼
┌─────────────────┐
│  Lookup in ETS  │───▶ Get current index
└─────────────────┘
         │
         ▼
┌─────────────────┐
│ Prefix + Fuzzy  │───▶ Prefix matches (dist=0) + fuzzy (dist≥1)
└─────────────────┘
         │
         ▼
┌─────────────────┐
│  Calculate Rank │───▶ TF-IDF score + field weight − distance penalty
└─────────────────┘
         │
         ▼
┌─────────────────┐
│ Hydrate Results │───▶ Load full structs from DB
└─────────────────┘
         │
         ▼
┌─────────────────┐
│  Render in UI   │───▶ Display product/shop cards
└─────────────────┘
```

## Usage

### Public API

```elixir
# Search for products and shops (fuzzy + TF-IDF)
SmartKioskCore.Search.query_products("iphone")
# => [%{id: "...", name: "iPhone 15", type: :product, ...}, ...]

# Prefix search for autocomplete
SmartKioskCore.Search.prefix_search("iph")
# => [%{name: "iPhone 15", type: :product}, ...]

# Check index status
SmartKioskCore.Search.ready?()
# => true

SmartKioskCore.Search.document_count()
# => 150101

# Manual rebuild
SmartKioskCore.Search.rebuild()
# => :ok

# Diagnostics
SmartKioskCore.Search.diagnose()
# => %{ready: true, document_count: 150101, ...}
```

### Metrics API

```bash
# Public endpoint — no authentication
curl http://localhost:4000/api/search/metrics
```

**Response**:
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

### Mix Tasks

```bash
# Rebuild search index (only if empty/stale)
mix search.rebuild

# Force rebuild even if index exists
mix search.rebuild --force
```

## Configuration

```elixir
# config/config.exs
config :smart_kiosk_core, Oban,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # Batch process changes every minute
       {"*/1 * * * *", SmartKioskCore.Workers.SearchIndexBatchWorker},
       # Daily full rebuild at 2 AM
       {"0 2 * * *", SmartKioskCore.Workers.SearchRebuildWorker}
     ]}
  ],
  queues: [default: 10, mailer: 5, search_index: 5]
```

## Performance Characteristics

| Metric | Target | Actual (150k docs) |
|--------|--------|-------------------|
| Query Latency (p50) | <10ms | ~3-5ms |
| Query Latency (p95) | <50ms | ~8-15ms |
| Query Latency (p99) | <100ms | ~20-30ms |
| Index Build Time | <30s | ~12-18s |
| Memory Usage | <100MB | ~30-40MB |
| Serialized Size | <20MB | ~8MB |
| Concurrent Queries | Unlimited | Limited by ETS |

## Comparison: Search vs ILIKE

### ILIKE (Old)
```sql
SELECT * FROM products WHERE name ILIKE '%iphone%'
-- Pros: Simple, no extra infrastructure
-- Cons: No typo tolerance, slow on large tables, linear scan
```

### Inverted Index (New)
```elixir
SmartKioskCore.Search.query_products("ipone")
# Returns: ["iPhone 15"] (auto-corrected 1 typo)
SmartKioskCore.Search.query_products("iphone 15")
# Returns: docs with BOTH "iphone" AND "15" tokens
-- Pros: Typo tolerance, TF-IDF ranking, sub-10ms, prefix autocomplete
-- Cons: Memory-only (rebuilds from DB on boot), eventual consistency (~1 min)
```

## Troubleshooting

### Issue: Search returns empty results
**Cause**: Index not built yet (first boot after deploy)
**Solution**:
```bash
mix search.rebuild --force
```

### Issue: Search crashes on short queries
**Cause**: Stale index file from old Trie version
**Solution**:
```bash
rm apps/smart_kiosk_core/priv/search_index.bin
mix search.rebuild --force
```

### Issue: High memory usage
**Cause**: Large document set loaded into memory
**Solution**: Monitor with metrics endpoint:
```bash
curl http://localhost:4000/api/search/metrics | jq '.index.memory_bytes'
```

### Issue: Slow queries (>100ms)
**Cause**: Very short prefixes (e.g., "a") matching thousands of tokens
**Solution**: Already mitigated — `Engine.search` caps results at `limit * 3`

## Testing

```elixir
# Unit tests
 test "search handles typos" do
   results = Search.query_products("iphne")
   assert length(results) > 0
 end

 test "prefix search returns results" do
   results = Search.prefix_search("kilim", limit: 5)
   assert length(results) > 0
 end

# Load test
 test "concurrent searches" do
   1..1000
   |> Task.async_stream(fn _ -> 
     Search.query_products("test")
   end, max_concurrency: 100)
   |> Enum.to_list()
 end
```

## See Also

- `SmartKioskCore.Search` — Public API
- `SmartKioskCore.Search.Engine` — Inverted index + fuzzy matching
- `SmartKioskCore.Search.Query` — TF-IDF ranking
- `SmartKioskCore.Search.MetricsAggregator` — Performance metrics
- `SmartKioskWeb.Api.SearchMetricsController` — HTTP metrics endpoint
- `SmartKioskCore.Workers.SearchRebuildWorker` — Index builder
- `SmartKioskWeb.Components.SearchBar` — UI component
