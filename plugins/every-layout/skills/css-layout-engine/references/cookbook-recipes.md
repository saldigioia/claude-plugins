# Cookbook — Recipes

# Recipe: Article Grid with Full-Bleed & Breakout

A named-grid-lines layout for editorial content with full-bleed images and breakout elements.

## Problem

Create an article layout where:
- Body text is constrained to a readable measure
- Some elements break out of the content column (pullquotes, figures)
- Some elements span the full viewport width (hero images, color bands)
- No media queries needed for the grid structure
- Content remains centered with consistent gutters

## Solution

```css
.article-grid {
  --content: min(var(--measure, 60ch), 100% - var(--gutter, var(--s1)) * 2);
  --breakout: minmax(0, calc((var(--breakout-max, 85ch) - var(--content)) / 2));
  --full: minmax(var(--gutter, var(--s1)), 1fr);

  display: grid;
  grid-template-columns:
    [full-start] var(--full)
    [breakout-start] var(--breakout)
    [content-start] var(--content) [content-end]
    var(--breakout) [breakout-end]
    var(--full) [full-end];
}

.article-grid > * {
  grid-column: content;
}

.article-grid > .breakout {
  grid-column: breakout;
}

.article-grid > .full-bleed {
  grid-column: full;
}
```

```html
<article class="article-grid">
  <h1>Article Title</h1>

  <div class="stack">
    <p>Body text is constrained to a readable measure,
       maintaining comfortable line lengths.</p>
    <p>Additional paragraphs flow naturally within
       the content column.</p>
  </div>

  <figure class="breakout">
    <div class="frame" style="--n: 16; --d: 9">
      <img src="wide-image.jpg" alt="A wider image that breaks out">
    </div>
    <figcaption>This image extends beyond the content column.</figcaption>
  </figure>

  <div class="stack">
    <p>Text returns to the content column after the breakout.</p>
  </div>

  <div class="full-bleed box" data-invert>
    <div class="center">
      <blockquote class="stack">
        <p>"A pullquote that spans the full viewport width
           with an inverted background."</p>
      </blockquote>
    </div>
  </div>

  <div class="stack">
    <p>And the article continues at the normal width.</p>
  </div>
</article>
```

## Why This Works

1. **Named grid lines** create semantic column zones
   - `content`: the readable text column, constrained by `--measure`
   - `breakout`: wider zone for figures and emphasis
   - `full`: edge-to-edge for hero images and color bands

2. **`min()` for the content column** ensures it never exceeds the measure but shrinks with the viewport, minus gutters

3. **`minmax(0, ...)` for breakout** collapses gracefully on narrow viewports — breakout elements simply match content width when there's no extra space

4. **Default `grid-column: content`** means every child is constrained by default; only explicitly classed elements escape

5. **No media queries** — the grid structure adapts intrinsically via `min()`, `minmax()`, and `1fr`

## Variations

### With Popout (Between Content and Breakout)

Add a fourth zone for subtle breakout:

```css
.article-grid {
  --content: min(var(--measure, 60ch), 100% - var(--gutter, var(--s1)) * 2);
  --popout: minmax(0, 2rem);
  --breakout: minmax(0, calc((var(--breakout-max, 85ch) - var(--content)) / 2 - 2rem));
  --full: minmax(var(--gutter, var(--s1)), 1fr);

  display: grid;
  grid-template-columns:
    [full-start] var(--full)
    [breakout-start] var(--breakout)
    [popout-start] var(--popout)
    [content-start] var(--content) [content-end]
    var(--popout) [popout-end]
    var(--breakout) [breakout-end]
    var(--full) [full-end];
}

.article-grid > .popout {
  grid-column: popout;
}
```

### With Sidebar Annotation Column

Use asymmetric named lines for a margin note gutter:

