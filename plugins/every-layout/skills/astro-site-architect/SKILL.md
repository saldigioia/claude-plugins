---
name: astro-site-architect
description: "Astro 5 architecture: astro.config, content collections (defineCollection, loader), [slug] routing, src/pages, src/layouts, SSG/SSR, ClientRouter, island hydration, performance. Use when building or structuring an Astro site."
allowed-tools: Bash(astro *) Bash(npm *) Bash(npx *) Read Glob Grep Write Edit
paths:
  - "**/*.astro"
  - "**/astro.config.*"
  - "**/content.config.*"
  - "**/src/pages/**"
  - "**/src/layouts/**"
  - "**/src/content/**/*.md"
  - "**/src/content/**/*.mdx"
---

# Astro Site Architect

Build, structure, and maintain Astro 5 sites with the Every Layout design philosophy: zero-JS by default, intrinsically responsive, token-driven, and archival-grade.

> **Axiomatic commitment.** Every island in this skill's recommendations must justify itself against axiom **ELA_005** (CSS-Dominant Composition). The `bin/js-budget.sh` script enforces a **15 KB per-route / 30 KB page-total** compressed JavaScript budget. `client:load` requires an entry in `escapes.md` (category `ESC_JS_EAGER`). See `skills/css-layout-engine/references/axioms.md` for the full axiom hierarchy.

---

## Astro 5 Project Structure

```
project-root/
├── astro.config.mjs           # Integrations, output mode, adapters
├── content.config.ts           # Collection definitions (Content Layer API)
├── src/
│   ├── pages/                  # File-based routing (.astro, .md, .mdx)
│   │   ├── index.astro
│   │   ├── about.astro
│   │   └── [collection]/
│   │       └── [...slug].astro # Dynamic routes for content collections
│   ├── layouts/                # Page shells — compose from Every Layout primitives
│   │   ├── Base.astro          # HTML document + critical CSS inline
│   │   ├── Article.astro       # Cover > Center > Stack for prose
│   │   └── Archive.astro       # Sidebar + Grid for collection pages
│   ├── components/             # Reusable Astro/framework components
│   │   ├── layout/             # Every Layout primitive components
│   │   ├── ui/                 # UI components (nav, footer, cards)
│   │   └── islands/            # Interactive components (client:* hydrated)
│   ├── content/                # Local content files (markdown, JSON, YAML)
│   ├── styles/
│   │   ├── global.css          # :root tokens, border-box reset, base styles
│   │   ├── primitives.css      # Every Layout primitive classes
│   │   └── print.css           # Print stylesheet
│   ├── lib/                    # Utilities, helpers, custom loaders
│   └── assets/                 # Optimized images (processed by astro:assets)
├── public/                     # Static files (favicon, robots.txt, fonts)
└── db/                         # Astro DB (if using database)
    ├── config.ts               # Table definitions
    └── seed.ts                 # Seed data
```

> Full annotated structure: `references/project-structure.md`

---

## Content Layer API (Astro 5)

Astro 5 introduced the Content Layer API — a unified system for defining typed content collections from any source.

### Defining Collections

```typescript
// content.config.ts
import { defineCollection, z } from 'astro:content';
import { glob, file } from 'astro/loaders';

const blog = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/blog' }),
  schema: z.object({
    title: z.string(),
    date: z.coerce.date(),
    tags: z.array(z.string()).default([]),
    draft: z.boolean().default(false),
  }),
});

const authors = defineCollection({
  loader: file('src/data/authors.json'),
  schema: z.object({
    name: z.string(),
    role: z.string(),
    avatar: z.string().optional(),
  }),
});

export const collections = { blog, authors };
```

### Built-in Loaders

| Loader | Source | Use Case |
|--------|--------|----------|
| `glob()` | Local files matching a pattern | Markdown, MDX, YAML, JSON content |
| `file()` | Single data file | JSON arrays, YAML collections |

