"""
Transport layer: proxy pool, circuit breakers, retry with backoff,
rate limiting, and robust HTTP client.

This is the single module through which ALL HTTP requests flow.
NEVER logs or prints proxy credentials.
"""
from __future__ import annotations

import logging
import math
import random
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional

import requests as _requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry as _Urllib3Retry

from .config import AppConfig, ProxyConfig
from .metrics import Metrics, get_metrics

log = logging.getLogger(__name__)


# ===================================================================
# Proxy primitives
# ===================================================================

class ProxyTier(Enum):
    DIRECT = "off"
    DATACENTER = "dc"
    ISP = "isp"


class BreakerState(Enum):
    CLOSED = "closed"
    OPEN = "open"
    HALF_OPEN = "half_open"


@dataclass
class ProxyEndpoint:
    """Single proxy endpoint. Credentials NEVER appear in logs."""
    tier: ProxyTier
    host: str
    port: int
    username: str
    password: str

    # Health bookkeeping
    breaker_state: BreakerState = BreakerState.CLOSED
    consecutive_failures: int = 0
    total_requests: int = 0
    total_failures: int = 0
    cooldown_until: float = 0.0
    last_success: float = 0.0
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def __repr__(self) -> str:
        return f"ProxyEndpoint({self.display_name}, state={self.breaker_state.value})"

    @property
    def proxy_url(self) -> str:
        """For requests library ONLY. NEVER log this."""
        from urllib.parse import quote
        return f"http://{quote(self.username, safe='')}:{quote(self.password, safe='')}@{self.host}:{self.port}"

    @property
    def display_name(self) -> str:
        return f"{self.tier.value}:{self.host}:{self.port}"

    @property
    def is_available(self) -> bool:
        with self._lock:
            if self.breaker_state == BreakerState.OPEN:
                if time.time() >= self.cooldown_until:
                    self.breaker_state = BreakerState.HALF_OPEN
                    return True
                return False
            return True

    @property
    def failure_rate(self) -> float:
        with self._lock:
            if self.total_requests == 0:
                return 0.0
            return self.total_failures / self.total_requests


@dataclass
class ProxyPool:
    """Manages a set of proxy endpoints with health-aware selection."""
    endpoints: list[ProxyEndpoint] = field(default_factory=list)
    _index: int = 0

    def get_best(self) -> Optional[ProxyEndpoint]:
        available = [e for e in self.endpoints if e.is_available]
        if not available:
            return None
        # Sort: prefer CLOSED, then lowest failure rate, then round-robin tie-break
        available.sort(key=lambda e: (
            e.breaker_state != BreakerState.CLOSED,
            e.failure_rate,
        ))
        return available[0]

    def get_next_round_robin(self) -> Optional[ProxyEndpoint]:
        """Simple round-robin among available endpoints."""
        available = [e for e in self.endpoints if e.is_available]
        if not available:
            return None
        ep = available[self._index % len(available)]
        self._index += 1
        return ep

    def record_success(self, ep: ProxyEndpoint) -> None:
        with ep._lock:
            ep.consecutive_failures = 0
            ep.total_requests += 1
            ep.last_success = time.time()
            if ep.breaker_state == BreakerState.HALF_OPEN:
                ep.breaker_state = BreakerState.CLOSED
                log.info("Breaker CLOSED for %s", ep.display_name)

    def record_failure(
        self, ep: ProxyEndpoint, threshold: int = 3, cooldown: float = 30.0
    ) -> None:
        metrics = get_metrics()
        with ep._lock:
            ep.consecutive_failures += 1
            ep.total_requests += 1
            ep.total_failures += 1
            if ep.consecutive_failures >= threshold and ep.breaker_state != BreakerState.OPEN:
                ep.breaker_state = BreakerState.OPEN
                ep.cooldown_until = time.time() + cooldown
                log.warning(
                    "Breaker OPEN for %s (failures=%d, cooldown=%.0fs)",
                    ep.display_name, ep.consecutive_failures, cooldown,
                )
                metrics.inc("breaker_open_events")

    @property
    def open_count(self) -> int:
        return sum(1 for e in self.endpoints if e.breaker_state == BreakerState.OPEN)


# ===================================================================
# Proxy router with auto-escalation
# ===================================================================

