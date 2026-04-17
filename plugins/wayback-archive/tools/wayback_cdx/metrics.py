"""
Lightweight in-process metrics counters and end-of-run summary.

No external dependencies.  Thread-safe via simple locks.
"""
from __future__ import annotations

import json
import logging
import threading
import time
from collections import defaultdict
from dataclasses import dataclass, field

log = logging.getLogger(__name__)


@dataclass
class Metrics:
    """Accumulates counters for observability and end-of-run reporting."""

    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)
    _start_time: float = field(default_factory=time.time)

    # Core counters
    requests_total: int = 0
    requests_success: int = 0
    requests_failed: int = 0
    retries_total: int = 0
    proxy_rotations: int = 0
    breaker_open_events: int = 0
    pages_completed: int = 0
    rows_yielded: int = 0
    rows_deduped: int = 0
    bytes_received: int = 0

    # Bucketed by status code
    status_counts: dict[int, int] = field(default_factory=lambda: defaultdict(int))

    # Timing
    request_durations: list[float] = field(default_factory=list)

    # Tier usage
    tier_counts: dict[str, int] = field(default_factory=lambda: defaultdict(int))

    def inc(self, name: str, amount: int = 1) -> None:
        with self._lock:
            current = getattr(self, name, 0)
            setattr(self, name, current + amount)

    def record_request(
        self,
        status: int,
        duration: float,
        tier: str = "direct",
        success: bool = True,
    ) -> None:
        with self._lock:
            self.requests_total += 1
            if success:
                self.requests_success += 1
            else:
                self.requests_failed += 1
            self.status_counts[status] += 1
            self.tier_counts[tier] += 1
            self.request_durations.append(duration)

    def summary(self) -> dict:
        with self._lock:
            elapsed = time.time() - self._start_time
            durations = sorted(self.request_durations) if self.request_durations else [0]
            p50 = durations[len(durations) // 2]
            p95 = durations[int(len(durations) * 0.95)]
            p99 = durations[int(len(durations) * 0.99)]

            return {
                "elapsed_seconds": round(elapsed, 1),
                "requests_total": self.requests_total,
                "requests_success": self.requests_success,
                "requests_failed": self.requests_failed,
                "success_rate": (
                    round(self.requests_success / max(self.requests_total, 1) * 100, 1)
                ),
                "retries_total": self.retries_total,
                "proxy_rotations": self.proxy_rotations,
                "breaker_open_events": self.breaker_open_events,
                "pages_completed": self.pages_completed,
                "rows_yielded": self.rows_yielded,
                "rows_deduped": self.rows_deduped,
                "bytes_received": self.bytes_received,
                "status_distribution": dict(self.status_counts),
                "tier_usage": dict(self.tier_counts),
                "latency_p50": round(p50, 3),
                "latency_p95": round(p95, 3),
                "latency_p99": round(p99, 3),
            }

    def print_summary(self) -> None:
        s = self.summary()
        log.info("=" * 60)
        log.info("RUN SUMMARY")
        log.info("=" * 60)
        for k, v in s.items():
            log.info("  %-26s %s", k, v)
        log.info("=" * 60)

    def summary_json(self) -> str:
        return json.dumps(self.summary(), indent=2)


# Module-level singleton
_global_metrics: Metrics | None = None
_metrics_lock = threading.Lock()


def get_metrics() -> Metrics:
    global _global_metrics
    with _metrics_lock:
        if _global_metrics is None:
            _global_metrics = Metrics()
        return _global_metrics


def reset_metrics() -> Metrics:
    global _global_metrics
    with _metrics_lock:
        _global_metrics = Metrics()
        return _global_metrics
