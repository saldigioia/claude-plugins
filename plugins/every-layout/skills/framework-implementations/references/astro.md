# Astro Implementation

All 13 Every Layout primitives as Astro components, plus barrel export.

## Box.astro

```astro
---
/**
 * Box Component
 * Padded container with optional border
 */

interface Props {
  padding?: string;
  borderWidth?: string;
  invert?: boolean;
  class?: string;
}

const {
  padding = 'var(--s1)',
  borderWidth = 'var(--border-thin, 1px)',
  invert = false,
  class: className = ''
} = Astro.props;
---

<div class:list={['box', { 'box--invert': invert }, className]}>
  <slot />
</div>

<style define:vars={{ padding, borderWidth }}>
  .box {
    padding: var(--padding);
    border-width: var(--borderWidth);
    border-style: solid;
    color: var(--color-dark, #000);
    background-color: var(--color-light, #fff);
  }
  .box :global(*) {
    color: inherit;
  }
  .box--invert {
    color: var(--color-light, #fff);
    background-color: var(--color-dark, #000);
  }
</style>
```

## Center.astro

```astro
---
/**
 * Center Component
 * Horizontal centering with max-width constraint
 */

interface Props {
  max?: string;
  gutters?: string;
  intrinsic?: boolean;
  andText?: boolean;
  class?: string;
}

const {
  max = 'var(--measure, 65ch)',
  gutters = 'var(--s1, 1rem)',
  intrinsic = false,
  andText = false,
  class: className = ''
} = Astro.props;
---

<div class:list={['center', { 'center--intrinsic': intrinsic, 'center--text': andText }, className]}>
  <slot />
</div>

<style define:vars={{ max, gutters }}>
  .center {
    box-sizing: content-box;
    max-inline-size: var(--max);
    margin-inline: auto;
    padding-inline: var(--gutters);
  }
  .center--intrinsic {
    display: flex;
    flex-direction: column;
    align-items: center;
  }
  .center--text {
    text-align: center;
  }
</style>
```

## Cluster.astro

```astro
---
/**
 * Cluster Component
 * Flexible wrapping horizontal layout
 */

interface Props {
  space?: string;
  justify?: 'flex-start' | 'flex-end' | 'center' | 'space-between' | 'space-around' | 'space-evenly';
  align?: 'flex-start' | 'flex-end' | 'center' | 'baseline' | 'stretch';
  class?: string;
}

const {
  space = 'var(--s1, 1rem)',
  justify = 'flex-start',
  align = 'center',
  class: className = ''
} = Astro.props;
---

<div class:list={['cluster', className]}>
  <slot />
</div>

<style define:vars={{ space, justify, align }}>
  .cluster {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space);
    justify-content: var(--justify);
    align-items: var(--align);
  }
  .cluster > :global(*) {
    min-inline-size: 0; /* ELP_033 */
  }
</style>
```

## Container.astro

```astro
---
/**
 * Container Component
 * Container query context wrapper
 */

interface Props {
  containerName?: string;
  class?: string;
}

const {
  containerName,
  class: className = ''
} = Astro.props;
---

{/* Canonical parameter name per the port contract: --container-name.
    One static block; the conditional define:vars only controls whether the
    custom property is emitted (same idiom as Cover's minHeight). */}
<div class:list={['container', className]}>
  <slot />
</div>

<style define:vars={containerName ? { containerName } : {}}>
  .container {
    container-type: inline-size;
    container-name: var(--containerName, layout);
  }
</style>
```

## Cover.astro