### Custom Loaders

For databases, APIs, or any external source, the canonical guidance lives in the `archival-data-engine` skill — see `archival-data-engine/SKILL.md` ("Custom Content Loaders") and `archival-data-engine/references/custom-loaders.md`. That skill owns the loader API, the `store.set/clear` lifecycle, typing with Zod, and integration patterns for SQLite, libSQL, Astro DB, Drizzle, and HTTP sources.

This skill composes with archival-data-engine when you're wiring a database-backed Astro site: use Astro's Content Layer here for routing and rendering; use that skill's loader recipes for data fetching.

### Querying Collections

```astro
---
import { getCollection, getEntry } from 'astro:content';

// Get all entries
const allPosts = await getCollection('blog', ({ data }) => !data.draft);

// Get single entry by ID
const post = await getEntry('blog', 'my-post-slug');

// Sort by date
const sorted = allPosts.sort((a, b) => b.data.date.valueOf() - a.data.date.valueOf());
---
```

> Full Content Layer deep dive: `references/content-layer.md`

---

## Routing

### File-Based Routing

| File | Route |
|------|-------|
| `src/pages/index.astro` | `/` |
| `src/pages/about.astro` | `/about` |
| `src/pages/blog/index.astro` | `/blog` |
| `src/pages/blog/[slug].astro` | `/blog/:slug` |
| `src/pages/[...slug].astro` | Catch-all (404 fallback) |

### Static Routes from Collections

```astro
---
// src/pages/blog/[slug].astro
import { getCollection, render } from 'astro:content';

export async function getStaticPaths() {
  const posts = await getCollection('blog');
  return posts.map(post => ({
    params: { slug: post.id },
    props: { post },
  }));
}

const { post } = Astro.props;
const { Content } = await render(post);
---

<Content />
```

### Output Modes

| Mode | Config | Use Case |
|------|--------|----------|
| `static` (default) | `output: 'static'` | Fully pre-rendered at build time |
| `server` | `output: 'server'` | All pages server-rendered on demand |
| `hybrid` | `output: 'hybrid'` | Static by default, opt-in SSR per page |

For archival sites, **always prefer `static`** — pre-rendered pages are durable, fast, and don't depend on runtime infrastructure.

> Full routing patterns: `references/routing.md`

---

## Layout Composition with Every Layout

### The Layout Spine: Cover > Center > Stack

Every page starts with three nested primitives:

```astro
<!-- src/layouts/Base.astro -->
---
interface Props {
  title: string;
  description?: string;
}
const { title, description } = Astro.props;
---

<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width" />
  <title>{title}</title>
  {description && <meta name="description" content={description} />}
  <style is:inline>
    /* Critical CSS inline: :root tokens + .center + .stack + border-box */
  </style>
  <!--
    CSS under src/styles/ must be imported (Astro content-hashes it into /_astro/*);
    it is NOT served at /styles/. Either import from the .astro frontmatter:
      import '../styles/primitives.css';
    or, if you want a stable unhashed URL, put the file in public/ — at the cost
    of bypassing Astro's build pipeline (no minification, no hashing).
  -->
</head>
<body>
  <a href="#main" class="skip-link">Skip to content</a>
  <div class="cover">            <!-- ELC_COVER: full viewport shell -->
    <header>
      <div class="center">
        <slot name="header" />
      </div>
    </header>
    <main id="main" class="principal">
      <div class="center">       <!-- ELC_CENTER: constrain to measure -->
        <div class="stack">       <!-- ELC_STACK: vertical rhythm -->
          <slot />
        </div>
      </div>
    </main>
    <footer>
      <div class="center">
        <slot name="footer" />
      </div>
    </footer>
  </div>
</body>
</html>
```

### Layout Patterns by Page Type

