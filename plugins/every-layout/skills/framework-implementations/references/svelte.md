# Svelte Implementation

All 13 Every Layout primitives as Svelte components, plus barrel export.

## Stack.svelte

```svelte
<!--
  Stack Component
  Vertical spacing between sibling elements
-->
<script lang="ts">
  export let as: string = 'div';
  export let space: string = 'var(--s1)';
  export let recursive: boolean = false;
  export let splitAfter: number | undefined = undefined;

  const id = `stack-${Math.random().toString(36).slice(2, 9)}`;
</script>

<svelte:element this={as} {id} class="stack {$$restProps.class || ''}" style="--space: {space}; display: flex; flex-direction: column; justify-content: flex-start;" {...$$restProps}>
  <slot />
</svelte:element>

<svelte:head>
  <style>
    {`
      #${id} > * { margin-block: 0; }
      #${id} > * + * { margin-block-start: var(--space, 1.5rem); }
      ${recursive ? `#${id} * + * { margin-block-start: var(--space, 1.5rem); }` : ''}
      ${splitAfter ? `#${id} > :nth-child(${splitAfter}) { margin-block-end: auto; }` : ''}
    `}
  </style>
</svelte:head>
```

## Box.svelte

```svelte
<!--
  Box Component
  Padded container with optional border
-->
<script lang="ts">
  export let as: string = 'div';
  export let padding: string = 'var(--s1)';
  export let borderWidth: string = 'var(--border-thin)';
  export let invert: boolean = false;
</script>

<svelte:element
  this={as}
  class="box {invert ? 'box--invert' : ''} {$$restProps.class || ''}"
  style="padding: {padding}; border-width: {borderWidth}; border-style: solid; color: {invert ? 'var(--color-light)' : 'var(--color-dark)'}; background-color: {invert ? 'var(--color-dark)' : 'var(--color-light)'};"
  {...$$restProps}
>
  <slot />
</svelte:element>
```

## Center.svelte

```svelte
<!--
  Center Component
  Horizontal centering with max-width constraint
-->
<script lang="ts">
  export let as: string = 'div';
  export let max: string = 'var(--measure)';
  export let gutters: string = 'var(--s1)';
  export let intrinsic: boolean = false;
  export let andText: boolean = false;

  $: baseStyle = `box-sizing: content-box; max-inline-size: ${max}; margin-inline: auto; padding-inline: ${gutters};`;
  $: intrinsicStyle = intrinsic ? ' display: flex; flex-direction: column; align-items: center;' : '';
  $: textStyle = andText ? ' text-align: center;' : '';
</script>

<svelte:element
  this={as}
  class="center {$$restProps.class || ''}"
  style="{baseStyle}{intrinsicStyle}{textStyle}"
  {...$$restProps}
>
  <slot />
</svelte:element>
```

## Cluster.svelte

```svelte
<!--
  Cluster Component
  Flexible wrapping horizontal layout
-->
<script lang="ts">
  export let as: string = 'div';
  export let space: string = 'var(--s1)';
  export let justify: string = 'flex-start';
  export let align: string = 'center';
</script>

<svelte:element
  this={as}
  class="cluster {$$restProps.class || ''}"
  style="display: flex; flex-wrap: wrap; gap: {space}; justify-content: {justify}; align-items: {align};"
  {...$$restProps}
>
  <slot />
</svelte:element>
```

## Sidebar.svelte

```svelte
<!--
  Sidebar Component
  Two-element layout with intrinsic switching
-->
<script lang="ts">
  export let as: string = 'div';
  export let side: 'left' | 'right' = 'left';
  export let sideWidth: string = '20rem';
  export let contentMin: string = '50%';
  export let space: string = 'var(--s1)';
  export let noStretch: boolean = false;

  const id = `sidebar-${Math.random().toString(36).slice(2, 9)}`;

  $: stretchStyle = noStretch ? ' align-items: flex-start;' : '';

  $: childCss = (() => {
    const sideChild = side === 'left' ? 'first' : 'last';
    const contentChild = side === 'left' ? 'last' : 'first';
    return `
      #${id} > * { flex-grow: 1; }
      #${id} > :${sideChild}-child { flex-basis: ${sideWidth}; }
      #${id} > :${contentChild}-child {
        flex-basis: 0;
        flex-grow: 999;
        min-inline-size: ${contentMin};
      }
    `;
  })();
</script>

<svelte:element
  this={as}
  {id}
  class="with-sidebar {noStretch ? 'with-sidebar--no-stretch' : ''} {$$restProps.class || ''}"
  style="--side-width: {sideWidth}; --content-min: {contentMin}; --space: {space}; display: flex; flex-wrap: wrap; gap: {space};{stretchStyle}"
  {...$$restProps}
>
  <slot />
</svelte:element>

<svelte:head>
  <style>{childCss}</style>
</svelte:head>
```

