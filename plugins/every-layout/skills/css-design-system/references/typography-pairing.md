# Typography Pairing

Font pairing principles and canonical combinations mapped to design postures. Typography is the single largest lever for visual identity within the Every Layout constraint system — the right pairing transforms austere structure into intentional craft.

---

## Pairing Principles

### 1. Contrast, Not Conflict

A good pairing has clear *role contrast* (one leads, one supports) without *aesthetic conflict* (they share underlying proportions or era). Pair a high-x-height sans with a high-x-height serif — they'll feel related despite structural difference.

### 2. Two Families Maximum

Body + display is sufficient. A third family (mono) is acceptable only for code or data. Four families is always wrong — it signals indecision, not range.

### 3. Weight Carries Hierarchy

Don't pair two families at the same weight. The display face should be heavier (700+) or dramatically lighter (300) than the body face (400). Weight contrast creates hierarchy without needing size contrast alone.

### 4. Fallback Stacks Are Design Decisions

A fallback stack isn't an afterthought — it's the font your users see during load and what they see if the web font fails. Choose fallbacks that preserve the pairing's character.

### 5. Performance Gate (ELP_032)

Every web font must use `font-display: optional`. This prevents layout shift from font swap. If the font doesn't load in time, the fallback renders permanently for that page view. This means fallback stacks must be *good enough* to stand alone.

---

## The 10 Canonical Pairings

