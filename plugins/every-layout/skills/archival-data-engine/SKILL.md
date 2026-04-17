---
name: archival-data-engine
description: "Archival-grade data for Astro: SQLite, libSQL, Astro DB, Drizzle ORM, custom content loaders, schema design. Use for db/config, content.config, loader .ts, .sql, drizzle.config, migrations, metadata, discography, timeline, credits."
allowed-tools: Bash(sqlite3 *) Bash(npx drizzle-kit *) Bash(astro db *) Read Write Edit Grep
paths: ["**/*.db", "**/*.sql", "**/db/**", "**/content.config.*", "**/loaders/**", "**/*loader*.ts", "**/drizzle.config.*"]
---

# Archival Data Engine

Handle archival-grade data for Astro sites: structured databases, typed content loaders, normalized schemas, and data integrity patterns. This skill bridges databases to Astro's Content Layer API.

> **Axiomatic commitment.** This skill's output is consumed at build time (static generation) by default. Axiom **ELA_006** (Archival Durability) governs: rendered pages must still work in five years with no framework upgrade path. Database access in client-side React islands is forbidden by default — always fetch at build, never at runtime, unless registered in `escapes.md` with justification.

---

## Architecture Overview

```
Database (SQLite/libSQL/Astro DB)
    ↓ custom loader
Content Layer (content.config.ts)
    ↓ getCollection() / getEntry()
Astro Pages (src/pages/)
    ↓ layout composition
Rendered HTML
```

The data flows one direction: from structured storage through typed loaders into Astro's collection system, then into pages via the primitives from `css-layout-engine`.

---

## Database Options

| Database | Use Case | Connection |
|----------|----------|------------|
| **SQLite** (better-sqlite3) | Local archival databases, read-only queries | File path, synchronous API |
| **libSQL** (@libsql/client) | SQLite-compatible with remote sync (Turso) | Local file or remote URL |
| **Astro DB** (built-in) | Astro-native database with Drizzle ORM | `db/config.ts` + `astro:db` |
| **Cloudflare D1** | Edge SQLite via Cloudflare Workers | Wrangler bindings or REST API |

### When to Use What

- **SQLite** — You have existing `.db` files with archival data. Read-only at build time.
- **libSQL** — You want SQLite compatibility plus remote sync or replication.
- **Astro DB** — You want database tables defined alongside your Astro project with Drizzle ORM integration.
- **D1** — Deploying to Cloudflare and need edge-accessible structured data.

---

## Astro DB Setup

For full table definitions (Works, Credits, Tracks, Sources), seed-data patterns, query-builder usage, and the common pitfall around column defaults (Astro DB defaults are literal values, not SQL expressions — `default: 'CURRENT_TIMESTAMP'` stores the literal string), see [`references/astro-db-setup.md`](references/astro-db-setup.md).

For SQL-level schema design (normalization, foreign keys, slugs, CHECK constraints, indexes, provenance tables), see [`references/schema-patterns.md`](references/schema-patterns.md).

For Drizzle-specific joins, aggregates, and parameterised queries, see [`references/drizzle-recipes.md`](references/drizzle-recipes.md).

---

## SQLite Integration

### Direct SQLite Queries

```typescript
// src/lib/db.ts
import Database from 'better-sqlite3';

export function getDb(path: string) {
  return new Database(path, { readonly: true });
}

export function queryAll<T>(db: Database.Database, sql: string, params: any[] = []): T[] {
  return db.prepare(sql).all(...params) as T[];
}

export function queryOne<T>(db: Database.Database, sql: string, params: any[] = []): T | undefined {
  return db.prepare(sql).get(...params) as T | undefined;
}
```

### SQLite Content Loader

