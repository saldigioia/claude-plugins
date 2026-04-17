---
name: framework-implementations
description: "Every Layout component ports: Astro, React, Vue, Svelte, Tailwind, vanilla CSS. Use for .astro, .tsx, .jsx, .vue, .svelte, tailwind.config, or any ELC_* primitive in a framework — Stack, Box, Grid, Sidebar, Switcher, Cover, Frame, Reel."
allowed-tools: Read Write Edit Grep Glob
paths:
  - "**/*.astro"
  - "**/*.tsx"
  - "**/*.jsx"
  - "**/*.vue"
  - "**/*.svelte"
  - "**/*.css"
  - "**/tailwind.config.*"
---

# Framework Implementations

Component ports of the 13 Every Layout primitives across 6 implementations.

> **Axiomatic commitment.** Each port is a prop-to-custom-property bridge only — it must not add runtime behavior the canonical CSS doesn't have, must not inject framework-runtime styling (CSS-in-JS is forbidden per axiom **ELA_005**), and must not require JavaScript to render correctly at initial paint. See `skills/css-layout-engine/references/axioms.md`.

## Available Frameworks

| Framework | Reference File | Components | Extras |
|-----------|---------------|------------|--------|
| **Astro** | `references/astro.md` | 13 `.astro` components | `index.ts` barrel export |
| **React** | `references/react.md` | 13 `.tsx` components | `types.ts` shared types + `index.ts` |
| **Vue** | `references/vue.md` | 13 `.vue` SFCs | `types.ts` shared types + `index.ts` |
| **Svelte** | `references/svelte.md` | 13 `.svelte` components | `index.ts` barrel export |
| **Tailwind** | `references/tailwind.md` | Plugin + tokens | `plugin.js` + `tokens.js` |
| **Vanilla CSS** | `references/vanilla.md` | CSS files | `every-layout.css` + `print.css` + `README.md` |

## Common Prop API

All framework implementations expose the same props (mapped to CSS custom properties):

| Prop | CSS Custom Property | Used By | Default |
|------|-------------------|---------|---------|
| `space` | `--space` | Stack, Cluster, Sidebar, Switcher, Grid, Reel | `var(--s1)` |
| `padding` | `--padding` | Box, Cover | `var(--s1)` |
| `measure` | `--measure` | Center | `65ch` |
| `gutter` | `--gutter` | Center | `1rem` |
| `sideWidth` | `--side-width` | Sidebar | `20rem` |
| `contentMin` | `--content-min` | Sidebar | `50%` |
| `threshold` | `--threshold` | Switcher | `30rem` |
| `min` | `--min` | Grid | `15rem` |
| `ratio` | `--ratio` | Frame | `16/9` |
| `minHeight` | `--min-height` | Cover | `100vh` |
| `itemWidth` | `--item-width` | Reel | `auto` |

## Usage Pattern

All components accept:
- Layout-specific props (above)
- A default slot for children
- Standard HTML attributes pass through

```astro
<!-- Astro example -->
<Stack space="var(--s2)">
  <Box padding="var(--s1)">
    <p>Content here</p>
  </Box>
</Stack>
```

## Generating New Ports

For porting primitives to a new framework, see `references/porting-guide.md`.
