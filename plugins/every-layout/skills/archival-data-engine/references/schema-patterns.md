# Schema Patterns — Archival Content Types

Canonical database schemas for media archive sites. All schemas use SQLite-compatible SQL with strict typing.

---

## Core Tables

### works

The central entity. Every archival item is a "work."

```sql
CREATE TABLE works (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slug TEXT UNIQUE NOT NULL,
  title TEXT NOT NULL,
  type TEXT NOT NULL CHECK(type IN (
    'album', 'single', 'ep', 'compilation',
    'feature', 'production', 'film', 'video',
    'performance', 'interview', 'article'
  )),
  release_date TEXT NOT NULL,      -- ISO 8601: YYYY-MM-DD
  year INTEGER NOT NULL,
  description TEXT,
  cover_url TEXT,
  external_id TEXT,                -- Discogs ID, MusicBrainz MBID, etc.
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX idx_works_year ON works(year);
CREATE INDEX idx_works_type ON works(type);
CREATE INDEX idx_works_slug ON works(slug);
CREATE INDEX idx_works_release_date ON works(release_date);
```

**Design notes:**
- `slug` is the public URL identifier — never expose `id` in URLs.
- `type` uses a CHECK constraint for a controlled vocabulary.
- `release_date` is TEXT not DATE — SQLite has no native date type, and ISO strings sort correctly.
- `year` is denormalized from `release_date` for fast year-based queries and grouping.

### tracks

Individual tracks within a work.

```sql
CREATE TABLE tracks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
  disc_number INTEGER DEFAULT 1,
  track_number INTEGER NOT NULL,
  title TEXT NOT NULL,
  duration_seconds INTEGER,
  isrc TEXT,                       -- International Standard Recording Code
  notes TEXT,
  UNIQUE(work_id, disc_number, track_number)
);

CREATE INDEX idx_tracks_work_id ON tracks(work_id);
```

### credits

People and their roles on works. Normalized — one row per person per role per work.

```sql
CREATE TABLE credits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
  track_id INTEGER REFERENCES tracks(id) ON DELETE CASCADE,  -- NULL = work-level credit
  person TEXT NOT NULL,
  role TEXT NOT NULL CHECK(role IN (
    'artist', 'producer', 'writer', 'composer', 'lyricist',
    'featured', 'engineer', 'mixer', 'mastering',
    'director', 'cinematographer', 'editor',
    'designer', 'photographer', 'interviewer'
  )),
  notes TEXT
);

CREATE INDEX idx_credits_work_id ON credits(work_id);
CREATE INDEX idx_credits_person ON credits(person);
CREATE INDEX idx_credits_role ON credits(role);
```

**Design notes:**
- `track_id` is optional — NULL means the credit applies to the entire work.
- `person` is plain text, not a foreign key to a `people` table. This is intentional for archival data where the same person may appear under different names across sources. Normalization to a `people` table can happen later.

### timeline

Dated events: releases, performances, milestones, appearances.

```sql
CREATE TABLE timeline (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  date TEXT NOT NULL,               -- YYYY-MM-DD (partial dates OK: YYYY or YYYY-MM)
  date_precision TEXT NOT NULL DEFAULT 'day' CHECK(date_precision IN ('year', 'month', 'day')),
  type TEXT NOT NULL CHECK(type IN (
    'release', 'performance', 'award', 'milestone',
    'announcement', 'appearance', 'controversy', 'other'
  )),
  title TEXT NOT NULL,
  description TEXT,
  work_id INTEGER REFERENCES works(id),  -- Optional link to a work
  location TEXT,
  source_url TEXT
);

CREATE INDEX idx_timeline_date ON timeline(date);
CREATE INDEX idx_timeline_type ON timeline(type);
CREATE INDEX idx_timeline_work_id ON timeline(work_id);
```

**Design notes:**
- `date_precision` handles partial dates. Some events are known only to a year or month.
- `work_id` is optional — not all events relate to a specific work.

---

## Supporting Tables

### media

Media assets associated with works.

```sql
CREATE TABLE media (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  work_id INTEGER REFERENCES works(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK(type IN ('image', 'audio', 'video', 'document')),
  url TEXT NOT NULL,
  alt_text TEXT,
  caption TEXT,
  mime_type TEXT,
  width INTEGER,
  height INTEGER,
  duration_seconds INTEGER,
  sort_order INTEGER DEFAULT 0
);

CREATE INDEX idx_media_work_id ON media(work_id);
CREATE INDEX idx_media_type ON media(type);
```

### sources

Provenance tracking — where data came from.

```sql
CREATE TABLE sources (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  work_id INTEGER REFERENCES works(id) ON DELETE CASCADE,
  url TEXT NOT NULL,
  name TEXT NOT NULL,              -- "Wikipedia", "Discogs", "AllMusic", etc.
  accessed_date TEXT NOT NULL,     -- When we captured this data
  archived_url TEXT,               -- Wayback Machine / archive.org URL
  notes TEXT
);

CREATE INDEX idx_sources_work_id ON sources(work_id);
```

