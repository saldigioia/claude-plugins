"""Unit tests for lib/wayback_archiver/surface_parser.py

Focus: the pure functions that decide which captured URLs are gateway
surfaces vs entity-scoped — a misclassification here silently drops
catalog-worth of product discovery.
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))

import pytest  # noqa: E402

from wayback_archiver.surface_parser import (  # noqa: E402
    _iter_html_product_refs,
    _normalize_product_ref,
    classify_filename,
    extract_outlinks,
)


# ── classify_filename ───────────────────────────────────────────────────────

class TestClassifyFilename:
    # Gateway surfaces — must be parsed for outlinks.
    @pytest.mark.parametrize("name,expected", [
        # Paginated atom feeds (the regression: these were misclassified "unknown")
        ("shop.example.com_products_1.atom", "atom"),
        ("shop.example.com_products_2.atom", "atom"),
        ("shop.example.com_products_page-2.atom", "atom"),
        ("shop.example.com_products_page_3.oembed", "oembed"),
        # Plain atom feed at apex
        ("shop.example.com.atom", "atom"),
        # Collection surfaces — regression: underscores in tail must be allowed
        ("shop.example.com_collections_all", "collection"),
        ("shop.example.com_collections_all_page-2", "collection"),
        ("shop.example.com_collections_men_tops", "collection"),
        ("shop.example.com_collections_sale_2024", "collection"),
        # Sitemaps take priority even though name contains `_products_`
        ("shop.example.com_sitemap_products_1.xml", "sitemap"),
        ("shop.example.com_sitemap.xml", "sitemap"),
        # products.json
        ("shop.example.com_products.json", "json_api"),
        # bare host
        ("shop.example.com", "home"),
    ])
    def test_gateway_surfaces(self, name, expected):
        assert classify_filename(name) == expected

    # Entity-scoped — NOT surfaces.
    @pytest.mark.parametrize("name", [
        "shop.example.com_products_my-tee.atom",
        "shop.example.com_products_some-handle.oembed",
        "shop.example.com_products_kanye-west-ye-hoodie.atom",
    ])
    def test_per_product_feeds_not_surfaces(self, name):
        assert classify_filename(name) == "unknown"


# ── _normalize_product_ref ──────────────────────────────────────────────────

class TestNormalizeProductRef:
    def test_absolute_url(self):
        got = _normalize_product_ref("https://shop.example.com/products/foo")
        assert got == ("https://shop.example.com/products/foo", "shop.example.com", "foo")

    def test_strips_wayback_wrapper(self):
        got = _normalize_product_ref(
            "https://web.archive.org/web/20230101id_/https://shop.example.com/products/bar"
        )
        assert got is not None
        canonical, host, slug = got
        assert host == "shop.example.com" and slug == "bar"

    def test_strips_wayback_path_prefix(self):
        # Injected path-prefix form (no origin)
        got = _normalize_product_ref(
            "/web/20230101/https://shop.example.com/products/bar"
        )
        assert got is not None and got[2] == "bar"

    def test_relative_url_with_base_host(self):
        # Regression: /products/foo inside collection HTML used to be dropped.
        got = _normalize_product_ref("/products/foo", base_host="shop.example.com")
        assert got == ("https://shop.example.com/products/foo", "shop.example.com", "foo")

    def test_relative_url_without_base_host_is_dropped(self):
        assert _normalize_product_ref("/products/foo") is None

    def test_non_product_url_returns_none(self):
        assert _normalize_product_ref("https://shop.example.com/blog/foo") is None

    def test_slug_extension_stripped(self):
        got = _normalize_product_ref("https://shop.example.com/products/foo.atom")
        assert got is not None and got[2] == "foo"


# ── HTML extractor ──────────────────────────────────────────────────────────

class TestIterHtmlProductRefs:
    def test_plain_href(self):
        body = b'<a href="/products/foo">Foo</a>'
        assert list(_iter_html_product_refs(body)) == ["/products/foo"]

    def test_data_attributes(self):
        # Regression: Shopify themes lazy-link via data attrs; these were missed.
        body = (
            b'<div data-href="/products/a"></div>'
            b'<div data-url="/products/b"></div>'
            b'<div data-product-url="/products/c"></div>'
        )
        hrefs = list(_iter_html_product_refs(body))
        assert "/products/a" in hrefs
        assert "/products/b" in hrefs
        assert "/products/c" in hrefs

    def test_non_product_hrefs_filtered(self):
        body = b'<a href="/about">about</a><a href="/products/foo">foo</a>'
        assert list(_iter_html_product_refs(body)) == ["/products/foo"]


# ── extract_outlinks end-to-end ─────────────────────────────────────────────

class TestExtractOutlinks:
    def test_collection_relative_hrefs_resolved(self):
        # Full integration: collection HTML with relative hrefs → refs with host.
        body = (
            b'<html><body>'
            b'<a href="/products/alpha">Alpha</a>'
            b'<div data-url="/products/beta"></div>'
            b'<a href="https://shop.example.com/products/gamma">Gamma</a>'
            b'</body></html>'
        )
        refs = extract_outlinks("collection", body, base_host="shop.example.com")
        slugs = sorted(s for _, _, s in refs)
        assert slugs == ["alpha", "beta", "gamma"]

    def test_atom_fallback_when_structured_parse_empty(self):
        # Body that parses as XML but has no <entry> — should fall back to regex.
        body = (
            b'<feed xmlns="http://www.w3.org/2005/Atom">'
            b'<link href="https://shop.example.com/products/x"/>'
            b'</feed>'
        )
        refs = extract_outlinks("atom", body)
        # Regex fallback finds the bare <link>; normalizer filters on /products/.
        assert any(s == "x" for _, _, s in refs)