```css
.article-grid--annotated {
  --content: min(var(--measure, 60ch), 100%);
  --note: minmax(0, 20ch);
  --full: minmax(var(--gutter, var(--s1)), 1fr);

  display: grid;
  grid-template-columns:
    [full-start] var(--full)
    [content-start] var(--content) [content-end]
    [note-start] var(--note) [note-end]
    var(--full) [full-end];
  gap: var(--s1);
}

.article-grid--annotated > .note {
  grid-column: note;
  font-size: var(--step--1, 0.875rem);
}
```

## Configuration

| Property | Default | Effect |
|----------|---------|--------|
| `--measure` | `60ch` | Content column max width |
| `--breakout-max` | `85ch` | Breakout column max width |
| `--gutter` | `var(--s1)` | Minimum side padding |

## Principles Applied

| Principle | How |
|-----------|-----|
| ELP_006 (Measure Constraint) | Content column capped at `--measure` |
| ELP_002 (Intrinsic Sizing) | Grid adapts to viewport via `min()` / `minmax()` |
| ELP_009 (Algorithmic Layout) | No media queries; grid self-governs |
| ELP_011 (Custom Properties) | All dimensions configurable via custom properties |
| ELP_004 (Logical Properties) | Grid tracks follow inline direction automatically |

## Primitives Used

| Primitive | Purpose |
|-----------|---------|
| Stack | Vertical spacing within content sections |
| Frame | Consistent aspect ratios for breakout images |
| Box | Full-bleed background sections |
| Center | Constraining content within full-bleed sections |

---

# Recipe: Responsive Card Grid

A grid of cards that adapts column count to available space.

## Problem

Create a grid of cards that:
- Shows more columns when space allows
- Reduces columns on narrower containers
- Maintains equal card widths
- Has consistent spacing

## Solution

```html
<div class="grid" style="--min: 20rem; --space: var(--s1)">
  <article class="box">
    <div class="stack">
      <div class="frame" style="--n: 16; --d: 9">
        <img src="image.jpg" alt="Description">
      </div>
      <h3>Card Title</h3>
      <p>Card description text that explains the content.</p>
    </div>
  </article>

  <article class="box">
    <div class="stack">
      <div class="frame" style="--n: 16; --d: 9">
        <img src="image.jpg" alt="Description">
      </div>
      <h3>Another Card</h3>
      <p>Different content here.</p>
    </div>
  </article>

  <!-- More cards... -->
</div>
```

## Why This Works

1. **Grid** with `--min: 20rem`
   - Creates columns of at least 20rem
   - `auto-fit` creates as many as will fit
   - `1fr` ensures equal distribution

2. **Box** provides consistent card styling
   - Padding creates internal spacing
   - Border gives visual boundary

3. **Stack** organizes card content
   - Consistent vertical spacing
   - Can use `data-split-after` for bottom actions

4. **Frame** ensures consistent image sizing
   - All images have same aspect ratio
   - No layout shift from varying image sizes

## Variations

### With Bottom Action

```html
<article class="box">
  <div class="stack" data-split-after="3">
    <div class="frame"><img>...</div>
    <h3>Title</h3>
    <p>Description</p>
    <a href="#">Learn more →</a>
  </div>
</article>
```

### With Tags

```html
<article class="box">
  <div class="stack">
    <div class="frame"><img>...</div>
    <div class="cluster" style="--space: 0.5rem">
      <span class="tag">Category</span>
      <span class="tag">Tag</span>
    </div>
    <h3>Title</h3>
    <p>Description</p>
  </div>
</article>
```

### Masonry-like (Variable Heights)

Let content determine height, Grid handles the rest:

```html
<div class="grid" style="--min: 20rem; align-items: start">
  <!-- Cards with varying content -->
</div>
```

## CSS Customization

```css
/* Tighter grid */
.grid.tight {
  --min: 15rem;
  --space: var(--s-1);
}

/* Looser grid */
.grid.loose {
  --min: 25rem;
  --space: var(--s2);
}
```

## Primitives Used

