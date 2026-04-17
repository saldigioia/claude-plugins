# Data Contracts

JSON schemas for pipeline stage inputs and outputs.

## Stage 1 Output: Product Index

`{name}_products_index.json`

```json
{
  "<slug>": {
    "slug": "string",
    "url_type": "api | slug | collection | sku | atom | oembed",
    "era": "early_shopify | late_shopify | adidas_api | adidas_spa | swell | fourthwall",
    "wayback_url": "string (full web.archive.org URL)",
    "original_url": "string (canonical https URL)",
    "timestamp": "string (14-digit YYYYMMDDHHMMSS)",
    "content_type": "string",
    "all_types": ["string"],
    "snapshot_count": "int >= 1"
  }
}
```

## Stage 2 Output: Product Metadata

`{name}_metadata.json`

```json
{
  "<slug>": {
    "slug": "string (required)",
    "era": "string (required)",
    "url_type": "string (required)",
    "url": "string (required)",
    "date": "string | null (YYYY-MM-DD)",
    "first_seen": "string | null (YYYYMMDD — earliest Wayback timestamp)",
    "image_count": "int >= 0 (required)",
    "name": "string | null",
    "title": "string | null",
    "price": "string | null (numeric string)",
    "currency": "string | null (ISO 4217)",
    "brand": "string | null",
    "vendor": "string | null",
    "category": "string | null",
    "type_code": "string | null",
    "sku": "string | null",
    "description": "string | null",
    "color": "string | null",
    "gender": "string | null",
    "sizes": "string | null (comma-separated)",
    "tags": ["string"] ,
    "variants": [
      {
        "title": "string",
        "sku": "string | null",
        "price": "string | null"
      }
    ],
    "matched_sku": "string | null (added by Stage 3)",
    "source": "string | null (products.json | atom | oembed | playwright | har)"
  }
}
```

## Stage 2 Output (sidecar): Image Links

`links/{slug}.txt` — one URL per line, sorted, deduplicated.

## Stage 4 Output: Download Report

Per-product download results tracked in checkpoint file.

## Stage 5: Gap Analysis Output

`{name}_gap_analysis.json`

```json
{
  "total_products": "int",
  "products_with_images": "int",
  "products_missing_images": "int",
  "apparent_missing": "int (before dedup)",
  "noise_removed": {
    "cross_source_duplicates": "int",
    "colorways_covered": "int",
    "draft_test_entries": "int",
    "alias_handles": "int"
  },
  "true_missing": "int (after dedup)",
  "retry_targets": ["string (slugs with CDX captures)"],
  "unrecoverable": ["string (slugs with no CDX captures)"],
  "har_recovery_candidates": ["string (high-value targets for manual browsing)"]
}
```

## Stage 7 Output: Product Catalog

`catalog/catalog.json`

```json
[
  {
    "id": "string | null",
    "slug": "string",
    "handle": "string",
    "title": "string",
    "name": "string",
    "season": "string | null",
    "era": "string | null",
    "url": "string | null",
    "date": "string | null",
    "first_seen": "string | null",
    "price": "number | null",
    "currency": "string | null",
    "brand": "string | null",
    "vendor": "string | null",
    "category": "string | null",
    "type_code": "string | null",
    "sku": "string | null",
    "color": "string | null",
    "gender": "string | null",
    "description": "string | null",
    "tags": ["string"],
    "variants": [
      {
        "title": "string",
        "sku": "string | null",
        "price": "string | null"
      }
    ],
    "images": [
      {
        "filename": "string",
        "size_bytes": "int",
        "is_front": "boolean"
      }
    ],
    "image_count": "int",
    "source": "string | null"
  }
]
```

## Stage 7 Output: Products CSV

`catalog/products.csv` — one row per product.

Columns: id, slug, title, season, era, price, currency, brand, vendor,
category, type_code, sku, color, gender, image_count, source, first_seen,
tags (semicolon-separated).

## Stage 7 Output: Images CSV

`catalog/images.csv` — one row per image file.

Columns: slug, filename, size_bytes, is_front, image_format.

## Checkpoint Files

`.checkpoint_{stage}.json`

```json
{
  "stage": "string",
  "completed": ["string (sorted slugs)"],
  "exhausted": ["string (sorted slugs)"]
}
```
