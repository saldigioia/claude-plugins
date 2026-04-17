# Vanilla CSS Implementation

Production-ready CSS classes implementing all 13 Every Layout primitives, plus print stylesheet.

## every-layout.css

```css
/**
 * Every Layout - Vanilla CSS Toolkit
 * Based on "Every Layout" by Andy Bell and Heydon Pickering
 * Version: 1.0.0
 */

/* ========================================
   CUSTOM PROPERTIES (Modular Scale)
   ======================================== */

:root {
  /* Modular Scale - ratio 1.5 (perfect fifth) */
  --ratio: 1.5;
  --s-5: calc(var(--s-4) / var(--ratio));
  --s-4: calc(var(--s-3) / var(--ratio));
  --s-3: calc(var(--s-2) / var(--ratio));
  --s-2: calc(var(--s-1) / var(--ratio));
  --s-1: calc(var(--s0) / var(--ratio));
  --s0: 1rem;
  --s1: calc(var(--s0) * var(--ratio));
  --s2: calc(var(--s1) * var(--ratio));
  --s3: calc(var(--s2) * var(--ratio));
  --s4: calc(var(--s3) * var(--ratio));
  --s5: calc(var(--s4) * var(--ratio));

  /* Measure (line length) */
  --measure: 60ch;

  /* Colors */
  --color-dark: #000;
  --color-light: #fff;

  /* Borders */
  --border-thin: 1px;
  --border-thick: 4px;
}

/* ========================================
   GLOBAL RESETS
   ======================================== */

*,
*::before,
*::after {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

*,
*::before,
*::after {
  border-style: solid;
  border-width: 0;
}

/* Responsive images */
img {
  max-inline-size: 100%;
  block-size: auto;
}

/* ========================================
   MOTION SAFETY (ELP_028)
   Disable animations for users who prefer
   reduced motion (WCAG 2.1 SC 2.3.3)
   ======================================== */

@media (prefers-reduced-motion: reduce) {
  *,
  *::before,
  *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
    scroll-behavior: auto !important;
  }
}

/* ========================================
   FOCUS VISIBILITY (ELP_029)
   Keyboard-only focus rings
   (WCAG 2.4.7 / 2.4.11)
   ======================================== */

:focus-visible {
  outline: 3px solid currentColor;
  outline-offset: 3px;
}

:focus:not(:focus-visible) {
  outline: none;
}

/* ========================================
   THE STACK
   Vertical spacing between sibling elements
   ======================================== */

.stack {
  display: flex;
  flex-direction: column;
  justify-content: flex-start;
}

.stack > * {
  margin-block: 0;
}

.stack > * + * {
  margin-block-start: var(--space, var(--s1));
}

/* Recursive variant */
.stack[data-recursive] * + * {
  margin-block-start: var(--space, var(--s1));
}

/* Split after variant - pushes items after nth child to bottom */
.stack:only-child {
  block-size: 100%;
}

.stack[data-split-after="1"] > :nth-child(1) {
  margin-block-end: auto;
}

.stack[data-split-after="2"] > :nth-child(2) {
  margin-block-end: auto;
}

.stack[data-split-after="3"] > :nth-child(3) {
  margin-block-end: auto;
}

/* ========================================
   THE BOX
   Padded container with optional border
   ======================================== */

.box {
  padding: var(--padding, var(--s1));
  border-width: var(--border-width, var(--border-thin));
  color: var(--color-dark);
  background-color: var(--color-light);
}

.box * {
  color: inherit;
}

.box[data-invert] {
  color: var(--color-light);
  background-color: var(--color-dark);
}

/* ========================================
   THE CENTER
   Horizontal centering with max-width
   ======================================== */

.center {
  box-sizing: content-box;
  max-inline-size: var(--measure);
  margin-inline: auto;
  padding-inline: var(--gutter, var(--s1));
}

/* Intrinsic centering variant */
.center[data-intrinsic] {
  display: flex;
  flex-direction: column;
  align-items: center;
}

/* Text centering variant */
.center[data-text] {
  text-align: center;
}

/* ========================================
   THE CLUSTER
   Flexible wrapping horizontal layout
   ======================================== */

.cluster {
  display: flex;
  flex-wrap: wrap;
  gap: var(--space, var(--s1));
  justify-content: var(--justify, flex-start);
  align-items: var(--align, center);
}

/* ========================================
   THE SIDEBAR
   Two-element layout with intrinsic switching
   ======================================== */

.with-sidebar {
  display: flex;
  flex-wrap: wrap;
  gap: var(--space, var(--s1));
}

.with-sidebar > * {
  flex-grow: 1;
}

.with-sidebar > :first-child {
  flex-basis: var(--side-width, 20rem);
}

.with-sidebar > :last-child {
  flex-basis: 0;
  flex-grow: 999;
  min-inline-size: var(--content-min, 50%);
}

/* No stretch variant */
.with-sidebar[data-no-stretch] {
  align-items: flex-start;
}

/* ========================================
   THE SWITCHER
   Equal columns that switch to stack below threshold
   ======================================== */

.switcher {
  display: flex;
  flex-wrap: wrap;
  gap: var(--space, var(--s1));
}

.switcher > * {
  flex-grow: 1;
  flex-basis: calc((var(--threshold, 30rem) - 100%) * 999);
}

/* Limit max items in row */
.switcher[data-limit="2"] > :nth-last-child(n+3),
.switcher[data-limit="2"] > :nth-last-child(n+3) ~ * {
  flex-basis: 100%;
}

.switcher[data-limit="3"] > :nth-last-child(n+4),
.switcher[data-limit="3"] > :nth-last-child(n+4) ~ * {
  flex-basis: 100%;
}

.switcher[data-limit="4"] > :nth-last-child(n+5),
.switcher[data-limit="4"] > :nth-last-child(n+5) ~ * {
  flex-basis: 100%;
}

/* ========================================
   THE COVER
   Vertical centering with optional header/footer
   ======================================== */

.cover {
  display: flex;
  flex-direction: column;
  min-block-size: var(--min-height, 100vh);
  padding: var(--padding, var(--s1));
}

.cover > * {
  margin-block: var(--space, var(--s1));
}

.cover > :first-child:not([data-centered]) {
  margin-block-start: 0;
}

.cover > :last-child:not([data-centered]) {
  margin-block-end: 0;
}

.cover > [data-centered] {
  margin-block: auto;
}

/* No padding variant */
.cover[data-no-pad] {
  padding: 0;
}

/* ========================================
   THE GRID
   Responsive grid with intrinsic sizing
   ======================================== */

.grid {
  display: grid;
  gap: var(--space, var(--s1));
  grid-template-columns: repeat(
    auto-fit,
    minmax(min(var(--min, 15rem), 100%), 1fr)
  );
}

/* Ragged variant — preserves natural item heights (no equal-row forcing) */
.grid[data-ragged] {
  align-items: start;
}

/* ========================================
   THE FRAME
   Aspect ratio container for media
   ======================================== */

.frame {
  aspect-ratio: var(--n, 16) / var(--d, 9);
  overflow: hidden;
  display: flex;
  justify-content: center;
  align-items: center;
}

.frame > img,
.frame > video {
  inline-size: 100%;
  block-size: 100%;
  object-fit: cover;
  object-position: var(--object-position, center);
}

/* ========================================
   THE REEL
   Horizontal scrolling container
   ======================================== */

.reel {
  display: flex;
  block-size: var(--height, auto);
  overflow-x: auto;
  overflow-y: hidden;
  scrollbar-color: var(--color-light) var(--color-dark);
}

.reel::-webkit-scrollbar {
  block-size: 1rem;
}

.reel::-webkit-scrollbar-track {
  background-color: var(--color-dark);
}

.reel::-webkit-scrollbar-thumb {
  background-color: var(--color-dark);
  background-image: linear-gradient(
    var(--color-dark) 0,
    var(--color-dark) 0.25rem,
    var(--color-light) 0.25rem,
    var(--color-light) 0.75rem,
    var(--color-dark) 0.75rem
  );
}

.reel > * {
  flex: 0 0 var(--item-width, auto);
}

.reel > img {
  block-size: 100%;
  flex-basis: auto;
  width: auto;
}

.reel > * + * {
  margin-inline-start: var(--space, var(--s1));
}

.reel.overflowing {
  padding-block-end: var(--space, var(--s1));
}

/* No scrollbar variant */
.reel[data-no-bar] {
  scrollbar-width: none;
}

.reel[data-no-bar]::-webkit-scrollbar {
  display: none;
}

/* Scroll snap variant (ELP_031) */
.reel[data-snap] {
  scroll-snap-type: x mandatory;
  scroll-padding-inline-start: var(--snap-offset, 0);
}

.reel[data-snap] > * {
  scroll-snap-align: start;
}

/* Proximity snap variant (less strict) */
.reel[data-snap="proximity"] {
  scroll-snap-type: x proximity;
}

/* ========================================
   THE IMPOSTER
   Superimposed/overlay positioning
   ======================================== */

.imposter {
  position: var(--positioning, absolute);
  inset-block-start: 50%;
  inset-inline-start: 50%;
  transform: translate(-50%, -50%);
}

.imposter[data-contain] {
  --margin: 0px;
  overflow: auto;
  max-inline-size: calc(100% - (var(--margin) * 2));
  max-block-size: calc(100% - (var(--margin) * 2));
}

.imposter[data-fixed] {
  --positioning: fixed;
}

/* ========================================
   THE ICON
   Inline SVG icon sizing and alignment
   ======================================== */

.icon {
  height: 0.75em;
  height: 1cap;
  width: 0.75em;
  width: 1cap;
}

.with-icon {
  display: inline-flex;
  align-items: baseline;
}

.with-icon .icon {
  margin-inline-end: var(--space, 0.5em);
}

/* ========================================
   THE CONTAINER
   Container query context
   ======================================== */

.container {
  container-type: inline-size;
}

.container[data-name] {
  container-name: var(--name);
}
```

