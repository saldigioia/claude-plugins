# Content Layer API — Deep Reference

The Content Layer API (Astro 5) is a unified system for defining, loading, validating, and querying content from any source — local files, databases, APIs, or custom sources.

---

## Configuration File

```typescript
// content.config.ts (project root — NOT src/content/config.ts)
import { defineCollection, z } from 'astro:content';

export const collections = { /* ... */ };
```

**Important:** In Astro 5, this file lives at the project root as `content.config.ts` (or `.mjs`). The Astro 4 location `src/content/config.ts` is legacy.

---

## Defining Collections

### With Built-in Loaders

```typescript
import { defineCollection, z } from 'astro:content';
import { glob, file } from 'astro/loaders';

// Markdown/MDX files from a directory
const blog = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/blog' }),
  schema: z.object({
    title: z.string(),
    date: z.coerce.date(),
    updated: z.coerce.date().optional(),
    description: z.string().optional(),
    tags: z.array(z.string()).default([]),
    draft: z.boolean().default(false),
    image: z.string().optional(),
  }),
});

// JSON data file
const navigation = defineCollection({
  loader: file('src/data/navigation.json'),
  schema: z.object({
    label: z.string(),
    href: z.string(),
    order: z.number(),
  }),
});

// YAML data file
const metadata = defineCollection({
  loader: file('src/data/site-meta.yaml'),
  schema: z.object({
    key: z.string(),
    value: z.string(),
  }),
});

export const collections = { blog, navigation, metadata };
```

### `glob()` Loader Options

| Option | Type | Description |
|--------|------|-------------|
| `pattern` | `string \| string[]` | Glob pattern(s) for files to include |
| `base` | `string` | Base directory to resolve patterns from |
| `generateId` | `(options) => string` | Custom ID generation from entry data |

The `glob()` loader automatically:
- Extracts frontmatter from Markdown/MDX
- Uses the filename (without extension) as the entry `id`
- Supports nested directories (path becomes part of ID)

### `file()` Loader Options

| Option | Type | Description |
|--------|------|-------------|
| First argument | `string` | Path to the data file |
| `parser` | `(text) => any` | Custom parser (default: JSON/YAML auto-detect) |

For JSON files, the file should contain an array of objects. Each object must have an `id` field (or the index is used).

---

## Custom Loaders

Custom loaders connect any data source to Astro's content system.

### Loader Interface

```typescript
interface Loader {
  name: string;
  load: (context: LoaderContext) => Promise<void>;
  schema?: ZodSchema;  // Optional: override collection schema
}

interface LoaderContext {
  store: DataStore;          // Key-value store for entries
  meta: Record<string, string>; // Persistent metadata between builds
  logger: AstroIntegrationLogger;
  config: AstroConfig;
  parseData: (props: { id: string; data: unknown }) => Promise<any>;
  generateDigest: (data: Record<string, unknown>) => string;
}
```

### SQLite Loader Example

```typescript
// src/lib/loaders/sqlite-loader.ts
import Database from 'better-sqlite3';
import type { Loader } from 'astro/loaders';

interface SQLiteLoaderOptions {
  dbPath: string;
  table: string;
  idColumn?: string;
  query?: string;
}

export function sqliteLoader(options: SQLiteLoaderOptions): Loader {
  const { dbPath, table, idColumn = 'id', query } = options;

  return {
    name: `sqlite-${table}`,
    load: async ({ store, logger, generateDigest }) => {
      const db = new Database(dbPath, { readonly: true });

      const sql = query || `SELECT * FROM ${table}`;
      const rows = db.prepare(sql).all();

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

      logger.info(`Loaded ${rows.length} entries from ${table}`);
      db.close();
    },
  };
}
```

Usage in `content.config.ts`:

