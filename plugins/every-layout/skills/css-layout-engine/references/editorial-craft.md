# Editorial Craft Patterns

How to create visually dramatic, magazine-quality layouts using only existing primitives and the modular scale. No new CSS, no JavaScript, no media queries — just composition, scale contrast, and typographic tension.

---

## The Three Levers of Drama

Every Layout's primitives are structurally neutral. Drama comes from *how* you use them:

1. **Scale contrast** — Using extreme scale steps together (--s-2 beside --s5)
2. **Measure tension** — Breaking the default measure for specific editorial moments
3. **Primitive stacking** — Layering primitives in unexpected but valid compositions

None of these require new CSS. They're all configuration — adjusting custom properties on existing primitives.

---

## Pattern 1: The Oversized Headline

A headline that dominates the viewport, creating immediate visual impact within the Cover primitive.

```html
<div class="cover" style="--min-height: 80vh; --padding: var(--s3)">
  <header>
    <nav class="cluster"><!-- nav links --></nav>
  </header>
  <div class="principal center" style="--measure: 20ch">
    <h1 class="headline-oversized">The Weight of the Archive</h1>
  </div>
  <footer>
    <p class="text-muted">Published March 2026</p>
  </footer>
</div>
```

```css
.headline-oversized {
  font-size: clamp(var(--s3), 8vw + 1rem, var(--s5));
  line-height: 0.95;
  text-wrap: balance;
  letter-spacing: -0.02em;
}
```

**What makes it work:**
- Cover (ELC_COVER) vertically centers the headline
- `--measure: 20ch` on Center creates a narrow text column — fewer words per line = more visual weight per word
- `clamp()` (ELP_025) scales the headline fluidly without media queries
- Tight `line-height: 0.95` removes excess space between lines at large sizes
- Negative letter-spacing tightens display text — standard typographic practice above 24px

**Scale contrast:** The headline uses `--s5` (7.594rem) while the nav and date use `--s-1` (0.667rem). That's a 11:1 ratio — the eye goes to the headline first, always.

---

## Pattern 2: The Full-Bleed Image Break

An image that breaks out of the Center measure to span the full viewport width, creating a visual "breath" in the reading flow.

```html
<article class="center stack">
  <p>Body text constrained to measure...</p>

  <!-- Full-bleed break -->
  <figure class="full-bleed">
    <div class="frame" style="--ratio: 21/9">
      <img src="landscape.jpg" alt="..." loading="lazy">
    </div>
    <figcaption class="center">
      <p>Caption returns to the measure.</p>
    </figcaption>
  </figure>

  <p>Body text continues at measure...</p>
</article>
```

```css
.full-bleed {
  inline-size: 100vw;
  margin-inline-start: calc(50% - 50vw);
}

.full-bleed > .frame {
  max-block-size: 70vh;
}
```

**What makes it work:**
- The `100vw` width + negative margin trick breaks out of Center's `max-inline-size` without disrupting the Stack rhythm
- Frame (ELC_FRAME) at 21:9 creates a cinematic aspect ratio
- `max-block-size: 70vh` prevents the image from dominating too much vertically
- The `<figcaption>` uses its own Center to return text to the measure
- The Stack's vertical rhythm continues unbroken — the bleed is horizontal only

**When to use:** Feature photography, data visualizations, maps — any content that benefits from edge-to-edge presentation within an otherwise measured article.

---

## Pattern 3: The Pull Quote

A typographically prominent quotation that interrupts the reading flow with visual weight.

```html
<article class="center stack">
  <p>Body text...</p>

  <blockquote class="pull-quote">
    <p>Design is not how it looks. Design is how it works.</p>
  </blockquote>

  <p>Body text continues...</p>
</article>
```

```css
.pull-quote {
  margin-block: var(--s3);
  padding-inline-start: var(--s1);
  border-inline-start: 3px solid var(--br-color-accent);
}

.pull-quote > p {
  font-family: var(--font-display);
  font-size: var(--s2);
  line-height: 1.2;
  text-wrap: balance;
  max-inline-size: 30ch;
  font-style: italic;
}
```

**What makes it work:**
- Larger `margin-block` (--s3) separates the quote from body text, giving it visual breathing room
- The display font at `--s2` (2.25rem) creates scale contrast against `--s0` body text
- `max-inline-size: 30ch` — narrower than the article measure — creates asymmetry within the centered column
- The accent border adds color without ornament
- `text-wrap: balance` (ELP_030) prevents awkward short last lines

---

## Pattern 4: The Sidenote

Marginal notes alongside the main text, using Sidebar to place them.

```html
<div class="with-sidebar" style="--side-width: 12rem; --content-min: 65%">
  <aside class="stack sidenotes">
    <p class="sidenote" id="sn-1">
      <sup>1</sup> Sidenote text appears here, alongside the paragraph that references it.
    </p>
  </aside>
  <article class="center stack">
    <p>Main body text with a reference.<sup><a href="#sn-1">1</a></sup></p>
    <p>More body text...</p>
  </article>
</div>
```

```css
.sidenotes {
  --space: var(--s1);
}

.sidenote {
  font-size: var(--s-1);
  color: var(--gl-color-muted);
  line-height: 1.4;
}
```

**What makes it work:**
- Sidebar (ELC_SIDEBAR) handles the two-column layout with automatic stacking on narrow viewports
- The `--content-min: 65%` ensures body text gets priority space
- Sidenote text at `--s-1` (smaller than body) creates a clear hierarchy
- On narrow screens, sidenotes stack below the article — graceful degradation, no media query