## print.css

```css
/**
 * Every Layout - Print Stylesheet
 * Companion to every-layout.css for printed output.
 *
 * Include via: <link rel="stylesheet" href="print.css" media="print">
 * Or: @media print { @import "print.css"; }
 *
 * Design decisions:
 * - Linearise multi-column layouts to single column
 * - Preserve Stack spacing as vertical rhythm
 * - Remove interactive affordances (scroll, overflow)
 * - Respect page break heuristics
 * - Keep Box borders/padding for visual grouping
 */

@media print {

  /* ========================================
     PAGE SETUP
     ======================================== */

  @page {
    margin: 2cm;
  }

  /* ========================================
     GLOBAL PRINT RESETS
     ======================================== */

  body {
    color: #000;
    background: #fff;
  }

  /* Remove decorative backgrounds and shadows */
  * {
    background: transparent !important;
    box-shadow: none !important;
    text-shadow: none !important;
  }

  /* Restore Box backgrounds where data-invert is used
     (inverted boxes need visible background for contrast) */
  .box[data-invert] {
    background-color: #eee !important;
    color: #000 !important;
  }

  /* ========================================
     TYPOGRAPHY
     ======================================== */

  /* Ensure readable print size */
  html {
    font-size: 12pt;
  }

  /* Prevent orphans and widows in body text */
  p, li, blockquote {
    orphans: 3;
    widows: 3;
  }

  /* Avoid breaking inside headings */
  h1, h2, h3, h4, h5, h6 {
    break-after: avoid;
    break-inside: avoid;
  }

  /* Keep headings with their following content */
  h1 + *, h2 + *, h3 + *, h4 + *, h5 + *, h6 + * {
    break-before: avoid;
  }

  /* Show URLs after links */
  a[href^="http"]::after {
    content: " (" attr(href) ")";
    font-size: 0.85em;
    font-style: italic;
    word-break: break-all;
  }

  /* Don't expand internal/anchor links */
  a[href^="#"]::after,
  a[href^="javascript"]::after {
    content: "";
  }

  /* ========================================
     STACK — Preserved
     Vertical spacing is the foundation of
     print layout. Keep it intact.
     ======================================== */

  /* Stack works as-is. No changes needed.
     margin-block-start spacing translates
     directly to printed vertical rhythm. */

  /* ========================================
     BOX — Preserved
     Borders and padding provide visual
     grouping on paper.
     ======================================== */

  .box {
    border-width: 1px;
    border-color: #666;
    break-inside: avoid;
  }

  /* ========================================
     CENTER — Preserved
     Max-width centering is fine for print.
     Remove gutters (page margins handle it).
     ======================================== */

  .center {
    padding-inline: 0;
  }

  /* ========================================
     CLUSTER — Linearise
     Wrapping horizontal layout becomes a
     vertical list on paper.
     ======================================== */

  .cluster {
    flex-direction: column;
    align-items: flex-start;
  }

  /* ========================================
     SIDEBAR — Linearise
     Two-column layout becomes single column.
     ======================================== */

  .with-sidebar {
    flex-direction: column;
  }

  .with-sidebar > * {
    flex-basis: auto;
  }

  .with-sidebar > :last-child {
    min-inline-size: 0;
  }

  /* ========================================
     SWITCHER — Linearise
     Already stacks below threshold;
     force stack for print.
     ======================================== */

  .switcher > * {
    flex-basis: 100%;
  }

  /* ========================================
     COVER — Collapse
     Remove min-height (no viewport on paper).
     ======================================== */

  .cover {
    min-block-size: auto;
  }

  /* ========================================
     GRID — Linearise
     Force single column for print.
     ======================================== */

  .grid {
    grid-template-columns: 1fr;
  }

  /* ========================================
     FRAME — Collapse
     Remove aspect ratio; let content
     determine height.
     ======================================== */

  .frame {
    aspect-ratio: auto;
    overflow: visible;
  }

  .frame > img,
  .frame > video {
    object-fit: contain;
    block-size: auto;
    max-block-size: 15cm;
  }

  /* ========================================
     REEL — Linearise
     Horizontal scroll is meaningless on
     paper. Stack items vertically.
     ======================================== */

  .reel {
    flex-direction: column;
    overflow: visible;
  }

  .reel > * {
    flex: 0 0 auto;
  }

  .reel > * + * {
    margin-inline-start: 0;
    margin-block-start: var(--space, var(--s1));
  }

  /* Hide scrollbar-related styling */
  .reel::-webkit-scrollbar {
    display: none;
  }

  /* ========================================
     IMPOSTER — Remove
     Overlays don't print. Collapse to flow.
     ======================================== */

  .imposter {
    position: static;
    transform: none;
    max-inline-size: 100%;
    max-block-size: auto;
  }

  /* ========================================
     ICON — Preserved
     SVG icons print fine at text scale.
     ======================================== */

  /* No changes needed. */

  /* ========================================
     CONTAINER — Remove containment
     Container queries are viewport concepts;
     remove containment for print.
     ======================================== */

  .container {
    container-type: normal;
  }

  /* ========================================
     PAGE BREAK HEURISTICS
     ======================================== */

  /* Avoid breaking inside figures, tables, cards, blockquotes */
  figure,
  table,
  blockquote,
  .box,
  .card {
    break-inside: avoid;
  }

  /* Images should not be split across pages */
  img, svg, video {
    break-inside: avoid;
    max-inline-size: 100%;
  }

  /* ========================================
     HIDE NON-PRINT ELEMENTS
     ======================================== */

  /* Navigation, interactive controls, scroll indicators */
  nav,
  [role="navigation"],
  [aria-hidden="true"],
  .reel.overflowing::after,
  button[aria-label],
  [data-print="hide"] {
    display: none;
  }
}
```