## Switcher.svelte

```svelte
<!--
  Switcher Component
  Equal columns that switch to stack below threshold
-->
<script lang="ts">
  export let as: string = 'div';
  export let threshold: string = '30rem';
  export let space: string = 'var(--s1)';
  export let limit: number | undefined = undefined;

  const id = `switcher-${Math.random().toString(36).slice(2, 9)}`;

  $: childCss = (() => {
    let css = `
      #${id} > * {
        flex-grow: 1;
        flex-basis: calc((${threshold} - 100%) * 999);
      }
    `;
    if (limit) {
      css += `
      #${id} > :nth-last-child(n+${limit + 1}),
      #${id} > :nth-last-child(n+${limit + 1}) ~ * {
        flex-basis: 100%;
      }`;
    }
    return css;
  })();
</script>

<svelte:element
  this={as}
  {id}
  class="switcher {$$restProps.class || ''}"
  style="--threshold: {threshold}; --space: {space}; display: flex; flex-wrap: wrap; gap: {space};"
  {...$$restProps}
>
  <slot />
</svelte:element>

<svelte:head>
  <style>{childCss}</style>
</svelte:head>
```

## Cover.svelte

```svelte
<!--
  Cover Component
  Vertical centering with optional header/footer
-->
<script lang="ts">
  export let as: string = 'div';
  export let centered: string = '[data-centered]';
  export let space: string = 'var(--s1)';
  export let minHeight: string = '100vh';
  export let noPad: boolean = false;

  const id = `cover-${Math.random().toString(36).slice(2, 9)}`;

  $: padStyle = noPad ? '' : ` padding: ${space};`;

  $: childCss = `
    #${id} > * { margin-block: var(--space, var(--s1)); }
    #${id} > :first-child:not(${centered}) { margin-block-start: 0; }
    #${id} > :last-child:not(${centered}) { margin-block-end: 0; }
    #${id} > ${centered} { margin-block: auto; }
  `;
</script>

<svelte:element
  this={as}
  {id}
  class="cover {$$restProps.class || ''}"
  style="--min-height: {minHeight}; --space: {space}; display: flex; flex-direction: column; min-block-size: {minHeight};{padStyle}"
  {...$$restProps}
>
  <slot />
</svelte:element>

<svelte:head>
  <style>{childCss}</style>
</svelte:head>
```

## Grid.svelte

```svelte
<!--
  Grid Component
  Responsive grid with intrinsic sizing
-->
<script lang="ts">
  export let as: string = 'div';
  export let min: string = '15rem';
  export let space: string = 'var(--s1)';
</script>

<svelte:element
  this={as}
  class="grid {$$restProps.class || ''}"
  style="display: grid; gap: {space}; grid-template-columns: repeat(auto-fit, minmax(min({min}, 100%), 1fr));"
  {...$$restProps}
>
  <slot />
</svelte:element>
```

## Frame.svelte

```svelte
<!--
  Frame Component
  Aspect ratio container for media
-->
<script lang="ts">
  export let as: string = 'div';
  export let ratio: string = '16/9';

  const id = `frame-${Math.random().toString(36).slice(2, 9)}`;
</script>

<svelte:element
  this={as}
  {id}
  class="frame {$$restProps.class || ''}"
  style="aspect-ratio: {ratio}; overflow: hidden; display: flex; justify-content: center; align-items: center;"
  {...$$restProps}
>
  <slot />
</svelte:element>

<svelte:head>
  <style>
    {`
      #${id} > img,
      #${id} > video {
        inline-size: 100%;
        block-size: 100%;
        object-fit: cover;
      }
    `}
  </style>
</svelte:head>
```

## Reel.svelte

