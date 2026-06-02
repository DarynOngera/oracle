#!/usr/bin/env python3
"""
Ingest a JSON Lines file of search documents into SearchService.

Reads the export file in configurable chunks and POSTs them
to POST /api/documents.

Run:
    python3 priv/scripts/ingest_docs.py

Environment variables:
    INPUT_FILE=priv/search_documents.jsonl
    API_URL=http://localhost:4000/api/documents
    BATCH_SIZE=1000
"""

import json
import os
import sys
import time

try:
    import requests
except ImportError:
    print("Error: requests is required. Install it with:")
    print("    pip3 install requests")
    sys.exit(1)

INPUT_FILE = os.getenv("INPUT_FILE", "priv/search_documents.jsonl")
API_URL = os.getenv("API_URL", "http://localhost:4000/api/documents")
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "500"))


def post_batch(docs):
    payload = {"documents": docs}
    resp = requests.post(API_URL, json=payload, timeout=30)
    resp.raise_for_status()
    return resp.json()


def main():
    if not os.path.exists(INPUT_FILE):
        print(f"Error: {INPUT_FILE} not found. Run export_search_docs.py first.")
        sys.exit(1)

    batch = []
    total_sent = 0
    total_queued = 0
    line_num = 0

    print(f"Ingesting from {INPUT_FILE} to {API_URL} in batches of {BATCH_SIZE}...")

    with open(INPUT_FILE, "r", encoding="utf-8") as f:
        for line in f:
            line_num += 1
            line = line.strip()
            if not line:
                continue
            try:
                doc = json.loads(line)
            except json.JSONDecodeError as e:
                print(f"  Warning: skipping malformed line {line_num}: {e}")
                continue

            batch.append(doc)

            if len(batch) >= BATCH_SIZE:
                result = post_batch(batch)
                total_sent += len(batch)
                total_queued += result.get("count", 0)
                print(f"  Sent {total_sent} docs...")
                batch = []
                time.sleep(0.05)  # small back-off to avoid overwhelming

        if batch:
            result = post_batch(batch)
            total_sent += len(batch)
            total_queued += result.get("count", 0)
            print(f"  Sent {total_sent} docs...")

    print(f"\nDone. Ingested {total_sent} documents (queued {total_queued}).")


if __name__ == "__main__":
    main()