| Primitive | Purpose |
|-----------|---------|
| Grid | Responsive column layout |
| Box | Card container styling |
| Stack | Internal card spacing |
| Frame | Consistent image ratios |
| Cluster | Tag/category display |

---

# Recipe: Content-Aware Layout with :has()

Use the `:has()` relational pseudo-class to adjust layout based on the *presence* of content — not viewport size.

## Problem

Create layouts where:
- A card switches from vertical to horizontal when it contains an image
- A form group adjusts spacing when it contains a help message
- A nav adapts when it has many items
- No JavaScript or media queries are needed for these adjustments
- The layout degrades gracefully in browsers without `:has()` support

## Solution: Card with Conditional Image Layout

```css
/* Base card: vertical stack */
.card {
  display: flex;
  flex-direction: column;
  gap: var(--s0);
  padding: var(--s1);
  border-width: var(--border-thin);
}

/* When the card contains an image, switch to horizontal (Sidebar pattern) */
.card:has(> img),
.card:has(> .frame) {
  flex-direction: row;
  flex-wrap: wrap;
}

.card:has(> img) > img,
.card:has(> .frame) > .frame {
  flex-basis: var(--image-width, 15rem);
  flex-grow: 1;
}

.card:has(> img) > :not(img),
.card:has(> .frame) > :not(.frame) {
  flex-basis: 0;
  flex-grow: 999;
  min-inline-size: var(--content-min, 50%);
}
```

```html
<!-- Card WITHOUT image: remains vertical Stack -->
<div class="card">
  <h3>Text-Only Card</h3>
  <p>This card has no image, so it stays in vertical layout.</p>
  <a href="#">Read more</a>
</div>

<!-- Card WITH image: switches to horizontal Sidebar -->
<div class="card">
  <div class="frame" style="--n: 4; --d: 3">
    <img src="photo.jpg" alt="Description">
  </div>
  <div class="stack">
    <h3>Image Card</h3>
    <p>This card has an image, so it switches to a horizontal layout.</p>
    <a href="#">Read more</a>
  </div>
</div>
```

## Why This Works

1. **Content-driven, not viewport-driven**: The layout responds to what's *in* the component, not the size of the window — a more intrinsic approach than media or container queries
2. **Progressive enhancement (ELP_027)**: Without `:has()` support, the card stays vertical — a functional fallback. The horizontal layout is an enhancement
3. **Composition (ELP_001)**: The `:has()` selector composes with existing primitives — it applies Sidebar-like behavior to the card only when the content warrants it
4. **No JavaScript**: Pure CSS content detection

## Variations

### Form Group with Conditional Help Spacing

Adjust spacing when a form field includes a help message:

```css
.field-group {
  display: flex;
  flex-direction: column;
  gap: var(--s-1);
}

/* Tighter gap when help text is present (text is closer to the field) */
.field-group:has(.help-text) {
  gap: var(--s-2);
}

/* Visual link between field and help */
.field-group:has(.help-text) .help-text {
  padding-inline-start: var(--s0);
  border-inline-start-width: 2px;
  border-color: currentColor;
  font-size: var(--step--1, 0.875rem);
  opacity: 0.8;
}
```

```html
<div class="field-group">
  <label for="email">Email</label>
  <input type="email" id="email" name="email">
  <p class="help-text">We'll never share your email.</p>
</div>
```

### Navigation Density Detection

Switch nav layout when many items are present:

```css
.nav-cluster {
  display: flex;
  flex-wrap: wrap;
  gap: var(--s0);
  align-items: center;
}

/* When nav has 6+ items, reduce spacing to prevent early wrapping */
.nav-cluster:has(> :nth-child(6)) {
  gap: var(--s-1);
  font-size: var(--step--1, 0.875rem);
}
```

### Empty State Detection

Show a message when a container has no content children:

```css
.item-list:has(> *) .empty-state {
  display: none;
}

.item-list:not(:has(> *)) .empty-state {
  display: block;
}
```

