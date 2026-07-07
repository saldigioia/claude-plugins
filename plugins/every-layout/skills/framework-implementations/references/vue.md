# Vue Implementation

All 13 Every Layout primitives as Vue 3 components with Composition API, plus shared types and barrel export.

**The stylesheet is loaded once per app** (see `references/vanilla.md`; `demos/every-layout.css` is its built artifact). These ports do not carry CSS — they render a primitive's class name and bind only the `--custom-property` parameters that class reads. Boolean variants become `data-*` attributes the stylesheet already selects on. See "Why no style objects" below.

## Shared Types (types.ts)

```typescript
/**
 * Every Layout - Vue Component Types
 * Based on "Every Layout" by Andy Bell and Heydon Pickering
 */

import type { CSSProperties } from 'vue';

// Base props that all layout components share
export interface BaseLayoutProps {
  as?: string;
  class?: string;
  style?: CSSProperties;
}

// Stack
export interface StackProps extends BaseLayoutProps {
  space?: string;
  recursive?: boolean;
}

// Box
export interface BoxProps extends BaseLayoutProps {
  padding?: string;
  borderWidth?: string;
  invert?: boolean;
}

// Center
export interface CenterProps extends BaseLayoutProps {
  max?: string;
  gutters?: string;
  intrinsic?: boolean;
  andText?: boolean;
}

// Cluster
export interface ClusterProps extends BaseLayoutProps {
  space?: string;
  justify?: string;
  align?: string;
}

// Sidebar
export interface SidebarProps extends BaseLayoutProps {
  side?: 'left' | 'right';
  sideWidth?: string;
  contentMin?: string;
  space?: string;
  noStretch?: boolean;
}

// Switcher
export interface SwitcherProps extends BaseLayoutProps {
  threshold?: string;
  space?: string;
  limit?: number;
}

// Cover
export interface CoverProps extends BaseLayoutProps {
  centered?: string;
  space?: string;
  minHeight?: string;
  noPad?: boolean;
}

// Grid
export interface GridProps extends BaseLayoutProps {
  min?: string;
  space?: string;
  ragged?: boolean;
}

// Frame
export interface FrameProps extends BaseLayoutProps {
  ratio?: string;
}

// Reel
export interface ReelProps extends BaseLayoutProps {
  itemWidth?: string;
  space?: string;
  height?: string;
  noBar?: boolean;
}

// Imposter
export interface ImposterProps extends BaseLayoutProps {
  breakout?: boolean;
  margin?: string;
  fixed?: boolean;
}

// Icon
export interface IconProps extends BaseLayoutProps {
  space?: string;
  label?: string;
}

// Container
export interface ContainerProps extends BaseLayoutProps {
  containerName?: string;
}
```

## Stack.vue

```vue
<!--
  Stack Component
  Vertical spacing between sibling elements
-->
<script setup lang="ts">
import type { StackProps } from './types';

const props = withDefaults(defineProps<StackProps>(), {
  as: 'div',
  space: 'var(--s1)',
  recursive: false,
});
</script>

<template>
  <component
    :is="as"
    :class="['stack', $attrs.class]"
    :data-recursive="recursive || undefined"
    :style="{ '--space': space }"
  >
    <slot />
  </component>
</template>
```

A child that should absorb remaining space (the old `splitAfter` prop) carries the marker attribute directly — no numeric index prop, no runtime CSS:

```vue
<Stack>
  <p>First</p>
  <p data-split-after>Pushes the rest down</p>
  <p>Last</p>
</Stack>
```

`.stack > [data-split-after] { margin-block-end: auto }` lives in the stylesheet (`vanilla.md`).

## Box.vue

```vue
<!--
  Box Component
  Padded container with optional border
-->
<script setup lang="ts">
import type { BoxProps } from './types';

const props = withDefaults(defineProps<BoxProps>(), {
  as: 'div',
  padding: 'var(--s1)',
  borderWidth: 'var(--border-thin)',
  invert: false,
});
</script>

<template>
  <component
    :is="as"
    :class="['box', $attrs.class]"
    :data-invert="invert || undefined"
    :style="{ '--padding': padding, '--border-width': borderWidth }"
  >
    <slot />
  </component>
</template>
```

