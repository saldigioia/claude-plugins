-- ============================================================
-- EXPECTED AUDIT RESULT: Score 9-10/10 (A, archival-grade)
-- Fixture category: compliant
-- Exercises: schema design portion of the archival-data-engine rubric
-- ============================================================
--
-- Compliant pattern for an archival database schema.
-- - Normalized: no duplicated artist names or roles in line rows
-- - Foreign keys declared AND enforced (PRAGMA at connection time)
-- - Slug columns (human-readable URLs), NOT exposing numeric IDs
-- - Dates stored as ISO 8601 TEXT
-- - CHECK constraints on enumerated fields
-- - Indexes on commonly queried columns
-- - Sources / provenance table

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

CREATE TABLE artists (
  id         INTEGER PRIMARY KEY,
  slug       TEXT    NOT NULL UNIQUE,                       -- URL-facing
  name       TEXT    NOT NULL,
  born       TEXT    CHECK (born GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  died       TEXT    CHECK (died IS NULL OR died GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  nationality TEXT
);

CREATE TABLE works (
  id         INTEGER PRIMARY KEY,
  slug       TEXT    NOT NULL UNIQUE,                       -- URL-facing
  title      TEXT    NOT NULL,
  year       INTEGER CHECK (year BETWEEN 1000 AND 2100),
  medium     TEXT    NOT NULL,
  edition    TEXT    CHECK (edition IN ('unique','limited','open','proof')),
  artist_id  INTEGER NOT NULL REFERENCES artists(id) ON DELETE RESTRICT,
  created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE credit_roles (
  role       TEXT    PRIMARY KEY                            -- controlled vocabulary
    CHECK (role IN ('artist','curator','photographer','writer','translator','printer','foundry'))
);

CREATE TABLE credits (
  id         INTEGER PRIMARY KEY,
  work_id    INTEGER NOT NULL REFERENCES works(id)   ON DELETE CASCADE,
  person_id  INTEGER NOT NULL REFERENCES artists(id) ON DELETE RESTRICT,
  role       TEXT    NOT NULL REFERENCES credit_roles(role),
  UNIQUE (work_id, person_id, role)
);

CREATE TABLE sources (
  id           INTEGER PRIMARY KEY,
  work_id      INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
  citation     TEXT    NOT NULL,                            -- human-readable
  url          TEXT,
  accessed_at  TEXT    CHECK (accessed_at IS NULL OR accessed_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*')
);

-- Query indexes
CREATE INDEX idx_works_artist  ON works(artist_id);
CREATE INDEX idx_works_year    ON works(year);
CREATE INDEX idx_credits_work  ON credits(work_id);
CREATE INDEX idx_credits_role  ON credits(role);

-- Seed the role vocabulary
INSERT INTO credit_roles (role) VALUES
  ('artist'),('curator'),('photographer'),
  ('writer'),('translator'),('printer'),('foundry');