## README.md

```markdown
# Every Layout - Vanilla CSS Toolkit

Production-ready CSS classes implementing all Every Layout primitives with custom property API.

## Installation

Include the stylesheet in your HTML:

```html
<link rel="stylesheet" href="every-layout.css">
```

## Primitives

### Stack
Vertical spacing between sibling elements.

```html
<div class="stack" style="--space: 2rem">
  <div>Item 1</div>
  <div>Item 2</div>
  <div>Item 3</div>
</div>
```

**Custom Properties:**
- `--space` - Gap between items (default: `var(--s1)`)

**Data Attributes:**
- `data-recursive` - Apply spacing to all descendants
- `data-split-after="n"` - Push items after nth child to bottom

### Box
Padded container with optional border.

```html
<div class="box" style="--padding: 2rem">
  Content here
</div>
```

**Custom Properties:**
- `--padding` - Internal padding (default: `var(--s1)`)
- `--border-width` - Border thickness (default: `var(--border-thin)`)

**Data Attributes:**
- `data-invert` - Swap foreground/background colors

### Center
Horizontal centering with max-width constraint.

```html
<div class="center" style="--measure: 40ch">
  Centered content
</div>
```

**Custom Properties:**
- `--measure` - Maximum content width (default: `60ch`)
- `--gutter` - Side padding (default: `var(--s1)`)

**Data Attributes:**
- `data-intrinsic` - Center based on content width
- `data-text` - Also center text alignment

### Cluster
Flexible wrapping horizontal layout.

```html
<div class="cluster" style="--space: 1rem">
  <span>Tag 1</span>
  <span>Tag 2</span>
  <span>Tag 3</span>