## Center.vue

```vue
<!--
  Center Component
  Horizontal centering with max-width constraint
-->
<script setup lang="ts">
import type { CenterProps } from './types';

const props = withDefaults(defineProps<CenterProps>(), {
  as: 'div',
  max: 'var(--measure)',
  gutters: 'var(--s1)',
  intrinsic: false,
  andText: false,
});
</script>

<template>
  <component
    :is="as"
    :class="['center', $attrs.class]"
    :data-intrinsic="intrinsic || undefined"
    :data-text="andText || undefined"
    :style="{ '--measure': max, '--gutter': gutters }"
  >
    <slot />
  </component>
</template>
```

## Cluster.vue

```vue
<!--
  Cluster Component
  Flexible wrapping horizontal layout
-->
<script setup lang="ts">
import type { ClusterProps } from './types';

const props = withDefaults(defineProps<ClusterProps>(), {
  as: 'div',
  space: 'var(--s1)',
  justify: 'flex-start',
  align: 'center',
});
</script>

<template>
  <component
    :is="as"
    :class="['cluster', $attrs.class]"
    :style="{ '--space': space, '--justify': justify, '--align': align }"
  >
    <slot />
  </component>
</template>
```

## Sidebar.vue

```vue
<!--
  Sidebar Component
  Two-element layout with intrinsic switching
-->
<script setup lang="ts">
import type { SidebarProps } from './types';

const props = withDefaults(defineProps<SidebarProps>(), {
  as: 'div',
  side: 'left',
  sideWidth: '20rem',
  contentMin: '50%',
  space: 'var(--s1)',
  noStretch: false,
});
</script>

<template>
  <component
    :is="as"
    :class="['with-sidebar', $attrs.class]"
    :data-side="side === 'right' ? 'right' : undefined"
    :data-no-stretch="noStretch || undefined"
    :style="{ '--side-width': sideWidth, '--content-min': contentMin, '--space': space }"
  >
    <slot />
  </component>
</template>
```

The stylesheet's `[data-side="right"]` variant swaps which child (first vs. last) receives `--side-width`; see `vanilla.md` for the selector pair.

## Switcher.vue

```vue
<!--
  Switcher Component
  Equal columns that switch to stack below threshold
-->
<script setup lang="ts">
import type { SwitcherProps } from './types';

const props = withDefaults(defineProps<SwitcherProps>(), {
  as: 'div',
  threshold: '30rem',
  space: 'var(--s1)',
});
</script>

<template>
  <component
    :is="as"
    :class="['switcher', $attrs.class]"
    :data-limit="limit"
    :style="{ '--threshold': threshold, '--space': space }"
  >
    <slot />
  </component>
</template>
```

`data-limit` takes the integer value directly (`data-limit="2"`) — the stylesheet ships `[data-limit="2"]`, `[data-limit="3"]`, and `[data-limit="4"]` selectors (`vanilla.md`). Values outside that range fall back to the unlimited default; add a new selector to the stylesheet (not to this component) to support another limit.

## Cover.vue

```vue
<!--
  Cover Component
  Vertical centering with optional header/footer.

  `minHeight` has no default (contrast `space`, `noPad`, etc., which do
  get one from withDefaults). The stylesheet already ships a
  two-declaration viewport chain — `min-block-size: var(--min-height, 100vh)`
  then `min-block-size: var(--min-height, 100dvh)` (see references/vanilla.md)
  — so that supporting browsers land on the stable 100dvh mobile viewport
  and older engines fall back to 100vh. `--min-height` is only bound (via
  the same ternary-to-`:style` idiom Container.vue uses for `--container-name`)
  when the caller actually passes minHeight; passing it overrides the
  chain with one fixed value, so reach for it only when you mean a fixed
  viewport unit, not the default responsive behavior.
-->
<script setup lang="ts">
import type { CoverProps } from './types';

const props = withDefaults(defineProps<CoverProps>(), {
  as: 'div',
  space: 'var(--s1)',
  noPad: false,
});
</script>

<template>
  <component
    :is="as"
    :class="['cover', $attrs.class]"
    :data-no-pad="noPad || undefined"
    :style="[{ '--space': space }, minHeight ? { '--min-height': minHeight } : undefined]"
  >
    <slot />
  </component>
</template>
```

