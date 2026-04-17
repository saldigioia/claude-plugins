"""
surface_parser.py — extract entity references from Protocol II surfaces.

A discovery surface is a gateway to many products: atom feeds, sitemap
XML, collection landing HTML, homepage HTML, products.json. Parsing a
surface yields entity references (product URLs) that get upserted into
the ledger's `entities` table with `first_seen_in` pointing back to the
surface URL.

Used by run_stage.py's run_fetch Phase B: when
`_is_discovery_surface_filename(path)` is true, the body is routed here
instead of to metadata extraction — preventing the feed-becomes-product
bug.

Minimal by design: each parser targets the one pattern its surface class
produces reliably (atom `<link href>`, sitemap `<loc>`, HTML `<a href>`
matching `/products/<slug>`). Anything else falls through as zero
outlinks — safer than faking data.
"""
from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Iterable
from urllib.parse import urlparse
from xml.etree import ElementTree as ET

from .ledger import (
    connect as ledger_connect,
    exists as ledger_exists,
    mark_surface_parsed,
    upsert_entity,
    upsert_host,
    upsert_surface,
)

log = logging.getLogger(__name__)


# ── Surface class detection (mirrors run_stage._is_discovery_surface_filename) ─

def classify_filename(filename: str) -> str:
    """Return surface class: atom | sitemap | json_api | collection | home | unknown."""
    name = filename[:-5] if filename.endswith(".html") else filename
    lower = name.lower()
    # Sitemap first — Shopify's `sitemap_products_N.xml` contains `_products_`.
    if re.search(r"_sitemap[_.-].*\.xml$|_sitemap\.xml$", lower):
        return "sitemap"
    # Per-product atoms/oembeds live at /products/<slug>.atom — those are
    # entity-scoped and shouldn't be treated as gateway surfaces here.
    if "_products_" in lower:
        return "unknown"
    if lower.endswith(".atom"):
        return "atom"
    if lower.endswith(".oembed"):
        return "oembed"
    if lower.endswith("_products.json"):
        return "json_api"
    if re.search(r"_collections?_[^_]+$", lower):
        return "collection"
    # Bare hostname + nothing = homepage
    if "_" not in name.split("/")[-1]:
        return "home"
    return "unknown"


# ── Parsers (each returns an iterable of (product_url, host) tuples) ────────

_PRODUCT_PATH_RE = re.compile(r"/products/([a-z0-9][a-z0-9-_.%]*)", re.IGNORECASE)
_ATOM_LINK_RE = re.compile(rb'<link[^>]*\bhref=["\']([^"\']+)["\']', re.IGNORECASE)
_SITEMAP_LOC_RE = re.compile(rb"<loc>([^<]+)</loc>", re.IGNORECASE)


def _normalize_product_ref(raw_url: str) -> tuple[str, str, str] | None:
    """Strip Wayback wrappers, extract (canonical_url, host, slug) if this is a
    /products/<slug> URL, else None.
    """
    # Strip web.archive.org wrapper if present
    raw = re.sub(r"^https?://web\.archive\.org/web/\d+(?:id_|im_|if_)?/", "", raw_url)
    try:
        parts = urlparse(raw)
    except ValueError:
        return None
    if not parts.hostname:
        return None
    m = _PRODUCT_PATH_RE.search(parts.path or "")
    if not m:
        return None
    slug = m.group(1).lower()
    # Strip .atom/.oembed/.json extensions from the slug
    for ext in (".atom", ".oembed", ".json"):
        if slug.endswith(ext):
            slug = slug[: -len(ext)]
    host = parts.hostname.lower().rstrip(".")
    canonical = f"{parts.scheme or 'https'}://{host}{parts.path or ''}"
    return canonical, host, slug


def _iter_atom_refs(body: bytes) -> Iterable[str]:
    """Yield raw href strings from <link> and <entry>/<id> tags."""
    # Prefer proper XML parse if possible — it's exact.
    try:
        root = ET.fromstring(body.decode("utf-8", errors="replace"))
    except ET.ParseError:
        root = None
    if root is not None:
        ns = {
            "atom": "http://www.w3.org/2005/Atom",
            "ns1": "http://purl.org/atom/ns#",   # rarely, old Atom 0.3
        }
        for link in root.iter():
            tag = link.tag.split("}", 1)[-1]  # strip namespace
            if tag == "link" and link.get("href"):
                yield link.get("href")
            elif tag == "id" and link.text:
                yield link.text.strip()
        return
    # Regex fallback for malformed feeds (Wayback replay sometimes mangles them).
    for m in _ATOM_LINK_RE.finditer(body):
        yield m.group(1).decode("utf-8", errors="replace")


