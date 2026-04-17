# Custom Content Loaders — Complete Examples

Custom loaders bridge external data sources to Astro's Content Layer API.

---

## Loader Interface

```typescript
interface Loader {
  name: string;
  load: (context: LoaderContext) => Promise<void>;
  schema?: ZodSchema;
}

interface LoaderContext {
  store: DataStore;
  meta: Record<string, string>;   // Persistent metadata between builds
  logger: AstroIntegrationLogger;
  config: AstroConfig;
  parseData: (props: { id: string; data: unknown }) => Promise<any>;
  generateDigest: (data: Record<string, unknown>) => string;
}

interface DataStore {
  set: (entry: { id: string; data: Record<string, any>; body?: string; rendered?: { html: string }; digest?: string }) => void;
  get: (id: string) => any;
  delete: (id: string) => void;
  clear: () => void;
  keys: () => string[];
  values: () => any[];
  entries: () => [string, any][];
  has: (id: string) => boolean;
}
```

---

## SQLite Loader — Basic

Loads all rows from a single table.

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
      db.pragma('foreign_keys = ON');

      try {
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
      } finally {
        db.close();
      }
    },
  };
}
```

### Usage

```typescript
// content.config.ts
import { defineCollection, z } from 'astro:content';
import { sqliteLoader } from './src/lib/loaders/sqlite-loader';

const works = defineCollection({
  loader: sqliteLoader({
    dbPath: './data/archive.db',
    query: 'SELECT slug, title, type, release_date, year, description FROM works ORDER BY year DESC',
    idColumn: 'slug',
    name: 'works',
  }),
  schema: z.object({
    title: z.string(),
    type: z.string(),
    release_date: z.string(),
    year: z.number(),
    description: z.string().nullable(),
  }),
});

export const collections = { works };
```

---

## SQLite Loader — With Joins

Loads works with their credits aggregated.

```typescript
// src/lib/loaders/works-loader.ts
import Database from 'better-sqlite3';
import type { Loader } from 'astro/loaders';

interface WorksLoaderOptions {
  dbPath: string;
}

export function worksLoader({ dbPath }: WorksLoaderOptions): Loader {
  return {
    name: 'works-with-credits',
    load: async ({ store, logger, generateDigest }) => {
      const db = new Database(dbPath, { readonly: true });
      db.pragma('foreign_keys = ON');

      try {
        // Load works
        const works = db.prepare(`
          SELECT slug, title, type, release_date, year, description, cover_url
          FROM works ORDER BY year DESC
        `).all() as Record<string, any>[];

        // Load credits grouped by work
        const creditsByWork = new Map<number, any[]>();
        const allCredits = db.prepare(`
          SELECT c.work_id, c.person, c.role, c.notes, w.slug as work_slug
          FROM credits c
          JOIN works w ON w.id = c.work_id
          ORDER BY c.role, c.person
        `).all() as Record<string, any>[];

        for (const credit of allCredits) {
          const slug = credit.work_slug;
          if (!creditsByWork.has(slug)) creditsByWork.set(slug, []);
          creditsByWork.get(slug)!.push({
            person: credit.person,
            role: credit.role,
            notes: credit.notes,
          });
        }

        // Load tracks grouped by work
        const tracksByWork = new Map<string, any[]>();
        const allTracks = db.prepare(`
          SELECT t.work_id, t.disc_number, t.track_number, t.title,
                 t.duration_seconds, t.isrc, w.slug as work_slug
          FROM tracks t
          JOIN works w ON w.id = t.work_id
          ORDER BY t.disc_number, t.track_number
        `).all() as Record<string, any>[];

        for (const track of allTracks) {
          const slug = track.work_slug;
          if (!tracksByWork.has(slug)) tracksByWork.set(slug, []);
          tracksByWork.get(slug)!.push({
            disc: track.disc_number,
            number: track.track_number,
            title: track.title,
            duration: track.duration_seconds,
            isrc: track.isrc,
          });
        }

        store.clear();

        for (const work of works) {
          const slug = work.slug;
          store.set({
            id: slug,
            data: {
              title: work.title,
              type: work.type,
              release_date: work.release_date,
              year: work.year,
              description: work.description,
              cover_url: work.cover_url,
              credits: creditsByWork.get(slug) || [],
              tracks: tracksByWork.get(slug) || [],
            },
            digest: generateDigest(work),
          });
        }

        logger.info(`[works] Loaded ${works.length} works with credits and tracks`);
      } finally {
        db.close();
      }
    },
  };
}
```

### Schema for Nested Data

```typescript
const works = defineCollection({
  loader: worksLoader({ dbPath: './data/archive.db' }),
  schema: z.object({
    title: z.string(),
    type: z.enum(['album', 'single', 'ep', 'compilation', 'feature', 'production']),
    release_date: z.string(),
    year: z.number(),
    description: z.string().nullable(),
    cover_url: z.string().nullable(),
    credits: z.array(z.object({
      person: z.string(),
      role: z.string(),
      notes: z.string().nullable(),
    })),
    tracks: z.array(z.object({
      disc: z.number(),
      number: z.number(),
      title: z.string(),
      duration: z.number().nullable(),
      isrc: z.string().nullable(),
    })),
  }),
});
```

---

## Timeline Loader

Loads chronological events, optionally linked to works.

```typescript
// src/lib/loaders/timeline-loader.ts
import Database from 'better-sqlite3';
import type { Loader } from 'astro/loaders';

