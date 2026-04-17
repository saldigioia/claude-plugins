# Vue Implementation

All 13 Every Layout primitives as Vue 3 components with Composition API, plus shared types and barrel export.

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
  splitAfter?: number;
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
  name?: string;
}
```

## Box.vue

```vue
<!--
  Box Component
  Padded container with optional border
-->
<script setup lang="ts">
import { computed } from 'vue';
import type { BoxProps } from './types';

const props = withDefaults(defineProps<BoxProps>(), {
  as: 'div',
  padding: 'var(--s1)',
  borderWidth: 'var(--border-thin)',
  invert: false,
});

const styles = computed(() => ({
  padding: props.padding,
  borderWidth: props.borderWidth,
  borderStyle: 'solid',
  color: props.invert ? 'var(--color-light)' : 'var(--color-dark)',
  backgroundColor: props.invert ? 'var(--color-dark)' : 'var(--color-light)',
}));
</script>

<template>
  <component
    :is="as"
    :class="['box', { 'box--invert': invert }, $attrs.class]"
    :style="styles"
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
import { computed } from 'vue';
import type { CenterProps } from './types';

const props = withDefaults(defineProps<CenterProps>(), {
  as: 'div',
  max: 'var(--measure)',
  gutters: 'var(--s1)',
  intrinsic: false,
  andText: false,
});

const styles = computed(() => ({
  boxSizing: 'content-box',
  maxInlineSize: props.max,
  marginInline: 'auto',
  paddingInline: props.gutters,
  ...(props.intrinsic && {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
  }),
  ...(props.andText && { textAlign: 'center' }),
}));
</script>

<template>
  <component :is="as" :class="['center', $attrs.class]" :style="styles">
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
import { computed } from 'vue';
import type { ClusterProps } from './types';

const props = withDefaults(defineProps<ClusterProps>(), {
  as: 'div',
  space: 'var(--s1)',
  justify: 'flex-start',
  align: 'center',
});

const styles = computed(() => ({
  display: 'flex',
  flexWrap: 'wrap',
  gap: props.space,
  justifyContent: props.justify,
  alignItems: props.align,
}));
</script>

<template>
  <component :is="as" :class="['cluster', $attrs.class]" :style="styles">
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
import { computed } from 'vue';
import type { ContainerProps } from './types';

const props = withDefaults(defineProps<ContainerProps>(), {
  as: 'div',
});

const styles = computed(() => ({
  containerType: 'inline-size',
  ...(props.name && { containerName: props.name }),
}));
</script>

<template>
  <component :is="as" :class="['container', $attrs.class]" :style="styles">
    <slot />
  </component>
</template>
```

## Cover.vue

```vue
<!--
  Cover Component
  Vertical centering with optional header/footer
-->
<script setup lang="ts">
import { computed, useId } from 'vue';
import type { CoverProps } from './types';

const props = withDefaults(defineProps<CoverProps>(), {
  as: 'div',
  centered: '[data-centered]',
  space: 'var(--s1)',
  minHeight: '100vh',
  noPad: false,
});

const id = useId();

const styles = computed(() => ({
  '--min-height': props.minHeight,
  '--space': props.space,
  display: 'flex',
  flexDirection: 'column',
  minBlockSize: props.minHeight,
  ...(!props.noPad && { padding: props.space }),
}));

const childCss = computed(() => `
  #${id} > * { margin-block: var(--space, var(--s1)); }
  #${id} > :first-child:not(${props.centered}) { margin-block-start: 0; }
  #${id} > :last-child:not(${props.centered}) { margin-block-end: 0; }
  #${id} > ${props.centered} { margin-block: auto; }
`);
</script>

<template>
  <component :is="as" :id="id" :class="['cover', $attrs.class]" :style="styles">
    <slot />
  </component>
  <component :is="'style'">{{ childCss }}</component>
</template>
```

## Frame.vue

```vue
<!--
  Frame Component
  Aspect ratio container for media
-->
<script setup lang="ts">
import { computed, useId } from 'vue';
import type { FrameProps } from './types';

const props = withDefaults(defineProps<FrameProps>(), {
  as: 'div',
  ratio: '16/9',
});

const id = useId();

const styles = computed(() => ({
  aspectRatio: props.ratio,
  overflow: 'hidden',
  display: 'flex',
  justifyContent: 'center',
  alignItems: 'center',
}));

const childCss = `
  #${id} > img,
  #${id} > video {
    inline-size: 100%;
    block-size: 100%;
    object-fit: cover;
  }
`;
</script>

<template>
  <component :is="as" :id="id" :class="['frame', $attrs.class]" :style="styles">
    <slot />
  </component>
  <component :is="'style'">{{ childCss }}</component>