```html
<div class="item-list">
  <!-- Items rendered here dynamically -->
  <p class="empty-state">No items to display.</p>
</div>
```

### Grid Column Adjustment Based on Content

Widen the grid minimum when cards contain images:

```css
.grid {
  --min: 15rem;
}

.grid:has(> .card > img),
.grid:has(> .card > .frame) {
  --min: 20rem;
}
```

## Configuration

| Property | Default | Effect |
|----------|---------|--------|
| `--image-width` | `15rem` | Image flex-basis in horizontal card |
| `--content-min` | `50%` | Minimum content width before wrapping |
| `--s-1`, `--s-2` | Scale values | Spacing adjustments |

## Browser Support

`:has()` is supported in Chrome 105+, Safari 15.4+, Firefox 121+. As of 2025, global support exceeds 90%.

> **Progressive enhancement**: Always design the `:has()`-less state first as the baseline. The `:has()`-enhanced layout should improve, not enable, the experience.

## Principles Applied

| Principle | How |
|-----------|-----|
| ELP_001 (Composition) | `:has()` composes Sidebar behavior onto a card without a new component |
| ELP_002 (Intrinsic Sizing) | Layout responds to content, not arbitrary viewport values |
| ELP_009 (Algorithmic Layout) | No media queries; layout self-governs based on content presence |
| ELP_011 (Custom Properties) | Thresholds and widths configurable via custom properties |
| ELP_027 (Progressive Enhancement) | Baseline layout works without `:has()` |

## Primitives Used

| Primitive | Purpose |
|-----------|---------|
| Stack | Vertical card layout (default / fallback) |
| Sidebar (pattern) | Horizontal card layout when image present |
| Frame | Aspect ratio for card images |
| Grid | Responsive card grid with adjusted minimums |
| Cluster | Navigation with density detection |

## Verification

Test your implementation:
- With and without images in cards — layout should adapt
- In Firefox 120 or older — fallback layout should be functional
- At 400% zoom — content should not overlap or clip
- With screen reader — content order should be logical in both layouts

---

# Recipe: Holy Grail Layout

The classic three-column layout with header, footer, and sticky footer behavior.

## Problem

Create a page layout with:
- Header at top
- Footer at bottom (sticky if content is short)
- Main content area with optional sidebars
- Responsive behavior without media queries

## Solution

```html
<body>
  <div class="cover" style="--min-height: 100vh">
    <header>
      <div class="center">
        <nav class="cluster" style="--justify: space-between">
          <a href="/">Logo</a>
          <div class="cluster">
            <a href="/about">About</a>
            <a href="/contact">Contact</a>
          </div>
        </nav>
      </div>
    </header>

    <main data-centered>
      <div class="center">
        <div class="with-sidebar">
          <aside>
            <div class="stack">
              <!-- sidebar content -->
            </div>
          </aside>
          <article class="stack">
            <!-- main content -->
          </article>
        </div>
      </div>
    </main>

    <footer>
      <div class="center">
        <p>© 2024 Company Name</p>
      </div>
    </footer>
  </div>
</body>
```

## Why This Works

1. **Cover** provides the overall vertical structure
   - `min-height: 100vh` ensures full viewport coverage
   - `data-centered` on main pushes it to center
   - Header stays at top, footer at bottom

2. **Center** constrains content width
   - Consistent gutters
   - Readable line lengths

3. **Sidebar** handles the two-column layout
   - Automatically stacks on narrow viewports
   - No media queries needed

4. **Cluster** arranges navigation items
   - `justify: space-between` pushes logo and links apart
   - Wraps gracefully on small screens

## Variations

### Without Sidebar
Remove the Sidebar layer for single-column:

```html
<main data-centered>
  <div class="center">
    <article class="stack">
      <!-- content -->
    </article>
  </div>
</main>
```

### Right Sidebar
Reverse child order in HTML or use `side="right"` prop:

