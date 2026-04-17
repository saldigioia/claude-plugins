#!/usr/bin/env python3
"""
bootstrap.py — URL → apex → hosts → platform → config.yaml + plan JSON

Turn-key entrypoint for the wayback-archive pipeline. Invoked by SKILL.md via
dynamic-context injection so Claude receives a ready-to-execute plan without
the user ever touching YAML.

Usage:
    python3 bootstrap.py --input "https://kanyewest.com"
    python3 bootstrap.py --input "yeezysupply.com,shop.yeezysupply.com"
    python3 bootstrap.py --input "kanyewest.com" --name kanyewest --dry-run

Output:
    - JSON plan to stdout (always)
    - projects/<name>/config.yaml (unless --dry-run)
    - projects/<name>/plan.json   (unless --dry-run)

Exit codes:
    0  plan emitted, config written
    2  input could not be parsed
    3  template missing
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from urllib.parse import urlparse

import requests

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lib"))

from wayback_archiver.http_client import DEFAULT_HEADERS, BROWSER_HEADERS  # noqa: E402
from wayback_archiver import ledger as ledger_mod  # noqa: E402
from wayback_archiver.env import load_env  # noqa: E402

load_env()

TEMPLATE_DIR = REPO_ROOT / "skills" / "wayback-archive" / "configs"
PROJECTS_DIR = REPO_ROOT / "projects"

# ── Input parsing ─────────────────────────────────────────────────────────────

# Multipart TLDs where the "apex" is the last 3 labels, not 2.
# Intentionally small — covers common cases, not exhaustive.
_MULTIPART_TLDS = {
    "co.uk", "co.jp", "co.nz", "co.za", "co.kr",
    "com.au", "com.br", "com.mx", "com.cn", "com.sg", "com.hk", "com.tr",
    "myshopify.com",  # treated as a pseudo-TLD: yeezygap.myshopify.com is an apex
}

_HOSTNAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$")


def _normalize_host(raw: str) -> str | None:
    """Strip scheme/path, lowercase, return bare hostname or None if unparseable."""
    s = raw.strip()
    if not s:
        return None
    if "://" not in s:
        s = "http://" + s
    try:
        host = urlparse(s).hostname
    except ValueError:
        return None
    if not host:
        return None
    host = host.lower().rstrip(".")
    if not _HOSTNAME_RE.match(host):
        return None
    return host


def _apex_of(host: str) -> str:
    """Return the registrable apex domain for a host.

    kanyewest.com        -> kanyewest.com
    www.kanyewest.com    -> kanyewest.com
    shop.kanyewest.co.uk -> kanyewest.co.uk
    yeezygap.myshopify.com -> yeezygap.myshopify.com  (myshopify.com is a pseudo-TLD)
    """
    labels = host.split(".")
    if len(labels) <= 2:
        return host
    for tld in _MULTIPART_TLDS:
        if host.endswith("." + tld):
            parts = tld.count(".") + 1  # number of label components in TLD
            return ".".join(labels[-(parts + 1):])
    return ".".join(labels[-2:])


def _safe_name(apex: str) -> str:
    """Filename-safe short name from an apex. kanyewest.com -> kanyewest."""
    stem = apex.split(".")[0]
    stem = re.sub(r"[^a-z0-9_-]", "_", stem.lower())
    return stem or "site"


def _display_name(apex: str) -> str:
    return apex.split(".")[0].replace("-", " ").title()


def _apex_regex(apex: str) -> str:
    """Escape an apex for embedding in a regex alternation group."""
    return apex.replace(".", r"\.")


# ── Host enumeration ──────────────────────────────────────────────────────────

COMMON_PREFIXES = ["www", "shop", "store", "us", "uk", "ca", "eu", "m", "mobile", "checkout"]


def enumerate_hosts_via_wayback(apex: str, timeout: float = 20.0) -> list[str]:
    """Query Wayback CDX for *.{apex} and collect unique hostnames.

    Uses a bounded sample (limit=5000) to keep the request cheap. Pagination is
    a later-stage concern — bootstrap only needs enough coverage to seed the
    config's domains list.
    """
    url = (
        "https://web.archive.org/cdx/search/cdx"
        f"?url=*.{apex}&output=json&fl=original&collapse=urlkey&limit=5000"
    )
    try:
        r = requests.get(url, timeout=timeout, headers=DEFAULT_HEADERS)
        r.raise_for_status()
        rows = r.json()
    except (requests.RequestException, ValueError):
        return []
    hosts: set[str] = set()
    for row in rows[1:] if rows and rows[0] == ["original"] else rows:
        if not row:
            continue
        host = _normalize_host(row[0])
        if host and (host == apex or host.endswith("." + apex)):
            hosts.add(host)
    return sorted(hosts)


# ── Platform detection ────────────────────────────────────────────────────────

# Signatures cribbed from shopify_downloader.py + platform-support.md
SIG_SHOPIFY = [
    re.compile(r'cdn\.shopify\.com', re.I),
    re.compile(r'ShopifyAnalytics', re.I),
    re.compile(r'Shopify\.shop\s*=', re.I),
    re.compile(r'"shopify-checkout-api-token"'),
    re.compile(r'/cdn/shop/(?:files|products)/'),
]
SIG_SWELL = [
    re.compile(r'cdn\.swell\.store'),
    re.compile(r'__data\.json'),
]
SIG_FOURTHWALL = [
    re.compile(r'imgproxy\.fourthwall\.com'),
    re.compile(r'fourthwall\.com/api'),
]
SIG_ADIDAS = [
    re.compile(r'/api/products/'),
    re.compile(r'assets\.adidas\.com/images/'),
]

MYSHOPIFY_RE = re.compile(r'Shopify\.shop\s*=\s*"([^"]+\.myshopify\.com)"')


@dataclass
class PlatformProbe:
    platform: str = "unknown"       # shopify | swell | fourthwall | adidas | unknown
    confidence: float = 0.0
    matched_signals: list[str] = field(default_factory=list)
    sample_host: str | None = None
    sample_source: str = "none"     # live | wayback | none
    myshopify_domain: str | None = None


def _fetch_html(url: str, timeout: float = 10.0) -> str | None:
    """GET url, return response text or None. Follows redirects. Short-circuits on non-HTML."""
    try:
        # Use browser-shaped UA for site probes — some stores gate API/HTML
        # responses on non-browser clients. Our identifier is appended.
        r = requests.get(url, timeout=timeout, allow_redirects=True, headers=BROWSER_HEADERS)
    except requests.RequestException:
        return None
    if r.status_code != 200:
        return None
    ctype = r.headers.get("Content-Type", "").lower()
    if ctype and "html" not in ctype and "json" not in ctype and "xml" not in ctype:
        return None
    # cap at ~1 MiB — signatures always appear early
    return r.text[:1_048_576]


def _score_body(body: str) -> tuple[str, float, list[str]]:
    """Return (platform, confidence, matched) from signature matches."""
    scores = {
        "shopify": sum(1 for p in SIG_SHOPIFY if p.search(body)),
        "swell": sum(1 for p in SIG_SWELL if p.search(body)),
        "fourthwall": sum(1 for p in SIG_FOURTHWALL if p.search(body)),
        "adidas": sum(1 for p in SIG_ADIDAS if p.search(body)),
    }
    best = max(scores, key=lambda k: scores[k])
    hits = scores[best]
    if hits == 0:
        return "unknown", 0.0, []
    # two matching signatures = high confidence; one = medium
    confidence = min(1.0, 0.4 + 0.25 * hits)
    matched = []
    sigs = {"shopify": SIG_SHOPIFY, "swell": SIG_SWELL, "fourthwall": SIG_FOURTHWALL, "adidas": SIG_ADIDAS}[best]
    for p in sigs:
        if p.search(body):
            matched.append(p.pattern)
    return best, confidence, matched


def probe_platform(candidate_hosts: list[str]) -> PlatformProbe:
    """Try each host live, then fall back to most-recent Wayback capture."""
    probe = PlatformProbe()

    # Pass 1 — live
    for host in candidate_hosts:
        for scheme in ("https", "http"):
            body = _fetch_html(f"{scheme}://{host}/")
            if not body:
                continue
            platform, conf, matched = _score_body(body)
            if platform != "unknown":
                probe.platform = platform
                probe.confidence = conf
                probe.matched_signals = matched
                probe.sample_host = host
                probe.sample_source = "live"
                m = MYSHOPIFY_RE.search(body)
                if m:
                    probe.myshopify_domain = m.group(1).lower()
                return probe

    # Pass 2 — Wayback most-recent via id_ modifier
    for host in candidate_hosts:
        url = f"https://web.archive.org/web/2id_/https://{host}/"
        body = _fetch_html(url, timeout=15.0)
        if not body:
            continue
        platform, conf, matched = _score_body(body)
        if platform != "unknown":
            probe.platform = platform
            probe.confidence = conf * 0.85   # discount for archived sample
            probe.matched_signals = matched
            probe.sample_host = host
            probe.sample_source = "wayback"
            m = MYSHOPIFY_RE.search(body)
            if m:
                probe.myshopify_domain = m.group(1).lower()
            return probe

    return probe


# ── Config rendering ──────────────────────────────────────────────────────────

TEMPLATE_FILES = {
    "shopify": "_template_shopify.yaml",
    "swell": "_template_swell.yaml",
    "fourthwall": "_template_fourthwall.yaml",
    "adidas": "_template_adidas.yaml",
    "unknown": "_template_generic.yaml",
}


def render_config(platform: str, name: str, display_name: str, apex: str, hosts: list[str]) -> str:
    template_name = TEMPLATE_FILES.get(platform, "_template_generic.yaml")
    template_path = TEMPLATE_DIR / template_name
    if not template_path.exists():
        raise FileNotFoundError(f"Template not found: {template_path}")
    body = template_path.read_text()
    domains_block = "\n".join(f"  - {h}" for h in hosts) or f"  - {apex}"
    body = body.replace("{NAME}", name)
    body = body.replace("{DISPLAY_NAME}", display_name)
    body = body.replace("{APEX}", apex)
    body = body.replace("{APEX_REGEX}", _apex_regex(apex))
    body = body.replace("{DOMAINS}", domains_block)
    return body


# ── Orchestration ─────────────────────────────────────────────────────────────

def bootstrap(raw_input: str, name_override: str | None = None, dry_run: bool = False) -> dict:
    # 1. Parse input into seed hosts
    seeds: list[str] = []
    for token in re.split(r"[,\s]+", raw_input):
        h = _normalize_host(token)
        if h:
            seeds.append(h)
    if not seeds:
        print(json.dumps({"error": "no parseable host in input", "input": raw_input}), file=sys.stdout)
        sys.exit(2)

    apex = _apex_of(seeds[0])
    name = name_override or _safe_name(apex)
    display_name = _display_name(apex)

    # 2. Enumerate captured hosts via Wayback + add common prefixes + user seeds
    t0 = time.time()
    wb_hosts = enumerate_hosts_via_wayback(apex)
    wb_elapsed = time.time() - t0

    # Confirmed hosts: user seeds + Wayback sample hits + apex itself.
    confirmed: set[str] = set(seeds) | set(wb_hosts) | {apex}
    # Speculative hosts: common e-commerce prefixes. CDX dump on an empty host
    # is cheap (~seconds, produces an empty file); missing a real host is
    # expensive (entire subtree of products lost). Default to aggressive.
    speculative: set[str] = {f"{p}.{apex}" for p in COMMON_PREFIXES}
    hosts = sorted(confirmed | speculative)

    # 3. Probe platform (try apex + www first, fall back to all hosts)
    probe_candidates = [apex, f"www.{apex}"] + [h for h in hosts if h not in (apex, f"www.{apex}")]
    probe = probe_platform(probe_candidates[:6])

    # 4. If myshopify alias found, promote it into the confirmed set.
    if probe.myshopify_domain:
        confirmed.add(probe.myshopify_domain)
        hosts = sorted(confirmed | speculative)

    # 5. Render config
    platform_key = probe.platform if probe.confidence >= 0.5 else "unknown"
    try:
        config_yaml = render_config(platform_key, name, display_name, apex, hosts)
    except FileNotFoundError as e:
        print(json.dumps({"error": str(e)}), file=sys.stdout)
        sys.exit(3)

    project_dir = PROJECTS_DIR / name
    config_path = project_dir / "config.yaml"
    plan_path = project_dir / "plan.json"

    plan: dict = {
        "input": raw_input,
        "apex": apex,
        "name": name,
        "display_name": display_name,
        "hosts": hosts,
        "host_count": len(hosts),
        "hosts_confirmed": sorted(confirmed),
        "hosts_speculative": sorted(speculative - confirmed),
        "wayback_sample": {
            "queried": f"*.{apex}",
            "host_count": len(wb_hosts),
            "elapsed_sec": round(wb_elapsed, 2),
        },
        "platform": platform_key,
        "platform_detected": probe.platform,
        "confidence": round(probe.confidence, 2),
        "matched_signals": probe.matched_signals,
        "probe_source": probe.sample_source,
        "probe_host": probe.sample_host,
        "myshopify_domain": probe.myshopify_domain,
        "config_path": str(config_path.relative_to(REPO_ROOT)) if not dry_run else None,
        "plan_path": str(plan_path.relative_to(REPO_ROOT)) if not dry_run else None,
        "template_used": TEMPLATE_FILES.get(platform_key, "_template_generic.yaml"),
        "dry_run": dry_run,
        "notes": _build_notes(probe, platform_key, len(confirmed)),
    }

    if not dry_run:
        project_dir.mkdir(parents=True, exist_ok=True)
        config_path.write_text(config_yaml)
        plan_path.write_text(json.dumps(plan, indent=2))

        # Protocol III prerequisite: seed the ledger with every host we've
        # identified so the `unenumerated_hosts` count has a baseline to
        # shrink against as CDX dumps complete. Ledger write failures are
        # non-fatal — the pipeline still runs without a ledger.
        try:
            ledger_mod.init(project_dir)
            with ledger_mod.connect(project_dir) as conn:
                ledger_mod.upsert_hosts(conn, hosts)
            plan["ledger_path"] = str((project_dir / "ledger.db").relative_to(REPO_ROOT))
            plan["ledger_hosts_seeded"] = len(hosts)
            plan_path.write_text(json.dumps(plan, indent=2))
        except Exception as e:  # noqa: BLE001
            plan["ledger_error"] = f"{type(e).__name__}: {e}"
            plan_path.write_text(json.dumps(plan, indent=2))

    return plan


def _build_notes(probe: PlatformProbe, platform_key: str, confirmed_count: int) -> list[str]:
    notes: list[str] = []
    if platform_key == "unknown":
        notes.append("Platform detection returned low confidence — review cdn_patterns before running `download`.")
    if probe.sample_source == "wayback":
        notes.append("Live site unreachable; detection used most-recent Wayback capture (confidence discounted 15%).")
    if probe.sample_source == "none":
        notes.append("Could not fetch any sample HTML (live or archived). Proceeding with generic config.")
    if confirmed_count <= 1:
        notes.append("Wayback found no captured subdomains — only the apex is confirmed. Speculative common prefixes (www./shop./store./…) were added; their CDX dumps may come back empty.")
    if probe.myshopify_domain:
        notes.append(f"Detected myshopify alias: {probe.myshopify_domain} — added to domains list.")
    return notes


def main():
    parser = argparse.ArgumentParser(description="Wayback-archive bootstrap: URL → plan JSON + config.yaml")
    parser.add_argument("--input", required=True, help="URL or comma-separated host list")
    parser.add_argument("--name", default=None, help="Override project short name (default: derived from apex)")
    parser.add_argument("--dry-run", action="store_true", help="Emit plan JSON only; do not write files")
    args = parser.parse_args()

    plan = bootstrap(args.input, name_override=args.name, dry_run=args.dry_run)
    print(json.dumps(plan, indent=2))


if __name__ == "__main__":
    main()