def _iter_sitemap_refs(body: bytes) -> Iterable[str]:
    for m in _SITEMAP_LOC_RE.finditer(body):
        yield m.group(1).decode("utf-8", errors="replace").strip()


def _iter_html_product_refs(body: bytes) -> Iterable[str]:
    # Fast path: every <a href="..."> whose path contains /products/<slug>.
    # Regex is deliberately loose (accepts relative URLs too).
    text = body.decode("utf-8", errors="replace")
    for m in re.finditer(r'href=["\']([^"\']+)["\']', text, re.IGNORECASE):
        href = m.group(1)
        if "/products/" in href.lower():
            yield href


# ── Top-level parser ────────────────────────────────────────────────────────

def extract_outlinks(surface_class: str, body: bytes) -> list[tuple[str, str, str]]:
    """Parse a surface body, return list of (canonical_url, host, slug).

    Deduped per surface call. Any relative URLs that don't have a host after
    normalization are dropped — the ledger needs a host to key the entity.
    """
    if surface_class == "atom" or surface_class == "oembed":
        raw_refs = list(_iter_atom_refs(body))
    elif surface_class == "sitemap":
        raw_refs = list(_iter_sitemap_refs(body))
    elif surface_class in ("collection", "home"):
        raw_refs = list(_iter_html_product_refs(body))
    elif surface_class == "json_api":
        # /products.json — structured, not handled here. Return nothing for
        # now; full products.json parsing is a Phase 3b3 concern
        # (each JSON entry has full product data, not just outlinks).
        return []
    else:
        return []

    seen: set[tuple[str, str]] = set()
    out: list[tuple[str, str, str]] = []
    for raw in raw_refs:
        norm = _normalize_product_ref(raw)
        if norm is None:
            continue
        canonical, host, slug = norm
        key = (host, slug)
        if key in seen:
            continue
        seen.add(key)
        out.append(norm)
    return out


def parse_surface_file(path: Path, config) -> int:
    """Read a surface body from disk, extract outlinks, upsert each as a
    ledger entity whose first_seen_in points back at the surface.

    Returns the number of new-or-confirmed entity references written.
    Silent on ledger-write failure; safe to call without a ledger present
    (returns 0).
    """
    surface_class = classify_filename(path.name)
    if surface_class == "unknown":
        return 0

    try:
        body = path.read_bytes()
    except OSError:
        return 0

    refs = extract_outlinks(surface_class, body)

    if not ledger_exists(config.project_path):
        return len(refs)

    surface_url = _filename_to_url(path.name)
    # Try to recover the host from the URL we reconstructed — falls back to
    # the first outlink's host if the reverse-derive didn't produce one.
    surface_host = ""
    if "://" in surface_url:
        try:
            surface_host = (urlparse(surface_url).hostname or "").lower().rstrip(".")
        except ValueError:
            surface_host = ""
    if not surface_host and refs:
        surface_host = refs[0][1]

    try:
        with ledger_connect(config.project_path) as conn:
            # Protocol III baseline: every host we saw in an outlink becomes
            # a tracked host. Full auto-recursion (auto-enqueue CDX dump for
            # never-before-seen hosts) lands in Phase 3b3.
            new_hosts = {host for _, host, _ in refs}
            for h in new_hosts:
                upsert_host(conn, h)
            for canonical, host, slug in refs:
                upsert_entity(
                    conn, slug, host,
                    canonical_url=canonical,
                    first_seen_in=surface_url,
                )
            # Stamp the surface as parsed with the real outlink count —
            # replaces the outlink_count=0 placeholder Phase A.1 used to set.
            if surface_host:
                # Upsert so surfaces that weren't pre-registered by Phase A.1
                # (e.g. import_cache-supplied files) still land.
                upsert_surface(conn, surface_url, surface_host, surface_class)
            status = "ok" if refs else "empty"
            mark_surface_parsed(
                conn, surface_url,
                outlink_count=len(refs),
                parse_status=status,
            )
    except Exception as e:  # noqa: BLE001
        log.debug("surface ledger-write failed for %s: %s", path.name, e)
    return len(refs)


def _filename_to_url(filename: str) -> str:
    """Best-effort filename → URL reverse for the `first_seen_in` stamp.
    Used for audit exemplar readability, not correctness-critical.
    """
    name = filename[:-5] if filename.endswith(".html") else filename
    # Heuristic: first underscore separates host from path (pre-Phase-4.3
    # shape); fallback is just the raw filename string.
    parts = name.split("_", 1)
    if len(parts) == 2 and "." in parts[0]:
        host, path = parts
        return f"https://{host}/{path.replace('_', '/')}"
    return name


__all__ = [
    "classify_filename",
    "extract_outlinks",
    "parse_surface_file",
]
