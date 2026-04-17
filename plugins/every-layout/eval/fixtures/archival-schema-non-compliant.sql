-- ============================================================
-- EXPECTED AUDIT RESULT: Score 2-4/10 (D-F)
-- Fixture category: anti-pattern
-- Exercises: schema design portion of the archival-data-engine rubric
-- ============================================================
--
-- VIOLATION: PRAGMA foreign_keys not enabled (SQLite default is OFF)
-- VIOLATION: no slug columns — URLs would expose numeric IDs
-- VIOLATION: denormalized — artist name and role duplicated on every row
-- VIOLATION: dates stored as INTEGER unix timestamps (loses precision, non-portable)
-- VIOLATION: no CHECK constraints on enumerated fields
-- VIOLATION: no foreign-key declarations
-- VIOLATION: no indexes — every query is a full table scan
-- VIOLATION: no provenance table — sources are inline free text in the same row

CREATE TABLE works (
  id             INTEGER PRIMARY KEY,
  -- no slug column
  title          TEXT,                       -- nullable; archival data should be titled
  year           INTEGER,                    -- no range check
  medium         TEXT,
  edition        TEXT,                       -- any string; no controlled vocabulary
  artist_name    TEXT,                       -- DENORMALIZED: duplicated across works
  artist_born    INTEGER,                    -- unix timestamp, lossy for archival dates
  artist_died    INTEGER,
  curator_name   TEXT,                       -- DENORMALIZED
  curator_role   TEXT,                       -- no enum; any string accepted
  source_note    TEXT,                       -- free text source citation in the row
  photographer   TEXT,                       -- DENORMALIZED
  created_at     INTEGER                     -- unix timestamp
);

-- no indexes
-- no foreign keys
-- no PRAGMA foreign_keys = ON
-- no provenance table
-- no credit_roles vocabulary table

-- Typical anti-pattern: a second "works_backup" table as a poor-man's history
CREATE TABLE works_backup (
  id             INTEGER,
  snapshot_json  TEXT                        -- opaque blob, un-queryable
);