```svelte
<!--
  Reel Component
  Horizontal scrolling container
-->
<script lang="ts">
  export let as: string = 'div';
  export let itemWidth: string = 'auto';
  export let space: string = 'var(--s1)';
  export let height: string = 'auto';
  export let noBar: boolean = false;

  const id = `reel-${Math.random().toString(36).slice(2, 9)}`;

  $: barStyle = noBar ? ' scrollbar-width: none;' : '';

  $: childCss = (() => {
    let css = `
      #${id} > * { flex: 0 0 ${itemWidth}; }
      #${id} > img { block-size: 100%; flex-basis: auto; width: auto; }
      #${id} > * + * { margin-inline-start: ${space}; }
    `;
    if (noBar) {
      css += `#${id}::-webkit-scrollbar { display: none; }`;
    }
    return css;
  })();
</script>

<svelte:element
  this={as}
  {id}
  class="reel {noBar ? 'reel--no-bar' : ''} {$$restProps.class || ''}"
  style="--item-width: {itemWidth}; --space: {space}; --height: {height}; display: flex; block-size: {height}; overflow-x: auto; overflow-y: hidden;{barStyle}"
  {...$$restProps}
>
  <slot />
</svelte:element>

<svelte:head>
  <style>{childCss}</style>
</svelte:head>
```

## Imposter.svelte

```svelte
<!--
  Imposter Component
  Superimposed/overlay positioning
-->
<script lang="ts">
  export let as: string = 'div';
  export let breakout: boolean = false;
  export let margin: string = '0px';
  export let fixed: boolean = false;

  $: containStyle = breakout ? '' : ` overflow: auto; max-inline-size: calc(100% - (${margin} * 2)); max-block-size: calc(100% - (${margin} * 2));`;
</script>

<svelte:element
  this={as}
  class="imposter {$$restProps.class || ''}"
  style="position: {fixed ? 'fixed' : 'absolute'}; inset-block-start: 50%; inset-inline-start: 50%; transform: translate(-50%, -50%);{containStyle}"
  {...$$restProps}
>
  <slot />
</svelte:element>
```

## Icon.svelte

```svelte
<!--
  Icon Component
  Inline SVG icon sizing and alignment
-->
<script lang="ts">
  export let as: string = 'span';
  export let space: string = '0.5em';
  export let label: string | undefined = undefined;

  const id = `icon-${Math.random().toString(36).slice(2, 9)}`;
</script>

<svelte:element
  this={as}
  {id}
  class="with-icon {$$restProps.class || ''}"
  style="--space: {space}; display: inline-flex; align-items: baseline;"
  role={label ? 'img' : undefined}
  aria-label={label}
  {...$$restProps}
>
  <slot />
</svelte:element>

<svelte:head>
  <style>
    {`
      #${id} .icon {
        height: 0.75em;
        height: 1cap;
        width: 0.75em;
        width: 1cap;
      }
      #${id} .icon {
        margin-inline-end: var(--space, 0.5em);
      }
    `}
  </style>
</svelte:head>
```

## Container.svelte

```svelte
<!--
  Container Component
  Container query context wrapper
-->
<script lang="ts">
  export let as: string = 'div';
  export let name: string | undefined = undefined;

  $: nameStyle = name ? ` container-name: ${name};` : '';
</script>

<svelte:element
  this={as}
  class="container {$$restProps.class || ''}"
  style="container-type: inline-size;{nameStyle}"
  {...$$restProps}
>
  <slot />
</svelte:element>
```

## index.ts

```typescript
/**
 * Every Layout - Svelte Components
 * Based on "Every Layout" by Andy Bell and Heydon Pickering
 */

export { default as Stack } from './Stack.svelte';
export { default as Box } from './Box.svelte';
export { default as Center } from './Center.svelte';
export { default as Cluster } from './Cluster.svelte';
export { default as Sidebar } from './Sidebar.svelte';
export { default as Switcher } from './Switcher.svelte';
export { default as Cover } from './Cover.svelte';
export { default as Grid } from './Grid.svelte';
export { default as Frame } from './Frame.svelte';
export { default as Reel } from './Reel.svelte';
export { default as Imposter } from './Imposter.svelte';
export { default as Icon } from './Icon.svelte';
export { default as Container } from './Container.svelte';
```
