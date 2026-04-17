import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import react from '@astrojs/react';

export default defineConfig({
  site: 'https://archive.example.com',
  output: 'static',
  trailingSlash: 'always',
  integrations: [
    react(),
    sitemap({
      filter: (page) => !page.includes('/draft/'),
    }),
  ],
  prefetch: {
    defaultStrategy: 'hover',
  },
  vite: {
    optimizeDeps: {
      exclude: ['better-sqlite3'],
    },
  },
});
