# Astro Project Structure — Annotated Reference

## Root Files

| File | Purpose | Notes |
|------|---------|-------|
| `astro.config.mjs` | Central configuration | Site URL, output mode, integrations, adapters, Vite config overrides |
| `content.config.ts` | Content Layer definitions | Must export `collections` object. Lives at project root (not in `src/`). |
| `tsconfig.json` | TypeScript config | Astro provides base configs: `astro/tsconfigs/strict` recommended |
| `package.json` | Dependencies and scripts | `astro dev`, `astro build`, `astro preview`, `astro check` |
| `.env` / `.env.local` | Environment variables | Access via `import.meta.env`. Prefix with `PUBLIC_` for client exposure. |

---

## `src/` Directory

### `src/pages/`

Every `.astro`, `.md`, `.mdx`, `.html`, `.ts`, or `.js` file in this directory becomes a route. This is Astro's file-based router.

```
src/pages/
├── index.astro              # /
├── about.astro              # /about
├── 404.astro                # Custom 404 page
├── blog/
│   ├── index.astro          # /blog
│   └── [slug].astro         # /blog/:slug (dynamic)
├── archive/
│   └── [...slug].astro      # /archive/* (catch-all / rest params)
├── tags/
│   └── [tag].astro          # /tags/:tag
└── api/
    └── search.ts            # /api/search (API endpoint, returns Response)
```

**Rules:**
- One file = one route. No exceptions.
- `index.astro` files map to directory paths (trailing slash behavior configured in `astro.config.mjs`).
- `[param].astro` = dynamic segment. Must export `getStaticPaths()` in static mode.
- `[...rest].astro` = catch-all. Captures any depth of nested paths.
- `.ts`/`.js` files are API endpoints — must export HTTP method handlers (`GET`, `POST`, etc.).

### `src/layouts/`

Page shells that wrap content via `<slot />`. Not a special Astro directory — convention only, but a strong one.

```
src/layouts/
├── Base.astro               # HTML document shell (Cover > Center > Stack)
├── Article.astro            # Prose layout (extends Base)
├── Archive.astro            # Collection index layout (extends Base)
└── Docs.astro               # Documentation layout with sidebar (extends Base)
```

**Layout composition pattern:**

```astro
<!-- Base.astro provides the document shell -->
<!-- Article.astro wraps Base with article-specific structure -->
<!-- A page file uses the layout: -->
---
import Article from '../layouts/Article.astro';
---
<Article title="My Post">
  <p>Content fills the slot.</p>
</Article>
```

**Every Layout mapping:**
- `Base.astro` = Cover (full-viewport shell) + Center (measure constraint) + Stack (vertical rhythm)
- `Article.astro` = Stack with tighter spacing for prose
- `Archive.astro` = Stack (header + Grid of cards)
- `Docs.astro` = Sidebar (nav + Center > Stack)

### `src/components/`

Reusable UI pieces. Organize by concern:

```
src/components/
├── layout/                  # Every Layout primitive Astro components
│   ├── Stack.astro
│   ├── Center.astro
│   ├── Sidebar.astro
│   ├── Grid.astro
│   ├── Cluster.astro
│   ├── Cover.astro
│   ├── Box.astro
│   ├── Switcher.astro
│   ├── Frame.astro
│   ├── Reel.astro
│   ├── Imposter.astro
│   ├── Icon.astro
│   └── Container.astro
├── ui/                      # Application UI components
│   ├── Nav.astro
│   ├── Footer.astro
│   ├── Card.astro
│   ├── Tag.astro
│   └── Breadcrumb.astro
└── islands/                 # Interactive components (require client:*)
    ├── SearchWidget.tsx      # Framework component, hydrated
    └── ThemeToggle.astro     # Can be zero-JS with :checked hack
```

**Guidelines:**
- Components in `layout/` are pure CSS primitives — no JavaScript, no hydration.
- Components in `ui/` are Astro components — server-rendered, zero JS.
- Components in `islands/` are the only ones that should use `client:*` directives.
- Prefer `.astro` files. Only use `.tsx`/`.vue`/`.svelte` when the component genuinely needs client-side framework features.

### `src/content/`

Local content files for collections using the `glob()` or `file()` loader.

```
src/content/
├── blog/
│   ├── first-post.md
│   └── second-post.md
├── projects/
│   ├── project-a.md
│   └── project-b.md
└── data/
    ├── authors.json
    └── navigation.yaml
```

**Note:** In Astro 5, the `content.config.ts` at the project root defines which directories become collections and their schemas. The `src/content/` directory is not special — it's just a conventional location for local content files.

### `src/styles/`

Global stylesheets imported in the Base layout.

```
src/styles/
├── global.css               # :root tokens, border-box reset, element styles
├── primitives.css           # Every Layout primitive classes
├── print.css                # Print stylesheet
└── fonts/                   # Self-hosted font files (optional)
    ├── font.woff2
    └── font-italic.woff2
```

**Loading strategy:**
- `global.css` critical tokens inlined in `<style is:inline>` in `<head>`
- `primitives.css` loaded via `<link rel="preload">`
- `print.css` loaded via `<link media="print">`

### `src/lib/`

Utility functions, custom content loaders, shared logic.

```
src/lib/
├── loaders/
│   └── sqlite-loader.ts     # Custom content loader for SQLite
├── utils/
│   ├── dates.ts             # Date formatting helpers
│   └── slugify.ts           # URL slug generation
└── types.ts                 # Shared TypeScript types
```

### `src/assets/`

Images and other files processed by Astro's asset pipeline. Import these in components to get optimized output.

```astro
---
import { Image } from 'astro:assets';
import photo from '../assets/photo.jpg';
---
<Image src={photo} alt="Description" />
```

---

## `public/` Directory

Static files served as-is, no processing. Use for:

```
public/
├── favicon.ico
├── favicon.svg
├── robots.txt
├── site.webmanifest
└── fonts/                   # If not importing through src/styles/
    └── font.woff2
```

**Rule:** If an asset needs optimization (images, CSS), put it in `src/`. If it's served verbatim (favicon, robots.txt), put it in `public/`.

---

## `db/` Directory (Astro DB)

Only present when using Astro DB for database-backed content.

```
db/
├── config.ts                # Table definitions using Drizzle-style schema
└── seed.ts                  # Seed data, runs on `astro db push`
```

---

## Anti-Patterns

| Pattern | Problem | Fix |
|---------|---------|-----|
| Components in `src/pages/` | Conflates routes with reusable UI | Move to `src/components/` |
| Layouts importing layouts | Creates confusing inheritance chains | Use slot composition, not deep nesting |
| `client:load` on everything | Ships unnecessary JS | Default to no directive; justify each island |
| CSS in `public/` | Bypasses Astro's build pipeline | Put in `src/styles/` and import |
| Barrel exports for Astro components | Astro components can't be re-exported from `.ts` | Import directly from file paths |
| `src/content/config.ts` | Astro 4 legacy location | Move to `content.config.ts` at project root (Astro 5) |