```typescript
// src/lib/loaders/sqlite-loader.ts
import Database from 'better-sqlite3';
import type { Loader } from 'astro/loaders';

interface SQLiteLoaderOptions {
  dbPath: string;
  query: string;
  idColumn?: string;
  name?: string;
}

export function sqliteLoader(options: SQLiteLoaderOptions): Loader {
  const { dbPath, query, idColumn = 'id', name = 'sqlite' } = options;

  return {
    name,
    load: async ({ store, logger, generateDigest }) => {
      const db = new Database(dbPath, { readonly: true });
      const rows = db.prepare(query).all() as Record<string, any>[];

      store.clear();

      for (const row of rows) {
        const id = String(row[idColumn]);
        const data = { ...row };
        delete data[idColumn];

        store.set({
          id,
          data,
          digest: generateDigest(data),
        });
      }

      logger.info(`[${name}] Loaded ${rows.length} entries`);
      db.close();
    },
  };
}
```

### Using the Loader

```typescript
// content.config.ts
import { defineCollection, z } from 'astro:content';
import { sqliteLoader } from './src/lib/loaders/sqlite-loader';

const works = defineCollection({
  loader: sqliteLoader({
    dbPath: './data/archive.db',
    query: `
      SELECT w.slug, w.title, w.type, w.release_date, w.year, w.description,
             GROUP_CONCAT(DISTINCT c.person || ':' || c.role) as credits
      FROM works w
      LEFT JOIN credits c ON c.work_id = w.id
      GROUP BY w.id
      ORDER BY w.year DESC
    `,
    idColumn: 'slug',
    name: 'works',
  }),
  schema: z.object({
    title: z.string(),
    type: z.enum(['album', 'single', 'ep', 'compilation', 'feature', 'production']),
    release_date: z.string(),
    year: z.number(),
    description: z.string().nullable(),
    credits: z.string().nullable(),
  }),
});

export const collections = { works };
```

> Full loader patterns: `references/custom-loaders.md`

---

## Archival Schema Design

### Core Entities

Every media archive needs these normalized tables:

| Table | Purpose | Key Fields |
|-------|---------|------------|
| `works` | Albums, singles, films, productions | slug, title, type, release_date, year |
| `tracks` | Individual tracks within works | work_id, number, title, duration, isrc |
| `credits` | People and roles on works | work_id, person, role |
| `timeline` | Dated events (releases, performances, milestones) | date, type, title, description |
| `media` | Media assets (images, audio, video) | work_id, type, url, alt_text, caption |
| `sources` | Citation and provenance | work_id, url, name, accessed_date |
| `tags` | Categorization | name |
| `work_tags` | Many-to-many junction | work_id, tag_id |

### Normalization Rules

1. **No data duplication.** Credits, tags, and sources are separate tables with foreign keys.
2. **Slugs, not IDs, in URLs.** The `slug` column is the public identifier; `id` is internal.
3. **Dates as ISO strings.** Store as `TEXT` in `YYYY-MM-DD` format for portability.
4. **Nullable vs. required.** Only make a column NOT NULL if every entry will have a value.
5. **Source everything.** Every fact should trace to a `sources` entry.

### Dublin Core Metadata

For archival completeness, map to Dublin Core where possible:

| Dublin Core | Database Column | Notes |
|-------------|----------------|-------|
| `dc:title` | `works.title` | Primary title |
| `dc:creator` | `credits.person` (role=creator) | Via credits join |
| `dc:date` | `works.release_date` | ISO 8601 |
| `dc:type` | `works.type` | Controlled vocabulary |
| `dc:identifier` | `tracks.isrc` or `works.slug` | Unique identifier |
| `dc:description` | `works.description` | Summary text |
| `dc:source` | `sources.url` | Provenance |

> Full schema patterns: `references/schema-patterns.md`

---

## Drizzle ORM Patterns

Astro DB uses Drizzle ORM under the hood. Key query patterns:

### Select with Joins

```typescript
import { db, Works, Credits, eq } from 'astro:db';

const worksWithCredits = await db
  .select({
    title: Works.title,
    slug: Works.slug,
    year: Works.year,
    person: Credits.person,
    role: Credits.role,
  })
  .from(Works)
  .leftJoin(Credits, eq(Works.id, Credits.work_id))
  .orderBy(Works.year);
```

### Filtering

