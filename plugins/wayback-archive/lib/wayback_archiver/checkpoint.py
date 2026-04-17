"""
Generic checkpoint/resume for pipeline stages.

Replaces 7 hand-coded checkpoint implementations with a single class
that uses atomic writes (tmp + rename) for crash safety.
"""
from __future__ import annotations

import json
import logging
import os
import tempfile
from pathlib import Path

log = logging.getLogger(__name__)


class StageCheckpoint:
    """
    Manages a set-based checkpoint for any pipeline stage.

    Tracks which items (slugs, SKUs, etc.) have been processed.
    Supports an optional secondary set (e.g. "exhausted" for items
    that were fully checked but yielded no results).
    """

    def __init__(self, path: Path, stage: str = ""):
        self.path = Path(path)
        self.stage = stage
        self._completed: set[str] = set()
        self._exhausted: set[str] = set()

    def load(self) -> None:
        """Load checkpoint from disk."""
        if not self.path.exists():
            return
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            self._completed = set(data.get("completed", []))
            self._exhausted = set(data.get("exhausted", []))
            log.info(
                "Checkpoint loaded (%s): %d completed, %d exhausted",
                self.stage or self.path.name,
                len(self._completed),
                len(self._exhausted),
            )
        except (json.JSONDecodeError, KeyError, TypeError) as e:
            log.warning("Corrupt checkpoint %s: %s — starting fresh", self.path, e)
            self._completed = set()
            self._exhausted = set()

    def save(self) -> None:
        """Persist checkpoint atomically (tmp + rename)."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(
            dir=str(self.path.parent),
            prefix=".ckpt_",
            suffix=".tmp",
        )
        try:
            data = {
                "stage": self.stage,
                "completed": sorted(self._completed),
                "exhausted": sorted(self._exhausted),
            }
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(json.dumps(data, indent=2))
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_path, str(self.path))
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise

    @property
    def completed(self) -> set[str]:
        return self._completed

    @property
    def exhausted(self) -> set[str]:
        return self._exhausted

    def is_done(self, key: str) -> bool:
        return key in self._completed or key in self._exhausted

    def mark_done(self, key: str) -> None:
        self._completed.add(key)
        self.save()

    def mark_exhausted(self, key: str) -> None:
        self._exhausted.add(key)
        self.save()

    def remaining(self, all_keys: set[str]) -> set[str]:
        return all_keys - self._completed - self._exhausted

    def delete(self) -> None:
        if self.path.exists():
            self.path.unlink()