```html
<div class="with-sidebar" style="--side-width: 20rem">
  <article>Main content</article>
  <aside>Sidebar</aside>
</div>
```

### With Two Sidebars
Nest Sidebar layouts:

```html
<div class="with-sidebar">
  <nav>Left nav</nav>
  <div class="with-sidebar">
    <article>Main content</article>
    <aside>Right sidebar</aside>
  </div>
</div>
```

## Primitives Used

| Primitive | Purpose |
|-----------|---------|
| Cover | Full-height layout with sticky footer |
| Center | Constrain and center content |
| Sidebar | Two-column responsive layout |
| Stack | Vertical spacing within sections |
| Cluster | Horizontal navigation items |

---

# Recipe: Responsive Data Table

A pattern for data tables that remain readable across viewport sizes without media queries.

## Problem

Create a data table where:
- Full table layout is preserved on wide viewports
- Content remains accessible and scannable on narrow viewports
- No media queries are used for the layout switch
- The table retains semantic HTML (`<table>`, `<th>`, `<td>`)
- Horizontal scrolling is available as a fallback

## Solution: Overflow Reel Pattern

Wrap a semantic table in a Reel (ELC_REEL) for horizontal scroll access on narrow viewports:

```css
.table-wrapper {
  display: flex;
  overflow-x: auto;
  overflow-y: hidden;
  -webkit-overflow-scrolling: touch;
}

.table-wrapper > table {
  min-inline-size: 100%;
  border-collapse: collapse;
}

.table-wrapper th,
.table-wrapper td {
  padding: var(--s-1) var(--s0);
  text-align: start;
  white-space: nowrap;
}

.table-wrapper th {
  font-weight: 700;
}

/* Sticky first column for context */
.table-wrapper[data-sticky-col] th:first-child,
.table-wrapper[data-sticky-col] td:first-child {
  position: sticky;
  inset-inline-start: 0;
  background-color: inherit;
  z-index: 1;
}
```

```html
<div class="table-wrapper" role="region" aria-label="Team statistics" tabindex="0">
  <table>
    <thead>
      <tr>
        <th scope="col">Player</th>
        <th scope="col">Goals</th>
        <th scope="col">Assists</th>
        <th scope="col">Minutes</th>
        <th scope="col">Rating</th>
      </tr>
    </thead>
    <tbody>
      <tr>
        <td>Jordan Lee</td>
        <td>12</td>
        <td>8</td>
        <td>1640</td>
        <td>7.2</td>
      </tr>
      <!-- More rows -->
    </tbody>
  </table>
</div>
```

## Why This Works

1. **Semantic HTML preserved**: The `<table>` element retains its proper structure for screen readers and parsing
2. **Horizontal scroll as progressive enhancement**: The wrapper provides overflow scrolling only when the table exceeds available space — otherwise it's a normal table
3. **`role="region"` + `tabindex="0"`**: Allows keyboard users to discover and navigate the scrollable area (WCAG 2.1 SC 2.1.1)
4. **No media queries**: The overflow behavior is intrinsic — the table scrolls when it needs to, not at an arbitrary breakpoint
5. **Sticky first column** (optional): Keeps the row identifier visible while scrolling horizontally

## Variations

### With Stack Spacing

Wrap multiple tables or add vertical context:

```html
<div class="stack">
  <h2>Quarterly Results</h2>
  <div class="table-wrapper" role="region" aria-label="Quarterly results" tabindex="0">
    <table><!-- ... --></table>
  </div>
  <p class="small">Source: internal data, 2025 Q4.</p>
</div>
```

### With Scroll Snap (ELP_031)

For tables with wide, uniform columns, add snap alignment:

```css
.table-wrapper[data-snap] {
  scroll-snap-type: x proximity;
}

.table-wrapper[data-snap] td,
.table-wrapper[data-snap] th {
  scroll-snap-align: start;
}
```

### Stacked Cards (Alternative for Small Tables)

For tables with few columns (2–3), a definition-list style can work without horizontal scroll. This approach uses CSS Grid and the `data-label` attribute:

