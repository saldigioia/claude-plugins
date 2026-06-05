# Astro Config Recipes

Common `astro.config.mjs` configurations for archive-style sites.

---

## Minimal Static Site

```javascript
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://example.com',
  output: 'static',
  trailingSlash: 'always',
});
```

---

## With Sitemap and MDX

```javascript
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import mdx from '@astrojs/mdx';

export default defineConfig({
  site: 'https://example.com',
  output: 'static',
  trailingSlash: 'always',
  integrations: [
    sitemap(),
    mdx(),
  ],
});
```

---

## Cloudflare Pages Deployment

```javascript
import { defineConfig } from 'astro/config';
import cloudflare from '@astrojs/cloudflare';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://example.com',
  output: 'static',             // Static by default; opt individual pages into SSR
  adapter: cloudflare(),
  trailingSlash: 'always',
  integrations: [sitemap()],
});
```

> **Astro 6 / Cloudflare.** The `'hybrid'` output mode was removed in Astro 5 — `output: 'static'` is the default and pages opt into on-demand rendering individually (below). The Cloudflare adapter had significant breaking changes in the release that accompanies Astro 6; see the [Cloudflare adapter upgrade guide](https://docs.astro.build/en/guides/integrations-guide/cloudflare/#upgrading-to-v13-and-astro-6).

### Opt-in SSR per page

With the default static output, add `export const prerender = false` to make an individual page server-rendered (requires an adapter):

```astro
---
// src/pages/api/search.ts
export const prerender = false;  // This page runs on the server

import type { APIRoute } from 'astro';
export const GET: APIRoute = async ({ url }) => {
  // Server-side logic here
};
---
```

---

## With Remote Images

```javascript
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://example.com',
  image: {
    domains: ['cdn.example.com', 'images.unsplash.com'],
    remotePatterns: [
      { protocol: 'https', hostname: '**.cloudflare.com' },
    ],
  },
});
```

---

## With Custom Vite Config

```javascript
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://example.com',
  vite: {
    css: {
      devSourcemap: true,
    },
    build: {
      cssMinify: 'lightningcss',
    },
    optimizeDeps: {
      exclude: ['better-sqlite3'],  // Native module, don't bundle
    },
  },
});
```

---

## With Redirects

```javascript
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://example.com',
  redirects: {
    '/old-path': '/new-path',
    '/blog/[...slug]': '/articles/[...slug]',  // Dynamic redirects
    '/legacy': {
      status: 301,
      destination: '/modern',
    },
  },
});
```

---

## With Prefetch Control

```javascript
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://example.com',
  prefetch: {
    prefetchAll: false,           // Don't prefetch everything
    defaultStrategy: 'hover',     // Prefetch on hover (default when ClientRouter is enabled)
  },
});
```

---

## With Markdown Configuration

```javascript
import { defineConfig } from 'astro/config';
import remarkToc from 'remark-toc';
import rehypeSlug from 'rehype-slug';
import rehypeAutolinkHeadings from 'rehype-autolink-headings';

export default defineConfig({
  site: 'https://example.com',
  markdown: {
    remarkPlugins: [remarkToc],
    rehypePlugins: [
      rehypeSlug,
      [rehypeAutolinkHeadings, { behavior: 'wrap' }],
    ],
    shikiConfig: {
      theme: 'github-dark',
      wrap: true,
    },
  },
});
```

---

## Full Archive Site Config

```javascript
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import mdx from '@astrojs/mdx';
import rehypeSlug from 'rehype-slug';

export default defineConfig({
  site: 'https://archive.example.com',
  output: 'static',
  trailingSlash: 'always',

  integrations: [
    sitemap({
      filter: (page) => !page.includes('/draft/'),
    }),
    mdx(),
  ],

  markdown: {
    rehypePlugins: [rehypeSlug],
    shikiConfig: {
      theme: 'github-dark',
      wrap: true,
    },
  },

  image: {
    domains: [],  // Add CDN domains as needed
  },

  prefetch: {
    defaultStrategy: 'hover',
  },

  redirects: {
    // Map old URLs to new structure
  },

  vite: {
    optimizeDeps: {
      exclude: ['better-sqlite3'],
    },
  },
});
```

---

## Config Reference

| Option | Type | Default | Purpose |
|--------|------|---------|---------|
| `site` | `string` | — | Full URL, used for sitemap and canonical URLs |
| `output` | `'static' \| 'server'` | `'static'` | Rendering mode (`'hybrid'` removed in Astro 5; use `'static'` + per-page `prerender = false`) |
| `adapter` | Adapter | — | Server adapter (Cloudflare, Node, Vercel, etc.) |
| `trailingSlash` | `'always' \| 'never' \| 'ignore'` | `'ignore'` | URL trailing slash behavior |
| `integrations` | `Integration[]` | `[]` | Astro integrations |
| `markdown` | `object` | — | Remark/rehype plugins, Shiki config |
| `image` | `object` | — | Remote image domains and patterns |
| `redirects` | `object` | — | URL redirect mappings |
| `prefetch` | `object` | — | Link prefetch strategy |
| `vite` | `object` | — | Vite config overrides |
| `build.format` | `'file' \| 'directory' \| 'preserve'` | `'directory'` | Output file structure |