</div>
```

**Custom Properties:**
- `--space` - Gap between items (default: `var(--s1)`)
- `--justify` - Horizontal alignment (default: `flex-start`)
- `--align` - Vertical alignment (default: `center`)

### Sidebar
Two-element layout with intrinsic switching.

```html
<div class="with-sidebar">
  <div>Sidebar content</div>
  <div>Main content</div>
</div>
```

**Custom Properties:**
- `--side-width` - Sidebar width (default: `20rem`)
- `--content-min` - Min content width before wrap (default: `50%`)
- `--space` - Gap between elements (default: `var(--s1)`)

**Data Attributes:**
- `data-no-stretch` - Prevent vertical stretching

### Switcher
Equal columns that switch to stack below threshold.

```html
<div class="switcher" style="--threshold: 40rem">
  <div>Column 1</div>
  <div>Column 2</div>
  <div>Column 3</div>
</div>
```

**Custom Properties:**
- `--threshold` - Width at which to switch (default: `30rem`)
- `--space` - Gap between items (default: `var(--s1)`)

**Data Attributes:**
- `data-limit="n"` - Force stack when more than n items

### Cover
Vertical centering with optional header/footer.

```html
<div class="cover">
  <header>Header</header>
  <h1 data-centered>Centered Title</h1>
  <footer>Footer</footer>
