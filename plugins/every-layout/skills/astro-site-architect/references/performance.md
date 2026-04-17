# Astro Performance — Deep Reference

Performance rules specific to Astro site building, complementing the CSS performance budget from the `css-design-system` skill.

---

## Zero-JS Default

Astro's core performance advantage: **no JavaScript ships unless you explicitly opt in.**

Every `.astro` component renders to static HTML at build time. The `client:*` directive is the only way to ship JS. This is not a limitation — it's the architecture.

### Hydration Cost Reference

| Directive | JS Shipped | Parse/Execute Timing |
|-----------|-----------|---------------------|
| *(none)* | 0 bytes | Never |
| `client:visible` | Component + framework runtime | On intersection |
| `client:idle` | Component + framework runtime | After `requestIdleCallback` |
| `client:load` | Component + framework runtime | Immediately |
| `client:only` | Component + framework runtime | Immediately (no SSR) |

**Framework runtime costs (approximate):**

| Framework | Runtime Size (gzipped) |
|-----------|----------------------|
| Preact | ~4 KB |
| Svelte | ~2 KB (per component) |
| Vue | ~16 KB |
| React | ~40 KB |
| Solid | ~7 KB |

**Rule:** If you must hydrate, prefer Preact or Svelte over React/Vue for the smallest runtime cost.

---

## Critical CSS Strategy

### Inline Critical CSS

The most important CSS must be in `<style is:inline>` in the `<head>` to avoid render-blocking:

```astro
<head>
  <style is:inline>
    /* ~1.2 KB: tokens + center + stack + border-box */
    *, *::before, *::after { box-sizing: border-box; }
    :root {
      --ratio: 1.5;
      --s-2: 0.444rem; --s-1: 0.667rem; --s0: 1rem;
      --s1: 1.5rem; --s2: 2.25rem; --s3: 3.375rem;
      --s4: 5.063rem; --s5: 7.594rem;
      --measure: 65ch;
      color-scheme: light dark;
    }
    body { margin: 0; }
    .center {
      box-sizing: content-box;
      max-inline-size: var(--measure, 65ch);
      margin-inline: auto;
      padding-inline: var(--gutter, 1rem);
    }
    .stack { display: flex; flex-direction: column; justify-content: flex-start; }
    .stack > * { margin-block: 0; }
    .stack > * + * { margin-block-start: var(--space, 1.5rem); }
    .cover { display: flex; flex-direction: column; min-block-size: 100vh; }
    .cover > * { margin-block: var(--s1); }
    .cover > :first-child:not(.principal) { margin-block-start: 0; }
    .cover > :last-child:not(.principal) { margin-block-end: 0; }
    .cover > .principal { margin-block: auto; }
  </style>
</head>
```

### Async Load Remaining CSS

```astro
<head>
  <!-- Critical CSS inline above -->

  <!-- src/styles/* is NOT served at /styles/ — Astro content-hashes it to /_astro/*.
       For a CSS file you want in the build pipeline, import it from the layout frontmatter:
         import '../styles/primitives.css';
       Astro will inject the correct hashed <link> itself.
       Only use raw <link href="/styles/..."> if the file is in public/ (no hashing, no minify). -->
</head>
```

If you genuinely need a stable-URL unhashed CSS file (e.g. for a legacy consumer or a third-party embed), put it in `public/styles/` and reference it as:

```html
<link rel="preload" href="/styles/primitives.css" as="style" />
<link rel="stylesheet" href="/styles/primitives.css" />
```

The `public/` directory bypasses Astro's build pipeline entirely — no minification, no hashing, no tree-shaking. Prefer the import-based path for anything you own.

### Astro Scoped Styles

Astro `<style>` blocks are automatically scoped and extracted:

```astro
<style>
  /* This CSS is scoped to this component and extracted to a .css file */
  .card { /* ... */ }
</style>
```

Use `is:global` sparingly — only for styles that genuinely need global scope:

```astro
<style is:global>
  /* Applies globally — use only in Base layout for element resets */
</style>
```

---

## Image Optimization

### `astro:assets` — The Only Way