```css
.table-cards {
  display: grid;
  gap: var(--s1);
}

.table-cards > * {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(10rem, 100%), 1fr));
  gap: var(--s-1) var(--s1);
  padding: var(--s0);
  border-width: var(--border-thin);
}

.table-cards [data-label]::before {
  content: attr(data-label) ": ";
  font-weight: 700;
}
```

```html
<div class="table-cards">
  <div class="box">
    <span data-label="Player">Jordan Lee</span>
    <span data-label="Goals">12</span>
    <span data-label="Assists">8</span>
  </div>
  <!-- More cards -->
</div>
```

> **Trade-off**: The card pattern loses the tabular comparison affordance. Use Reel-based overflow for data-dense tables; use cards only for simple key-value displays.

## Configuration

| Property | Default | Effect |
|----------|---------|--------|
| `--s-1` | `0.667rem` | Cell block padding |
| `--s0` | `1rem` | Cell inline padding |
| `--s1` | `1.5rem` | Stack/card gap |
| `data-sticky-col` | — | Enables sticky first column |
| `data-snap` | — | Enables scroll snap on columns |

## Principles Applied

| Principle | How |
|-----------|-----|
| ELP_002 (Intrinsic Sizing) | Table width determined by content; overflow handled intrinsically |
| ELP_005 (Modular Scale) | All spacing from the scale |
| ELP_009 (Algorithmic Layout) | No media queries; overflow triggers scrolling automatically |
| ELP_027 (Progressive Enhancement) | Semantic table works without CSS; scroll wrapper enhances UX |
| ELP_031 (Scroll Snap) | Optional snap alignment for structured columns |

## Primitives Used

| Primitive | Purpose |
|-----------|---------|
| Reel (pattern) | Horizontal scroll wrapper for the table |
| Stack | Vertical spacing around the table |
| Box | Card variant container |
| Grid | Card variant auto-responsive layout |

## Verification

Test your implementation at:
- 320px viewport width — table should scroll horizontally
- 1920px viewport — table should display normally without scroll
- With keyboard — `Tab` to the wrapper, arrow keys to scroll
- With screen reader — table structure and `aria-label` should be announced
- At 400% zoom — content should not be clipped (WCAG 1.4.10)

---

# Recipe: Tufte-Style Sidenotes

Margin notes that sit alongside body text on wide viewports and collapse inline on narrow ones.

## Problem

Create a sidenote system where:
- Notes appear in the margin alongside their referenced text on wide screens
- Notes collapse to inline/footnote-style on narrow screens
- Content remains readable without the notes
- The pattern follows progressive enhancement (ELP_027)

## Media Query Exception

> **This recipe uses a media query for layout switching.** Per ELP_009 (Algorithmic Self-Governing Layout), media queries for layout are discouraged. This is a **documented exception** because sidenotes require a content-adjacent layout that cannot be achieved with Switcher or Sidebar alone — the note must sit *beside a specific paragraph*, not beside the entire content column. The Sidebar primitive governs two-column page structure; sidenotes govern per-paragraph annotation placement.

## Solution

```css
/* Sidenote base: inline by default (narrow viewports) */
.sidenote {
  font-size: var(--step--1, 0.875rem);
  color: var(--color-muted, #555);
  padding-block: var(--s-1);
  border-block-start: var(--border-thin) solid currentColor;
  margin-block-start: var(--s-1);
}

.sidenote::before {
  content: attr(data-marker) ". ";
  font-weight: 700;
}

/* Sidenote marker in body text */
.sidenote-ref {
  font-size: 0.75em;
  vertical-align: super;
  line-height: 0;
  font-weight: 700;
}

/* DOCUMENTED EXCEPTION: @media for sidenote placement (see note above) */
@media (min-width: 60rem) {
  .has-sidenotes {
    display: grid;
    grid-template-columns: [content-start] 1fr [content-end sidenote-start] 18ch [sidenote-end];
    gap: var(--s1);
  }

  .has-sidenotes > * {
    grid-column: content;
  }

  .has-sidenotes > .sidenote {
    grid-column: sidenote;
    grid-row: span 1;
    border-block-start: none;
    margin-block-start: 0;
    padding-block: 0;
  }
}
```

