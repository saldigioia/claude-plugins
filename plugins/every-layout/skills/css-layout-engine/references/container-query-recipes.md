# Container Query Recipes

When and how to use ELC_CONTAINER for component-level responsive design. Container queries respond to the component's own size, not the viewport — the natural evolution of "no media queries for layout" (ELP_009).

---

## When to Use Container Queries

```
Is the layout change based on the viewport?
├─ No → Don't use a media query OR a container query
└─ Yes → Can an intrinsic primitive handle it?
    ├─ Yes → Use Switcher / Sidebar / Grid (preferred)
    └─ No → Is the change based on the component's container?
        ├─ Yes → Use Container Query (ELC_CONTAINER)
        └─ No → Media query is acceptable (document why)
```

**The hierarchy:** Intrinsic primitives > container queries > media queries.

Container queries are the right choice when:
1. A component appears in **different-sized slots** on the same page
2. The component's internal layout should change based on **its own available space**, not the viewport
3. Intrinsic primitives (Switcher, Sidebar) don't provide enough control over the internal rearrangement

---

## Setting Up a Container

```css
/* ELC_CONTAINER — creates a containment context */
.container {
  container-type: inline-size;
  container-name: var(--container-name, layout);
}
```

**Key constraints (ELP_019, ELP_020):**
- Always use `inline-size` containment, not `size` (block-size containment causes layout loops)
- Name containers when nesting them to avoid ambiguous query resolution
- Container elements cannot have intrinsic inline-size — they take the width of their parent

---

## Recipe 1: Card That Rearranges by Slot Size

A card component that shows image-left/text-right in wide slots and image-top/text-bottom in narrow slots.

```html
<div class="container" style="--container-name: card-slot">
  <article class="adaptive-card">
    <img src="photo.jpg" alt="...">
    <div class="card-body stack">
      <h3>Title</h3>
      <p>Description</p>
    </div>
  </article>
</div>
```

```css
.container {
  container-type: inline-size;
  container-name: card-slot;
}

/* Default: vertical (narrow) */
.adaptive-card {
  display: grid;
  gap: var(--s1);
}

.adaptive-card > img {
  inline-size: 100%;
  aspect-ratio: 16 / 9;
  object-fit: cover;
}

/* Wide slot: horizontal */
@container card-slot (min-inline-size: 30rem) {
  .adaptive-card {
    grid-template-columns: minmax(0, 1fr) minmax(0, 2fr); /* ELP_033 */
  }

  .adaptive-card > img {
    aspect-ratio: 1;
    block-size: 100%;
  }
}
```

**Why not Sidebar?** Sidebar stacks when the container narrows, which is close. But it doesn't let you change the image's aspect ratio or the grid proportion. Container queries provide finer internal control.

---

## Recipe 2: Navigation That Collapses by Container

A nav that shows horizontal links when its container is wide, and a compact layout when narrow.

```html
<div class="container" style="--container-name: nav-area">
  <nav>
    <ul class="nav-links">
      <li><a href="/">Home</a></li>
      <li><a href="/archive">Archive</a></li>
      <li><a href="/about">About</a></li>
      <li><a href="/contact">Contact</a></li>
    </ul>
  </nav>
</div>
```

```css
.container { container-type: inline-size; container-name: nav-area; }

/* Default: vertical stack */
.nav-links {
  display: flex;
  flex-direction: column;
  gap: var(--s-1);
  list-style: none;
  padding: 0;
}

/* Wide container: horizontal cluster */
@container nav-area (min-inline-size: 35rem) {
  .nav-links {
    flex-direction: row;
    flex-wrap: wrap;
    gap: var(--s1);
  }
}
```

**Why not Cluster?** Cluster always wraps horizontally. If the nav must *start* vertical and *become* horizontal based on its container (not the viewport), a container query is the right tool.

---

## Recipe 3: Data Display Density by Container

A stats panel that shows compact numbers when squeezed into a sidebar, and expanded cards when given full width.