class ProxyRouter:
    def __init__(
        self,
        dc_pool: ProxyPool,
        isp_pool: ProxyPool,
        mode: str = "auto",
        config: AppConfig | None = None,
    ):
        self.dc_pool = dc_pool
        self.isp_pool = isp_pool
        self.mode = mode
        self._config = config or AppConfig()
        self._active_tier: ProxyTier = (
            ProxyTier.DATACENTER if mode in ("auto", "dc")
            else ProxyTier.ISP if mode == "isp"
            else ProxyTier.DIRECT
        )
        self._error_window: deque[tuple[float, bool]] = deque(maxlen=300)
        self._last_escalation: float = 0.0

    @property
    def active_tier(self) -> ProxyTier:
        return self._active_tier

    def get_endpoint(self) -> Optional[ProxyEndpoint]:
        if self.mode == "off":
            return None
        if self.mode == "auto":
            self._maybe_adjust_tier()

        pool = self.dc_pool if self._active_tier == ProxyTier.DATACENTER else self.isp_pool
        ep = pool.get_best()

        # Auto fallback
        if ep is None and self.mode == "auto":
            fallback = self.isp_pool if self._active_tier == ProxyTier.DATACENTER else self.dc_pool
            ep = fallback.get_best()
            if ep:
                log.warning("Falling back to %s (primary pool exhausted)", ep.display_name)
        return ep

    def get_alternate(self, exclude: ProxyEndpoint | None) -> Optional[ProxyEndpoint]:
        """Get a different endpoint than the one that just failed."""
        pool = self.dc_pool if self._active_tier == ProxyTier.DATACENTER else self.isp_pool
        available = [e for e in pool.endpoints if e.is_available and e is not exclude]
        if available:
            available.sort(key=lambda e: (e.breaker_state != BreakerState.CLOSED, e.failure_rate))
            return available[0]
        # Try other pool in auto mode
        if self.mode == "auto":
            other = self.isp_pool if self._active_tier == ProxyTier.DATACENTER else self.dc_pool
            available = [e for e in other.endpoints if e.is_available]
            if available:
                return available[0]
        return None

    def record_result(self, ep: ProxyEndpoint, success: bool) -> None:
        cfg = self._config
        pool = self.dc_pool if ep.tier == ProxyTier.DATACENTER else self.isp_pool
        if success:
            pool.record_success(ep)
        else:
            pool.record_failure(ep, threshold=cfg.breaker_threshold, cooldown=cfg.breaker_cooldown)
        if self.mode == "auto":
            self._error_window.append((time.time(), success))

    def _maybe_adjust_tier(self) -> None:
        cfg = self._config
        now = time.time()
        cutoff = now - cfg.escalation_cooldown
        recent = [(t, ok) for t, ok in self._error_window if t > cutoff]
        if len(recent) < 10:
            return
        error_rate = sum(1 for _, ok in recent if not ok) / len(recent)

        if self._active_tier == ProxyTier.DATACENTER:
            dc_total = len(self.dc_pool.endpoints) or 1
            if (
                error_rate > cfg.escalation_error_rate
                and self.dc_pool.open_count / dc_total > cfg.escalation_pool_broken
                and self.isp_pool.endpoints
            ):
                log.warning(
                    "Auto-escalating DC→ISP (error_rate=%.0f%%, open=%d/%d)",
                    error_rate * 100, self.dc_pool.open_count, dc_total,
                )
                self._active_tier = ProxyTier.ISP
                self._last_escalation = now
        elif self._active_tier == ProxyTier.ISP:
            if now - self._last_escalation < cfg.escalation_cooldown:
                return
            dc_total = len(self.dc_pool.endpoints) or 1
            dc_closed = sum(
                1 for e in self.dc_pool.endpoints if e.breaker_state == BreakerState.CLOSED
            )
            if dc_closed / dc_total > 0.5:
                log.info("DC pool recovered — decaying ISP→DC")
                self._active_tier = ProxyTier.DATACENTER


# ===================================================================
# Rate limiter (token bucket)
# ===================================================================

class TokenBucket:
    """Thread-safe token-bucket rate limiter."""

    def __init__(self, rate: float, burst: int | None = None):
        self._rate = rate
        self._burst = burst or max(int(rate * 2), 1)
        self._tokens = float(self._burst)
        self._last = time.monotonic()
        self._lock = threading.Lock()

    def acquire(self, timeout: float = 30.0) -> bool:
        deadline = time.monotonic() + timeout
        while True:
            with self._lock:
                now = time.monotonic()
                elapsed = now - self._last
                self._tokens = min(self._burst, self._tokens + elapsed * self._rate)
                self._last = now
                if self._tokens >= 1.0:
                    self._tokens -= 1.0
                    return True
            if time.monotonic() >= deadline:
                return False
            time.sleep(min(0.05, 1.0 / max(self._rate, 0.1)))