---

## Pattern 5: The Data Showcase

A numbers-forward section that gives statistics visual prominence.

```html
<section class="center">
  <div class="switcher" style="--threshold: 25rem; --space: var(--s2)">
    <div class="stack stat" style="--space: var(--s-2)">
      <span class="stat-value">1,247</span>
      <span class="stat-label">Archival works</span>
    </div>
    <div class="stack stat" style="--space: var(--s-2)">
      <span class="stat-value">89</span>
      <span class="stat-label">Contributing artists</span>
    </div>
    <div class="stack stat" style="--space: var(--s-2)">
      <span class="stat-value">2018</span>
      <span class="stat-label">Earliest record</span>
    </div>
  </div>
</section>
```

```css
.stat-value {
  font-family: var(--font-display);
  font-size: var(--s4);
  line-height: 1;
  font-variant-numeric: tabular-nums;
  letter-spacing: -0.03em;
}

.stat-label {
  font-size: var(--s-1);
  color: var(--gl-color-muted);
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
```

**What makes it work:**
- Switcher (ELC_SWITCHER) places stats side-by-side when wide, stacks when narrow
- `--s4` (5.063rem) stat values create immediate visual impact
- `tabular-nums` ensures numbers align vertically in the stacked layout
- Small caps + wide letter-spacing on labels creates a visual tier below the numbers
- The inner Stack at `--s-2` keeps value and label tightly coupled

---

## Pattern 6: The Typographic Section Break

A visual divider using only typography, replacing decorative `<hr>` elements.

```html
<article class="center stack">
  <p>End of section one...</p>

  <p class="section-break" aria-hidden="true">* * *</p>

  <p>Beginning of section two...</p>
</article>
```

```css
.section-break {
  text-align: center;
  margin-block: var(--s3);
  font-size: var(--s1);
  color: var(--gl-color-muted);
  letter-spacing: 0.5em;
}
```

**Alternatives:**
- `---` for a more horizontal feel
- A single `*` for minimal separation
- An em dash `—` for literary contexts
- `aria-hidden="true"` prevents screen readers from announcing decorative content

---

## Pattern 7: The Card with Typographic Hierarchy

A card that uses scale and weight — not decoration — to create visual interest.

```html
<div class="grid" style="--min: 18rem">
  <article class="box stack" style="--padding: var(--s2); --space: var(--s-1)">
    <time class="card-date">2024-03-15</time>
    <h3 class="card-title">The Title Creates the Tension</h3>
    <p class="card-excerpt">A brief excerpt that provides enough context to decide whether to read more, without revealing the conclusion.</p>
  </article>
</div>
```

```css
.card-date {
  font-size: var(--s-2);
  font-variant-caps: small-caps;
  letter-spacing: 0.08em;
  color: var(--gl-color-muted);
}

.card-title {
  font-family: var(--font-display);
  font-size: var(--s1);
  line-height: 1.2;
}

.card-excerpt {
  font-size: var(--s-1);
  color: var(--gl-color-muted);
  max-inline-size: 45ch;
}
```

**What makes it work:**
- Three distinct typographic tiers: date (tiny, muted, small-caps) → title (display, bold) → excerpt (small, muted)
- Box padding at `--s2` (generous) creates premium spacing
- Stack spacing at `--s-1` (tight) keeps card contents cohesive
- No borders, no shadows, no background changes — hierarchy comes entirely from type

---

## Composition Rules

### When to Break the Measure

The default `--measure: 65ch` is for body text. These elements may override it:

| Element | Measure | Reason |
|---------|---------|--------|
| Headlines | `20-30ch` | Fewer words = more weight per word |
| Pull quotes | `30-40ch` | Distinct from body, but still readable |
| Captions | `50-60ch` | Slightly narrower than body for visual tier |
| Data tables | `100%` (no measure constraint) | Tables need horizontal space |
| Full-bleed images | `100vw` | Edge-to-edge for visual impact |

### Scale Contrast Targets

| Contrast | Ratio | Use |
|----------|-------|-----|
| Subtle | 1.5x (one step) | Body text → caption |
| Clear | 2.25x (two steps) | Body → subheading |
| Dramatic | 5x+ (three+ steps) | Body → display headline |
| Extreme | 10x+ (four+ steps) | Metadata → hero headline |

### Whitespace as Punctuation

Large `margin-block` values create visual pauses, similar to paragraph breaks in writing:

| Spacing | Effect |
|---------|--------|
| `--s0` | Continuation — elements belong together |
| `--s1` | Paragraph-level — natural reading break |
| `--s2` | Section-level — topic change |
| `--s3` | Chapter-level — major division |
| `--s4`+ | Page-level — used sparingly, for maximum impact |

---

## Anti-Patterns

| Bad | Why | Fix |
|-----|-----|-----|
| Every heading the same size | No hierarchy, no drama | Use 2-3 distinct scale steps |
| Decorative borders on every element | Visual noise, no meaning | Reserve borders for semantic grouping |
| Drop shadows on everything | Elevation overuse flattens hierarchy | Reserve shadows for interactive/elevated elements |
| All text at the same measure | Monotonous reading rhythm | Vary measure for different content types |
| Colored backgrounds on every section | Zebra-stripe fatigue | Use whitespace for separation; reserve color for emphasis |
| Centered everything | Removes the natural left-aligned anchor | Center headlines and CTAs; left-align body text |