</div>
```

**Custom Properties:**
- `--min-height` - Minimum height (default: `100vh`)
- `--padding` - Container padding (default: `var(--s1)`)
- `--space` - Space between elements (default: `var(--s1)`)

**Data Attributes:**
- `data-centered` - Mark element to be vertically centered
- `data-no-pad` - Remove padding

### Grid
Responsive grid with intrinsic sizing.

```html
<div class="grid" style="--min: 20rem">
  <div>Item 1</div>
  <div>Item 2</div>
  <div>Item 3</div>
</div>
```

**Custom Properties:**
- `--min` - Minimum column width (default: `15rem`)
- `--space` - Gap between items (default: `var(--s1)`)

### Frame
Aspect ratio container for media.

```html
<div class="frame" style="--n: 4; --d: 3">
  <img src="image.jpg" alt="Description">
</div>
```

**Custom Properties:**
- `--n` - Aspect ratio numerator (default: `16`)
- `--d` - Aspect ratio denominator (default: `9`)
- `--object-position` - Cropping position (default: `center`)

### Reel
Horizontal scrolling container.

```html
<div class="reel" style="--item-width: 20rem">
  <div>Card 1</div>
  <div>Card 2</div>
  <div>Card 3</div>
</div>
```

**Custom Properties:**
- `--item-width` - Width of each item (default: `auto`)
- `--height` - Container height (default: `auto`)
- `--space` - Gap between items (default: `var(--s1)`)

**Data Attributes:**
- `data-no-bar` - Hide scrollbar

### Imposter
Superimposed/overlay positioning.

```html
<div style="position: relative">
  <div class="imposter">
    Centered overlay
  </div>
</div>
```

**Custom Properties:**
- `--positioning` - `absolute` or `fixed` (default: `absolute`)
- `--margin` - Gap from container edges when contained

**Data Attributes:**
- `data-contain` - Constrain to container bounds
- `data-fixed` - Position relative to viewport

### Icon
Inline SVG icon sizing and alignment.

```html
<span class="with-icon">
  <svg class="icon"><!-- icon --></svg>
  Button text
</span>
```

**Custom Properties:**
- `--space` - Gap between icon and text (default: `0.5em`)

### Container
Container query context.

```html
<div class="container" data-name style="--name: myContainer">
  Content that can use @container queries
</div>
```

**Custom Properties:**
- `--name` - Container name for queries

## Modular Scale

The toolkit includes a modular scale with ratio 1.5:

- `--s-5` through `--s5` - Scale values
- `--s0` = `1rem` (base)

## License

Based on "Every Layout" by Andy Bell and Heydon Pickering.
```
