"""
Data contract schemas for pipeline stages.

Each stage has defined input/output types enforced via dataclasses.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class IndexEntry:
    """Stage 1 output: a product in the product index."""
    slug: str
    url_type: str       # api | slug | collection | sku | catalog_api
    era: str            # early_shopify | late_shopify | adidas_api | adidas_spa
    wayback_url: str
    original_url: str
    timestamp: str
    content_type: str
    all_types: list[str] = field(default_factory=list)
    snapshot_count: int = 1


@dataclass
class ProductMetadata:
    """Stage 2 output: accumulated metadata for a product."""
    slug: str
    era: str
    url_type: str
    url: str
    date: str | None = None
    image_count: int = 0
    name: str | None = None
    price: str | None = None
    currency: str | None = None
    brand: str | None = None
    category: str | None = None
    sku: str | None = None
    description: str | None = None
    color: str | None = None
    gender: str | None = None
    sizes: str | None = None
    sport: str | None = None
    matched_sku: str | None = None  # added by Stage 3


@dataclass
class DownloadResult:
    """Stage 4 output: download report for a single product."""
    slug: str
    dir_path: str
    downloaded: int = 0
    failed: int = 0
    strategies_used: list[str] = field(default_factory=list)
    status: str = "empty"  # complete | partial | empty


@dataclass
class CatalogEntry:
    """Stage 6 output: final catalog entry."""
    slug: str
    name: str
    era: str | None = None
    url: str | None = None
    date: str | None = None
    price: float | None = None
    currency: str | None = None
    brand: str | None = None
    category: str | None = None
    sku: str | None = None
    color: str | None = None
    gender: str | None = None
    images: list[str] = field(default_factory=list)
    image_count: int = 0
