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
  max = 'var(--measure, 60ch)',
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
  name?: string;
  class?: string;
}

const {
  name,
  class: className = ''
} = Astro.props;
---

<div class:list={['container', className]}>
  <slot />
</div>

<style define:vars={name ? { name } : {}}>
  .container {
    container-type: inline-size;
  }
</style>

{name && (
  <style>
    .container { container-name: var(--name); }
  </style>
)}
```

## Cover.astro

```astro
---
/**
 * Cover Component
 * Vertical centering with optional header/footer
 */

interface Props {
  centered?: string;
  space?: string;
  minHeight?: string;
  noPad?: boolean;
  class?: string;
}

const {
  centered = '[data-centered]',
  space = 'var(--s1, 1rem)',
  minHeight = '100vh',
  noPad = false,
  class: className = ''
} = Astro.props;

const id = `cover-${Math.random().toString(36).slice(2, 9)}`;
---

<div class:list={['cover', { 'cover--no-pad': noPad }, className]} id={id}>
  <slot />
</div>

<style define:vars={{ space, minHeight }}>
  .cover {
    display: flex;
    flex-direction: column;
    min-block-size: var(--minHeight);
    padding: var(--space);
  }
  .cover--no-pad {
    padding: 0;
  }
  .cover > :global(*) {
    margin-block: var(--space);
  }
</style>

<style>
  #{id} > :global(:first-child:not({centered})) {
    margin-block-start: 0;
  }
  #{id} > :global(:last-child:not({centered})) {
    margin-block-end: 0;
  }
  #{id} > :global({centered}) {
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

const id = `sidebar-${Math.random().toString(36).slice(2, 9)}`;
---

<div class:list={['with-sidebar', { 'with-sidebar--no-stretch': noStretch }, className]} id={id}>
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
  .with-sidebar--no-stretch {
    align-items: flex-start;
  }
</style>

{side === 'left' ? (
  <style>
    #{id} > :global(:first-child) {
      flex-basis: var(--sideWidth);
    }
    #{id} > :global(:last-child) {
      flex-basis: 0;
      flex-grow: 999;
      min-inline-size: var(--contentMin);
    }
  </style>
) : (
  <style>
    #{id} > :global(:last-child) {
      flex-basis: var(--sideWidth);
    }
    #{id} > :global(:first-child) {
      flex-basis: 0;
      flex-grow: 999;
      min-inline-size: var(--contentMin);
    }
  </style>
)}
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
  splitAfter?: number;
  class?: string;
}

const {
  space = 'var(--s1)',
  recursive = false,
  splitAfter,
  class: className = ''
} = Astro.props;

const id = `stack-${Math.random().toString(36).slice(2, 9)}`;
---

<div class:list={['stack', className]} id={id}>
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
</style>

{recursive && (
  <style>
    #{id} :global(* + *) {
      margin-block-start: var(--space);
    }
  </style>
)}

{splitAfter && (
  <style>
    #{id} > :global(:nth-child({splitAfter})) {
      margin-block-end: auto;
    }
  </style>
)}
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
  limit?: number;
  class?: string;
}

const {
  threshold = '30rem',
  space = 'var(--s1, 1rem)',
  limit,
  class: className = ''
} = Astro.props;

const id = `switcher-${Math.random().toString(36).slice(2, 9)}`;
---

<div class:list={['switcher', className]} id={id}>
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
  }
</style>

{limit && (
  <style>
    #{id} > :global(:nth-last-child(n+{limit + 1})),
    #{id} > :global(:nth-last-child(n+{limit + 1}) ~ *) {
      flex-basis: 100%;
    }
  </style>
)}
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
| Center | `max`, `gutters`, `intrinsic`, `andText` | `var(--measure, 60ch)`, `var(--s1, 1rem)`, `false`, `false` |
| Cluster | `space`, `justify`, `align` | `var(--s1, 1rem)`, `flex-start`, `center` |
| Container | `name` | `undefined` |
| Cover | `centered`, `space`, `minHeight`, `noPad` | `[data-centered]`, `var(--s1, 1rem)`, `100vh`, `false` |
| Frame | `ratio` | `16 / 9` |
| Grid | `min`, `space` | `15rem`, `var(--s1, 1rem)` |
| Icon | `space`, `label` | `0.5em`, `undefined` |
| Imposter | `breakout`, `margin`, `fixed` | `false`, `0px`, `false` |
| Reel | `itemWidth`, `space`, `height`, `noBar` | `auto`, `var(--s1, 1rem)`, `auto`, `false` |
| Sidebar | `side`, `sideWidth`, `contentMin`, `space`, `noStretch` | `left`, `20rem`, `50%`, `var(--s1, 1rem)`, `false` |
| Stack | `space`, `recursive`, `splitAfter` | `var(--s1)`, `false`, `undefined` |
| Switcher | `threshold`, `space`, `limit` | `30rem`, `var(--s1, 1rem)`, `undefined` |