```html
<div class="container" style="--container-name: stats-area">
  <div class="stats">
    <div class="stat">
      <span class="stat-value">1,247</span>
      <span class="stat-label">Total Works</span>
    </div>
    <div class="stat">
      <span class="stat-value">89</span>
      <span class="stat-label">Artists</span>
    </div>
    <div class="stat">
      <span class="stat-value">2018</span>
      <span class="stat-label">Earliest</span>
    </div>
  </div>
</div>
```

```css
.container { container-type: inline-size; container-name: stats-area; }

/* Narrow: compact inline */
.stats {
  display: flex;
  flex-wrap: wrap;
  gap: var(--s-1);
}

.stat {
  display: flex;
  gap: var(--s-2);
  align-items: baseline;
}

.stat-value { font-weight: bold; }
.stat-label { font-size: var(--s-1); color: var(--color-muted); }

/* Wide: expanded cards */
@container stats-area (min-inline-size: 30rem) {
  .stats {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(8rem, 1fr));
    gap: var(--s1);
  }

  .stat {
    flex-direction: column;
    text-align: center;
    padding: var(--s1);
    border: 1px solid;
  }

  .stat-value { font-size: var(--s2); }
}
```

---

## Naming Conventions

Name containers to avoid ambiguity when nesting:

```css
/* Good — named, clear scope */
.sidebar-container { container-name: sidebar; container-type: inline-size; }
.card-container { container-name: card-slot; container-type: inline-size; }

/* Bad — unnamed, queries resolve to nearest ancestor */
.container { container-type: inline-size; }
```

Use `@container <name>` in queries, not bare `@container`, to target the intended container explicitly.

---

## Anti-Patterns

| Bad | Why | Fix |
|-----|-----|-----|
| Container query for viewport-based changes | Same as a media query with extra steps | Use media query (if justified) or intrinsic primitive |
| `container-type: size` | Block-size containment causes layout loops | Use `inline-size` (ELP_020) |
| Unnamed containers with nesting | Ambiguous query resolution | Name every container |
| Container query replacing Switcher | Switcher is simpler for equal-column stacking | Use Switcher when threshold-based stacking suffices |
| Deep nesting (3+ container contexts) | Hard to debug, performance implications | Flatten to 2 levels max |

---

## Container-Relative Units (cqi)

Inside an ELC_CONTAINER context, `cqi` (1% of the container's inline size) is
to the container what `vi`/`vw` is to the viewport — and it composes with the
same rules:

- **Fluid type scoped to a component** — the ELP_025 clamp pattern with `cqi`
  in the preferred term, and per ELP_026 always mixed with a `rem` term so
  browser zoom still scales the text:

```css
.card h3 {
  font-size: clamp(var(--step-0, 1rem), 0.75rem + 2cqi, var(--step-2, 1.5rem));
}
```

- **Container-fluid spacing** — acceptable only for *bespoke* gaps inside a
  registered escape context; modular-scale tokens (ELP_005) remain the rule
  for system spacing. Prefer `gap: var(--s1)` over `gap: 2cqi`.
- `cqi`/`cqb` are the logical forms — use them, not `cqw`/`cqh`, for the same
  reason ELP_004 mandates logical properties.

### Performance note — nested containers

Every `container-type: inline-size` creates layout containment: the browser
sizes the container without consulting its contents, then lays out contents
in a second pass. Nesting containers multiplies those passes along the
ancestor chain of every resize. Guidance:

1. Declare containment at **component boundaries** (card, panel), never on
   deep wrappers "just in case" (ELP_020's inline-size default keeps the
   block axis cheap — `container-type: size` is almost never justified).
2. If a layout can be expressed intrinsically (Switcher/Sidebar/Grid math),
   prefer it over a container query entirely — ELP_014's ordering
   (intrinsic → container query → media query) is also the performance
   ordering.
3. Two levels of nested named containers is the practical ceiling; past
   that, restructure.
