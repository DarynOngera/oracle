# SearchService

A high-performance, standalone Elixir search microservice using an **inverted index** with TF-IDF ranking and fuzzy matching.

## Overview

SearchService replaces traditional SQL `ILIKE` pattern matching with an in-memory inverted index combined with Levenshtein distance for typo tolerance and TF-IDF for relevance ranking. It provides sub-10ms query response times for 150k+ documents.

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
                           ┌─────────────────┐
                           │   ETS Table     │───▶ Fast concurrent reads
                           │  (In-Memory)    │
                           └─────────────────┘
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

- **ETS Table**: Concurrent read access for HTTP requests
- **File Persistence**: Compressed snapshot (`priv/search_index.bin`)
- **Scheduled Snapshots**: Every 24 hours (configurable)
- **Batch Updates**: Queued changes applied on-demand

**Data Flow**:
1. Search queries read from ETS (sub-10ms)
2. Index updates write to ETS (single writer pattern)
3. Periodic snapshots save to file (~8MB for 150k documents)

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
| Query Latency (p50) | <10ms | ~3-5ms |
| Query Latency (p95) | <50ms | ~8-15ms |
| Query Latency (p99) | <100ms | ~20-30ms |
| Index Build Time | <30s | ~12-18s |
| Memory Usage | <100MB | ~30-40MB |
| Serialized Size | <20MB | ~8MB |
| Concurrent Queries | Unlimited | Limited by ETS |

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
**Pros**: Typo tolerance, TF-IDF ranking, sub-10ms, prefix autocomplete
**Cons**: Memory-only (persisted to disk), eventual consistency for updates

## Project Structure

```
lib/
├── search_service/
│   ├── application.ex          # OTP supervisor
│   ├── engine.ex               # Inverted index + fuzzy matching
│   ├── query.ex                # TF-IDF ranking
│   ├── index_server.ex         # GenServer + ETS coordinator
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

## See Also

- `SearchService.Engine` — Inverted index + fuzzy matching
- `SearchService.Query` — TF-IDF ranking
- `SearchService.IndexServer` — ETS + persistence coordinator
- `SearchService.MetricsAggregator` — Performance metrics
- `SearchServiceWeb.Router` — HTTP routing
