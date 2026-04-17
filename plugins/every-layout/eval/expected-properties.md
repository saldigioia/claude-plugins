# Expected CSS Properties by Primitive

Reference guide for validating primitive implementations.

## Stack (ELC_STACK)

### Required Properties
```css
.stack {
  display: flex;
  flex-direction: column;
  justify-content: flex-start;
}

.stack > * {
  margin-block: 0;
}

.stack > * + * {
  margin-block-start: var(--space);
}
```

### Forbidden Properties
- `gap` on parent (use margin for owl selector)
- Fixed heights on children

### Custom Properties
- `--space` - spacing between children

---

## Box (ELC_BOX)

### Required Properties
```css
.box {
  padding: var(--padding);
  border-width: var(--border-width);
  border-style: solid;
}

.box * {
  color: inherit;
}
```

### Forbidden Properties
- Hard-coded colors (use custom properties)

### Custom Properties
- `--padding`
- `--border-width`
- `--color-dark`
- `--color-light`

---

## Center (ELC_CENTER)

### Required Properties
```css
.center {
  box-sizing: content-box;
  max-inline-size: var(--measure);
  margin-inline: auto;
  padding-inline: var(--gutter);
}
```

### Forbidden Properties
- `width` (use max-inline-size)
- `text-align: center` for block centering

### Custom Properties
- `--measure`
- `--gutter`

---

## Cluster (ELC_CLUSTER)

### Required Properties
```css
.cluster {
  display: flex;
  flex-wrap: wrap;
  gap: var(--space);
  justify-content: var(--justify);
  align-items: var(--align);
}
```

### Forbidden Properties
- `flex-direction: column`
- Fixed widths on children

### Custom Properties
- `--space`
- `--justify`
- `--align`

---

## Sidebar (ELC_SIDEBAR)

### Required Properties
```css
.with-sidebar {
  display: flex;
  flex-wrap: wrap;
  gap: var(--space);
}

.with-sidebar > :first-child {
  flex-basis: var(--side-width);
  flex-grow: 1;
}

.with-sidebar > :last-child {
  flex-basis: 0;
  flex-grow: 999;
  min-inline-size: var(--content-min);
}
```

### Forbidden Properties
- `@media` queries for switching

### Custom Properties
- `--side-width`
- `--content-min`
- `--space`

---

## Switcher (ELC_SWITCHER)

### Required Properties
```css
.switcher {
  display: flex;
  flex-wrap: wrap;
  gap: var(--space);
}

.switcher > * {
  flex-grow: 1;
  flex-basis: calc((var(--threshold) - 100%) * 999);
}
```

### Forbidden Properties
- `@media` queries for switching
- Fixed widths on children

### Custom Properties
- `--threshold`
- `--space`

---

## Cover (ELC_COVER)

### Required Properties
```css
.cover {
  display: flex;
  flex-direction: column;
  min-block-size: var(--min-height);
}

.cover > [data-centered] {
  margin-block: auto;
}
```

### Forbidden Properties
- `height` (use min-block-size)
- `justify-content: center` (use margin: auto)

### Custom Properties
- `--min-height`
- `--space`

---

## Grid (ELC_GRID)

### Required Properties
```css
.grid {
  display: grid;
  gap: var(--space);
  grid-template-columns: repeat(
    auto-fit,
    minmax(min(var(--min), 100%), 1fr)
  );
}
```

### Forbidden Properties
- Fixed column counts
- `@media` queries for column changes
- Percentage values in minmax minimum

### Custom Properties
- `--min`
- `--space`

---

## Frame (ELC_FRAME)

### Required Properties
```css
.frame {
  aspect-ratio: var(--n) / var(--d);
  overflow: hidden;
}

.frame > img,
.frame > video {
  inline-size: 100%;
  block-size: 100%;
  object-fit: cover;
}
```

### Forbidden Properties
- Fixed width/height on parent
- `background-image` for content images

### Custom Properties
- `--n` (numerator)
- `--d` (denominator)

---

## Reel (ELC_REEL)

### Required Properties
```css
.reel {
  display: flex;
  overflow-x: auto;
  overflow-y: hidden;
}

.reel > * {
  flex: 0 0 var(--item-width);
}
```

### Forbidden Properties
- `flex-wrap: wrap`
- Bidirectional overflow

### Custom Properties
- `--item-width`
- `--space`
- `--height`

---

## Imposter (ELC_IMPOSTER)

### Required Properties
```css
.imposter {
  position: absolute; /* or fixed */
  inset-block-start: 50%;
  inset-inline-start: 50%;
  transform: translate(-50%, -50%);
}
```

### Forbidden Properties
- Negative margins for centering
- `z-index` without consideration

### Custom Properties
- `--positioning`
- `--margin`

---

## Icon (ELC_ICON)

### Required Properties
```css
.icon {
  height: 0.75em; /* fallback */
  height: 1cap;   /* preferred */
  width: 0.75em;
  width: 1cap;
}
```

### Forbidden Properties
- Fixed pixel sizes
- Icon fonts

### Custom Properties
- `--space`

---

## Container (ELC_CONTAINER)

### Required Properties
```css
.container {
  container-type: inline-size;
}
```

### Optional Properties
```css
.container {
  container-name: var(--name);
}
```

### Custom Properties
- `--name`
