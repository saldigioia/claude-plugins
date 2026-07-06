# Svelte Implementation

All 13 Every Layout primitives as Svelte components, plus barrel export.

> **Stylesheet is loaded once, globally.** These components never emit CSS. The
> canonical primitive stylesheet (see `references/vanilla.md`; `demos/every-layout.css`
> is its built artifact) is linked once per app, the same way you'd load any
> other global stylesheet. Every component below does exactly two things: render
> its primitive's class name, and pass per-instance parameters through Svelte's
> custom-property style directive — `style:--space={space}`, `style:--min={min}`,
> and so on. There is no `style="..."` string, no interpolated declaration, and
> no `<style>` block that restates primitive CSS (ELA_005 — framework runtimes do
> not style DOM). Boolean variants become data attributes
> (`data-invert`, `data-recursive`, `data-ragged`, `data-no-stretch`, ...) that the
> stylesheet's attribute selectors already handle; the component sets presence,
> the stylesheet supplies behavior.
>
> `bin/ports-lint.sh` enforces this mechanically — it fails on any style-object
> key that isn't a `--custom-property`, any `style="...{...}"` interpolation, and
> any runtime `<style>` injection. `style:--x={y}` directives are invisible to
> bespoke-declaration detection because they carry no declaration text at all.

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
</script>

<svelte:element
  this={as}
  class="stack {$$restProps.class || ''}"
  style:--space={space}
  data-recursive={recursive ? true : undefined}
  {...$$restProps}
>
  <slot />
</svelte:element>
```

**Why no `splitAfter` prop:** the primitive's split-to-bottom behavior is a
child-side marker, not a parent-side index. The stylesheet ships
`.stack > [data-split-after] { margin-block-end: auto }`; mark the child that
should absorb the remaining space directly:

```svelte
<Stack>
  <p>First</p>
  <p>Second</p>
  <button data-split-after>Pushed to the bottom</button>
</Stack>
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
  class="box {$$restProps.class || ''}"
  style:--padding={padding}
  style:--border-width={borderWidth}
  data-invert={invert ? true : undefined}
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
</script>

<svelte:element
  this={as}
  class="center {$$restProps.class || ''}"
  style:--measure={max}
  style:--gutter={gutters}
  data-intrinsic={intrinsic ? true : undefined}
  data-text={andText ? true : undefined}
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
  style:--space={space}
  style:--justify={justify}
  style:--align={align}
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
</script>

<svelte:element
  this={as}
  class="with-sidebar {$$restProps.class || ''}"
  style:--side-width={sideWidth}
  style:--content-min={contentMin}
  style:--space={space}
  data-no-stretch={noStretch ? true : undefined}
  {...$$restProps}
