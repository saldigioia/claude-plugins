# Drizzle ORM Recipes — Archival Data Queries

Query patterns for Astro DB using Drizzle ORM. All examples assume tables defined in `db/config.ts` and imported from `astro:db`.

---

## Basic CRUD

### Select All

```typescript
import { db, Works } from 'astro:db';

const allWorks = await db.select().from(Works);
```

### Select with Ordering

```typescript
import { db, Works, desc, asc } from 'astro:db';

// Newest first
const byYear = await db.select().from(Works).orderBy(desc(Works.year));

// Alphabetical
const byTitle = await db.select().from(Works).orderBy(asc(Works.title));

// Multiple columns
const sorted = await db.select().from(Works)
  .orderBy(desc(Works.year), asc(Works.title));
```

### Select Specific Columns

```typescript
const titles = await db
  .select({ slug: Works.slug, title: Works.title, year: Works.year })
  .from(Works);
```

### Insert

```typescript
import { db, Works } from 'astro:db';

await db.insert(Works).values({
  slug: 'graduation',
  title: 'Graduation',
  type: 'album',
  release_date: '2007-09-11',
  year: 2007,
});

// Bulk insert
await db.insert(Works).values([
  { slug: 'album-1', title: 'Album 1', type: 'album', release_date: '2020-01-01', year: 2020 },
  { slug: 'album-2', title: 'Album 2', type: 'album', release_date: '2021-06-15', year: 2021 },
]);
```

### Update

```typescript
import { db, Works, eq } from 'astro:db';

await db.update(Works)
  .set({ description: 'Updated description' })
  .where(eq(Works.slug, 'graduation'));
```

### Delete

```typescript
import { db, Works, eq } from 'astro:db';

await db.delete(Works).where(eq(Works.slug, 'old-entry'));
```

---

## Filtering

### Equality

```typescript
import { db, Works, eq } from 'astro:db';

const albums = await db.select().from(Works).where(eq(Works.type, 'album'));
```

### Comparison

```typescript
import { db, Works, gt, gte, lt, lte, ne } from 'astro:db';

const after2010 = await db.select().from(Works).where(gte(Works.year, 2010));
const before2000 = await db.select().from(Works).where(lt(Works.year, 2000));
const notSingles = await db.select().from(Works).where(ne(Works.type, 'single'));
```

### Compound Conditions

```typescript
import { db, Works, and, or, eq, gte, lte } from 'astro:db';

// AND
const albumsIn2010s = await db.select().from(Works).where(
  and(
    eq(Works.type, 'album'),
    gte(Works.year, 2010),
    lte(Works.year, 2019)
  )
);

// OR
const albumsOrEps = await db.select().from(Works).where(
  or(
    eq(Works.type, 'album'),
    eq(Works.type, 'ep')
  )
);
```

### Pattern Matching

```typescript
import { db, Works, like } from 'astro:db';

const matches = await db.select().from(Works)
  .where(like(Works.title, '%dropout%'));
```

### IN Clause

```typescript
import { db, Works, inArray } from 'astro:db';

const selected = await db.select().from(Works)
  .where(inArray(Works.type, ['album', 'ep', 'compilation']));
```

### NULL Checks

```typescript
import { db, Works, isNull, isNotNull } from 'astro:db';

const withDescription = await db.select().from(Works).where(isNotNull(Works.description));
const withoutCover = await db.select().from(Works).where(isNull(Works.cover_url));
```

---

## Joins

### Inner Join

```typescript
import { db, Works, Credits, eq } from 'astro:db';

const worksWithCredits = await db
  .select({
    title: Works.title,
    year: Works.year,
    person: Credits.person,
    role: Credits.role,
  })
  .from(Works)
  .innerJoin(Credits, eq(Works.id, Credits.work_id));
```

### Left Join