```html
<article class="has-sidenotes">
  <div class="stack">
    <h1>Article with Sidenotes</h1>

    <p>
      The main text flows in the content column with comfortable
      line lengths.<span class="sidenote-ref" aria-hidden="true">1</span>
    </p>

    <aside class="sidenote" data-marker="1" role="note">
      This note appears in the margin on wide screens
      and inline on narrow screens.
    </aside>

    <p>
      Subsequent paragraphs continue naturally. The sidenote
      aligns with its reference point in the text.
      <span class="sidenote-ref" aria-hidden="true">2</span>
    </p>

    <aside class="sidenote" data-marker="2" role="note">
      A second note. Each note corresponds to its marker.
    </aside>

    <p>
      The article continues. Notes are progressively enhanced:
      they work as inline annotations without CSS.
    </p>
  </div>
</article>
```

## Why This Works

1. **Progressive enhancement** (ELP_027): Without CSS, `<aside>` elements appear inline — readable, if not ideal. CSS enhances them into margin notes.

2. **Grid with named lines**: The `has-sidenotes` container creates a two-track grid. Body content fills the main column; `<aside class="sidenote">` elements are pulled into the sidenote column.

3. **Mobile-first**: On narrow viewports (default), sidenotes appear as styled inline blocks with a top border and marker. The `@media` query promotes them to the margin only when space allows.

4. **Semantic HTML**: Using `<aside role="note">` correctly identifies the content as supplementary. The `data-marker` attribute generates the note number via `::before`.

5. **No JavaScript required**: The entire pattern works with CSS alone.

## Variations

### Numbered Footnotes (No Margin)

Remove the grid entirely for a simpler footnote pattern:

```html
<p>
  Some text.<sup><a href="#fn1" id="fnref1">1</a></sup>
</p>

<!-- At article end -->
<footer class="stack" role="doc-endnotes">
  <ol>
    <li id="fn1">
      <p>Footnote text. <a href="#fnref1" aria-label="Back to content">↩</a></p>
    </li>
  </ol>
</footer>
```

### Left-Side Notes

Flip the grid columns:

```css
@media (min-width: 60rem) {
  .has-sidenotes--left {
    grid-template-columns: [sidenote-start] 18ch [sidenote-end content-start] 1fr [content-end];
  }
}
```

### With Sidebar Primitive for Page-Level Layout

Combine with Sidebar for a main+sidebar page that also has sidenotes:

```html
<div class="with-sidebar">
  <nav>Page sidebar</nav>
  <article class="has-sidenotes">
    <!-- sidenotes within the main content area -->
  </article>
</div>
```

## Configuration

| Property | Default | Effect |
|----------|---------|--------|
| `--step--1` | `0.875rem` | Sidenote font size |
| `--color-muted` | `#555` | Sidenote text color |
| `--s1` | `1.5rem` | Gap between content and notes |
| `60rem` | (breakpoint) | Width at which notes move to margin |

## Principles Applied

| Principle | How |
|-----------|-----|
| ELP_027 (Progressive Enhancement) | Notes readable without CSS |
| ELP_006 (Measure Constraint) | Content column preserves readable line length |
| ELP_009 (Algorithmic Layout) | **Exception documented** — media query required |
| ELP_011 (Custom Properties) | Configurable via custom properties |
| ELP_005 (Modular Scale) | Spacing from scale |

## Primitives Used

| Primitive | Purpose |
|-----------|---------|
| Stack | Vertical spacing within article content |
| Center | Can wrap `.has-sidenotes` for page centering |
| Sidebar | Page-level layout (optional, see variation) |