>
  {#if side === 'left'}
    <slot name="side" /><slot name="content" />
  {:else}
    <slot name="content" /><slot name="side" />
  {/if}
</svelte:element>
```

The stylesheet's `.with-sidebar > :first-child` / `:last-child` selectors key
on DOM order, so reversing the sidebar's visual side is a slot-order decision,
not a style. `side="right"` changes which named slot renders first; it never
touches `style`.

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
</script>

<svelte:element
  this={as}
  class="switcher {$$restProps.class || ''}"
  style:--threshold={threshold}
  style:--space={space}
  data-limit={limit ?? undefined}
  {...$$restProps}
>
  <slot />
</svelte:element>
```

`data-limit` takes the same integer the stylesheet's
`.switcher[data-limit="2"|"3"|"4"]` selectors match against — pass `2`, `3`, or
`4`.

## Cover.svelte

```svelte
<!--
  Cover Component
  Vertical centering with optional header/footer
-->
<script lang="ts">
  export let as: string = 'div';
  export let space: string = 'var(--s1)';
  export let minHeight: string = '100vh';
  export let noPad: boolean = false;
</script>

<svelte:element
  this={as}
  class="cover {$$restProps.class || ''}"
  style:--min-height={minHeight}
  style:--space={space}
  data-no-pad={noPad ? true : undefined}
  {...$$restProps}
>
  <slot />
</svelte:element>
```

The principal (vertically centered) child is marked with a plain `class="principal"`
in the consumer's own markup — the stylesheet's `.cover > .principal` selector
picks it up directly. There is no `centered` prop; a class the author writes is
not a runtime style.

```svelte
<Cover minHeight="100vh">
  <header>Site header</header>
  <h1 class="principal">Centered heading</h1>
  <footer>Site footer</footer>
</Cover>
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
  export let ragged: boolean = false;
</script>

<svelte:element
  this={as}
  class="grid {$$restProps.class || ''}"
  style:--min={min}
  style:--space={space}
  data-ragged={ragged ? true : undefined}
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
</script>

<svelte:element
  this={as}
  class="frame {$$restProps.class || ''}"
  style:--ratio={ratio}
  {...$$restProps}
>
  <slot />
</svelte:element>
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
</script>

<svelte:element
  this={as}
  class="reel {$$restProps.class || ''}"
  style:--item-width={itemWidth}
  style:--space={space}
  style:--height={height}
  data-no-bar={noBar ? true : undefined}
  {...$$restProps}
>
  <slot />
</svelte:element>
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
  export let margin: string = 'var(--s1)';
  export let fixed: boolean = false;
</script>

<svelte:element
  this={as}
  class="imposter {$$restProps.class || ''}"
  style:--margin={margin}
  data-contain={breakout ? undefined : true}
  data-fixed={fixed ? true : undefined}
  {...$$restProps}
>
  <slot />
</svelte:element>
```

`breakout` inverts to `data-contain`: the stylesheet's contained (clamped)
behavior lives behind `.imposter[data-contain]`, so the component sets that
attribute whenever the caller has *not* asked to break out.

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
</script>

<svelte:element
  this={as}
  class="with-icon {$$restProps.class || ''}"
  style:--space={space}
  role={label ? 'img' : undefined}
  aria-label={label}
  {...$$restProps}
>
  <slot />
</svelte:element>
```

## Container.svelte

```svelte
<!--
  Container Component
  Container query context wrapper
-->
<script lang="ts">
  export let as: string = 'div';
  export let containerName: string | undefined = undefined;
</script>

<svelte:element
  this={as}
  class="container {$$restProps.class || ''}"
  style:--container-name={containerName}
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

## Prop/Slot API Summary

Every component accepts `as` (polymorphic element, default per component) and
forwards `$$restProps` (including a caller-supplied `class`) onto the rendered
element. Parameters bind through `style:--custom-property={prop}`; boolean
variants set a `data-*` attribute the stylesheet already selects on.

| Component | Props | CSS custom properties | Data attributes |
|-----------|-------|------------------------|------------------|
| Stack | `space`, `recursive` | `--space` | `data-recursive`; child sets `data-split-after` |
| Box | `padding`, `borderWidth`, `invert` | `--padding`, `--border-width` | `data-invert` |
| Center | `max`, `gutters`, `intrinsic`, `andText` | `--measure`, `--gutter` | `data-intrinsic`, `data-text` |
| Cluster | `space`, `justify`, `align` | `--space`, `--justify`, `--align` | — |
| Sidebar | `side`, `sideWidth`, `contentMin`, `space`, `noStretch` | `--side-width`, `--content-min`, `--space` | `data-no-stretch`; `side` picks slot order, not style |
| Switcher | `threshold`, `space`, `limit` | `--threshold`, `--space` | `data-limit` |
| Cover | `space`, `minHeight`, `noPad` | `--space`, `--min-height` | `data-no-pad`; principal child uses `class="principal"` |
| Grid | `min`, `space`, `ragged` | `--min`, `--space` | `data-ragged` |
| Frame | `ratio` | `--ratio` | — |
| Reel | `itemWidth`, `space`, `height`, `noBar` | `--item-width`, `--space`, `--height` | `data-no-bar` |
| Imposter | `breakout`, `margin`, `fixed` | `--margin` | `data-contain` (`!breakout`), `data-fixed` |
| Icon | `space`, `label` | `--space` | — (`role`/`aria-label` from `label`) |
| Container | `containerName` | `--container-name` | — |
