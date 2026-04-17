# Subgrid Composition Patterns

Patterns using CSS subgrid on top of ELC_GRID (ELP_021). Subgrid enables cross-item alignment that the base Grid primitive cannot achieve alone. No new primitive — subgrid is a modifier on Grid.

**Browser support:** All modern browsers (Chrome 117+, Firefox 71+, Safari 16+).

---

## When to Use Subgrid vs. Base Grid

| Need | Use |
|------|-----|
| Equal-width responsive columns | ELC_GRID (base) |
| Items with independently-sized internals | ELC_GRID (base) |
| Items whose internals must align across items | **Subgrid** |
| Table-like alignment without `<table>` | **Subgrid** |
| Form labels aligning across rows | **Subgrid** |

**Decision rule:** If you need *cross-item alignment of child elements*, use subgrid. Otherwise, the base Grid is simpler and sufficient.

---

## Pattern 1: Card Grid with Aligned Titles

Cards in a grid where all titles, images, and descriptions align horizontally across cards regardless of content length.

```html
<div class="grid" style="--min: 18rem">
  <article class="card">
    <img src="a.jpg" alt="...">
    <h3>Short Title</h3>
    <p>Description text that might be quite long.</p>
  </article>
  <article class="card">
    <img src="b.jpg" alt="...">
    <h3>A Much Longer Card Title That Wraps</h3>
    <p>Short desc.</p>
  </article>
  <article class="card">
    <img src="c.jpg" alt="...">
    <h3>Medium Title</h3>
    <p>Medium-length description paragraph.</p>
  </article>
</div>
```

```css
.grid {
  display: grid;
  gap: var(--s1);
  grid-template-columns: repeat(auto-fit, minmax(min(var(--min, 18rem), 100%), 1fr));
  /* Each column has 3 implicit rows: image, title, description */
  grid-template-rows: subgrid;
}

.card {
  display: grid;
  grid-template-rows: subgrid;
  grid-row: span 3; /* Card spans 3 rows of the parent grid */
  gap: var(--s-1);
}

.card > img {
  inline-size: 100%;
  block-size: 100%;
  object-fit: cover;
}
```

**How it works:** Each card spans 3 rows of the parent grid. Subgrid inherits the parent's row tracks, so all cards' images, titles, and descriptions align across the grid. The tallest title in any column determines the title row height for all cards in that row.

---

## Pattern 2: Data List with Aligned Labels

A definition-list-style layout where labels and values align in a two-column grid.

```html
<dl class="data-grid">
  <div>
    <dt>Release Date</dt>
    <dd>2024-03-15</dd>
  </div>
  <div>
    <dt>Artist</dt>
    <dd>A longer artist name that wraps to multiple lines</dd>
  </div>
  <div>
    <dt>Format</dt>
    <dd>Vinyl LP</dd>
  </div>
</dl>
```

```css
.data-grid {
  display: grid;
  grid-template-columns: max-content 1fr;
  gap: var(--s-1) var(--s1);
}

.data-grid > div {
  display: grid;
  grid-template-columns: subgrid;
  grid-column: span 2;
}

.data-grid dt {
  font-weight: bold;
}
```

**How it works:** The parent grid defines two columns (label + value). Each `<div>` spans both columns and uses subgrid to inherit the column tracks. The `max-content` first column sizes to the widest label across all rows.

---

## Pattern 3: Form Fields with Aligned Labels

Labels and inputs align across rows without fixed widths.

```html
<form class="form-grid">
  <div>
    <label for="name">Name</label>
    <input id="name" type="text">
  </div>
  <div>
    <label for="email">Email address</label>
    <input id="email" type="email">
  </div>
  <div>
    <label for="phone">Phone number</label>
    <input id="phone" type="tel">
  </div>
</form>
```

```css
.form-grid {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: var(--s-1) var(--s1);
  align-items: baseline;
}

.form-grid > div {
  display: grid;
  grid-template-columns: subgrid;
  grid-column: span 2;
}
```

**How it works:** The `auto` first column sizes to the widest label. All labels align to the same column edge. All inputs start at the same position. No fixed widths needed — the layout is intrinsic (ELP_002).

**Fallback for narrow containers:** Wrap the form-grid in a Container (ELC_CONTAINER) and use a container query to switch to single-column layout:

```css
@container (max-inline-size: 25rem) {
  .form-grid {
    grid-template-columns: 1fr;
  }
  .form-grid > div {
    grid-column: span 1;
  }
}
```

---

## Pattern 4: Table-Like Layout Without `<table>`

When data is relational but not tabular (no column headers, no row operations), subgrid provides alignment without table semantics.

```html
<div class="pseudo-table">
  <div class="row">
    <span>Track 1</span>
    <span>3:42</span>
    <span>feat. Artist Name</span>
  </div>
  <div class="row">
    <span>Track 2 (Extended)</span>
    <span>5:18</span>
    <span>feat. Another Artist</span>
  </div>
</div>
```

```css
.pseudo-table {
  display: grid;
  grid-template-columns: 1fr max-content max-content;
  gap: var(--s-2) var(--s1);
}

.pseudo-table > .row {
  display: grid;
  grid-template-columns: subgrid;
  grid-column: span 3;
}
```

**When to use `<table>` instead:** If the data has column headers, supports sorting, or represents a true data relationship, use a `<table>` with proper `<thead>`/`<tbody>` semantics. Subgrid is for *presentational alignment*, not *data relationships*.

---

## Pattern 5: Nested Grid with Shared Tracks

A page layout where the content area and sidebar share a grid track system.

```html
<div class="page-grid">
  <nav class="sidebar">
    <ul class="stack">
      <li><a href="#">Link 1</a></li>
      <li><a href="#">Link 2</a></li>
    </ul>
  </nav>
  <main class="content">
    <div class="grid" style="--min: 15rem">
      <!-- Grid items inherit parent column tracks -->
    </div>
  </main>
</div>
```

```css
.page-grid {
  display: grid;
  grid-template-columns: 15rem 1fr;
  gap: var(--s1);
}

.content {
  display: grid;
  grid-template-columns: subgrid;
}
```

**Note:** This pattern is more rigid than ELC_SIDEBAR because it uses explicit column tracks. Prefer Sidebar for most two-element layouts. Use this pattern only when nested content must align to the parent's column boundaries.

---

## Anti-Patterns

| Bad | Why | Fix |
|-----|-----|-----|
| Subgrid for simple equal columns | Unnecessary complexity | Use base ELC_GRID |
| Subgrid without `span` on children | Children won't participate in subgrid | Always set `grid-row: span N` or `grid-column: span N` |
| Subgrid for responsive stacking | Subgrid doesn't provide intrinsic stacking | Use ELC_SWITCHER or ELC_SIDEBAR |
| Deep subgrid nesting (3+ levels) | Difficult to reason about, fragile | Limit to 2 levels |