| Page Type | Layout Composition | Primitives |
|-----------|-------------------|------------|
| Article / prose | Cover > Center > Stack | ELC_COVER + ELC_CENTER + ELC_STACK |
| Archive / index | Cover > Center > Grid | ELC_COVER + ELC_CENTER + ELC_GRID |
| Dashboard | Cover > Sidebar(nav, Center > Grid) | ELC_COVER + ELC_SIDEBAR + ELC_CENTER + ELC_GRID |
| Gallery | Cover > Center > Reel or Grid | ELC_COVER + ELC_CENTER + ELC_REEL or ELC_GRID |
| Hero landing | Cover(principal) > Center > Stack | ELC_COVER + ELC_CENTER + ELC_STACK |
| Documentation | Cover > Sidebar(nav, Center > Stack) | ELC_COVER + ELC_SIDEBAR + ELC_CENTER + ELC_STACK |

### Composing Layouts

```astro
<!-- src/layouts/Article.astro -->
---
import Base from './Base.astro';
const { frontmatter } = Astro.props;
---

<Base title={frontmatter.title} description={frontmatter.description}>
  <article>
    <div class="stack" style="--space: var(--s2)">
      <header class="stack" style="--space: var(--s-1)">
        <h1>{frontmatter.title}</h1>
        <time datetime={frontmatter.date}>{frontmatter.date}</time>
      </header>
      <slot />
    </div>
  </article>
</Base>
```

```astro
<!-- src/layouts/Archive.astro -->
---
import Base from './Base.astro';
const { title, description } = Astro.props;
---

<Base title={title} description={description}>
  <div class="stack" style="--space: var(--s3)">
    <header class="stack" style="--space: var(--s-1)">
      <h1>{title}</h1>
      {description && <p>{description}</p>}
    </header>
    <div class="grid" style="--min: 20rem">
      <slot />
    </div>
  </div>
</Base>
```

---

## Island Architecture

Astro renders everything to static HTML by default. JavaScript only ships when explicitly opted in via `client:*` directives.

### Hydration Directives

| Directive | When JS Loads | Use Case |
|-----------|--------------|----------|
| `client:load` | Immediately on page load | Critical interactivity (nav menus, auth) |
| `client:idle` | After page is idle | Non-critical interactivity (comment forms) |
| `client:visible` | When component scrolls into view | Below-fold interactive content |
| `client:media="(query)"` | When media query matches | Mobile-only interactions |
| `client:only="framework"` | Client-only, no SSR | Components that can't SSR (canvas, WebGL) |
| *(none)* | Never — static HTML only | **Default. Use this unless you need JS.** |

### The ye-archive Philosophy

1. **No directive = no JavaScript.** The overwhelming default.
2. **Every island must justify its hydration.** Ask: "Does this need client-side state?"
3. **Prefer HTML + CSS solutions.** `<details>`, `:target`, `:checked`, scroll-snap, `dialog` — all zero-JS.
4. **If JS is required, prefer `client:visible` or `client:idle`.** Almost nothing needs `client:load`.

```astro
<!-- Zero-JS accordion using HTML details -->
<details>
  <summary>Section Title</summary>
  <div class="stack">
    <p>Content revealed without JavaScript.</p>
  </div>
</details>

<!-- Only hydrate if truly interactive -->
<SearchWidget client:idle />
```

---

## Astro Configuration

### Minimal Config

```javascript
// astro.config.mjs
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://example.com',
  output: 'static',
});
```

### Common Integrations

| Integration | Purpose | Install |
|-------------|---------|---------|
| `@astrojs/sitemap` | Auto-generate sitemap.xml | `npx astro add sitemap` |
| `@astrojs/mdx` | MDX support in content | `npx astro add mdx` |
| `@astrojs/rss` | RSS feed generation | `npm i @astrojs/rss` |
| `astro-icon` | SVG icon component | `npm i astro-icon` |
| `@astrojs/cloudflare` | Cloudflare Pages adapter | `npx astro add cloudflare` |

### View Transitions