```typescript
import { db, Works, eq, like, and, gte, lte } from 'astro:db';

// By type
const albums = await db.select().from(Works).where(eq(Works.type, 'album'));

// By year range
const decade = await db.select().from(Works).where(
  and(gte(Works.year, 2010), lte(Works.year, 2019))
);

// By title search
const matches = await db.select().from(Works).where(
  like(Works.title, '%graduation%')
);
```

### Aggregation

```typescript
import { db, Works, Credits, eq, count, sql } from 'astro:db';

// Count works per type
const typeCounts = await db
  .select({
    type: Works.type,
    count: count(),
  })
  .from(Works)
  .groupBy(Works.type);

// Count credits per work
const creditCounts = await db
  .select({
    title: Works.title,
    creditCount: count(Credits.id),
  })
  .from(Works)
  .leftJoin(Credits, eq(Works.id, Credits.work_id))
  .groupBy(Works.id);
```

> Full Drizzle recipes: `references/drizzle-recipes.md`

---

## Data Integrity

### Foreign Keys

Always enable foreign keys in SQLite:

```typescript
const db = new Database(path, { readonly: true });
db.pragma('foreign_keys = ON');
```

### Validation at Build Time

Zod schemas in `content.config.ts` validate data during `astro build`. Invalid data causes clear build errors — this is your data integrity gate.

### Migration Patterns

```sql
-- Always use IF NOT EXISTS for idempotent migrations
CREATE TABLE IF NOT EXISTS works (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slug TEXT UNIQUE NOT NULL,
  title TEXT NOT NULL,
  type TEXT NOT NULL CHECK(type IN ('album','single','ep','compilation','feature','production')),
  release_date TEXT NOT NULL,
  year INTEGER NOT NULL
);

-- Add columns safely
ALTER TABLE works ADD COLUMN description TEXT;

-- Create indexes for common queries
CREATE INDEX IF NOT EXISTS idx_works_year ON works(year);
CREATE INDEX IF NOT EXISTS idx_works_type ON works(type);
CREATE INDEX IF NOT EXISTS idx_credits_work_id ON credits(work_id);
```

### Backup Before Mutations

```bash
# Always backup before any write operation
cp archive.db "archive.db.bak.$(date +%Y%m%d_%H%M%S)"
```

> Full integrity patterns: `references/data-integrity.md`

---

## Connecting Collections to Pages

### Archive Index Page

```astro
---
// src/pages/music/index.astro
import { getCollection } from 'astro:content';
import Archive from '../../layouts/Archive.astro';
import Card from '../../components/ui/Card.astro';

const works = (await getCollection('works'))
  .sort((a, b) => b.data.year - a.data.year);

const types = [...new Set(works.map(w => w.data.type))];
---

<Archive title="Discography" description="Complete works archive">
  {types.map(type => (
    <section class="stack">
      <h2>{type}s</h2>
      <div class="grid" style="--min: 18rem">
        {works
          .filter(w => w.data.type === type)
          .map(work => <Card work={work} />)}
      </div>
    </section>
  ))}
</Archive>
```

### Single Work Page

```astro
---
// src/pages/music/[slug].astro
import { getCollection } from 'astro:content';
import Article from '../../layouts/Article.astro';

export async function getStaticPaths() {
  const works = await getCollection('works');
  return works.map(work => ({
    params: { slug: work.id },
    props: { work },
  }));
}

const { work } = Astro.props;
---

<Article title={work.data.title}>
  <dl class="cluster">
    <div><dt>Year</dt><dd>{work.data.year}</dd></div>
    <div><dt>Type</dt><dd>{work.data.type}</dd></div>
    <div><dt>Released</dt><dd>{work.data.release_date}</dd></div>
  </dl>
  {work.data.description && <p>{work.data.description}</p>}
</Article>
```

---

## Reference Files

- `references/schema-patterns.md` — Canonical database schemas for archival content types
- `references/custom-loaders.md` — Complete examples of SQLite-to-Astro content loaders
- `references/drizzle-recipes.md` — Common Drizzle ORM query patterns for archival data
- `references/data-integrity.md` — Migration, backup, and validation patterns

---

*For Astro project structure and routing, see the **astro-site-architect** skill.*
*For CSS layout primitives, see the **css-layout-engine** skill.*