### tags

Flexible categorization via many-to-many relationship.

```sql
CREATE TABLE tags (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT UNIQUE NOT NULL,
  slug TEXT UNIQUE NOT NULL
);

CREATE TABLE work_tags (
  work_id INTEGER NOT NULL REFERENCES works(id) ON DELETE CASCADE,
  tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  PRIMARY KEY (work_id, tag_id)
);

CREATE INDEX idx_work_tags_tag_id ON work_tags(tag_id);
```

---

## Full-Text Search

SQLite FTS5 for search across works and tracks:

```sql
CREATE VIRTUAL TABLE works_fts USING fts5(
  title,
  description,
  content=works,
  content_rowid=id
);

-- Populate FTS index
INSERT INTO works_fts(rowid, title, description)
SELECT id, title, description FROM works;

-- Search
SELECT w.* FROM works w
JOIN works_fts fts ON w.id = fts.rowid
WHERE works_fts MATCH 'graduation'
ORDER BY rank;
```

---

## Schema for Astro DB

The same schema expressed as Astro DB table definitions:

```typescript
// db/config.ts
import { defineDb, defineTable, column } from 'astro:db';

const Works = defineTable({
  columns: {
    id: column.number({ primaryKey: true }),
    slug: column.text({ unique: true }),
    title: column.text(),
    type: column.text(),
    release_date: column.text(),
    year: column.number(),
    description: column.text({ optional: true }),
    cover_url: column.text({ optional: true }),
    external_id: column.text({ optional: true }),
  },
});

const Tracks = defineTable({
  columns: {
    id: column.number({ primaryKey: true }),
    work_id: column.number({ references: () => Works.columns.id }),
    disc_number: column.number({ default: 1 }),
    track_number: column.number(),
    title: column.text(),
    duration_seconds: column.number({ optional: true }),
    isrc: column.text({ optional: true }),
  },
});

const Credits = defineTable({
  columns: {
    id: column.number({ primaryKey: true }),
    work_id: column.number({ references: () => Works.columns.id }),
    track_id: column.number({ optional: true, references: () => Tracks.columns.id }),
    person: column.text(),
    role: column.text(),
    notes: column.text({ optional: true }),
  },
});

const Timeline = defineTable({
  columns: {
    id: column.number({ primaryKey: true }),
    date: column.text(),
    date_precision: column.text({ default: 'day' }),
    type: column.text(),
    title: column.text(),
    description: column.text({ optional: true }),
    work_id: column.number({ optional: true, references: () => Works.columns.id }),
    location: column.text({ optional: true }),
  },
});

const Sources = defineTable({
  columns: {
    id: column.number({ primaryKey: true }),
    work_id: column.number({ optional: true, references: () => Works.columns.id }),
    url: column.text(),
    name: column.text(),
    accessed_date: column.text(),
    archived_url: column.text({ optional: true }),
  },
});

const Tags = defineTable({
  columns: {
    id: column.number({ primaryKey: true }),
    name: column.text({ unique: true }),
    slug: column.text({ unique: true }),
  },
});

const WorkTags = defineTable({
  columns: {
    work_id: column.number({ references: () => Works.columns.id }),
    tag_id: column.number({ references: () => Tags.columns.id }),
  },
});

export default defineDb({
  tables: { Works, Tracks, Credits, Timeline, Sources, Tags, WorkTags },
});
```

---

## Zod Schemas for Content Collections

Corresponding Zod schemas for validating loader output:

```typescript
import { z } from 'astro:content';

export const workSchema = z.object({
  title: z.string(),
  type: z.enum(['album', 'single', 'ep', 'compilation', 'feature', 'production']),
  release_date: z.string().regex(/^\d{4}(-\d{2}(-\d{2})?)?$/),
  year: z.number().int().min(1900).max(2100),
  description: z.string().nullable().default(null),
  cover_url: z.string().url().nullable().default(null),
});

export const trackSchema = z.object({
  work_slug: z.string(),
  disc_number: z.number().int().default(1),
  track_number: z.number().int(),
  title: z.string(),
  duration_seconds: z.number().int().nullable().default(null),
  isrc: z.string().nullable().default(null),
});

export const creditSchema = z.object({
  work_slug: z.string(),
  person: z.string(),
  role: z.string(),
  notes: z.string().nullable().default(null),
});

export const timelineSchema = z.object({
  date: z.string(),
  date_precision: z.enum(['year', 'month', 'day']).default('day'),
  type: z.string(),
  title: z.string(),
  description: z.string().nullable().default(null),
  work_slug: z.string().nullable().default(null),
  location: z.string().nullable().default(null),
});
```