The element that should be pinned to the vertical center (the old `centered` prop, a selector string) is now a marker on the child itself, matching the stylesheet's default `[data-centered]` selector:

```vue
<Cover>
  <header>Header</header>
  <h1 data-centered>Centered Title</h1>
  <footer>Footer</footer>
</Cover>
```

## Grid.vue

```vue
<!--
  Grid Component
  Responsive grid with intrinsic sizing
-->
<script setup lang="ts">
import type { GridProps } from './types';

const props = withDefaults(defineProps<GridProps>(), {
  as: 'div',
  min: '15rem',
  space: 'var(--s1)',
  ragged: false,
});
</script>

<template>
  <component
    :is="as"
    :class="['grid', $attrs.class]"
    :data-ragged="ragged || undefined"
    :style="{ '--min': min, '--space': space }"
  >
    <slot />
  </component>
</template>
```

## Frame.vue

```vue
<!--
  Frame Component
  Aspect ratio container for media
-->
<script setup lang="ts">
import { computed } from 'vue';
import type { FrameProps } from './types';

const props = withDefaults(defineProps<FrameProps>(), {
  as: 'div',
  ratio: '16/9',
});

// The stylesheet's .frame reads --n and --d (aspect-ratio: var(--n, 16) / var(--d, 9)),
// not a single --ratio custom property, so the "16/9"-style prop is split here.
// This computed returns only --n/--d — no other keys.
const params = computed(() => {
  const [n, d] = props.ratio.split('/').map((part) => part.trim());
  return { '--n': n, '--d': d };
});
</script>

<template>
  <component :is="as" :class="['frame', $attrs.class]" :style="params">
    <slot />
  </component>
</template>
```

## Reel.vue

```vue
<!--
  Reel Component
  Horizontal scrolling container
-->
<script setup lang="ts">
import type { ReelProps } from './types';

const props = withDefaults(defineProps<ReelProps>(), {
  as: 'div',
  itemWidth: 'auto',
  space: 'var(--s1)',
  height: 'auto',
  noBar: false,
});
</script>

<template>
  <component
    :is="as"
    :class="['reel', $attrs.class]"
    :data-no-bar="noBar || undefined"
    :style="{ '--item-width': itemWidth, '--space': space, '--height': height }"
  >
    <slot />
  </component>
</template>
```

## Imposter.vue

```vue
<!--
  Imposter Component
  Superimposed/overlay positioning
-->
<script setup lang="ts">
import type { ImposterProps } from './types';

const props = withDefaults(defineProps<ImposterProps>(), {
  as: 'div',
  breakout: false,
  margin: '0px',
  fixed: false,
});
</script>

<template>
  <component
    :is="as"
    :class="['imposter', $attrs.class]"
    :data-contain="!breakout || undefined"
    :data-fixed="fixed || undefined"
    :style="{ '--margin': margin }"
  >
    <slot />
  </component>
</template>
```

## Icon.vue

```vue
<!--
  Icon Component
  Inline SVG icon sizing and alignment
-->
<script setup lang="ts">
import type { IconProps } from './types';

const props = withDefaults(defineProps<IconProps>(), {
  as: 'span',
  space: '0.5em',
});
</script>

<template>
  <component
    :is="as"
    :class="['with-icon', $attrs.class]"
    :role="label ? 'img' : undefined"
    :aria-label="label"
    :style="{ '--space': space }"
  >
    <slot />
  </component>
</template>
```

## Container.vue

```vue
<!--
  Container Component
  Container query context wrapper
-->
<script setup lang="ts">
import type { ContainerProps } from './types';

const props = withDefaults(defineProps<ContainerProps>(), {
  as: 'div',
});
</script>

<template>
  <component
    :is="as"
    :class="['container', $attrs.class]"
    :data-name="containerName || undefined"
    :style="containerName ? { '--container-name': containerName } : undefined"
  >
    <slot />
  </component>
</template>
```

## Barrel Export (index.ts)

