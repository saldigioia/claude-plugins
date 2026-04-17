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