```astro
---
/**
 * Cover Component
 * Vertical centering with optional header/footer
 *
 * `minHeight` has no default — same conditional-vars idiom as Container.astro's
 * `name`. Unlike the React/Vue/Svelte ports, this component's `.cover` rule is
 * its own self-contained scoped style (Astro components don't share the
 * external canonical stylesheet), so the two-declaration viewport chain lives
 * right here: `min-block-size: var(--minHeight, 100vh)` then
 * `min-block-size: var(--minHeight, 100dvh)` gives supporting browsers the
 * stable 100dvh mobile viewport while older engines fall back to 100vh
 * (mirrors references/vanilla.md's chain). `--minHeight` is only added to
 * `define:vars` when the caller actually passes minHeight, exactly like
 * Container.astro only adds `--name` when `name` is passed — never emit the
 * custom property with an undefined value. Passing minHeight overrides the
 * chain with a single fixed value, so only pass it when you mean a fixed
 * viewport unit.
 */

interface Props {
  space?: string;
  minHeight?: string;
  noPad?: boolean;
  class?: string;
}

const {
  space = 'var(--s1, 1rem)',
  minHeight,
  noPad = false,
  class: className = ''
} = Astro.props;
---

{/* The centered element marks ITSELF: `class="principal"` (canonical) or a
    bare `data-centered` attribute (port alias) — the static rules below
    match both. The old selector-string `centered` prop is gone: it fed a
    per-instance <style> block keyed on a generated id, which Astro never
    templates (plain <style> blocks are static), and id selectors violate
    ELA_003 anyway. */}
<div class:list={['cover', { 'cover--no-pad': noPad }, className]}>
  <slot />
</div>

<style define:vars={minHeight ? { space, minHeight } : { space }}>
  .cover {
    display: flex;
    flex-direction: column;
    min-block-size: var(--minHeight, 100vh);
    min-block-size: var(--minHeight, 100dvh);
    padding: var(--space);
  }
  .cover--no-pad {
    padding: 0;
  }
  .cover > :global(*) {
    margin-block: var(--space);
  }
  .cover > :global(:first-child:not(.principal):not([data-centered])) {
    margin-block-start: 0;
  }
  .cover > :global(:last-child:not(.principal):not([data-centered])) {
    margin-block-end: 0;
  }
  .cover > :global(.principal),
  .cover > :global([data-centered]) {
    margin-block: auto;
  }
</style>
```

## Frame.astro

```astro
---
/**
 * Frame Component
 * Aspect ratio container for media
 */

interface Props {
  ratio?: string;
  class?: string;
}

const {
  ratio = '16 / 9',
  class: className = ''
} = Astro.props;
---

<div class:list={['frame', className]}>
  <slot />
</div>

<style define:vars={{ ratio }}>
  .frame {
    aspect-ratio: var(--ratio);
    overflow: hidden;
    display: flex;
    justify-content: center;
    align-items: center;
  }
  .frame > :global(img),
  .frame > :global(video) {
    inline-size: 100%;
    block-size: 100%;
    object-fit: cover;
  }
</style>
```

## Grid.astro

```astro
---
/**
 * Grid Component
 * Responsive grid with intrinsic sizing
 */

interface Props {
  min?: string;
  space?: string;
  class?: string;
}

const {
  min = '15rem',
  space = 'var(--s1, 1rem)',
  class: className = ''
} = Astro.props;
---

<div class:list={['grid', className]}>
  <slot />
</div>

<style define:vars={{ min, space }}>
  .grid {
    display: grid;
    gap: var(--space);
    grid-template-columns: repeat(auto-fit, minmax(min(var(--min), 100%), 1fr));
  }
  .grid > :global(*) {
    min-inline-size: 0; /* ELP_033 */
  }
</style>
```

## Icon.astro

```astro
---
/**
 * Icon Component
 * Inline SVG icon sizing and alignment
 */

interface Props {
  space?: string;
  label?: string;
  class?: string;
}

const {
  space = '0.5em',
  label,
  class: className = ''
} = Astro.props;
---

<span
  class:list={['with-icon', className]}
  role={label ? 'img' : undefined}
  aria-label={label}
>
  <slot />
</span>

<style define:vars={{ space }}>
  .with-icon {
    display: inline-flex;
    align-items: baseline;
  }
  .with-icon > :global(.icon) {
    height: 0.75em;
    height: 1cap;
    width: 0.75em;
    width: 1cap;
    margin-inline-end: var(--space);
  }
</style>
```

## Imposter.astro

```astro
---
/**
 * Imposter Component
 * Superimposed/overlay positioning
 */

interface Props {
  breakout?: boolean;
  margin?: string;
  fixed?: boolean;
  class?: string;
}

const {
  breakout = false,
  margin = '0px',
  fixed = false,
  class: className = ''
} = Astro.props;

const positioning = fixed ? 'fixed' : 'absolute';
---

<div class:list={['imposter', { 'imposter--contain': !breakout }, className]}>
  <slot />
</div>

<style define:vars={{ positioning, margin }}>
  .imposter {
    position: var(--positioning);
    inset-block-start: 50%;
    inset-inline-start: 50%;
    transform: translate(-50%, -50%);
  }
  .imposter--contain {
    overflow: auto;
    max-inline-size: calc(100% - (var(--margin) * 2));
    max-block-size: calc(100% - (var(--margin) * 2));
  }
</style>
```