# ===================================================================
# Backoff calculator
# ===================================================================

def compute_backoff(
    attempt: int,
    base: float = 1.0,
    maximum: float = 60.0,
    jitter_max: float = 1.0,
) -> float:
    """Exponential backoff with full jitter."""
    exp = min(base * (2 ** attempt), maximum)
    jitter = random.uniform(0, jitter_max)
    return exp + jitter


# ===================================================================
# Response classification
# ===================================================================

RETRYABLE_STATUSES = frozenset({429, 500, 502, 503, 504})
ROTATE_STATUSES = frozenset({403, 429})
FATAL_PROXY_STATUSES = frozenset({407, 521, 523})


def _parse_retry_after(resp: _requests.Response) -> float | None:
    val = resp.headers.get("Retry-After")
    if val is None:
        return None
    try:
        return float(val)
    except ValueError:
        return None


# ===================================================================
# Transport client
# ===================================================================

class TransportError(Exception):
    """Raised when all retries are exhausted."""
    def __init__(self, message: str, status: int | None = None, last_error: Exception | None = None):
        super().__init__(message)
        self.status = status
        self.last_error = last_error


class Transport:
    """
    Robust HTTP client with proxy rotation, retry, backoff,
    rate limiting, and circuit breakers.

    All external HTTP goes through `self.fetch()`.
    """

    def __init__(self, config: AppConfig, router: ProxyRouter | None = None):
        self.config = config
        self.router = router
        self._limiter = TokenBucket(config.max_rps)
        self._metrics = get_metrics()

        # Build a requests session with connection pooling
        self._session = _requests.Session()
        self._session.headers["User-Agent"] = config.user_agent
        # Mount adapter with pool size matching concurrency
        adapter = HTTPAdapter(
            pool_connections=config.max_concurrency + 2,
            pool_maxsize=config.max_concurrency + 2,
        )
        self._session.mount("https://", adapter)
        self._session.mount("http://", adapter)

    def close(self) -> None:
        self._session.close()

    # ---------------------------------------------------------------
    # Public API
    # ---------------------------------------------------------------

    def fetch(self, url: str, params: dict | None = None) -> str:
        """
        Fetch URL text with full retry / proxy / rate-limit pipeline.
        Returns response body as string.
        Raises TransportError on exhausted retries.
        """
        last_error: Exception | None = None
        last_status: int | None = None
        endpoint = self.router.get_endpoint() if self.router else None

        for attempt in range(self.config.max_retries + 1):
            # Rate limit
            if not self._limiter.acquire(timeout=30):
                log.warning("Rate limiter timeout; proceeding anyway")

            # Inter-request jitter
            if attempt > 0:
                backoff = compute_backoff(
                    attempt - 1,
                    base=self.config.backoff_base,
                    maximum=self.config.backoff_max,
                    jitter_max=self.config.jitter_max,
                )
                log.debug("Retry %d/%d — backoff %.1fs", attempt, self.config.max_retries, backoff)
                time.sleep(backoff)
                self._metrics.inc("retries_total")

            proxies = None
            tier_label = "direct"
            if endpoint:
                proxies = {"https": endpoint.proxy_url, "http": endpoint.proxy_url}
                tier_label = endpoint.display_name

            t0 = time.monotonic()
            try:
                resp = self._session.get(
                    url,
                    params=params,
                    proxies=proxies,
                    timeout=(self.config.connect_timeout, self.config.read_timeout),
                )
                duration = time.monotonic() - t0
                status = resp.status_code

                # --- Success path ---
                if 200 <= status < 300:
                    self._metrics.record_request(status, duration, tier_label, success=True)
                    if endpoint and self.router:
                        self.router.record_result(endpoint, success=True)
                    body = resp.text
                    self._metrics.inc("bytes_received", len(body))
                    return body

                # --- Fatal proxy errors ---
                if status in FATAL_PROXY_STATUSES:
                    log.error("Fatal proxy error %d from %s", status, tier_label)
                    self._metrics.record_request(status, duration, tier_label, success=False)
                    if endpoint and self.router:
                        self.router.record_result(endpoint, success=False)
                    raise TransportError(
                        f"Fatal proxy status {status}", status=status
                    )

                # --- Retryable ---
                last_status = status
                self._metrics.record_request(status, duration, tier_label, success=False)

                if endpoint and self.router:
                    self.router.record_result(endpoint, success=False)

                # Respect Retry-After header
                retry_after = _parse_retry_after(resp)
                if retry_after and retry_after > 0:
                    wait = min(retry_after, self.config.backoff_max)
                    log.info("Retry-After: %.1fs (status %d)", wait, status)
                    time.sleep(wait)

                # Rotate proxy on 403/429
                if status in ROTATE_STATUSES and self.router:
                    new_ep = self.router.get_alternate(exclude=endpoint)
                    if new_ep:
                        log.info("Rotating proxy %s → %s (status %d)",
                                 endpoint.display_name if endpoint else "direct",
                                 new_ep.display_name, status)
                        endpoint = new_ep
                        self._metrics.inc("proxy_rotations")

                if status not in RETRYABLE_STATUSES:
                    raise TransportError(
                        f"Non-retryable status {status}", status=status
                    )

            except _requests.exceptions.ConnectionError as e:
                duration = time.monotonic() - t0
                last_error = e
                log.warning("Connection error (attempt %d): %s", attempt + 1, type(e).__name__)
                self._metrics.record_request(0, duration, tier_label, success=False)
                if endpoint and self.router:
                    self.router.record_result(endpoint, success=False)
                    new_ep = self.router.get_alternate(exclude=endpoint)
                    if new_ep:
                        endpoint = new_ep
                        self._metrics.inc("proxy_rotations")

            except _requests.exceptions.Timeout as e:
                duration = time.monotonic() - t0
                last_error = e
                log.warning("Timeout (attempt %d): %s", attempt + 1, type(e).__name__)
                self._metrics.record_request(0, duration, tier_label, success=False)
                if endpoint and self.router:
                    self.router.record_result(endpoint, success=False)

            except TransportError:
                raise

            except Exception as e:
                duration = time.monotonic() - t0
                last_error = e
                log.warning("Unexpected error (attempt %d): %s: %s", attempt + 1, type(e).__name__, e)
                self._metrics.record_request(0, duration, tier_label, success=False)
                if endpoint and self.router:
                    self.router.record_result(endpoint, success=False)

        raise TransportError(
            f"Exhausted {self.config.max_retries + 1} attempts (last_status={last_status})",
            status=last_status,
            last_error=last_error,
        )