Each pairing is mapped to a design posture (from `density-patterns.md` and the integration plan's style collapse).

### 1. Source Serif 4 + Source Sans 3

**Posture:** `editorial-restraint`
**Character:** Scholarly, precise, controlled warmth. Adobe's Source superfamily shares metrics across serif/sans, guaranteeing vertical rhythm alignment.

```css
:root {
  --font-display: "Source Serif 4", "Iowan Old Style", Palatino, Georgia, serif;
  --font-body: "Source Sans 3", "Helvetica Neue", Helvetica, Arial, sans-serif;
  --font-mono: "Source Code Pro", ui-monospace, "Cascadia Code", monospace;
}
```

**Use when:** Archives, research sites, documentation, academic publishing.
**Why it works:** Same designer (Paul Hunt), matched x-heights, optical sizing on both. The serif carries authority in headlines; the sans recedes in body text.

---

### 2. Fraunces + Inter

**Posture:** `warm-utility`
**Character:** Playful headlines grounded by a neutral body. Fraunces is a "wonky" old-style serif with optical size variation — its display cuts are dramatic, its text cuts are readable.

```css
:root {
  --font-display: "Fraunces", "Iowan Old Style", Palatino, Georgia, serif;
  --font-body: "Inter", "Helvetica Neue", Helvetica, Arial, sans-serif;
}
```

**Use when:** Creative portfolios, editorial blogs, product marketing with personality.
**Why it works:** Fraunces at large sizes is distinctive and warm. Inter at body size is invisible — it lets the display face carry the identity without competing.

---

### 3. JetBrains Mono + IBM Plex Sans

**Posture:** `research-dense`
**Character:** Technical, data-forward, engineering credibility. Monospace headlines signal "we build things."

```css
:root {
  --font-display: "JetBrains Mono", ui-monospace, "Cascadia Code", monospace;
  --font-body: "IBM Plex Sans", "Helvetica Neue", Helvetica, Arial, sans-serif;
  --font-mono: "JetBrains Mono", ui-monospace, "Cascadia Code", monospace;
}
```

**Use when:** Developer tools, API documentation, technical dashboards, data-dense interfaces.
**Why it works:** Monospace headlines create a distinctive visual signature without decorative fonts. IBM Plex is neutral but has enough character to avoid blandness.

---

### 4. Playfair Display + Lora

**Posture:** `editorial-restraint` (luxury variant)
**Character:** High-contrast display serif over a softer text serif. Old-world editorial presence.

```css
:root {
  --font-display: "Playfair Display", Didot, "Bodoni MT", Georgia, serif;
  --font-body: "Lora", "Palatino Linotype", Palatino, Georgia, serif;
}
```

**Use when:** Magazine layouts, long-form journalism, luxury brand editorials, literary publishing.
**Why it works:** Both are serifs, but Playfair's high stroke contrast reads as display while Lora's moderate contrast reads as text. Serif-on-serif pairings work when the contrast axis shifts from structure to weight.

---

### 5. Space Grotesk + Space Mono

**Posture:** `structured-grid`
**Character:** Geometric, systematic, grid-native. The shared "Space" superfamily ensures metric harmony.

```css
:root {
  --font-display: "Space Grotesk", "Helvetica Neue", Helvetica, Arial, sans-serif;
  --font-body: "Space Grotesk", "Helvetica Neue", Helvetica, Arial, sans-serif;
  --font-mono: "Space Mono", ui-monospace, "Cascadia Code", monospace;
}
```

**Use when:** Data dashboards, design system documentation, systematic interfaces, developer portfolios.
**Why it works:** Single-family with mono variant. The geometric forms reinforce grid alignment. Mono appears in data cells and code blocks, sans everywhere else.

---

### 6. Crimson Pro + Manrope

**Posture:** `editorial-restraint`
**Character:** Refined serif headlines with a humanist sans body. Crimson Pro's Renaissance proportions create gravitas; Manrope's rounded terminals add approachability.

```css
:root {
  --font-display: "Crimson Pro", "Iowan Old Style", Palatino, Georgia, serif;
  --font-body: "Manrope", "Helvetica Neue", Helvetica, Arial, sans-serif;
}
```

**Use when:** Cultural institutions, art archives, museum collections, book review sites.
**Why it works:** Crimson Pro is narrower than most serifs — it packs more characters per line, raising information density without reducing font size. Manrope's generous spacing balances the density.

---

### 7. DM Sans + DM Serif Display

**Posture:** `quiet-utility`
**Character:** Clean, contemporary, unobtrusive. Google's DM superfamily shares metrics for seamless switching between serif headings and sans body.

```css
:root {
  --font-display: "DM Serif Display", Georgia, "Times New Roman", serif;
  --font-body: "DM Sans", "Helvetica Neue", Helvetica, Arial, sans-serif;
}
```

**Use when:** Product landing pages, SaaS marketing, company blogs, minimal portfolios.
**Why it works:** Maximum readability with minimum personality. The serif display adds just enough distinction to headings without asserting a strong visual identity.

---

### 8. Literata + Nunito Sans

**Posture:** `warm-utility`
**Character:** Literata was designed for Google Books — optimized for sustained screen reading. Nunito Sans provides a friendly, rounded complement.

```css
:root {
  --font-display: "Literata", "Iowan Old Style", Palatino, Georgia, serif;
  --font-body: "Nunito Sans", "Helvetica Neue", Helvetica, Arial, sans-serif;
}
```

**Use when:** Reading-heavy applications, digital libraries, e-learning platforms, content-first sites.
**Why it works:** Literata has variable optical sizing — it adjusts stroke contrast automatically from caption to display sizes. This makes it work across the entire fluid type scale without manual intervention.

---

### 9. Instrument Serif + Instrument Sans

**Posture:** `editorial-restraint` (contemporary variant)
**Character:** Crisp, modern editorial. Sharp serifs in display sizes, clean sans for body. Another matched superfamily.

```css
:root {
  --font-display: "Instrument Serif", Georgia, "Times New Roman", serif;
  --font-body: "Instrument Sans", "Helvetica Neue", Helvetica, Arial, sans-serif;
}
```

**Use when:** Design studio sites, editorial platforms, contemporary magazine layouts.
**Why it works:** Both faces are narrow, enabling high character density. The serif's sharp wedge serifs provide instant editorial presence at display sizes.

---

### 10. System Stack Only

**Posture:** Any (performance-first)
**Character:** Native, fast, zero network requests. The system font stack matches each OS's default: San Francisco on macOS/iOS, Segoe UI on Windows, Roboto on Android.

```css
:root {
  --font-display: ui-serif, Georgia, Cambria, "Times New Roman", serif;
  --font-body: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Helvetica, Arial, sans-serif;
  --font-mono: ui-monospace, "Cascadia Code", "Source Code Pro", Menlo, Consolas, monospace;
}
```

**Use when:** Performance is the highest priority, or the site is a tool/utility where brand identity is secondary.
**Why it works:** Zero font loading, zero CLS, zero `font-display` concerns. The fastest possible text rendering. Not every project needs a custom typeface.

---

## Pairing × Posture Quick Reference

| Posture | Recommended Pairing | Character |
|---------|-------------------|-----------|
| `editorial-restraint` | Source Serif 4 + Source Sans 3 | Scholarly, precise |
| `editorial-restraint` (luxury) | Playfair Display + Lora | High-contrast editorial |
| `editorial-restraint` (contemporary) | Instrument Serif + Instrument Sans | Crisp, modern |
| `research-dense` | JetBrains Mono + IBM Plex Sans | Technical, data-forward |
| `quiet-utility` | DM Serif Display + DM Sans | Clean, unobtrusive |
| `warm-utility` | Fraunces + Inter | Playful + grounded |
| `warm-utility` (reading) | Literata + Nunito Sans | Optimized for sustained reading |
| `structured-grid` | Space Grotesk + Space Mono | Geometric, systematic |
| Any (cultural) | Crimson Pro + Manrope | Refined, dense |
| Any (performance-first) | System stack | Native, instant |

---

## Anti-Patterns

| Bad | Why | Fix |
|-----|-----|-----|
| Inter + Roboto | Two neutral sans-serifs with no contrast | Use Inter alone, or pair with a serif |
| Three unrelated families | Visual noise, no hierarchy | Two families max + optional mono |
| Display face at body sizes | Display cuts have exaggerated features that reduce readability at 16px | Use the face's text optical size, or choose a different body face |
| No fallback stack | Flash of unstyled text, layout shift | Always specify 3+ fallbacks with similar metrics |
| `font-display: swap` | Causes layout shift when font loads | Use `font-display: optional` (ELP_032) |
| Decorative/script fonts for body | Illegible at sustained reading length | Reserve decorative faces for display only, 2-3 words max |

---

## Loading Strategy

```css
/* Preload the body font — it's the most critical */
/* In <head>: */
/* <link rel="preload" href="/fonts/body.woff2" as="font" type="font/woff2" crossorigin> */

@font-face {
  font-family: "Body Font";
  src: url("/fonts/body.woff2") format("woff2");
  font-display: optional; /* ELP_032 — no layout shift */
  font-weight: 100 900;   /* Variable font — one file for all weights */
}

@font-face {
  font-family: "Display Font";
  src: url("/fonts/display.woff2") format("woff2");
  font-display: optional;
  font-weight: 100 900;
}
```

Prefer variable fonts (single file, all weights) over multiple static files. One variable font request replaces 4-6 static font requests.