```astro
---
import { Image } from 'astro:assets';
import hero from '../assets/hero.jpg';
---

<!-- Local image: fully optimized -->
<Image
  src={hero}
  alt="Descriptive text"
  widths={[400, 800, 1200]}
  sizes="(max-width: 800px) 100vw, 800px"
  format="avif"
  quality={80}
  loading="lazy"
  decoding="async"
/>
```

### Rules

1. **Always import local images.** `import img from '../assets/img.jpg'` — this enables optimization.
2. **Always set `alt`.** Empty string for decorative images: `alt=""`.
3. **Always set `width` and `height`** (automatic when imported) to prevent CLS.
4. **Use `loading="lazy"`** for below-fold images.
5. **Use `decoding="async"`** always.
6. **Prefer AVIF** (`format="avif"`) with WebP fallback for older browsers.
7. **Provide `widths` and `sizes`** for responsive images.
8. **Use `<Picture>` for art direction:**

```astro
---
import { Picture } from 'astro:assets';
import hero from '../assets/hero.jpg';
---

<Picture
  src={hero}
  formats={['avif', 'webp']}
  widths={[400, 800, 1200]}
  sizes="(max-width: 800px) 100vw, 800px"
  alt="Description"
/>
```

### Remote Images

```javascript
// astro.config.mjs
export default defineConfig({
  image: {
    domains: ['cdn.example.com'],
    // or
    remotePatterns: [{ protocol: 'https', hostname: '**.example.com' }],
  },
});
```

---

## Font Loading

### Self-Hosted Fonts (Recommended)

```css
/* src/styles/global.css */
@font-face {
  font-family: 'Body';
  src: url('/fonts/body.woff2') format('woff2');
  font-weight: 400;
  font-style: normal;
  font-display: optional;  /* Prevents CLS with ch-unit measure */
}
```

**Rules:**
- Use `font-display: optional` when the layout uses `ch` units (Center's `--measure`). This prevents CLS caused by font metric differences.
- Subset fonts to required character sets.
- Preload the primary font:

```html
<link rel="preload" href="/fonts/body.woff2" as="font" type="font/woff2" crossorigin />
```

---

## View Transitions

Astro's View Transitions provide smooth page navigation without full-page reloads, using the browser-native View Transitions API with a fallback.

```astro
---
import { ClientRouter } from 'astro:transitions';
---
<head>
  <ClientRouter />
</head>
```

Astro 5 renamed this component from `ViewTransitions` to `ClientRouter`. The old name is a deprecated alias retained for backwards compatibility — use `ClientRouter` in new code.

### Performance Implications

- **Positive:** Avoids full page reload, feels instant.
- **Positive:** Prefetches linked pages on hover.
- **Neutral:** Adds ~3 KB of JS for the transition router.
- **Caution:** Persistent islands keep their state across navigations — can cause memory leaks if not careful.

### Transition Directives

```astro
<!-- Named transition for matching elements across pages -->
<h1 transition:name="page-title">{title}</h1>

<!-- Animation style -->
<div transition:animate="slide">Content</div>

<!-- Persist element across navigations (no re-render) -->
<video transition:persist>...</video>
```

---

## Build Output Optimization

### Static Site (Default)

```
dist/
├── index.html
├── about/index.html
├── blog/
│   ├── index.html
│   └── my-post/index.html
├── _astro/
│   ├── primitives.abc123.css
│   └── hero.def456.avif
└── fonts/
    └── body.woff2
```

All assets in `_astro/` are content-hashed for aggressive caching.

### Build Performance Tips

1. **Content caching.** Astro 5 caches content layer data between builds. Loaders that use `digest` enable incremental updates.
2. **Parallel image processing.** Astro processes images in parallel during build.
3. **Avoid dynamic imports in frontmatter.** These create additional build chunks.

---

## Performance Checklist

- [ ] Zero `client:*` directives unless justified
- [ ] Critical CSS inlined in `<head>` (~1.2 KB)
- [ ] Remaining CSS preloaded, not render-blocking
- [ ] All images use `astro:assets` with width/height
- [ ] Below-fold images use `loading="lazy"`
- [ ] Fonts use `font-display: optional`
- [ ] Primary font preloaded
- [ ] Static output mode (no server runtime)
- [ ] Total CSS within system budget — see `css-design-system/references/performance-rules.md`
- [ ] View Transitions enabled for multi-page navigation
- [ ] No unnecessary framework runtimes shipped