```typescript
const allWorksWithCredits = await db
  .select({
    slug: Works.slug,
    title: Works.title,
    person: Credits.person,
    role: Credits.role,
  })
  .from(Works)
  .leftJoin(Credits, eq(Works.id, Credits.work_id))
  .orderBy(Works.year);
```

### Multiple Joins

```typescript
import { db, Works, Credits, Tracks, eq } from 'astro:db';

const full = await db
  .select({
    workTitle: Works.title,
    trackTitle: Tracks.title,
    trackNumber: Tracks.track_number,
    creditPerson: Credits.person,
    creditRole: Credits.role,
  })
  .from(Works)
  .leftJoin(Tracks, eq(Works.id, Tracks.work_id))
  .leftJoin(Credits, eq(Works.id, Credits.work_id))
  .orderBy(Works.year, Tracks.track_number);
```

---

## Aggregation

### Count

```typescript
import { db, Works, Credits, eq, count } from 'astro:db';

// Total works
const [{ total }] = await db.select({ total: count() }).from(Works);

// Count per type
const typeCounts = await db
  .select({ type: Works.type, count: count() })
  .from(Works)
  .groupBy(Works.type);

// Credits per work
const creditCounts = await db
  .select({
    slug: Works.slug,
    title: Works.title,
    creditCount: count(Credits.id),
  })
  .from(Works)
  .leftJoin(Credits, eq(Works.id, Credits.work_id))
  .groupBy(Works.id);
```

### Distinct Values

```typescript
import { db, Works, sql } from 'astro:db';

// All unique types
const types = await db.selectDistinct({ type: Works.type }).from(Works);

// All unique years
const years = await db.selectDistinct({ year: Works.year })
  .from(Works)
  .orderBy(desc(Works.year));
```

---

## Pagination

### Offset-Based

```typescript
import { db, Works, desc } from 'astro:db';

const PAGE_SIZE = 12;

async function getPage(page: number) {
  return db.select().from(Works)
    .orderBy(desc(Works.year))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
}

// Total pages
const [{ total }] = await db.select({ total: count() }).from(Works);
const totalPages = Math.ceil(total / PAGE_SIZE);
```

---

## Common Archive Queries

### Discography Timeline

```typescript
// All works ordered chronologically
const discography = await db.select().from(Works)
  .orderBy(asc(Works.release_date));
```

### Works by Person

```typescript
// All works a person contributed to
const personWorks = await db
  .select({
    title: Works.title,
    slug: Works.slug,
    year: Works.year,
    role: Credits.role,
  })
  .from(Credits)
  .innerJoin(Works, eq(Credits.work_id, Works.id))
  .where(eq(Credits.person, 'Person Name'))
  .orderBy(desc(Works.year));
```

### Year Summary

```typescript
// Works grouped by year with counts
const yearSummary = await db
  .select({
    year: Works.year,
    albumCount: count(),
  })
  .from(Works)
  .groupBy(Works.year)
  .orderBy(desc(Works.year));
```

### Tracklist for a Work

```typescript
// Ordered tracklist with disc numbers
const tracklist = await db.select().from(Tracks)
  .where(eq(Tracks.work_id, workId))
  .orderBy(asc(Tracks.disc_number), asc(Tracks.track_number));
```

### Credits Grouped by Role

```typescript
// Credits for a work, grouped by role
const credits = await db.select().from(Credits)
  .where(eq(Credits.work_id, workId))
  .orderBy(asc(Credits.role), asc(Credits.person));

// Group in application code
const byRole = Map.groupBy(credits, c => c.role);
```

---

## Raw SQL Escape Hatch

When Drizzle's query builder isn't enough:

```typescript
import { db, sql } from 'astro:db';

// Raw SQL query
const results = await db.run(sql`
  SELECT w.title, COUNT(c.id) as credit_count
  FROM Works w
  LEFT JOIN Credits c ON c.work_id = w.id
  GROUP BY w.id
  HAVING credit_count > 5
  ORDER BY credit_count DESC
`);
```

Use sparingly — prefer the type-safe query builder when possible.