export function timelineLoader(dbPath: string): Loader {
  return {
    name: 'timeline',
    load: async ({ store, logger, generateDigest }) => {
      const db = new Database(dbPath, { readonly: true });

      try {
        const events = db.prepare(`
          SELECT t.id, t.date, t.date_precision, t.type, t.title,
                 t.description, t.location, w.slug as work_slug
          FROM timeline t
          LEFT JOIN works w ON w.id = t.work_id
          ORDER BY t.date DESC
        `).all() as Record<string, any>[];

        store.clear();

        for (const event of events) {
          const id = `${event.date}-${event.id}`;
          store.set({
            id,
            data: {
              date: event.date,
              date_precision: event.date_precision,
              type: event.type,
              title: event.title,
              description: event.description,
              location: event.location,
              work_slug: event.work_slug,
            },
            digest: generateDigest(event),
          });
        }

        logger.info(`[timeline] Loaded ${events.length} events`);
      } finally {
        db.close();
      }
    },
  };
}
```

---

## libSQL Loader (Turso Remote)

For remote databases using Turso/libSQL:

```typescript
// src/lib/loaders/libsql-loader.ts
import { createClient } from '@libsql/client';
import type { Loader } from 'astro/loaders';

interface LibSQLLoaderOptions {
  url: string;
  authToken?: string;
  query: string;
  idColumn?: string;
  name?: string;
}

export function libsqlLoader(options: LibSQLLoaderOptions): Loader {
  const { url, authToken, query, idColumn = 'id', name = 'libsql' } = options;

  return {
    name,
    load: async ({ store, logger, generateDigest }) => {
      const client = createClient({ url, authToken });

      const result = await client.execute(query);
      store.clear();

      for (const row of result.rows) {
        const obj = Object.fromEntries(
          result.columns.map((col, i) => [col, row[i]])
        );
        const id = String(obj[idColumn]);
        const data = { ...obj };
        delete data[idColumn];

        store.set({
          id,
          data,
          digest: generateDigest(data as Record<string, unknown>),
        });
      }

      logger.info(`[${name}] Loaded ${result.rows.length} entries from libSQL`);
    },
  };
}
```

### Usage with Environment Variables

```typescript
// content.config.ts
import { libsqlLoader } from './src/lib/loaders/libsql-loader';

const works = defineCollection({
  loader: libsqlLoader({
    url: import.meta.env.TURSO_DATABASE_URL,
    authToken: import.meta.env.TURSO_AUTH_TOKEN,
    query: 'SELECT slug, title, type, year FROM works',
    idColumn: 'slug',
    name: 'works',
  }),
  schema: workSchema,
});
```

---

## Loader with Markdown Body

For entries that include rendered content:

```typescript
store.set({
  id: 'my-entry',
  data: { title: 'Entry Title', date: '2024-01-15' },
  body: '# Heading\n\nParagraph content with **bold** text.',
  rendered: {
    html: '<h1>Heading</h1>\n<p>Paragraph content with <strong>bold</strong> text.</p>',
  },
  digest: generateDigest(data),
});
```

Then in pages:

```astro
---
import { getEntry, render } from 'astro:content';
const entry = await getEntry('collection', 'my-entry');
const { Content } = await render(entry);
---
<Content />
```

---

## Incremental Loading

Use `meta` and `digest` to skip unchanged entries:

```typescript
load: async ({ store, meta, logger, generateDigest }) => {
  const lastSync = meta.lastSync;
  const query = lastSync
    ? `SELECT * FROM works WHERE updated_at > ?`
    : `SELECT * FROM works`;

  const rows = lastSync
    ? db.prepare(query).all(lastSync)
    : db.prepare(query).all();

  // Only clear store on full reload
  if (!lastSync) store.clear();

  for (const row of rows) {
    const digest = generateDigest(row);
    store.set({ id: row.slug, data: row, digest });
  }

  meta.lastSync = new Date().toISOString();
  logger.info(`Synced ${rows.length} entries (incremental: ${!!lastSync})`);
}
```

---

## Testing Loaders

Test loaders independently of Astro:

```typescript
// tests/loaders.test.ts
import { sqliteLoader } from '../src/lib/loaders/sqlite-loader';

const mockStore = {
  entries: new Map(),
  set(entry) { this.entries.set(entry.id, entry); },
  clear() { this.entries.clear(); },
  keys() { return [...this.entries.keys()]; },
};

const mockLogger = { info: console.log, warn: console.warn, error: console.error };
const mockDigest = (data) => JSON.stringify(data);

// Test
const loader = sqliteLoader({ dbPath: './test.db', query: 'SELECT * FROM works', idColumn: 'slug' });
await loader.load({ store: mockStore, logger: mockLogger, generateDigest: mockDigest });

console.assert(mockStore.entries.size > 0, 'Should load entries');
```
