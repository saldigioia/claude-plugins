# Content Density Patterns

Systematic approach to adjusting layouts for different information density levels using existing modular scale values. No new tokens — only guidance on which `--s*` values to prefer.

---

## Three Density Postures

| Property | Compact | Default | Spacious |
|----------|---------|---------|----------|
| Stack `--space` | `--s-1` (0.667rem) | `--s1` (1.5rem) | `--s2` (2.25rem) |
| Grid `--min` | `10rem` | `15rem` | `20rem` |
| Grid `--space` | `--s-1` | `--s1` | `--s2` |
| Box `--padding` | `--s-1` | `--s1` | `--s2` |
| Center `--measure` | `75ch` | `65ch` | `55ch` |
| Sidebar `--side-width` | `12rem` | `20rem` | `25rem` |
| Body font-size | `--s-1` (0.667rem) | `--s0` (1rem) | `--s0` (1rem) |
| Heading scale start | `--s1` | `--s2` | `--s3` |

---

## Compact — Research & Data Dense

For archival interfaces, data dashboards, dense reference material. Maximizes content per viewport.

```css
:root {
  --density-space: var(--s-1);
  --density-padding: var(--s-1);
  --density-grid-min: 10rem;
  --density-measure: 75ch;
}

.stack { --space: var(--density-space); }
.grid { --min: var(--density-grid-min); --space: var(--density-space); }
.box { --padding: var(--density-padding); }
.center { --measure: var(--density-measure); }
```

**Use when:** Research archives, API documentation, data tables, admin panels, search results.
**Posture:** High information density, minimal whitespace, tight vertical rhythm. The user is scanning, not reading leisurely.

---

## Default — Editorial & General

The baseline. Comfortable reading density for articles, blogs, marketing pages.

```css
:root {
  --density-space: var(--s1);
  --density-padding: var(--s1);
  --density-grid-min: 15rem;
  --density-measure: 65ch;
}
```

**Use when:** Blog posts, landing pages, documentation, most websites.
**Posture:** Balanced. Enough whitespace for readability without wasting screen real estate.

---

## Spacious — Marketing & Editorial Luxury

For brand-forward pages, hero sections, premium editorial. Generous whitespace signals quality.

```css
:root {
  --density-space: var(--s2);
  --density-padding: var(--s2);
  --density-grid-min: 20rem;
  --density-measure: 55ch;
}
```

**Use when:** Landing pages, brand showcases, magazine layouts, luxury product pages.
**Posture:** Low density, high whitespace. Each element breathes. The narrower measure forces shorter lines, slowing reading pace — intentional for brand storytelling.

---

## Mixing Densities on One Page

Different page sections can use different densities. The Cover > Center > Stack spine accommodates this through scoped custom properties:

```html
<div class="cover">
  <!-- Hero: spacious -->
  <header class="center" style="--measure: 55ch">
    <div class="stack" style="--space: var(--s3)">
      <h1>Title</h1>
      <p>Subtitle</p>
    </div>
  </header>

  <!-- Content: default -->
  <main class="center">
    <article class="stack">
      <!-- body content at default density -->
    </article>
  </main>

  <!-- Footer: compact -->
  <footer class="center" style="--measure: 75ch">
    <div class="stack" style="--space: var(--s-1)">
      <!-- dense footer links -->
    </div>
  </footer>
</div>
```

**Principle:** ELP_008 (child-only layout effects). Each section's density is scoped to that section. No global override.

---

## Density and the Modular Scale

All density values come from the existing modular scale (ratio 1.5). Never use arbitrary values for density adjustments.

| Scale step | Value | Density role |
|------------|-------|-------------|
| `--s-2` | 0.444rem | Micro spacing (icon gaps, inline padding) |
| `--s-1` | 0.667rem | Compact density default |
| `--s0` | 1rem | Body text baseline |
| `--s1` | 1.5rem | Default density default |
| `--s2` | 2.25rem | Spacious density default |
| `--s3` | 3.375rem | Section separators, hero spacing |
| `--s4` | 5.063rem | Page-level divisions |
| `--s5` | 7.594rem | Maximum whitespace (rare) |

Moving one scale step up or down changes density by the ratio (1.5x). Two steps = 2.25x. This is why the three postures use adjacent scale steps.

---

## Density in the Brief

When using the `design-brief` skill (v4.1+), the `density` field in `brief.json` maps directly to these postures:

| brief.json `density` | Posture | Stack `--space` | Grid `--min` |
|-----------------------|---------|-----------------|-------------|
| `"compact"` | Compact | `--s-1` | `10rem` |
| `"default"` | Default | `--s1` | `15rem` |
| `"spacious"` | Spacious | `--s2` | `20rem` |