# ===================================================================
# Factory helpers
# ===================================================================

def build_pools(proxy_cfg: ProxyConfig) -> tuple[ProxyPool, ProxyPool]:
    dc_endpoints = []
    if proxy_cfg.dc_available:
        for port in proxy_cfg.dc_ports:
            dc_endpoints.append(ProxyEndpoint(
                tier=ProxyTier.DATACENTER,
                host=proxy_cfg.dc_host,
                port=port,
                username=proxy_cfg.dc_user,
                password=proxy_cfg.dc_pass,
            ))

    isp_endpoints = []
    if proxy_cfg.isp_available:
        for port in proxy_cfg.isp_ports:
            isp_endpoints.append(ProxyEndpoint(
                tier=ProxyTier.ISP,
                host=proxy_cfg.isp_host,
                port=port,
                username=proxy_cfg.isp_user,
                password=proxy_cfg.isp_pass,
            ))

    return ProxyPool(dc_endpoints), ProxyPool(isp_endpoints)


def build_transport(config: AppConfig) -> Transport:
    """Build a fully-configured Transport from AppConfig."""
    dc_pool, isp_pool = build_pools(config.proxy)
    mode = config.proxy.mode

    # Validate mode against available pools
    if mode == "dc" and not dc_pool.endpoints:
        log.warning("DC mode requested but no DC credentials; falling back to direct")
        mode = "off"
    if mode == "isp" and not isp_pool.endpoints:
        log.warning("ISP mode requested but no ISP credentials; falling back to direct")
        mode = "off"
    if mode == "auto" and not dc_pool.endpoints and not isp_pool.endpoints:
        log.warning("Auto mode but no proxy credentials configured; using direct")
        mode = "off"

    router = None
    if mode != "off":
        router = ProxyRouter(dc_pool, isp_pool, mode=mode, config=config)
        pool_summary = []
        if dc_pool.endpoints:
            pool_summary.append(f"DC={len(dc_pool.endpoints)} endpoints")
        if isp_pool.endpoints:
            pool_summary.append(f"ISP={len(isp_pool.endpoints)} endpoints")
        log.info("Proxy mode=%s  %s", mode, ", ".join(pool_summary))
    else:
        log.info("Proxy mode=off (direct requests)")

    return Transport(config=config, router=router)
