"""
Circuit breaker and resilience utilities for the wayback-archive pipeline.

Tracks consecutive failures per domain and applies escalating pauses
to avoid hammering unresponsive endpoints.
"""
from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field

log = logging.getLogger(__name__)


@dataclass
class CircuitBreaker:
    """Per-domain circuit breaker with escalating backoff.

    Tracks consecutive failures for each domain. When thresholds are hit:
      - 3 consecutive failures → pause 120 seconds
      - 6 consecutive failures → pause 300 seconds
      - 10 consecutive failures → skip domain entirely

    Usage:
        cb = CircuitBreaker()

        if cb.should_skip(domain):
            continue  # domain is tripped

        try:
            result = fetch(url)
            cb.record_success(domain)
        except Exception:
            pause = cb.record_failure(domain)
            if pause > 0:
                await asyncio.sleep(pause)
    """
    max_retries: int = 10
    backoff_factor: float = 2.0

    # Thresholds: (failure_count, pause_seconds)
    _thresholds: list[tuple[int, float]] = field(default_factory=lambda: [
        (3, 120.0),
        (6, 300.0),
    ])

    _failures: dict[str, int] = field(default_factory=dict, repr=False)
    _tripped: set[str] = field(default_factory=set, repr=False)
    _last_pause: dict[str, float] = field(default_factory=dict, repr=False)

    # Counters for observability
    total_successes: int = 0
    total_failures: int = 0
    domains_tripped: int = 0

    def should_skip(self, domain: str) -> bool:
        """Check if a domain's circuit breaker has tripped (skip entirely)."""
        return domain in self._tripped

    def record_success(self, domain: str) -> None:
        """Record a successful request — resets consecutive failure count."""
        if domain in self._failures:
            self._failures[domain] = 0
        self.total_successes += 1

    def record_failure(self, domain: str) -> float:
        """Record a failed request. Returns the pause duration (0 if no pause needed).

        Caller is responsible for actually sleeping/pausing.
        """
        self._failures[domain] = self._failures.get(domain, 0) + 1
        count = self._failures[domain]
        self.total_failures += 1

        # Check if domain should be skipped entirely
        if count >= self.max_retries:
            self._tripped.add(domain)
            self.domains_tripped += 1
            log.warning(
                "Circuit breaker TRIPPED for %s (%d consecutive failures) — skipping domain",
                domain, count,
            )
            return 0.0

        # Check thresholds (iterate in reverse to find the highest matching)
        for threshold, pause in reversed(self._thresholds):
            if count == threshold:
                log.warning(
                    "Circuit breaker: %s hit %d consecutive failures — pausing %.0fs",
                    domain, count, pause,
                )
                self._last_pause[domain] = pause
                return pause

        return 0.0

    def get_failure_count(self, domain: str) -> int:
        return self._failures.get(domain, 0)

    def get_stats(self) -> dict:
        """Return observability stats."""
        return {
            "total_successes": self.total_successes,
            "total_failures": self.total_failures,
            "domains_tripped": self.domains_tripped,
            "tripped_domains": sorted(self._tripped),
            "failure_counts": {
                d: c for d, c in sorted(self._failures.items()) if c > 0
            },
        }

    def reset(self, domain: str | None = None) -> None:
        """Reset circuit breaker state for a domain (or all domains)."""
        if domain:
            self._failures.pop(domain, None)
            self._tripped.discard(domain)
            self._last_pause.pop(domain, None)
        else:
            self._failures.clear()
            self._tripped.clear()
            self._last_pause.clear()


@dataclass
class StageTimer:
    """Tracks wall time and method-level success/failure counts for a pipeline stage."""
    stage_name: str
    _start_time: float = 0.0
    _end_time: float = 0.0
    _method_success: dict[str, int] = field(default_factory=dict, repr=False)
    _method_failure: dict[str, int] = field(default_factory=dict, repr=False)

    def start(self) -> None:
        self._start_time = time.time()

    def stop(self) -> None:
        self._end_time = time.time()

    @property
    def elapsed(self) -> float:
        end = self._end_time if self._end_time else time.time()
        return end - self._start_time if self._start_time else 0.0

    def record_success(self, method: str) -> None:
        self._method_success[method] = self._method_success.get(method, 0) + 1

    def record_failure(self, method: str) -> None:
        self._method_failure[method] = self._method_failure.get(method, 0) + 1

    @property
    def total_success(self) -> int:
        return sum(self._method_success.values())

    @property
    def total_failure(self) -> int:
        return sum(self._method_failure.values())

    def get_stats(self) -> dict:
        """Return timing and method-level stats for serialization."""
        return {
            "stage": self.stage_name,
            "wall_time_seconds": round(self.elapsed, 1),
            "total_success": self.total_success,
            "total_failure": self.total_failure,
            "by_method": {
                "success": dict(sorted(self._method_success.items(), key=lambda x: -x[1])),
                "failure": dict(sorted(self._method_failure.items(), key=lambda x: -x[1])),
            },
        }

    def log_summary(self) -> None:
        """Log a human-readable summary."""
        total = self.total_success + self.total_failure
        pct = (100 * self.total_success / total) if total else 0
        log.info("Stage '%s' completed in %.1fs", self.stage_name, self.elapsed)
        log.info("  Total: %d (%d success, %d failure, %.0f%% success rate)",
                 total, self.total_success, self.total_failure, pct)
        if self._method_success:
            log.info("  By method (success):")
            for method, count in sorted(self._method_success.items(), key=lambda x: -x[1]):
                log.info("    %s: %d", method, count)
        if self._method_failure:
            log.info("  By method (failure):")
            for method, count in sorted(self._method_failure.items(), key=lambda x: -x[1]):
                log.info("    %s: %d", method, count)
