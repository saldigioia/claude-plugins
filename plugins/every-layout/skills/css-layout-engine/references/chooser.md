# Every Layout Primitive Chooser

A decision guide for selecting the appropriate layout primitive.

---

## Decision Tree

### Question 1: What type of spacing do you need?

**Vertical spacing between siblings?**
- Use **Stack** (ELC_STACK)
- The owl selector (`* + *`) ensures consistent spacing

**Horizontal spacing with wrapping?**
- Use **Cluster** (ELC_CLUSTER)
- Items wrap naturally and maintain gaps

**Both directions (grid of items)?**
- Use **Grid** (ELC_GRID)
- Auto-responsive columns without media queries

---

### Question 2: How many elements are involved?

**Two elements (one fixed, one flexible)?**
- Use **Sidebar** (ELC_SIDEBAR)
- One element has intrinsic width, other fills space
- Wraps to stacked when content area too narrow

**Two+ equal elements that should switch?**
- Use **Switcher** (ELC_SWITCHER)
- Equal width columns above threshold
- Stacked layout below threshold

**Many items for horizontal browsing?**
- Use **Reel** (ELC_REEL)
- Horizontal scroll without breaking page layout

---

### Question 3: What kind of centering?

**Horizontal centering with max-width?**
- Use **Center** (ELC_CENTER)
- Constrains measure for readability
- Includes gutters for edge padding

**Vertical centering on a page/section?**
- Use **Cover** (ELC_COVER)
- Centers principal element vertically
- Optional header/footer push to edges

**Overlay centering (modal, tooltip)?**
- Use **Imposter** (ELC_IMPOSTER)
- Centers absolutely positioned element
- Can break out of container or be contained

---

### Question 4: What about containment?

**Need padded, bordered region?**
- Use **Box** (ELC_BOX)
- Consistent padding and border
- Color inversion support

**Need specific aspect ratio?**
- Use **Frame** (ELC_FRAME)
- Maintains ratio regardless of content
- Crops media with object-fit

**Need container query context?**
- Use **Container** (ELC_CONTAINER)
- Only when intrinsic layout insufficient
- Prefer intrinsic first (ELP_014)

---

### Question 5: Inline elements?

**Icons with text?**
- Use **Icon** (ELC_ICON)
- Scales with text size
- Aligns with baseline

---

## Quick Reference Table

| Problem | Primitive | ID |
|---------|-----------|-----|
| Vertical spacing | Stack | ELC_STACK |
| Padded container | Box | ELC_BOX |
| Horizontal centering | Center | ELC_CENTER |
| Inline items with wrap | Cluster | ELC_CLUSTER |
| Fixed + flexible layout | Sidebar | ELC_SIDEBAR |
| Equal columns that switch | Switcher | ELC_SWITCHER |
| Vertical centering | Cover | ELC_COVER |
| Auto-responsive grid | Grid | ELC_GRID |
| Aspect ratio container | Frame | ELC_FRAME |
| Horizontal scroll | Reel | ELC_REEL |
| Overlay centering | Imposter | ELC_IMPOSTER |
| Inline icons | Icon | ELC_ICON |
| Container queries | Container | ELC_CONTAINER |

---

## Anti-Patterns to Avoid

| Bad Practice | Why It's Wrong | Better Solution |
|--------------|----------------|-----------------|
| Fixed pixel widths | Breaks responsiveness (ELP_002) | Use intrinsic sizing |
| Media queries for layout | Couples to viewport (ELP_009) | Use Switcher/Sidebar |
| Arbitrary spacing values | Inconsistent rhythm (ELP_005) | Use modular scale |
| Physical properties | Breaks RTL (ELP_004) | Use logical properties |
| Manual breakpoints | Fragile, arbitrary | Algorithmic layouts |

---

## Composition Patterns

Primitives compose naturally. Common combinations:

### Stack + Center
```html
<div class="center">
  <div class="stack">
    <!-- Centered, spaced content -->
  </div>
</div>
```

### Sidebar + Stack
```html
<div class="with-sidebar">
  <nav class="stack"><!-- Nav items --></nav>
  <main class="stack"><!-- Main content --></main>
</div>
```

### Grid + Box
```html
<div class="grid">
  <div class="box">Card 1</div>
  <div class="box">Card 2</div>
  <div class="box">Card 3</div>
</div>
```

### Cover + Center
```html
<div class="cover">
  <header>...</header>
  <div class="center principal">
    <h1>Centered Title</h1>
  </div>
  <footer>...</footer>
</div>
```

---

## Editorial & Composite Recipes

When your layout need goes beyond a single primitive, these recipes combine multiple primitives into production-ready patterns.

### Question 6: What kind of page are you building?

**Long-form article with breakout images?**
- Use the **Article Grid** recipe → `cookbook-recipes.md` (Article Grid section)
- Named grid lines: content / breakout / full-bleed zones
- Composes: Stack, Frame, Box, Center

**Article with margin notes or annotations?**
- Use the **Sidenotes** recipe → `cookbook-recipes.md` (Sidenotes section)
- Tufte-style margin notes on wide viewports, inline on narrow
- Composes: Stack, Grid (documented media query exception)

**Data table that must work on mobile?**
- Use the **Responsive Table** recipe → `cookbook-recipes.md` (Responsive Table section)
- Horizontal scroll wrapper preserving semantic `<table>` HTML
- Composes: Reel (pattern), Stack, optional scroll snap (ELP_031)

**Layout that adapts based on what content is present?**
- Use the **Content-Aware :has()** recipe → `cookbook-recipes.md` (Content-Aware section)
- Cards switch from vertical to horizontal when they contain an image
- Composes: Stack, Sidebar (pattern), Frame, Grid

**Classic header / sidebar / footer page?**
- Use the **Holy Grail** recipe → `cookbook-recipes.md` (Holy Grail section)
- Composes: Stack, Sidebar, Cover

**Responsive card grid?**
- Use the **Card Grid** recipe → `cookbook-recipes.md` (Card Grid section)
- Composes: Grid, Box, Stack

---

## Anti-Patterns to Avoid (Extended)

| Bad Practice | Why It's Wrong | Better Solution |
|--------------|----------------|-----------------|
| Fixed pixel widths | Breaks responsiveness (ELP_002) | Use intrinsic sizing |
| Media queries for layout | Couples to viewport (ELP_009) | Use Switcher/Sidebar |
| Arbitrary spacing values | Inconsistent rhythm (ELP_005) | Use modular scale |
| Physical properties | Breaks RTL (ELP_004) | Use logical properties |
| Manual breakpoints | Fragile, arbitrary | Algorithmic layouts |
| Scroll jacking | Breaks browser delegation (ELP_010) | Native scroll + optional snap |
| Icon-only buttons | Missing accessible name (ELP_015) | Visible text + `aria-hidden` icon |
| Zoom prevention | WCAG 1.4.4 failure | Intrinsic sizing + `rem` units |
| Animations without motion gate | WCAG 2.3.3 failure (ELP_028) | `prefers-reduced-motion` reset |

See `cookbook-antipatterns.md` for detailed guides on each.

---

## When NOT to Use a Primitive

- **Don't use Grid** for two-element fixed/flexible layouts (use Sidebar)
- **Don't use Sidebar** for equal-width elements (use Switcher)
- **Don't use Container** when intrinsic layout works (ELP_014)
- **Don't use Stack** for horizontal layouts (use Cluster)
- **Don't use Center** when text-align: center is sufficient
