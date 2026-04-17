-- Archive Site Schema
-- SQLite database for archival content

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS works (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slug TEXT UNIQUE NOT NULL,
  title TEXT NOT NULL,
  type TEXT NOT NULL CHECK(type IN ('album', 'single', 'ep', 'compilation', 'feature', 'production')),
  release_date TEXT NOT NULL,
  year INTEGER NOT NULL,
  description TEXT,
  cover_url TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS tracks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
  disc_number INTEGER DEFAULT 1,
  track_number INTEGER NOT NULL,
  title TEXT NOT NULL,
  duration_seconds INTEGER,
  UNIQUE(work_id, disc_number, track_number)
);

CREATE TABLE IF NOT EXISTS credits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
  person TEXT NOT NULL,
  role TEXT NOT NULL,
  notes TEXT
);

CREATE TABLE IF NOT EXISTS sources (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  work_id INTEGER REFERENCES works(id) ON DELETE CASCADE,
  url TEXT NOT NULL,
  name TEXT NOT NULL,
  accessed_date TEXT NOT NULL,
  archived_url TEXT
);

CREATE INDEX IF NOT EXISTS idx_works_year ON works(year);
CREATE INDEX IF NOT EXISTS idx_works_type ON works(type);
CREATE INDEX IF NOT EXISTS idx_tracks_work_id ON tracks(work_id);
CREATE INDEX IF NOT EXISTS idx_credits_work_id ON credits(work_id);
CREATE INDEX IF NOT EXISTS idx_credits_person ON credits(person);

-- Seed data
INSERT OR IGNORE INTO works (slug, title, type, release_date, year, description) VALUES
  ('the-college-dropout', 'The College Dropout', 'album', '2004-02-10', 2004, 'Debut studio album.'),
  ('late-registration', 'Late Registration', 'album', '2005-08-30', 2005, 'Second studio album.'),
  ('graduation', 'Graduation', 'album', '2007-09-11', 2007, 'Third studio album.');

INSERT OR IGNORE INTO tracks (work_id, disc_number, track_number, title, duration_seconds) VALUES
  (1, 1, 1, 'We Don''t Care', 228),
  (1, 1, 2, 'Graduation Day', 76),
  (1, 1, 3, 'All Falls Down', 225),
  (2, 1, 1, 'Wake Up Mr. West', 51),
  (2, 1, 2, 'Heard ''Em Say', 223),
  (3, 1, 1, 'Good Morning', 192),
  (3, 1, 2, 'Champion', 170);

INSERT OR IGNORE INTO credits (work_id, person, role) VALUES
  (1, 'Kanye West', 'artist'),
  (1, 'Kanye West', 'producer'),
  (2, 'Kanye West', 'artist'),
  (2, 'Jon Brion', 'producer'),
  (3, 'Kanye West', 'artist'),
  (3, 'Kanye West', 'producer');
