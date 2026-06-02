#!/usr/bin/env python3
"""
Export SmartKiosk products & shops into a JSON Lines file
suitable for bulk-ingesting into SearchService.

Each line is one search document:
    {"id": "...", "text": "...", "field": "...", "weight": 1.0}

Run:
    python3 priv/scripts/export_search_docs.py

Environment variables (all optional, defaults shown below):
    DB_HOST=localhost
    DB_NAME=smart_kiosk_dev
    DB_USER=ongera
    DB_PASSWORD=Winger2004!
    DB_PORT=5432
    OUTPUT_FILE=priv/search_documents.jsonl
"""

import json
import os
import sys

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    print("Error: psycopg2 is required. Install it with:")
    print("    pip3 install psycopg2-binary")
    sys.exit(1)

DB_CONFIG = {
    "host": os.getenv("DB_HOST", "localhost"),
    "database": os.getenv("DB_NAME", ""),
    "user": os.getenv("DB_USER", ""),
    "password": os.getenv("DB_PASSWORD", ""),
    "port": int(os.getenv("DB_PORT", "5432")),
}

OUTPUT_FILE = os.getenv("OUTPUT_FILE", "priv/search_documents.jsonl")


def main():
    conn = psycopg2.connect(**DB_CONFIG)
    conn.set_client_encoding("UTF8")

    total = 0
    written = 0

    with conn.cursor() as cur, open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        # --- Shops ---
        print("Fetching shops...")
        cur.execute("SELECT id, name FROM shops ORDER BY id")
        for row in cur:
            total += 1
            shop_id, shop_name = row
            if not shop_name:
                continue
            doc = {
                "id": str(shop_id),
                "text": shop_name.strip(),
                "field": "shop_name",
                "weight": 1.0,
            }
            f.write(json.dumps(doc, ensure_ascii=False) + "\n")
            written += 1
        print(f"  {written} shop documents")

        # --- Products ---
        print("Fetching products...")
        cur.execute(
            """
            SELECT id, name, description, shop_id
            FROM products
            WHERE status = 'active'
            ORDER BY id
            """
        )

        shop_doc_count = written
        product_docs = 0
        desc_docs = 0

        for row in cur:
            total += 1
            product_id, name, description, shop_id = row

            if name and name.strip():
                doc = {
                    "id": str(product_id),
                    "text": name.strip(),
                    "field": "product_name",
                    "weight": 1.0,
                }
                f.write(json.dumps(doc, ensure_ascii=False) + "\n")
                product_docs += 1

            if description and description.strip():
                doc = {
                    "id": f"{product_id}_desc",
                    "text": description.strip(),
                    "field": "description",
                    "weight": 0.3,
                }
                f.write(json.dumps(doc, ensure_ascii=False) + "\n")
                desc_docs += 1

        print(f"  {product_docs} product name documents")
        print(f"  {desc_docs} product description documents")
        written += product_docs + desc_docs

    conn.close()
    print(f"\nDone. Exported {written} documents to {OUTPUT_FILE}")
    print(f"Total rows scanned: {total}")


if __name__ == "__main__":
    main()