```typescript
/**
 * Every Layout - Vue Components
 * Based on "Every Layout" by Andy Bell and Heydon Pickering
 */

export { default as Stack } from './Stack.vue';
export { default as Box } from './Box.vue';
export { default as Center } from './Center.vue';
export { default as Cluster } from './Cluster.vue';
export { default as Sidebar } from './Sidebar.vue';
export { default as Switcher } from './Switcher.vue';
export { default as Cover } from './Cover.vue';
export { default as Grid } from './Grid.vue';
export { default as Frame } from './Frame.vue';
export { default as Reel } from './Reel.vue';
export { default as Imposter } from './Imposter.vue';
export { default as Icon } from './Icon.vue';
export { default as Container } from './Container.vue';

// Re-export types
export type {
  BaseLayoutProps,
  StackProps,
  BoxProps,
  CenterProps,
  ClusterProps,
  SidebarProps,
  SwitcherProps,
  CoverProps,
  GridProps,
  FrameProps,
  ReelProps,
  ImposterProps,
  IconProps,
  ContainerProps,
} from './types';
```

## Prop/Slot API Summary

All Vue components use `<script setup>` with `withDefaults(defineProps<T>())`, accept an `as` prop for polymorphic rendering, and provide a default `<slot />` for children. Every prop maps to either a `--custom-property` bound via `:style` or a `data-*` attribute the stylesheet already selects on — no component owns a declaration object.

| Component | Props | Defaults | `--param` / `data-*` |
|-----------|-------|----------|-----------------------|
| Box | `padding`, `borderWidth`, `invert` | `var(--s1)`, `var(--border-thin)`, `false` | `--padding`, `--border-width` / `data-invert` |
| Center | `max`, `gutters`, `intrinsic`, `andText` | `var(--measure)`, `var(--s1)`, `false`, `false` | `--measure`, `--gutter` / `data-intrinsic`, `data-text` |
| Cluster | `space`, `justify`, `align` | `var(--s1)`, `flex-start`, `center` | `--space`, `--justify`, `--align` |
| Container | `containerName` | `undefined` | `--name` / `data-name` |
| Cover | `space`, `minHeight`, `noPad` | `var(--s1)`, `— (stylesheet: 100dvh, 100vh fallback)`, `false` | `--space`, `--min-height` / `data-no-pad` (mark the centered child with `data-centered`) |
| Frame | `ratio` | `16/9` | `--n`, `--d` (parsed from `ratio`) |
| Grid | `min`, `space`, `ragged` | `15rem`, `var(--s1)`, `false` | `--min`, `--space` / `data-ragged` |
| Icon | `space`, `label` | `0.5em`, `undefined` | `--space` |
| Imposter | `breakout`, `margin`, `fixed` | `false`, `0px`, `false` | `--margin` / `data-contain`, `data-fixed` |
| Reel | `itemWidth`, `space`, `height`, `noBar` | `auto`, `var(--s1)`, `auto`, `false` | `--item-width`, `--space`, `--height` / `data-no-bar` |
| Sidebar | `side`, `sideWidth`, `contentMin`, `space`, `noStretch` | `left`, `20rem`, `50%`, `var(--s1)`, `false` | `--side-width`, `--content-min`, `--space` / `data-side`, `data-no-stretch` |
| Stack | `space`, `recursive` | `var(--s1)`, `false` | `--space` / `data-recursive` (mark a child `data-split-after` to absorb trailing space) |
| Switcher | `threshold`, `space`, `limit` | `30rem`, `var(--s1)`, `undefined` | `--threshold`, `--space` / `data-limit` |

## Why no style objects

Axiom `ELA_005` (CSS-Dominant Composition) reserves styling for CSS: a framework runtime emits classes and parameters, never declarations. A Vue `computed(() => ({ padding, borderWidth, color, ... }))` object bound via `:style` is CSS-in-JS by another name — it just moved the declaration from a stylesheet into a script block, and it duplicates rules the shared stylesheet already owns. Every component above binds only `--custom-property` keys, so `:style="{...}"` never carries a bespoke declaration. `bin/ports-lint.sh` enforces this mechanically: it parses every `:style="{...}"` binding in `.vue` source and fails on any key that doesn't start with `--`.
