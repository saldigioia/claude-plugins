# Astro DB — Setup

Astro-native database with Drizzle ORM integration. Use this when you want database tables defined alongside your Astro project and don't need an external database server.

## Table Definitions

```typescript
// db/config.ts
import { defineDb, defineTable, column } from 'astro:db';

const Works = defineTable({
  columns: {
    id: column.number({ primaryKey: true }),
    slug: column.text({ unique: true }),
    title: column.text(),
    type: column.text(),  // album, single, feature, production
    release_date: column.text(),
    year: column.number(),
    description: column.text({ optional: true }),
    cover_url: column.text({ optional: true }),
    // No `created_at` here — Astro DB column defaults are literal typed
    // values, not SQL expressions. Set timestamps at insert time in seed
    // code or application code (see Seed Data section below).
  },
});

const Credits = defineTable({
  columns: {
    id: column.number({ primaryKey: true }),
    work_id: column.number({ references: () => Works.columns.id }),
    person: column.text(),
    role: column.text(),  // producer, writer, featured, engineer, etc.
    notes: column.text({ optional: true }),
  },
});

const Tracks = defineTable({
  columns: {
    id: column.number({ primaryKey: true }),
    work_id: column.number({ references: () => Works.columns.id }),
    number: column.number(),
    title: column.text(),
    duration_seconds: column.number({ optional: true }),
    isrc: column.text({ optional: true }),
  },
});

const Sources = defineTable({
  columns: {
    id: column.number({ primaryKey: true }),
    work_id: column.number({ references: () => Works.columns.id }),
    url: column.text(),
    name: column.text(),
    accessed_date: column.text(),
    archived_url: column.text({ optional: true }),
  },
});

export default defineDb({
  tables: { Works, Credits, Tracks, Sources },
});
```

## Common Pitfall — SQL Expressions as Defaults

**Don't do this:**

```typescript
// This stores the literal string "CURRENT_TIMESTAMP" on every row:
created_at: column.text({ default: 'CURRENT_TIMESTAMP' })
```

Astro DB's `column.*({ default })` takes a value of the column's declared type, not a SQL expression. A text column default must be a string literal that you actually want in the cell.

**Do this instead:**

```typescript
// Option A — set the timestamp in seed / application code
await db.insert(Works).values({
  ...work,
  created_at: new Date().toISOString(),
});

// Option B — use a Drizzle `sql` raw expression (only when you control the ORM layer)
import { sql } from 'drizzle-orm';
created_at: column.text({ default: sql`(datetime('now'))` }),
```

Option A is the safer default for Astro DB because it avoids coupling your schema to a specific SQL dialect. Option B works when you're using Drizzle directly against a SQLite database and want server-side defaults.

## Seed Data

```typescript
// db/seed.ts
import { db, Works, Credits, Tracks } from 'astro:db';

export default async function seed() {
  const now = new Date().toISOString();

  await db.insert(Works).values([
    {
      slug: 'the-college-dropout',
      title: 'The College Dropout',
      type: 'album',
      release_date: '2004-02-10',
      year: 2004,
      description: 'Debut studio album.',
      cover_url: null,
    },
    // ...
  ]);

  await db.insert(Tracks).values([
    { work_id: 1, number: 1, title: 'We Don\'t Care', duration_seconds: 228 },
    // ...
  ]);
}
```

## Querying Astro DB

```astro
---
import { db, Works, Credits, eq } from 'astro:db';

// All works, ordered by year
const works = await db
  .select()
  .from(Works)
  .orderBy(Works.year);

// Credits for a specific work
const credits = await db
  .select()
  .from(Credits)
  .where(eq(Credits.work_id, 1));
---
```

Astro DB uses Drizzle's fluent query builder. For `WHERE` clauses, import operators (`eq`, `and`, `or`, `gt`, `lt`, `inArray`, etc.) from `astro:db` directly. See `drizzle-recipes.md` for join, aggregate, and parameterised-query patterns that reuse the same builder.
