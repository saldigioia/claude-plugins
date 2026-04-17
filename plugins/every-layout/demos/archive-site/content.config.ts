import { defineCollection, z } from 'astro:content';
import { sqliteLoader } from './src/lib/loaders/sqlite-loader';

const works = defineCollection({
  loader: sqliteLoader({
    dbPath: './data/archive.db',
    query: `
      SELECT w.slug, w.title, w.type, w.release_date, w.year, w.description,
             w.cover_url
      FROM works w
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
    description: z.string().nullable().default(null),
    cover_url: z.string().nullable().default(null),
  }),
});

export const collections = { works };
