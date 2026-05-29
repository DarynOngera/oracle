# SearchService API Reference

Base URL: `http://localhost:4000/api`

## Authentication

If `SEARCH_API_KEY` is set, mutation endpoints require the header:

```
X-API-Key: your-secret-key
```

Read endpoints (`/search`, `/prefix`, `/health`, `/metrics`) remain open.

---

## Endpoints

### POST /documents

Add or update documents. Accepts a single document or an array under `documents`.

**Request:**
```bash
curl -X POST http://localhost:4000/api/documents \
  -H "Content-Type: application/json" \
  -d '{
    "documents": [
      {"id": "prod_1", "text": "iPhone 15 Pro", "field": "product_name", "weight": 1.0},
      {"id": "shop_1", "text": "Kilimani Electronics", "field": "shop_name", "weight": 1.0}
    ]
  }'
```

**Response (202):**
```json
{"status": "queued", "count": 2}
```

**Fields:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique document identifier |
| `text` | string | Yes | Content to index |
| `field` | string | No | One of: `product_name`, `shop_name`, `name`, `description`. Default: `name` |
| `weight` | float | No | Boost factor. Default: `1.0` |

---

### DELETE /documents/:id

Remove a document from the index.

**Request:**
```bash
curl -X DELETE http://localhost:4000/api/documents/prod_1
```

**Response (200):**
```json
{"status": "deleted", "id": "prod_1"}
```

---

### POST /rebuild

Replace the entire index. Provide all documents in the body.

**Request:**
```bash
curl -X POST http://localhost:4000/api/rebuild \
  -H "Content-Type: application/json" \
  -d '{
    "documents": [
      {"id": "prod_1", "text": "iPhone 15 Pro", "field": "product_name", "weight": 1.0}
    ]
  }'
```

**Response (200):**
```json
{"status": "rebuilt", "document_count": 1}
```

---

### GET /search

Full-text search with fuzzy matching and TF-IDF ranking.

**Request:**
```bash
curl "http://localhost:4000/api/search?q=iphone&limit=20"
```

**Query Parameters:**
| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `q` | string | — | Search query |
| `limit` | integer | 50 | Max results to return |

**Response (200):**
```json
{
  "query": "iphone",
  "count": 1,
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

**Result Fields:**
| Field | Description |
|-------|-------------|
| `score` | Combined TF-IDF + field weight - distance penalty |
| `distance` | Levenshtein edit distance (0 = exact match) |
| `tfidf` | Term frequency-inverse document frequency score |
| `field` | Which field matched |

---

### GET /prefix

Prefix autocomplete. Returns documents where tokens start with the query.

**Request:**
```bash
curl "http://localhost:4000/api/prefix?q=kili&limit=5"
```

**Response (200):**
```json
{
  "query": "kili",
  "count": 1,
  "results": [
    {
      "id": "shop_1",
      "score": 0.25,
      "field": "shop_name"
    }
  ]
}
```

---

### GET /health

Check service readiness and document count.

**Request:**
```bash
curl http://localhost:4000/api/health
```

**Response (200):**
```json
{"ready": true, "document_count": 150101}
```

---

### GET /metrics

Performance and index statistics.

**Request:**
```bash
curl http://localhost:4000/api/metrics
```

**Response (200):**
```json
{
  "query_latency": {
    "p50_ms": 5.2,
    "p95_ms": 12.4,
    "p99_ms": 28.6,
    "count_1m": 342
  },
  "index": {
    "document_count": 150101,
    "memory_bytes": 33554432,
    "last_rebuild_at": "2026-05-28T09:32:53Z"
  },
  "relevance": {
    "avg_results_per_query": 8.3,
    "zero_result_rate": 0.02
  }
}
```

---

## Error Responses

| Status | Body | Cause |
|--------|------|-------|
| 400 | `{"error": "Missing documents or document field"}` | Empty or malformed POST /documents body |
| 404 | `{"error": "Not found"}` | Unknown route or missing resource |
| 500 | Internal server error | Unexpected crash (check logs) |

---

## Testing Workflow

### 1. Ingest documents
```bash
curl -X POST http://localhost:4000/api/documents \
  -H "Content-Type: application/json" \
  -d '{
    "documents": [
      {"id": "prod_1", "text": "iPhone 15 Pro", "field": "product_name", "weight": 1.0},
      {"id": "shop_1", "text": "Kilimani Electronics", "field": "shop_name", "weight": 1.0},
      {"id": "prod_2", "text": "Samsung Galaxy S24", "field": "product_name", "weight": 1.0}
    ]
  }'
```

### 2. Search exact match
```bash
curl "http://localhost:4000/api/search?q=iphone&limit=10"
```

### 3. Search with typo (fuzzy)
```bash
curl "http://localhost:4000/api/search?q=iphoen&limit=10"
```

### 4. Prefix autocomplete
```bash
curl "http://localhost:4000/api/prefix?q=gal&limit=5"
```

### 5. Full rebuild (optional)
```bash
curl -X POST http://localhost:4000/api/rebuild \
  -H "Content-Type: application/json" \
  -d '{
    "documents": [
      {"id": "prod_1", "text": "iPhone 15 Pro", "field": "product_name", "weight": 1.0}
    ]
  }'
```

---

## Notes for Testers

- **First boot**: If `priv/search_index.bin` does not exist, the index starts empty. Ingest documents or call `/rebuild` before searching.
- **Eventual consistency**: `POST /documents` returns 202 immediately. The index is updated synchronously, but the response confirms queuing, not search availability.
- **Bulk ingestion**: Pass documents as an array in a single request. The engine finalizes the index once after the batch, which is much faster than one doc per request.
- **Fuzzy rules**: 0 typos for queries < 4 chars, 1 typo for 4-8 chars, 2 typos for > 8 chars.
- **Multi-token queries**: `q=iphone+15` requires both tokens to match (AND logic).