## Reel.astro

```astro
---
/**
 * Reel Component
 * Horizontal scrolling container
 */

interface Props {
  itemWidth?: string;
  space?: string;
  height?: string;
  noBar?: boolean;
  class?: string;
}

const {
  itemWidth = 'auto',
  space = 'var(--s1, 1rem)',
  height = 'auto',
  noBar = false,
  class: className = ''
} = Astro.props;
---

<div class:list={['reel', { 'reel--no-bar': noBar }, className]}>
  <slot />
</div>

<style define:vars={{ itemWidth, space, height }}>
  .reel {
    display: flex;
    block-size: var(--height);
    overflow-x: auto;
    overflow-y: hidden;
  }
  .reel > :global(*) {
    flex: 0 0 var(--itemWidth);
  }
  .reel > :global(img) {
    block-size: 100%;
    flex-basis: auto;
    width: auto;
  }
  .reel > :global(* + *) {
    margin-inline-start: var(--space);
  }
  .reel--no-bar {
    scrollbar-width: none;
  }
  .reel--no-bar::-webkit-scrollbar {
    display: none;
  }
</style>
```

## Sidebar.astro

```astro
---
/**
 * Sidebar Component
 * Two-element layout with intrinsic switching
 */

interface Props {
  side?: 'left' | 'right';
  sideWidth?: string;
  contentMin?: string;
  space?: string;
  noStretch?: boolean;
  class?: string;
}

const {
  side = 'left',
  sideWidth = '20rem',
  contentMin = '50%',
  space = 'var(--s1, 1rem)',
  noStretch = false,
  class: className = ''
} = Astro.props;
---

{/* All variant styling is static: the `side` prop becomes a data attribute
    the scoped CSS keys on. No per-instance ids, no conditional <style>
    blocks — plain <style> is never templated in Astro, and generated ids
    would break both ELA_003 (ID selectors) and build determinism (ELA_006). */}
<div
  class:list={['with-sidebar', { 'with-sidebar--no-stretch': noStretch }, className]}
  data-side={side === 'right' ? 'right' : undefined}
>
  <slot />
</div>

<style define:vars={{ sideWidth, contentMin, space }}>
  .with-sidebar {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space);
  }
  .with-sidebar > :global(*) {
    flex-grow: 1;
  }
  .with-sidebar > :global(:first-child) {
    flex-basis: var(--sideWidth);
    min-inline-size: 0; /* ELP_033 — the content pane's contentMin already replaces auto */
  }
  .with-sidebar > :global(:last-child) {
    flex-basis: 0;
    flex-grow: 999;
    min-inline-size: var(--contentMin);
  }
  /* Right-hand sidebar: same recipe mirrored. data-side is Sidebar-only, so
     the attribute alone keeps each selector at 0-2-0 (ELA_003). */
  [data-side="right"] > :global(:first-child) {
    flex-basis: 0;
    flex-grow: 999;
    min-inline-size: var(--contentMin);
  }
  [data-side="right"] > :global(:last-child) {
    flex-basis: var(--sideWidth);
    flex-grow: 1;
    min-inline-size: 0; /* ELP_033 */
  }
  .with-sidebar--no-stretch {
    align-items: flex-start;
  }
</style>
```

## Stack.astro

```astro
---
/**
 * Stack Component
 * Vertical spacing between sibling elements
 */

interface Props {
  space?: string;
  recursive?: boolean;
  class?: string;
}

const {
  space = 'var(--s1)',
  recursive = false,
  class: className = ''
} = Astro.props;
---

{/* To split a stack, mark the CHILD after which the split happens with a
    bare `data-split-after` attribute — the static rule below handles it.
    (The numeric splitAfter prop is gone: counting children required
    per-instance generated CSS, which is exactly what this port must not
    ship. Same child-marker contract as the React/Vue/Svelte ports.) */}
<div class:list={['stack', className]} data-recursive={recursive ? '' : undefined}>
  <slot />
</div>

<style define:vars={{ space }}>
  .stack {
    display: flex;
    flex-direction: column;
    justify-content: flex-start;
  }
  .stack > :global(*) {
    margin-block: 0;
  }
  .stack > :global(* + *) {
    margin-block-start: var(--space);
  }
  .stack[data-recursive] :global(* + *) {
    margin-block-start: var(--space);
  }
  .stack > :global([data-split-after]) {
    margin-block-end: auto;
  }
</style>
```

