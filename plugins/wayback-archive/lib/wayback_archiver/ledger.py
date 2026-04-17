"""
SQLite ledger — single source of truth for Protocol I/II/III/IV/V accounting.

Located at `<project_dir>/ledger.db`. Four tables, mirroring
IMPROVEMENT_PLAN.md §II exactly:

  - discovery_surfaces  — feeds, sitemaps, collections, JSONs we've seen
  - entities            — product slugs (resolved or referenced-only)
  - hosts               — every hostname we know about
  - fetch_attempts      — per-URL fetch log for Protocol IV retry_queue_depth

All writes are parameterized; no ORM. The ledger is optional for basic
pipeline operation — writes in the orchestrator are guarded so a missing
or corrupt DB never blocks a stage. When present, the ledger provides
exact counts for the five audit integers; when absent, scripts/audit.py
falls back to disk scanning.

Convention: timestamps are ISO-8601 UTC with seconds precision. NULL
timestamps mean "not yet" (Protocol II: `parsed_at IS NULL` = unexpanded).
"""
from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Iterator

SCHEMA_VERSION = 1

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS discovery_surfaces (
    url            TEXT PRIMARY KEY,
    host           TEXT NOT NULL,
    surface_class  TEXT NOT NULL,
    fetched_at     TEXT,
    parsed_at      TEXT,
    parse_status   TEXT,
    outlink_count  INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_surfaces_host ON discovery_surfaces(host);
CREATE INDEX IF NOT EXISTS idx_surfaces_parsed ON discovery_surfaces(parsed_at);
CREATE INDEX IF NOT EXISTS idx_surfaces_class ON discovery_surfaces(surface_class);

CREATE TABLE IF NOT EXISTS entities (
    slug           TEXT NOT NULL,
    host           TEXT NOT NULL,
    canonical_url  TEXT,
    resolved_at    TEXT,
    first_seen_in  TEXT,
    PRIMARY KEY (slug, host)
);
CREATE INDEX IF NOT EXISTS idx_entities_resolved ON entities(resolved_at);
CREATE INDEX IF NOT EXISTS idx_entities_host ON entities(host);

CREATE TABLE IF NOT EXISTS hosts (
    host               TEXT PRIMARY KEY,
    cdx_dumped_at      TEXT,
    product_pattern    TEXT,
    coverage_estimate  REAL
);

CREATE TABLE IF NOT EXISTS fetch_attempts (
    url           TEXT NOT NULL,
    attempted_at  TEXT NOT NULL,
    status        INTEGER,
    failure_class TEXT,
    retry_after   TEXT,
    PRIMARY KEY (url, attempted_at)
);
CREATE INDEX IF NOT EXISTS idx_attempts_failure ON fetch_attempts(failure_class);
CREATE INDEX IF NOT EXISTS idx_attempts_url ON fetch_attempts(url);
"""

# Failure classes that are retriable per IMPROVEMENT_PLAN phase B4.
RETRIABLE_FAILURE_CLASSES = frozenset({"throttle", "network", "http_5xx"})
TERMINAL_FAILURE_CLASSES = frozenset({"http_404", "parse"})


# ── Helpers ──────────────────────────────────────────────────────────────────

def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def ledger_path(project_dir: Path | str) -> Path:
    return Path(project_dir) / "ledger.db"


def exists(project_dir: Path | str) -> bool:
    return ledger_path(project_dir).exists()


@contextmanager
def connect(project_dir: Path | str) -> Iterator[sqlite3.Connection]:
    """Open a ledger connection with sensible pragmas.

    Commits on context exit (or rolls back on exception). Callers may also
    commit manually during long batches to amortize fsyncs.
    """
    path = ledger_path(project_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA synchronous = NORMAL")
    try:
        yield conn
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


def init(project_dir: Path | str) -> Path:
    """Create the ledger schema. Idempotent; safe to call repeatedly."""
    path = ledger_path(project_dir)
    with connect(project_dir) as conn:
        conn.executescript(SCHEMA_SQL)
        row = conn.execute("SELECT version FROM schema_version").fetchone()
        if row is None:
            conn.execute("INSERT INTO schema_version(version) VALUES (?)", (SCHEMA_VERSION,))
    return path


# ── Hosts ────────────────────────────────────────────────────────────────────

def upsert_host(conn: sqlite3.Connection, host: str, *,
                product_pattern: str | None = None) -> None:
    conn.execute(
        """
        INSERT INTO hosts(host, product_pattern)
        VALUES (?, ?)
        ON CONFLICT(host) DO UPDATE SET
            product_pattern = COALESCE(excluded.product_pattern, hosts.product_pattern)
        """,
        (host, product_pattern),
    )


def upsert_hosts(conn: sqlite3.Connection, hosts: Iterable[str]) -> int:
    rows = [(h,) for h in hosts]
    conn.executemany("INSERT OR IGNORE INTO hosts(host) VALUES (?)", rows)
    return len(rows)


def mark_host_dumped(conn: sqlite3.Connection, host: str,
                     dumped_at: str | None = None) -> None:
    conn.execute(
        "UPDATE hosts SET cdx_dumped_at = ? WHERE host = ?",
        (dumped_at or _now(), host),
    )


# ── Entities ─────────────────────────────────────────────────────────────────

def upsert_entity(conn: sqlite3.Connection, slug: str, host: str, *,
                  canonical_url: str | None = None,
                  first_seen_in: str | None = None) -> None:
    conn.execute(
        """
        INSERT INTO entities(slug, host, canonical_url, first_seen_in)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(slug, host) DO UPDATE SET
            canonical_url = COALESCE(excluded.canonical_url, entities.canonical_url),
            first_seen_in = COALESCE(entities.first_seen_in, excluded.first_seen_in)
        """,
        (slug, host, canonical_url, first_seen_in),
    )


def upsert_entities(conn: sqlite3.Connection,
                    rows: Iterable[tuple[str, str, str | None, str | None]]) -> int:
    """Bulk upsert. rows: (slug, host, canonical_url, first_seen_in)."""
    data = list(rows)
    conn.executemany(
        """
        INSERT INTO entities(slug, host, canonical_url, first_seen_in)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(slug, host) DO UPDATE SET
            canonical_url = COALESCE(excluded.canonical_url, entities.canonical_url),
            first_seen_in = COALESCE(entities.first_seen_in, excluded.first_seen_in)
        """,
        data,
    )
    return len(data)


def mark_entity_resolved(conn: sqlite3.Connection, slug: str, host: str,
                         resolved_at: str | None = None) -> None:
    conn.execute(
        "UPDATE entities SET resolved_at = ? WHERE slug = ? AND host = ?",
        (resolved_at or _now(), slug, host),
    )


# ── Discovery surfaces ───────────────────────────────────────────────────────

def upsert_surface(conn: sqlite3.Connection, url: str, host: str,
                   surface_class: str) -> None:
    conn.execute(
        """
        INSERT INTO discovery_surfaces(url, host, surface_class)
        VALUES (?, ?, ?)
        ON CONFLICT(url) DO UPDATE SET
            host = excluded.host,
            surface_class = excluded.surface_class
        """,
        (url, host, surface_class),
    )


def mark_surface_fetched(conn: sqlite3.Connection, url: str,
                         fetched_at: str | None = None) -> None:
    conn.execute(
        "UPDATE discovery_surfaces SET fetched_at = ? WHERE url = ?",
        (fetched_at or _now(), url),
    )


def mark_surface_parsed(conn: sqlite3.Connection, url: str,
                        outlink_count: int,
                        parse_status: str = "ok",
                        parsed_at: str | None = None) -> None:
    conn.execute(
        """
        UPDATE discovery_surfaces
        SET parsed_at = ?, outlink_count = ?, parse_status = ?
        WHERE url = ?
        """,
        (parsed_at or _now(), outlink_count, parse_status, url),
    )


# ── Fetch attempts ───────────────────────────────────────────────────────────

def record_fetch(conn: sqlite3.Connection, url: str, status: int,
                 failure_class: str, *,
                 retry_after: str | None = None,
                 attempted_at: str | None = None) -> None:
    conn.execute(
        """
        INSERT OR REPLACE INTO fetch_attempts(
            url, attempted_at, status, failure_class, retry_after
        ) VALUES (?, ?, ?, ?, ?)
        """,
        (url, attempted_at or _now(), status, failure_class, retry_after),
    )


# ── Audit count helpers ──────────────────────────────────────────────────────

def count_unresolved_slugs(conn: sqlite3.Connection) -> int:
    return conn.execute(
        "SELECT COUNT(*) FROM entities WHERE resolved_at IS NULL"
    ).fetchone()[0]


def count_unexpanded_surfaces(conn: sqlite3.Connection) -> int:
    return conn.execute(
        "SELECT COUNT(*) FROM discovery_surfaces WHERE parsed_at IS NULL"
    ).fetchone()[0]


def count_unenumerated_hosts(conn: sqlite3.Connection) -> int:
    return conn.execute(
        "SELECT COUNT(*) FROM hosts WHERE cdx_dumped_at IS NULL"
    ).fetchone()[0]


def count_retry_queue_depth(conn: sqlite3.Connection) -> int:
    """Count URLs whose most-recent attempt is a retriable failure with no success."""
    q = """
    WITH latest AS (
        SELECT url, failure_class,
               ROW_NUMBER() OVER (PARTITION BY url ORDER BY attempted_at DESC) AS rn
        FROM fetch_attempts
    )
    SELECT COUNT(*) FROM latest WHERE rn = 1 AND failure_class IN ({})
    """.format(",".join("?" * len(RETRIABLE_FAILURE_CLASSES)))
    return conn.execute(q, tuple(RETRIABLE_FAILURE_CLASSES)).fetchone()[0]


def count_resolved_entities(conn: sqlite3.Connection) -> int:
    return conn.execute(
        "SELECT COUNT(*) FROM entities WHERE resolved_at IS NOT NULL"
    ).fetchone()[0]


def count_entities(conn: sqlite3.Connection) -> int:
    return conn.execute("SELECT COUNT(*) FROM entities").fetchone()[0]


def count_hosts(conn: sqlite3.Connection) -> int:
    return conn.execute("SELECT COUNT(*) FROM hosts").fetchone()[0]


def count_surfaces(conn: sqlite3.Connection) -> int:
    return conn.execute("SELECT COUNT(*) FROM discovery_surfaces").fetchone()[0]


# ── Exemplar queries (for audit residual reporting) ──────────────────────────

def exemplar_unresolved_slugs(conn: sqlite3.Connection, limit: int = 20) -> list[str]:
    rows = conn.execute(
        "SELECT slug FROM entities WHERE resolved_at IS NULL ORDER BY slug LIMIT ?",
        (limit,),
    ).fetchall()
    return [r[0] for r in rows]


def exemplar_unexpanded_surfaces(conn: sqlite3.Connection, limit: int = 20) -> list[str]:
    rows = conn.execute(
        "SELECT url FROM discovery_surfaces WHERE parsed_at IS NULL ORDER BY url LIMIT ?",
        (limit,),
    ).fetchall()
    return [r[0] for r in rows]


def exemplar_unenumerated_hosts(conn: sqlite3.Connection, limit: int = 20) -> list[str]:
    rows = conn.execute(
        "SELECT host FROM hosts WHERE cdx_dumped_at IS NULL ORDER BY host LIMIT ?",
        (limit,),
    ).fetchall()
    return [r[0] for r in rows]


def exemplar_retry_queue(conn: sqlite3.Connection, limit: int = 20) -> list[str]:
    q = """
    WITH latest AS (
        SELECT url, failure_class,
               ROW_NUMBER() OVER (PARTITION BY url ORDER BY attempted_at DESC) AS rn
        FROM fetch_attempts
    )
    SELECT url FROM latest WHERE rn = 1 AND failure_class IN ({})
    ORDER BY url LIMIT ?
    """.format(",".join("?" * len(RETRIABLE_FAILURE_CLASSES)))
    params = tuple(RETRIABLE_FAILURE_CLASSES) + (limit,)
    rows = conn.execute(q, params).fetchall()
    return [r[0] for r in rows]


# ── Convenience: five-question audit snapshot ───────────────────────────────

def audit_snapshot(conn: sqlite3.Connection, exemplar_cap: int = 20) -> dict:
    """Return the Protocol IV five-integer audit + raw counts + exemplars."""
    integers = {
        "unresolved_slugs": count_unresolved_slugs(conn),
        "unexpanded_surfaces": count_unexpanded_surfaces(conn),
        "index_missing": 0,  # derived by caller against disk (needs image check)
        "unenumerated_hosts": count_unenumerated_hosts(conn),
        "retry_queue_depth": count_retry_queue_depth(conn),
    }
    raw = {
        "entities_total": count_entities(conn),
        "entities_resolved": count_resolved_entities(conn),
        "hosts_total": count_hosts(conn),
        "surfaces_total": count_surfaces(conn),
    }
    exemplars = {
        "unresolved_slugs": exemplar_unresolved_slugs(conn, exemplar_cap),
        "unexpanded_surfaces": exemplar_unexpanded_surfaces(conn, exemplar_cap),
        "unenumerated_hosts": exemplar_unenumerated_hosts(conn, exemplar_cap),
        "retry_queue_depth": exemplar_retry_queue(conn, exemplar_cap),
    }
    return {"integers": integers, "raw_counts": raw, "exemplars": exemplars}


__all__ = [
    "SCHEMA_VERSION",
    "RETRIABLE_FAILURE_CLASSES",
    "TERMINAL_FAILURE_CLASSES",
    "ledger_path",
    "exists",
    "connect",
    "init",
    "upsert_host",
    "upsert_hosts",
    "mark_host_dumped",
    "upsert_entity",
    "upsert_entities",
    "mark_entity_resolved",
    "upsert_surface",
    "mark_surface_fetched",
    "mark_surface_parsed",
    "record_fetch",
    "count_unresolved_slugs",
    "count_unexpanded_surfaces",
    "count_unenumerated_hosts",
    "count_retry_queue_depth",
    "count_resolved_entities",
    "count_entities",
    "count_hosts",
    "count_surfaces",
    "exemplar_unresolved_slugs",
    "exemplar_unexpanded_surfaces",
    "exemplar_unenumerated_hosts",
    "exemplar_retry_queue",
    "audit_snapshot",
]
