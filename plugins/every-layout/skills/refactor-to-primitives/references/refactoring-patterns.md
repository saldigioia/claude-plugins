# Common Refactoring Patterns

Copy these before/after pairs when you encounter the anti-pattern in the left column. Each refactor cites the principle it satisfies.

## Media-query grid → ELC_GRID (ELP_009)

```css
/* Before — breakpoint-driven */
.grid { display: grid; grid-template-columns: 1fr; }
@media (min-width: 768px) { .grid { grid-template-columns: repeat(3, 1fr); } }
```

```css
/* After — intrinsic */
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(15rem, 100%), 1fr));
  gap: var(--s1);
}
```

## Fixed sidebar → ELC_SIDEBAR (ELP_002, ELP_009)

```css
/* Before */
.sidebar { width: 250px; }
.main { width: calc(100% - 250px); }
```

```css
/* After — flex with side-width + content-min */
.with-sidebar {
  display: flex;
  flex-wrap: wrap;
  gap: var(--s1);
}
.with-sidebar > :first-child { flex-basis: 15rem; flex-grow: 1; }
.with-sidebar > :last-child { flex-basis: 0; flex-grow: 999; min-inline-size: 50%; }
```

## Arbitrary spacing → modular scale (ELP_005)

```css
/* Before */
.element { margin: 17px 23px; padding-bottom: 13px; }
```

```css
/* After */
.element {
  margin-block: var(--s1);
  margin-inline: var(--s2);
  padding-block-end: var(--s0);
}
```

## Physical properties → logical (ELP_004)

```css
/* Before */
.card { margin-left: 1rem; padding-top: 0.5rem; width: 100%; }
```

```css
/* After */
.card { margin-inline-start: var(--s0); padding-block-start: var(--s-1); inline-size: 100%; }
```

## `outline: none` → `:focus-visible` (ELP_029)

```css
/* Before */
button:focus { outline: none; }
```

```css
/* After */
button:focus-visible {
  outline: 3px solid var(--color-focus);
  outline-offset: 2px;
}
button:focus:not(:focus-visible) { outline: none; }
```

## Unconditional animation → reduced-motion gated (ELP_028)

```css
/* Before */
.card { transition: all 0.3s ease; }
```

```css
/* After */
@media (prefers-reduced-motion: no-preference) {
  .card { transition: transform 0.3s ease, opacity 0.3s ease; }
}
```

Only `opacity`, `transform`, `color`, `background-color` may be transitioned per the motion allowlist. Never `all`. See `skills/css-design-system/references/motion-allowlist.md`.

## Fixed card heights → intrinsic (ELP_002)

```css
/* Before */
.card { height: 320px; }
```

```css
/* After — let content size the card; Frame only when aspect-ratio is required */
.card { min-block-size: 0; }
```

If you genuinely need aspect ratio (e.g., media thumbnails), wrap the media in ELC_FRAME and let the card below flow to its intrinsic height.