</template>
```

## Grid.vue

```vue
<!--
  Grid Component
  Responsive grid with intrinsic sizing
-->
<script setup lang="ts">
import { computed } from 'vue';
import type { GridProps } from './types';

const props = withDefaults(defineProps<GridProps>(), {
  as: 'div',
  min: '15rem',
  space: 'var(--s1)',
});

const styles = computed(() => ({
  display: 'grid',
  gap: props.space,
  gridTemplateColumns: `repeat(auto-fit, minmax(min(${props.min}, 100%), 1fr))`,
}));
</script>

<template>
  <component :is="as" :class="['grid', $attrs.class]" :style="styles">
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
import { computed, useId } from 'vue';
import type { IconProps } from './types';

const props = withDefaults(defineProps<IconProps>(), {
  as: 'span',
  space: '0.5em',
});

const id = useId();

const styles = computed(() => ({
  '--space': props.space,
  display: 'inline-flex',
  alignItems: 'baseline',
}));

const childCss = `
  #${id} .icon {
    height: 0.75em;
    height: 1cap;
    width: 0.75em;
    width: 1cap;
  }
  #${id} .icon {
    margin-inline-end: var(--space, 0.5em);
  }
`;
</script>

<template>
  <component
    :is="as"
    :id="id"
    :class="['with-icon', $attrs.class]"
    :style="styles"
    :role="label ? 'img' : undefined"
    :aria-label="label"
  >
    <slot />
  </component>
  <component :is="'style'">{{ childCss }}</component>
</template>
```

## Imposter.vue

```vue
<!--
  Imposter Component
  Superimposed/overlay positioning
-->
<script setup lang="ts">
import { computed } from 'vue';
import type { ImposterProps } from './types';

const props = withDefaults(defineProps<ImposterProps>(), {
  as: 'div',
  breakout: false,
  margin: '0px',
  fixed: false,
});

const styles = computed(() => ({
  position: props.fixed ? 'fixed' : 'absolute',
  insetBlockStart: '50%',
  insetInlineStart: '50%',
  transform: 'translate(-50%, -50%)',
  ...(!props.breakout && {
    overflow: 'auto',
    maxInlineSize: `calc(100% - (${props.margin} * 2))`,
    maxBlockSize: `calc(100% - (${props.margin} * 2))`,
  }),
}));
</script>

<template>
  <component :is="as" :class="['imposter', $attrs.class]" :style="styles">
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
import { computed, useId } from 'vue';
import type { ReelProps } from './types';

const props = withDefaults(defineProps<ReelProps>(), {
  as: 'div',
  itemWidth: 'auto',
  space: 'var(--s1)',
  height: 'auto',
  noBar: false,
});

const id = useId();

const styles = computed(() => ({
  '--item-width': props.itemWidth,
  '--space': props.space,
  '--height': props.height,
  display: 'flex',
  blockSize: props.height,
  overflowX: 'auto',
  overflowY: 'hidden',
  ...(props.noBar && { scrollbarWidth: 'none' }),
}));

const childCss = computed(() => {
  let css = `
    #${id} > * { flex: 0 0 var(--item-width, auto); }
    #${id} > img { block-size: 100%; flex-basis: auto; width: auto; }
    #${id} > * + * { margin-inline-start: var(--space, var(--s1)); }
  `;
  if (props.noBar) {
    css += `#${id}::-webkit-scrollbar { display: none; }`;
  }
  return css;
});
</script>

<template>
  <component
    :is="as"
    :id="id"
    :class="['reel', { 'reel--no-bar': noBar }, $attrs.class]"
    :style="styles"
  >
    <slot />
  </component>
  <component :is="'style'">{{ childCss }}</component>
</template>
```

## Sidebar.vue

```vue
<!--
  Sidebar Component
  Two-element layout with intrinsic switching
-->
<script setup lang="ts">
import { computed, useId } from 'vue';
import type { SidebarProps } from './types';

const props = withDefaults(defineProps<SidebarProps>(), {
  as: 'div',
  side: 'left',
  sideWidth: '20rem',
  contentMin: '50%',
  space: 'var(--s1)',
  noStretch: false,
});

const id = useId();

const styles = computed(() => ({
  '--side-width': props.sideWidth,
  '--content-min': props.contentMin,
  '--space': props.space,
  display: 'flex',
  flexWrap: 'wrap',
  gap: props.space,
  ...(props.noStretch && { alignItems: 'flex-start' }),
}));

