"""
Checkpoint / resume system for crash-safe CDX harvesting.

Writes checkpoint state as JSON sidecar. Uses atomic write (tmp + rename)
to guarantee no corrupt state on crash.
"""
from __future__ import annotations

import json
import logging
import os
import tempfile
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional

log = logging.getLogger(__name__)


@dataclass
class CheckpointState:
    """Serializable snapshot of crawl progress."""
    domain: str = ""
    total_pages: int = 0
    last_completed_page: int = -1  # -1 = not started
    rows_written: int = 0
    seen_count: int = 0
    output_path: str = ""
    from_ts: str = ""
    to_ts: str = ""
    started_at: str = ""
    updated_at: str = ""
    version: int = 1

    @property
    def next_page(self) -> int:
        return self.last_completed_page + 1

    @property
    def is_complete(self) -> bool:
        return self.last_completed_page >= self.total_pages - 1

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2)

    @classmethod
    def from_json(cls, text: str) -> CheckpointState:
        data = json.loads(text)
        return cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})


class CheckpointManager:
    """Manages checkpoint read/write with atomic file operations."""

    def __init__(self, path: str | Path):
        self.path = Path(path)
        self._state: Optional[CheckpointState] = None

    def load(self) -> Optional[CheckpointState]:
        """Load existing checkpoint, or None if not found."""
        if not self.path.exists():
            return None
        try:
            text = self.path.read_text(encoding="utf-8")
            state = CheckpointState.from_json(text)
            log.info(
                "Loaded checkpoint: page %d/%d (%d rows written)",
                state.last_completed_page + 1, state.total_pages, state.rows_written,
            )
            self._state = state
            return state
        except (json.JSONDecodeError, KeyError, TypeError) as e:
            log.warning("Corrupt checkpoint at %s: %s — starting fresh", self.path, e)
            return None

    def initialize(
        self, domain: str, total_pages: int, output_path: str,
        from_ts: str = "", to_ts: str = "",
    ) -> CheckpointState:
        """Create a fresh checkpoint state."""
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self._state = CheckpointState(
            domain=domain,
            total_pages=total_pages,
            last_completed_page=-1,
            rows_written=0,
            seen_count=0,
            output_path=output_path,
            from_ts=from_ts,
            to_ts=to_ts,
            started_at=now,
            updated_at=now,
        )
        self._write()
        return self._state

    def update(
        self,
        last_completed_page: int,
        rows_written: int,
        seen_count: int = 0,
    ) -> None:
        """Update and persist checkpoint atomically."""
        if self._state is None:
            return
        self._state.last_completed_page = last_completed_page
        self._state.rows_written = rows_written
        self._state.seen_count = seen_count
        self._state.updated_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self._write()

    def mark_complete(self) -> None:
        if self._state:
            self._state.updated_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            self._write()
            log.info("Checkpoint marked complete")

    def delete(self) -> None:
        """Remove checkpoint file after successful completion."""
        if self.path.exists():
            self.path.unlink()
            log.info("Checkpoint file removed: %s", self.path)

    def _write(self) -> None:
        """Atomic write: tmp file → fsync → rename."""
        if self._state is None:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(
            dir=str(self.path.parent),
            prefix=".ckpt_",
            suffix=".tmp",
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(self._state.to_json())
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_path, str(self.path))
        except Exception:
            # Clean up tmp on failure
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise

    @property
    def state(self) -> Optional[CheckpointState]:
        return self._state


def default_checkpoint_path(domain: str) -> Path:
    """Generate default checkpoint filename from domain."""
    safe = domain.replace(".", "_").replace("/", "_")
    return Path(f".{safe}_wayback.ckpt.json")