## Switcher.astro

```astro
---
/**
 * Switcher Component
 * Equal columns that switch to stack below threshold
 */

interface Props {
  threshold?: string;
  space?: string;
  limit?: 2 | 3 | 4;
  class?: string;
}

const {
  threshold = '30rem',
  space = 'var(--s1, 1rem)',
  limit,
  class: className = ''
} = Astro.props;
---

{/* `limit` passes straight through as data-limit; the static rules below
    match the stylesheet's [data-limit="2|3|4"] contract. data-limit is
    Switcher-only, so the attribute alone stays at 0-2-0 (ELA_003). */}
<div class:list={['switcher', className]} data-limit={limit}>
  <slot />
</div>

<style define:vars={{ threshold, space }}>
  .switcher {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space);
  }
  .switcher > :global(*) {
    flex-grow: 1;
    flex-basis: calc((var(--threshold) - 100%) * 999);
    min-inline-size: 0; /* ELP_033 */
  }
  [data-limit="2"] > :global(:nth-last-child(n+3)),
  [data-limit="2"] > :global(:nth-last-child(n+3) ~ *) {
    flex-basis: 100%;
  }
  [data-limit="3"] > :global(:nth-last-child(n+4)),
  [data-limit="3"] > :global(:nth-last-child(n+4) ~ *) {
    flex-basis: 100%;
  }
  [data-limit="4"] > :global(:nth-last-child(n+5)),
  [data-limit="4"] > :global(:nth-last-child(n+5) ~ *) {
    flex-basis: 100%;
  }
</style>
```

## Barrel Export (index.ts)

```typescript
/**
 * Every Layout - Astro Components
 * Based on "Every Layout" by Andy Bell and Heydon Pickering
 *
 * Usage:
 * import { Stack, Box, Center, Cluster, Grid } from './index';
 *
 * Or import individually:
 * import Stack from './Stack.astro';
 */

export { default as Stack } from './Stack.astro';
export { default as Box } from './Box.astro';
export { default as Center } from './Center.astro';
export { default as Cluster } from './Cluster.astro';
export { default as Sidebar } from './Sidebar.astro';
export { default as Switcher } from './Switcher.astro';
export { default as Cover } from './Cover.astro';
export { default as Grid } from './Grid.astro';
export { default as Frame } from './Frame.astro';
export { default as Reel } from './Reel.astro';
export { default as Imposter } from './Imposter.astro';
export { default as Icon } from './Icon.astro';
export { default as Container } from './Container.astro';
```

## Prop/Slot API Summary

All Astro components accept a `class` prop and render a `<slot />` for children.

| Component | Props | Defaults |
|-----------|-------|----------|
| Box | `padding`, `borderWidth`, `invert` | `var(--s1)`, `var(--border-thin, 1px)`, `false` |
| Center | `max`, `gutters`, `intrinsic`, `andText` | `var(--measure, 65ch)`, `var(--s1, 1rem)`, `false`, `false` |
| Cluster | `space`, `justify`, `align` | `var(--s1, 1rem)`, `flex-start`, `center` |
| Container | `name` | `undefined` |
| Cover | `space`, `minHeight`, `noPad` | `var(--s1, 1rem)`, `— (stylesheet: 100dvh, 100vh fallback)`, `false` — mark the centered child itself: `class="principal"` or `data-centered` |
| Frame | `ratio` | `16 / 9` |
| Grid | `min`, `space` | `15rem`, `var(--s1, 1rem)` |
| Icon | `space`, `label` | `0.5em`, `undefined` |
| Imposter | `breakout`, `margin`, `fixed` | `false`, `0px`, `false` |
| Reel | `itemWidth`, `space`, `height`, `noBar` | `auto`, `var(--s1, 1rem)`, `auto`, `false` |
| Sidebar | `side`, `sideWidth`, `contentMin`, `space`, `noStretch` | `left`, `20rem`, `50%`, `var(--s1, 1rem)`, `false` |
| Stack | `space`, `recursive` | `var(--s1)`, `false` — split via a `data-split-after` attribute on the child |
| Switcher | `threshold`, `space`, `limit` (2\|3\|4 → `data-limit`) | `30rem`, `var(--s1, 1rem)`, `undefined` |
