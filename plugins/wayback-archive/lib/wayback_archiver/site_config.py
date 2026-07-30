"""
Site configuration loader.

Reads YAML config files that define how to process a specific e-commerce site.
Adding a new target site = writing a YAML file, no Python code needed.
"""
from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from pathlib import Path

import yaml

log = logging.getLogger(__name__)

# Download strategies that exist as code in download.py. Anything else in a
# config's `download_cascade` is inert.
#
# `exhaustive` and `asset_rescue` were declared in every template and in this
# module's default for a long time without ever being implemented — the config,
# the templates, and download.py's own docstring all advertised a five-strategy
# cascade over a three-strategy implementation. They are gone from the defaults;
# a config that still names them gets a warning rather than silent no-op.
IMPLEMENTED_DOWNLOAD_STRATEGIES = ("live_cdn", "direct_fetch", "wayback_cdx_best")

DEFAULT_DOWNLOAD_CASCADE = list(IMPLEMENTED_DOWNLOAD_STRATEGIES)


def _validate_cascade(cascade: list[str], source: str) -> list[str]:
    """Drop unimplemented strategy names, loudly.

    Returning the filtered list rather than the raw one means a typo degrades
    to "that step didn't run" with a warning, instead of silently doing
    nothing while the config claims otherwise.
    """
    known, unknown = [], []
    for name in cascade:
        (known if name in IMPLEMENTED_DOWNLOAD_STRATEGIES else unknown).append(name)
    if unknown:
        log.warning(
            "%s: download_cascade names %d unimplemented strateg%s (%s) — ignoring. "
            "Implemented: %s",
            source, len(unknown), "y" if len(unknown) == 1 else "ies",
            ", ".join(unknown), ", ".join(IMPLEMENTED_DOWNLOAD_STRATEGIES),
        )
    if not known:
        log.warning("%s: download_cascade has no implemented strategies — using the default",
                    source)
        return list(DEFAULT_DOWNLOAD_CASCADE)
    return known


@dataclass
class SiteConfig:
    """Complete configuration for archiving a single e-commerce site."""
    name: str
    display_name: str
    credit_line: str
    domains: list[str]
    cdx_files: list[str]
    project_dir: str
    transport_pkg: str | None = None
    cdn_tool: str | None = None

    # Stage 1: URL classification
    url_rules: list[dict] = field(default_factory=list)
    junk_patterns: list[str] = field(default_factory=list)
    era_rules: list[dict] = field(default_factory=list)

    # Stage 1: Dedup
    type_priority: list[str] = field(default_factory=lambda: ["api", "slug", "collection", "sku"])

    # Stage 2: CDN patterns for image extraction
    cdn_patterns: list[dict] = field(default_factory=list)

    # Stage 2: Metadata extractors
    metadata_extractors: dict = field(default_factory=dict)

    # Stage 2: Catalog API patterns
    catalog_api_patterns: list[str] = field(default_factory=list)

    # Stage 4: Download cascade
    download_cascade: list[str] = field(
        default_factory=lambda: list(DEFAULT_DOWNLOAD_CASCADE))

    # Image validation
    min_image_bytes: int = 500

    # Alternative archives
    alternative_archives: dict = field(default_factory=dict)

    # Raw config data (for extensions)
    _raw: dict = field(default_factory=dict, repr=False)

    @property
    def project_path(self) -> Path:
        return Path(self.project_dir)

    @property
    def cdx_paths(self) -> list[Path]:
        return [Path(p) for p in self.cdx_files]

    @property
    def cdn_tool_path(self) -> Path | None:
        return Path(self.cdn_tool) if self.cdn_tool else None

    @property
    def transport_path(self) -> Path | None:
        return Path(self.transport_pkg) if self.transport_pkg else None

    @property
    def filtered_links_file(self) -> Path:
        return self.project_path / f"{self.name}_filtered_links.txt"

    @property
    def fetch_output_dir(self) -> Path:
        return self.project_path / "html"

    @property
    def cc_index_file(self) -> Path:
        return self.project_path / f"{self.name}_commoncrawl_index.json"

    @property
    def fetch_stats_file(self) -> Path:
        return self.project_path / f"{self.name}_fetch_stats.json"

    @property
    def products_dir(self) -> Path:
        return self.project_path / "products"

    @property
    def links_dir(self) -> Path:
        return self.project_path / "links"

    @property
    def metadata_file(self) -> Path:
        return self.project_path / f"{self.name}_metadata.json"

    @property
    def index_file(self) -> Path:
        return self.project_path / f"{self.name}_products_index.json"

    @property
    def catalog_file(self) -> Path:
        return self.project_path / f"{self.name}_catalog.json"

    @property
    def compiled_junk(self) -> re.Pattern:
        if self.junk_patterns:
            return re.compile("|".join(self.junk_patterns))
        return re.compile(r'%22|%3[CcEe]|%7[Bb]|%5[Bb]|\[insert|:productId')

    def checkpoint_path(self, stage: str) -> Path:
        return self.project_path / f".checkpoint_{stage}.json"

    def ensure_project_dirs(self) -> None:
        """Create every directory the pipeline writes into. Idempotent.

        Call at the top of any stage that produces files. Prevents the
        "stage fails because products/ dir doesn't exist yet" quirk that
        surfaced on the pablosupply end-to-end.
        """
        for d in (self.project_path, self.fetch_output_dir, self.links_dir, self.products_dir):
            d.mkdir(parents=True, exist_ok=True)


def load_config(config_path: Path) -> SiteConfig:
    """Load a site configuration from a YAML file.

    Relative paths in the config (project_dir, cdx_files, cdn_tool) are
    resolved relative to the config file's parent directory.
    """
    config_path = config_path.resolve()
    config_dir = config_path.parent

    with open(config_path, encoding="utf-8") as f:
        data = yaml.safe_load(f)

    def _resolve(p: str) -> str:
        """Resolve a path relative to the config file if not absolute."""
        pp = Path(p)
        if not pp.is_absolute():
            pp = (config_dir / pp).resolve()
        return str(pp)

    project_dir = _resolve(data["project_dir"])
    cdx_files = [_resolve(p) for p in data.get("cdx_files", [])]
    cdn_tool = _resolve(data["cdn_tool"]) if data.get("cdn_tool") else None

    return SiteConfig(
        name=data["name"],
        display_name=data["display_name"],
        credit_line=data.get("credit_line", data["display_name"]),
        domains=data.get("domains", []),
        cdx_files=cdx_files,
        project_dir=project_dir,
        transport_pkg=data.get("transport_pkg"),
        cdn_tool=cdn_tool,
        url_rules=data.get("url_rules", []),
        junk_patterns=data.get("junk_patterns", []),
        era_rules=data.get("era_rules", []),
        type_priority=data.get("type_priority", ["api", "slug", "collection", "sku"]),
        cdn_patterns=data.get("cdn_patterns", []),
        metadata_extractors=data.get("metadata_extractors", {}),
        catalog_api_patterns=data.get("catalog_api_patterns", []),
        download_cascade=_validate_cascade(
            data.get("download_cascade", DEFAULT_DOWNLOAD_CASCADE), str(config_path)),
        min_image_bytes=data.get("min_image_bytes", 500),
        alternative_archives=data.get("alternative_archives", {}),
        _raw=data,
    )
