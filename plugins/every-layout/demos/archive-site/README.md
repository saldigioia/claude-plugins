# Archive Site Demo

A complete ye-archive-style site scaffold that exercises all 5 skills in the
Every Layout plugin:

1. **css-layout-engine** — Primitives compose every layout
2. **css-design-system** — Token architecture, theming, typography
3. **framework-implementations** — Astro component ports of primitives
4. **astro-site-architect** — Project structure, content layer, routing
5. **archival-data-engine** — Database schema, custom loader, typed collections

## Framework Port Demo

`/react-port/` is an integration test proving that React layout primitives from
the plugin's `framework-implementations` skill are usable in a real Astro project.

**What it demonstrates:**
- `Stack`, `Grid`, and `Sidebar` are extracted verbatim from
  `skills/framework-implementations/references/react.md` and placed in
  `src/components/react-ports/`. No reimplementation — the skill's output is the
  implementation.
- The React primitives provide structural layout; `Card.astro` (a pure Astro
  component) renders the card markup inside them. This proves React primitives
  can host Astro-rendered content as slot children.

**Ports exercised:** Stack (ELC_STACK), Grid (ELC_GRID), Sidebar (ELC_SIDEBAR)

**Hydration directive: `client:visible`**
The layout primitives appear below the page fold in a gallery context.
`client:visible` defers loading the React runtime until the island scrolls into
the viewport, avoiding an unnecessary JavaScript parse cost on initial load. The
primitives emit only inline CSS custom properties and class names — content that
Astro serialises correctly into static HTML before hydration fires — so there is
no hydration mismatch risk from the defer.

## Structure

```
archive-site/
├── astro.config.mjs           # Static output, sitemap, @astrojs/react
├── content.config.ts          # Collections from SQLite + local markdown
├── db/
│   └── schema.sql             # SQLite schema for archival data
├── src/
│   ├── lib/
│   │   └── loaders/
│   │       └── sqlite-loader.ts   # Custom content loader
│   ├── styles/
│   │   ├── global.css         # Tokens, reset, critical CSS
│   │   └── primitives.css     # Every Layout primitive classes
│   ├── layouts/
│   │   ├── Base.astro         # Cover > Center > Stack spine
│   │   └── Article.astro      # Prose layout
│   ├── components/
│   │   ├── Card.astro         # Work card using Box + Stack
│   │   └── react-ports/       # React port subset (integration test)
│   │       ├── types.ts       # Shared prop types
│   │       ├── Stack.tsx      # ELC_STACK — verbatim from react.md
│   │       ├── Grid.tsx       # ELC_GRID — verbatim from react.md
│   │       ├── Sidebar.tsx    # ELC_SIDEBAR — verbatim from react.md
│   │       └── index.ts       # Barrel export
│   └── pages/
│       ├── index.astro        # Archive index with Grid
│       ├── react-port/
│       │   └── index.astro    # Framework port integration test
│       └── works/
│           └── [slug].astro   # Dynamic work detail page
└── README.md
```

## How to Use

This demo is a reference blueprint, not a runnable project. Use it as a
starting point when the site-builder agent scaffolds a new archive site.

To make it runnable:
1. `npm create astro@latest` in a new directory
2. Copy the `src/` files into the new project
3. Create or mount a SQLite database matching `db/schema.sql`
4. `npm install better-sqlite3`
5. `npm run dev`