Astro 5 renamed the router component from `<ViewTransitions />` (the Astro 4 alias) to `<ClientRouter />`. Use the new name in new code:

```astro
---
// In layout <head>
import { ClientRouter } from 'astro:transitions';
---
<head>
  <ClientRouter />
</head>
```

Pair with `transition:name` and `transition:animate` on elements for smooth page transitions. Note: the client router **is not zero-JS** — it ships approximately 3 KB of JavaScript to intercept navigation and orchestrate transitions. Count it toward the page's island JS budget. The underlying CSS-only `view-transition-name` declarations work without the router but only within a single page.

> Full config recipes: `references/astro-config-recipes.md`

---

## Performance

### Critical CSS Strategy

| Bundle | Contents | Loading |
|--------|----------|---------|
| Critical inline (~1.2 KB) | `:root` tokens + `.center` + `.stack` + border-box reset | `<style is:inline>` in `<head>` |
| Core async | Remaining primitives + fluid-type.css | `<link rel="preload">` |
| Theme + print (lazy) | color-theming.css + print.css | `media="print"` / idle load |

### Image Optimization

```astro
---
import { Image } from 'astro:assets';
import heroImage from '../assets/hero.jpg';
---

<Image
  src={heroImage}
  alt="Description"
  widths={[400, 800, 1200]}
  sizes="(max-width: 800px) 100vw, 800px"
  format="avif"
  loading="lazy"
  decoding="async"
/>
```

Always use `astro:assets` for local images — it generates optimized formats, responsive srcsets, and proper width/height to prevent CLS.

### Performance Rules

1. **Zero JS by default.** No `client:*` without justification.
2. **Inline critical CSS.** Tokens + Center + Stack + reset in `<head>`.
3. **Preload core CSS.** Remaining primitives via `rel="preload"`.
4. **Lazy-load below-fold images.** `loading="lazy" decoding="async"`.
5. **Static output.** Pre-render everything possible at build time.
6. **Respect the CSS budget.** See `css-design-system/references/performance-rules.md` — this skill does not restate the numbers.

> Full performance patterns: `references/performance.md`

---

## Build Order

When building a new site, follow this sequence:

1. **Data model** — Define schemas, tables, seed data
2. **Content layer** — Write loaders, define collections in `content.config.ts`
3. **Global styles** — Tokens, primitives CSS, reset
4. **Base layout** — Cover > Center > Stack spine in `Base.astro`
5. **Page layouts** — Article, Archive, etc. extending Base
6. **Pages** — Route files that query collections and render through layouts
7. **Components** — Cards, nav, footer, figures — composed from primitives
8. **Islands** — Only after everything works without JS
9. **Optimize** — Critical CSS inline, preload, verify budget

---

## Quick Reference: Astro Files

| File | Purpose |
|------|---------|
| `astro.config.mjs` | Site URL, output mode, integrations, adapters |
| `content.config.ts` | Collection definitions with schemas and loaders |
| `src/pages/**/*.astro` | Routes — each file = one URL |
| `src/layouts/*.astro` | Page shells with `<slot />` |
| `src/components/**/*.astro` | Reusable components |
| `src/styles/global.css` | Imported in Base layout for global styles |
| `src/lib/*.ts` | Utility functions, custom loaders |
| `public/` | Static assets served as-is |
| `db/config.ts` | Astro DB table definitions |
| `db/seed.ts` | Astro DB seed data |

---

## Reference Files

- `references/project-structure.md` — Canonical directory layout with annotations
- `references/content-layer.md` — Content Layer deep dive with custom loader patterns
- `references/routing.md` — Routing patterns for archive sites
- `references/performance.md` — Astro-specific performance rules
- `references/astro-config-recipes.md` — Common `astro.config.mjs` configurations

---

*For CSS primitives and composition, see the **css-layout-engine** skill.*
*For design tokens, theming, and accessibility, see the **css-design-system** skill.*
*For framework component ports, see the **framework-implementations** skill.*
