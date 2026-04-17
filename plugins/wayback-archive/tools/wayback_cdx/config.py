"""
Configuration loader for wayback-cdx.

All secrets come from environment variables or .env file.
NEVER log or print credential values.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


def _load_dotenv() -> None:
    """Best-effort load of .env (no hard dep on python-dotenv)."""
    try:
        from dotenv import load_dotenv  # type: ignore[import-untyped]
    except ImportError:
        return
    for candidate in (Path.cwd() / ".env", Path(__file__).parent / ".env"):
        if candidate.exists():
            load_dotenv(candidate, override=False)
            break


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class ProxyConfig:
    mode: str = "auto"  # auto | dc | isp | off

    dc_user: str = ""
    dc_pass: str = ""
    dc_host: str = "dc.oxylabs.io"
    dc_ports: tuple[int, ...] = ()

    isp_user: str = ""
    isp_pass: str = ""
    isp_host: str = "isp.oxylabs.io"
    isp_ports: tuple[int, ...] = ()

    @property
    def dc_available(self) -> bool:
        return bool(self.dc_user and self.dc_pass and self.dc_ports)

    @property
    def isp_available(self) -> bool:
        return bool(self.isp_user and self.isp_pass and self.isp_ports)


@dataclass(frozen=True)
class AppConfig:
    proxy: ProxyConfig = field(default_factory=ProxyConfig)
    max_rps: float = 2.0
    max_concurrency: int = 3
    connect_timeout: float = 10.0
    read_timeout: float = 60.0
    max_retries: int = 4
    backoff_base: float = 1.0
    backoff_max: float = 60.0
    jitter_max: float = 1.0
    checkpoint_file: str = ""
    # Default UA identifies this as part of the wayback-archive plugin, per
    # the Internet Archive's guidance that AI-agent traffic must be
    # attributable. Keep this string in sync with
    # lib/wayback_archiver/http_client.py USER_AGENT_SUFFIX.
    user_agent: str = (
        "wayback-cdx-dump/2.0 wayback-archive "
        "(Claude Code AI agent; +https://github.com/saldigioia/wayback-archive-plugin)"
    )

    # Breaker config
    breaker_threshold: int = 3
    breaker_cooldown: float = 30.0

    # Auto-mode thresholds
    escalation_error_rate: float = 0.30
    escalation_pool_broken: float = 0.50
    escalation_cooldown: float = 300.0

    @staticmethod
    def from_env() -> AppConfig:
        _load_dotenv()

        def _parse_ports(raw: str) -> tuple[int, ...]:
            return tuple(
                int(p.strip())
                for p in raw.split(",")
                if p.strip().isdigit()
            )

        proxy = ProxyConfig(
            mode=os.getenv("PROXY_MODE", "auto").lower().strip(),
            dc_user=os.getenv("OXY_DC_USER", ""),
            dc_pass=os.getenv("OXY_DC_PASS", ""),
            dc_host=os.getenv("OXY_DC_HOST", "dc.oxylabs.io"),
            dc_ports=_parse_ports(os.getenv("OXY_DC_PORTS", "")),
            isp_user=os.getenv("OXY_ISP_USER", ""),
            isp_pass=os.getenv("OXY_ISP_PASS", ""),
            isp_host=os.getenv("OXY_ISP_HOST", "isp.oxylabs.io"),
            isp_ports=_parse_ports(os.getenv("OXY_ISP_PORTS", "")),
        )

        return AppConfig(
            proxy=proxy,
            max_rps=float(os.getenv("CDX_MAX_RPS", "2")),
            max_concurrency=int(os.getenv("CDX_MAX_CONCURRENCY", "3")),
            connect_timeout=float(os.getenv("CDX_CONNECT_TIMEOUT", "10")),
            read_timeout=float(os.getenv("CDX_READ_TIMEOUT", "60")),
            max_retries=int(os.getenv("CDX_MAX_RETRIES", "4")),
            backoff_base=float(os.getenv("CDX_BACKOFF_BASE", "1.0")),
            backoff_max=float(os.getenv("CDX_BACKOFF_MAX", "60.0")),
            jitter_max=float(os.getenv("CDX_JITTER_MAX", "1.0")),
            checkpoint_file=os.getenv("CDX_CHECKPOINT_FILE", ""),
            user_agent=os.getenv(
                "CDX_USER_AGENT",
                "wayback-cdx-dump/2.0 wayback-archive "
                "(Claude Code AI agent; +https://github.com/saldigioia/wayback-archive-plugin)",
            ),
            breaker_threshold=int(os.getenv("CDX_BREAKER_THRESHOLD", "3")),
            breaker_cooldown=float(os.getenv("CDX_BREAKER_COOLDOWN", "30")),
            escalation_error_rate=float(os.getenv("CDX_ESC_ERROR_RATE", "0.30")),
            escalation_pool_broken=float(os.getenv("CDX_ESC_POOL_BROKEN", "0.50")),
            escalation_cooldown=float(os.getenv("CDX_ESC_COOLDOWN", "300")),
        )