const childCss = computed(() => {
  const sideChild = props.side === 'left' ? 'first' : 'last';
  const contentChild = props.side === 'left' ? 'last' : 'first';
  return `
    #${id} > * { flex-grow: 1; }
    #${id} > :${sideChild}-child { flex-basis: var(--side-width); }
    #${id} > :${contentChild}-child {
      flex-basis: 0;
      flex-grow: 999;
      min-inline-size: var(--content-min);
    }
  `;
});
</script>

<template>
  <component
    :is="as"
    :id="id"
    :class="['with-sidebar', { 'with-sidebar--no-stretch': noStretch }, $attrs.class]"
    :style="styles"
  >
    <slot />
  </component>
  <component :is="'style'">{{ childCss }}</component>
</template>
```

## Stack.vue

```vue
<!--
  Stack Component
  Vertical spacing between sibling elements
-->
<script setup lang="ts">
import { computed, useId } from 'vue';
import type { StackProps } from './types';

const props = withDefaults(defineProps<StackProps>(), {
  as: 'div',
  space: 'var(--s1)',
  recursive: false,
});

const id = useId();

const styles = computed(() => ({
  '--space': props.space,
  display: 'flex',
  flexDirection: 'column',
  justifyContent: 'flex-start',
}));

const childCss = computed(() => {
  let css = `
    #${id} > * { margin-block: 0; }
    #${id} > * + * { margin-block-start: var(--space, 1.5rem); }
  `;
  if (props.recursive) {
    css += `#${id} * + * { margin-block-start: var(--space, 1.5rem); }`;
  }
  if (props.splitAfter) {
    css += `#${id} > :nth-child(${props.splitAfter}) { margin-block-end: auto; }`;
  }
  return css;
});
</script>

<template>
  <component :is="as" :id="id" :class="['stack', $attrs.class]" :style="styles">
    <slot />
  </component>
  <component :is="'style'">{{ childCss }}</component>
</template>
```

## Switcher.vue

```vue
<!--
  Switcher Component
  Equal columns that switch to stack below threshold
-->
<script setup lang="ts">
import { computed, useId } from 'vue';
import type { SwitcherProps } from './types';

const props = withDefaults(defineProps<SwitcherProps>(), {
  as: 'div',
  threshold: '30rem',
  space: 'var(--s1)',
});

const id = useId();

const styles = computed(() => ({
  '--threshold': props.threshold,
  '--space': props.space,
  display: 'flex',
  flexWrap: 'wrap',
  gap: props.space,
}));

const childCss = computed(() => {
  let css = `
    #${id} > * {
      flex-grow: 1;
      flex-basis: calc((var(--threshold, 30rem) - 100%) * 999);
    }
  `;
  if (props.limit) {
    css += `
    #${id} > :nth-last-child(n+${props.limit + 1}),
    #${id} > :nth-last-child(n+${props.limit + 1}) ~ * {
      flex-basis: 100%;
    }`;
  }
  return css;
});
</script>

<template>
  <component :is="as" :id="id" :class="['switcher', $attrs.class]" :style="styles">
    <slot />
  </component>
  <component :is="'style'">{{ childCss }}</component>
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

All Vue components use `<script setup>` with `withDefaults(defineProps<T>())`, accept an `as` prop for polymorphic rendering, and provide a default `<slot />` for children.

| Component | Props | Defaults |
|-----------|-------|----------|
| Box | `padding`, `borderWidth`, `invert` | `var(--s1)`, `var(--border-thin)`, `false` |
| Center | `max`, `gutters`, `intrinsic`, `andText` | `var(--measure)`, `var(--s1)`, `false`, `false` |
| Cluster | `space`, `justify`, `align` | `var(--s1)`, `flex-start`, `center` |
| Container | `name` | `undefined` |
| Cover | `centered`, `space`, `minHeight`, `noPad` | `[data-centered]`, `var(--s1)`, `100vh`, `false` |
| Frame | `ratio` | `16/9` |
| Grid | `min`, `space` | `15rem`, `var(--s1)` |
| Icon | `space`, `label` | `0.5em`, `undefined` |
| Imposter | `breakout`, `margin`, `fixed` | `false`, `0px`, `false` |
| Reel | `itemWidth`, `space`, `height`, `noBar` | `auto`, `var(--s1)`, `auto`, `false` |
| Sidebar | `side`, `sideWidth`, `contentMin`, `space`, `noStretch` | `left`, `20rem`, `50%`, `var(--s1)`, `false` |
| Stack | `space`, `recursive`, `splitAfter` | `var(--s1)`, `false`, `undefined` |
| Switcher | `threshold`, `space`, `limit` | `30rem`, `var(--s1)`, `undefined` |