```typescript
import { defineCollection, z } from 'astro:content';
import { sqliteLoader } from './src/lib/loaders/sqlite-loader';

const works = defineCollection({
  loader: sqliteLoader({
    dbPath: './data/archive.db',
    table: 'works',
    idColumn: 'slug',
  }),
  schema: z.object({
    title: z.string(),
    year: z.number(),
    type: z.enum(['album', 'single', 'feature', 'production']),
    release_date: z.string(),
  }),
});

export const collections = { works };
```

### API Loader Example

```typescript
// src/lib/loaders/api-loader.ts
import type { Loader } from 'astro/loaders';

export function apiLoader(endpoint: string): Loader {
  return {
    name: 'api-loader',
    load: async ({ store, logger, meta, generateDigest }) => {
      // Use ETag/Last-Modified for incremental updates
      const headers: Record<string, string> = {};
      if (meta.etag) headers['If-None-Match'] = meta.etag;

      const response = await fetch(endpoint, { headers });

      if (response.status === 304) {
        logger.info('No changes since last fetch');
        return;
      }

      const etag = response.headers.get('etag');
      if (etag) meta.etag = etag;

      const items = await response.json();
      store.clear();

      for (const item of items) {
        store.set({
          id: String(item.id),
          data: item,
          digest: generateDigest(item),
        });
      }

      logger.info(`Loaded ${items.length} entries from API`);
    },
  };
}
```

### Loader with Rendered Content

For loaders that provide body content (like Markdown):

```typescript
store.set({
  id: 'my-entry',
  data: { title: 'My Entry', date: '2025-01-01' },
  body: '# Heading\n\nMarkdown content here...',
  rendered: {
    html: '<h1>Heading</h1><p>Markdown content here...</p>',
  },
  digest: generateDigest(data),
});
```

---

## Querying Collections

### Get All Entries

```typescript
import { getCollection } from 'astro:content';

// All entries
const allPosts = await getCollection('blog');

// Filtered entries
const published = await getCollection('blog', ({ data }) => {
  return !data.draft && data.date <= new Date();
});
```

### Get Single Entry

```typescript
import { getEntry } from 'astro:content';

// By collection and ID
const post = await getEntry('blog', 'my-post-slug');
```

### Render Content

```typescript
import { render } from 'astro:content';

const post = await getEntry('blog', 'my-post-slug');
const { Content, headings, remarkPluginFrontmatter } = await render(post);
```

```astro
<Content />
```

### Collection References

Link between collections using `reference()`:

```typescript
const blog = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/blog' }),
  schema: ({ image }) => z.object({
    title: z.string(),
    author: reference('authors'),      // References the 'authors' collection
    cover: image(),                     // Astro image optimization
    relatedPosts: z.array(reference('blog')).default([]),
  }),
});
```

---

## Schema Patterns for Archives

### Dates

```typescript
z.coerce.date()                         // Auto-coerce strings to Date
z.string().date()                       // Validate as ISO date string
z.string().regex(/^\d{4}-\d{2}-\d{2}$/) // Strict YYYY-MM-DD
```

### Enums for Content Types

```typescript
z.enum(['album', 'single', 'ep', 'compilation', 'feature', 'production'])
```

### Optional Fields with Defaults

```typescript
z.string().default('Unknown')
z.array(z.string()).default([])
z.boolean().default(false)
z.number().nullable().default(null)
```

### Nested Objects

```typescript
z.object({
  source: z.object({
    url: z.string().url(),
    name: z.string(),
    accessed: z.coerce.date(),
  }).optional(),
})
```

---

## Gotchas

1. **`content.config.ts` location.** Must be at project root in Astro 5, not `src/content/config.ts`.
2. **Collection entry IDs.** With `glob()`, the ID is the file path relative to `base`, without extension. With custom loaders, you set the ID explicitly.
3. **Type generation.** Run `astro sync` to regenerate types after changing collection schemas.
4. **Schema validation.** Zod validates at build time. Invalid data causes build errors with clear messages.
5. **`render()` import.** In Astro 5, import `render` from `astro:content`, not as a method on the entry.
