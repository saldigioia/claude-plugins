# Data Integrity — Migration, Backup, and Validation

Patterns for maintaining data quality and durability in archival databases.

---

## SQLite Integrity Fundamentals

### Enable Foreign Keys

SQLite does NOT enforce foreign keys by default. Always enable them:

```sql
PRAGMA foreign_keys = ON;
```

In `better-sqlite3`:

```typescript
const db = new Database(path);
db.pragma('foreign_keys = ON');
```

### WAL Mode for Concurrent Reads

```sql
PRAGMA journal_mode = WAL;
```

WAL (Write-Ahead Logging) allows concurrent readers during writes — important when the build process reads while a separate process writes.

### Integrity Check

```sql
PRAGMA integrity_check;
PRAGMA foreign_key_check;
```

Run these periodically or before major operations.

---

## Migration Patterns

### Idempotent Migrations

Every migration SQL should be safe to run multiple times:

```sql
-- Good: idempotent
CREATE TABLE IF NOT EXISTS works (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slug TEXT UNIQUE NOT NULL,
  title TEXT NOT NULL
);

ALTER TABLE works ADD COLUMN description TEXT;
-- Note: ALTER TABLE ADD COLUMN fails if column exists.
-- Wrap in a check or handle the error.

CREATE INDEX IF NOT EXISTS idx_works_slug ON works(slug);
```

### Migration File Convention

```
migrations/
├── 001_initial_schema.sql
├── 002_add_timeline.sql
├── 003_add_media_table.sql
├── 004_add_fts_index.sql
└── 005_add_sources.sql
```

Each migration file should:
1. Have a sequential number prefix
2. Be named descriptively
3. Be safe to run on an already-migrated database (where possible)
4. Include both the schema change and any data transformations

### Migration Runner

```typescript
// src/lib/migrate.ts
import Database from 'better-sqlite3';
import { readdirSync, readFileSync } from 'fs';
import { join } from 'path';

export function migrate(dbPath: string, migrationsDir: string) {
  const db = new Database(dbPath);
  db.pragma('foreign_keys = ON');
  db.pragma('journal_mode = WAL');

  // Create migrations tracking table
  db.exec(`
    CREATE TABLE IF NOT EXISTS _migrations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT UNIQUE NOT NULL,
      applied_at TEXT DEFAULT (datetime('now'))
    )
  `);

  const applied = new Set(
    db.prepare('SELECT name FROM _migrations').all().map((r: any) => r.name)
  );

  const files = readdirSync(migrationsDir)
    .filter(f => f.endsWith('.sql'))
    .sort();

  for (const file of files) {
    if (applied.has(file)) continue;

    const sql = readFileSync(join(migrationsDir, file), 'utf-8');

    db.transaction(() => {
      db.exec(sql);
      db.prepare('INSERT INTO _migrations (name) VALUES (?)').run(file);
    })();

    console.log(`Applied migration: ${file}`);
  }

  db.close();
}
```

### Column Addition Pattern

SQLite doesn't support `ALTER TABLE ADD COLUMN IF NOT EXISTS`. Use this pattern:

```typescript
function addColumnIfNotExists(
  db: Database.Database,
  table: string,
  column: string,
  definition: string
) {
  const columns = db.pragma(`table_info(${table})`);
  const exists = columns.some((c: any) => c.name === column);
  if (!exists) {
    db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
  }
}

// Usage
addColumnIfNotExists(db, 'works', 'external_id', 'TEXT');
```

---

## Backup Patterns

### Timestamped Backup

```bash
#!/usr/bin/env bash
# backup-db.sh
DB_PATH="${1:?Usage: backup-db.sh <db-path>}"
BACKUP_DIR="${2:-./backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="$BACKUP_DIR/$(basename "$DB_PATH" .db)_$TIMESTAMP.db"

mkdir -p "$BACKUP_DIR"
sqlite3 "$DB_PATH" ".backup '$BACKUP_PATH'"
echo "Backed up to: $BACKUP_PATH"
```

### SQLite Online Backup API

```typescript
import Database from 'better-sqlite3';

function backupDatabase(sourcePath: string, destPath: string) {
  const source = new Database(sourcePath, { readonly: true });
  source.backup(destPath).then((result) => {
    console.log(`Backup complete: ${result.totalPages} pages`);
    source.close();
  });
}
```

### Backup Before Mutation

Always backup before write operations:

```typescript
import { copyFileSync } from 'fs';

function withBackup<T>(dbPath: string, operation: () => T): T {
  const backupPath = `${dbPath}.bak.${Date.now()}`;
  copyFileSync(dbPath, backupPath);

  try {
    return operation();
  } catch (error) {
    // Restore from backup on failure
    copyFileSync(backupPath, dbPath);
    throw error;
  }
}
```

---

## Validation Patterns

### Build-Time Validation via Zod

The primary validation gate is Zod schemas in `content.config.ts`. Invalid data fails the build:

```typescript
const works = defineCollection({
  loader: sqliteLoader({ /* ... */ }),
  schema: z.object({
    title: z.string().min(1, 'Title cannot be empty'),
    type: z.enum(['album', 'single', 'ep']),
    year: z.number().int().min(1900).max(2100),
    release_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Must be YYYY-MM-DD'),
  }),
});
```

Build output on validation failure:

```
[ERROR] Invalid content entry in works:
  - title: String must contain at least 1 character(s)
  - release_date: Must be YYYY-MM-DD
```

### Database-Level Constraints

```sql
CREATE TABLE works (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slug TEXT UNIQUE NOT NULL,
  title TEXT NOT NULL CHECK(length(title) > 0),
  type TEXT NOT NULL CHECK(type IN ('album', 'single', 'ep', 'compilation')),
  year INTEGER NOT NULL CHECK(year >= 1900 AND year <= 2100),
  release_date TEXT NOT NULL CHECK(release_date GLOB '????-??-??')
);
```

### Data Quality Queries

Run these to find data issues:

```sql
-- Works without credits
SELECT w.slug, w.title FROM works w
LEFT JOIN credits c ON c.work_id = w.id
WHERE c.id IS NULL;

-- Works without sources (no provenance)
SELECT w.slug, w.title FROM works w
LEFT JOIN sources s ON s.work_id = w.id
WHERE s.id IS NULL;

-- Duplicate slugs (should be caught by UNIQUE constraint)
SELECT slug, COUNT(*) as count FROM works
GROUP BY slug HAVING count > 1;

-- Tracks with missing duration
SELECT w.title, t.track_number, t.title as track_title
FROM tracks t JOIN works w ON w.id = t.work_id
WHERE t.duration_seconds IS NULL;

-- Credits with empty person names
SELECT * FROM credits WHERE trim(person) = '' OR person IS NULL;

-- Orphaned credits (work_id doesn't exist)
SELECT c.* FROM credits c
LEFT JOIN works w ON w.id = c.work_id
WHERE w.id IS NULL;

-- Timeline events without dates
SELECT * FROM timeline WHERE date IS NULL OR date = '';
```

### Validation Script

```typescript
// scripts/validate-db.ts
import Database from 'better-sqlite3';

const db = new Database('./data/archive.db', { readonly: true });

const checks = [
  {
    name: 'Works without credits',
    query: `SELECT COUNT(*) as count FROM works w
            LEFT JOIN credits c ON c.work_id = w.id
            WHERE c.id IS NULL`,
    warn: (count: number) => count > 0,
  },
  {
    name: 'Works without sources',
    query: `SELECT COUNT(*) as count FROM works w
            LEFT JOIN sources s ON s.work_id = w.id
            WHERE s.id IS NULL`,
    warn: (count: number) => count > 0,
  },
  {
    name: 'Orphaned credits',
    query: `SELECT COUNT(*) as count FROM credits c
            LEFT JOIN works w ON w.id = c.work_id
            WHERE w.id IS NULL`,
    warn: (count: number) => count > 0,
  },
  {
    name: 'Empty titles',
    query: `SELECT COUNT(*) as count FROM works WHERE trim(title) = ''`,
    warn: (count: number) => count > 0,
  },
];

let hasWarnings = false;

for (const check of checks) {
  const result = db.prepare(check.query).get() as { count: number };
  if (check.warn(result.count)) {
    console.warn(`WARNING: ${check.name} — found ${result.count}`);
    hasWarnings = true;
  } else {
    console.log(`OK: ${check.name}`);
  }
}

db.close();
process.exit(hasWarnings ? 1 : 0);
```

---

## Data Export

### Export to JSON

```bash
sqlite3 archive.db -json "SELECT * FROM works ORDER BY year" > works.json
```

### Export Schema

```bash
sqlite3 archive.db ".schema" > schema.sql
```

### Dump Entire Database

```bash
sqlite3 archive.db ".dump" > dump.sql
```

### Export for Astro `file()` Loader

If migrating from SQLite to file-based collections:

```typescript
import Database from 'better-sqlite3';
import { writeFileSync } from 'fs';

const db = new Database('./data/archive.db', { readonly: true });
const works = db.prepare('SELECT * FROM works ORDER BY year DESC').all();

writeFileSync(
  './src/content/data/works.json',
  JSON.stringify(works, null, 2)
);

db.close();
```

---

## Archival Principles

1. **Source everything.** Every fact should trace to a `sources` entry.
2. **Preserve originals.** Keep original data alongside cleaned/normalized versions.
3. **Date your captures.** `sources.accessed_date` records when you captured external data.
4. **Archive external URLs.** Save Wayback Machine URLs in `sources.archived_url`.
5. **Never delete — soft delete.** Add an `archived_at` column rather than `DELETE`ing rows.
6. **Version your schema.** Track applied migrations in `_migrations` table.
7. **Backup before mutating.** Every write operation gets a timestamped backup.
