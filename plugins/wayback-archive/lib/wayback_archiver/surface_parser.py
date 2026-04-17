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

Surface classes and their parsers:
  atom / oembed  → XML <link href> + regex fallback, outlinks only
  sitemap        → <loc> tags, outlinks only
  collection     → <a href> with /products/<slug>, outlinks only
  home           → same as collection
  json_api       → Shopify /products.json structured parse; yields
                   outlinks AND writes image URLs into
                   <links_dir>/<slug>.txt for the download stage

Protocol III: new hosts discovered in outlinks (not already in the
ledger's hosts table) are logged at WARNING and appended to
<project>/.new_hosts.txt — a sidecar the user (or the `resume`
subcommand) can consume to enqueue CDX dumps for them on the next
pipeline invocation.
"""
from __future__ import annotations

import json
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
    """Yield product href strings from <entry>/<link rel="alternate" type="text/html">.

    Shopify atoms put the human-readable handle URL in <link rel="alternate"
    type="text/html"> and a machine-ID URL (e.g. /products/8402798929) in
    <id>. Both point to the same product, but /products/<id> and
    /products/<handle> would register as distinct entities in the ledger.
    Extract ONLY the handle form to avoid phantom-twin entries.

    Feed-level <link> tags (not inside <entry>) point to the collection
    landing page or the feed's self-URL — filtered out because they don't
    match the /products/<slug> path pattern downstream, but also skipped
    here for clarity.
    """
    try:
        root = ET.fromstring(body.decode("utf-8", errors="replace"))
    except ET.ParseError:
        root = None
    if root is not None:
        for entry in root.iter():
            if entry.tag.split("}", 1)[-1] != "entry":
                continue
            # Scan direct children only — don't recurse into nested elements.
            for child in entry:
                if child.tag.split("}", 1)[-1] != "link":
                    continue
                href = child.get("href")
                if not href:
                    continue
                rel = child.get("rel", "")
                ctype = child.get("type", "")
                # rel="self" / rel="enclosure" / rel="edit" / rel="related"
                # aren't canonical product URLs; keep only rel="alternate"
                # (the default when rel is absent) pointing at HTML.
                if rel and rel != "alternate":
                    continue
                if ctype and "html" not in ctype.lower():
                    continue
                yield href
        return
    # Regex fallback for malformed feeds (Wayback replay sometimes mangles XML).
    # We can't distinguish <entry> scope vs feed scope here — the downstream
    # /products/<slug> path filter catches non-product hrefs.
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


def parse_products_json(body: bytes, host_hint: str = "") -> tuple[list[tuple[str, str, str]], dict[str, list[str]]]:
    """Parse a Shopify /products.json body.

    Returns (refs, images_by_slug) where:
      refs          = [(canonical_url, host, slug), ...]
      images_by_slug = {slug: [image_url, ...]}

    The host is taken from each product's canonical if present, else falls
    back to `host_hint` (derived by the caller from the surface URL).
    """
    refs: list[tuple[str, str, str]] = []
    images: dict[str, list[str]] = {}
    try:
        data = json.loads(body.decode("utf-8", errors="replace"))
    except json.JSONDecodeError:
        return refs, images

    products = data.get("products", []) if isinstance(data, dict) else []
    if not isinstance(products, list):
        return refs, images

    for p in products:
        if not isinstance(p, dict):
            continue
        slug = str(p.get("handle") or "").lower().strip("/")
        if not slug:
            continue
        host = host_hint or ""
        canonical = f"https://{host}/products/{slug}" if host else f"/products/{slug}"
        refs.append((canonical, host, slug))
        img_urls: list[str] = []
        for img in p.get("images", []) or []:
            if isinstance(img, dict):
                src = img.get("src") or ""
                if src:
                    img_urls.append(src)
            elif isinstance(img, str):
                img_urls.append(img)
        if img_urls:
            images[slug] = img_urls
    return refs, images


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

    For products.json surfaces, also writes image URLs to the per-slug
    links files so the download stage can fetch them directly — this
    is the Shopify "holy grail" path where one API call yields a full
    catalog's image manifest.

    Returns the number of new-or-confirmed entity references written.
    Silent on ledger-write failure; safe to call without a ledger
    present (returns the ref count anyway).
    """
    surface_class = classify_filename(path.name)
    if surface_class == "unknown":
        return 0

    try:
        body = path.read_bytes()
    except OSError:
        return 0

    surface_url = _filename_to_url(path.name)
    surface_host = ""
    if "://" in surface_url:
        try:
            surface_host = (urlparse(surface_url).hostname or "").lower().rstrip(".")
        except ValueError:
            surface_host = ""

    # Dispatch per surface class. products.json is the structured case
    # (yields outlinks + per-product image URLs); everything else is
    # URL-only.
    images_by_slug: dict[str, list[str]] = {}
    if surface_class == "json_api":
        refs, images_by_slug = parse_products_json(body, host_hint=surface_host)
    else:
        refs = extract_outlinks(surface_class, body)

    if not surface_host and refs:
        surface_host = refs[0][1]

    # Side effect: write image URLs to per-slug links files. The download
    # stage consumes these. This is the real Shopify /products.json win —
    # a single 200 KB JSON can yield thousands of product-image URLs.
    if images_by_slug:
        try:
            config.ensure_project_dirs()
            for slug, urls in images_by_slug.items():
                links_file = config.links_dir / f"{slug}.txt"
                existing: set[str] = set()
                if links_file.exists():
                    existing = {l.strip() for l in links_file.read_text().splitlines() if l.strip()}
                merged = sorted(existing | set(urls))
                links_file.write_text("\n".join(merged) + "\n")
        except OSError as e:
            log.debug("failed to write links files for %s: %s", path.name, e)

    if not ledger_exists(config.project_path):
        return len(refs)

    try:
        with ledger_connect(config.project_path) as conn:
            # Protocol III detection: diff outlink hosts against the ledger's
            # existing hosts set to identify genuinely new ones. These get
            # upserted (cdx_dumped_at NULL, audit visible) AND logged loudly
            # + written to a sidecar so the next pipeline invocation picks
            # them up.
            existing_hosts = {
                r[0] for r in conn.execute("SELECT host FROM hosts").fetchall()
            }
            observed_hosts = {host for _, host, _ in refs if host}
            truly_new = observed_hosts - existing_hosts

            for h in observed_hosts:
                upsert_host(conn, h)
            for canonical, host, slug in refs:
                if not host:
                    continue
                upsert_entity(
                    conn, slug, host,
                    canonical_url=canonical,
                    first_seen_in=surface_url,
                )
            if surface_host:
                upsert_surface(conn, surface_url, surface_host, surface_class)
            status = "ok" if refs else "empty"
            mark_surface_parsed(
                conn, surface_url,
                outlink_count=len(refs),
                parse_status=status,
            )

        if truly_new:
            log.warning(
                "Protocol III: surface %s references %d new host(s): %s",
                path.name, len(truly_new), sorted(truly_new)[:5],
            )
            try:
                sidecar = config.project_path / ".new_hosts.txt"
                seen_before: set[str] = set()
                if sidecar.exists():
                    seen_before = {l.strip() for l in sidecar.read_text().splitlines() if l.strip()}
                with sidecar.open("a", encoding="utf-8") as f:
                    for h in sorted(truly_new):
                        if h not in seen_before:
                            f.write(f"{h}\t{surface_url}\n")
            except OSError:
                pass
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
    "parse_products_json",
    "parse_surface_file",
]
