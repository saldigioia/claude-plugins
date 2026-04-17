# CSS-Only Visual Texture

Techniques for adding visual richness without JavaScript, layout disruption, or motion safety violations. Every technique here is paint-only — it affects appearance, not flow. All work within the token architecture and modular scale.

---

## Principles

1. **Paint-only.** Every technique uses properties that trigger paint (or composite) but never layout. No `width`, `height`, `margin`, or `padding` manipulation.
2. **Token-sourced.** Colors come from the three-tier token architecture (`--gl-*`, `--br-*`, component). Shadows use modular scale values. No magic numbers.
3. **Motion-safe.** Static textures by default. Any transition is gated by `prefers-reduced-motion: no-preference` and uses only allowed properties (see `motion-allowlist.md`).
4. **Progressive enhancement.** Every technique has a usable fallback. If `backdrop-filter` isn't supported, the element is still readable.

---

## 1. Layered Shadows for Depth

Stacked `box-shadow` creates realistic elevation without images. Each layer is softer and more spread than the last, mimicking light diffusion.

### Surface Elevation Scale

```css
:root {
  --shadow-color: 0deg 0% 0%;

  --elevation-1: 0 1px 2px hsl(var(--shadow-color) / 0.04),
                 0 1px 3px hsl(var(--shadow-color) / 0.06);

  --elevation-2: 0 1px 2px hsl(var(--shadow-color) / 0.03),
                 0 3px 6px hsl(var(--shadow-color) / 0.05),
                 0 6px 12px hsl(var(--shadow-color) / 0.04);

  --elevation-3: 0 2px 4px hsl(var(--shadow-color) / 0.02),
                 0 6px 12px hsl(var(--shadow-color) / 0.04),
                 0 12px 24px hsl(var(--shadow-color) / 0.05),
                 0 24px 48px hsl(var(--shadow-color) / 0.03);
}
```

**Usage:**
```css
.box { box-shadow: var(--elevation-1); }
.box[data-elevated] { box-shadow: var(--elevation-2); }
```

**Why layered:** A single `box-shadow` looks flat. Multiple layers with decreasing opacity simulate real light scatter. The performance cost is negligible — `box-shadow` is paint-only.

### Dark Mode Adjustment

In dark mode, shadows are invisible against dark backgrounds. Use lighter, tinted shadows or border-based elevation:

```css
@media (prefers-color-scheme: dark) {
  :root {
    --shadow-color: 0deg 0% 100%;
    --elevation-1: 0 1px 3px hsl(var(--shadow-color) / 0.06),
                   0 0 0 1px hsl(var(--shadow-color) / 0.04);
  }
}
```

---

## 2. Gradient Backgrounds

Subtle gradients add depth to surfaces without images or JavaScript.

### Warm Paper

```css
.surface-warm {
  background: linear-gradient(
    180deg,
    hsl(40deg 30% 97%) 0%,
    hsl(40deg 20% 95%) 100%
  );
}
```

### Cool Steel

```css
.surface-cool {
  background: linear-gradient(
    135deg,
    hsl(220deg 15% 96%) 0%,
    hsl(220deg 10% 93%) 100%
  );
}
```

### Accent Glow (hero sections)

```css
.surface-glow {
  background:
    radial-gradient(
      ellipse at 20% 0%,
      hsl(var(--br-accent-hsl) / 0.08) 0%,
      transparent 60%
    ),
    var(--gl-color-bg);
}
```

**Rule:** Gradients must use colors from the token architecture. Never hardcode hex values in gradients. The `hsl()` function with token-sourced hue/saturation enables consistent tinting.

---

## 3. Geometric Patterns (CSS-only)

Repeating patterns using `conic-gradient` and `repeating-linear-gradient` — no SVG, no images, no JS.

### Subtle Dot Grid

```css
.pattern-dots {
  background-image: radial-gradient(
    circle at center,
    hsl(var(--shadow-color) / 0.08) 1px,
    transparent 1px
  );
  background-size: var(--s1) var(--s1);
}
```

### Diagonal Lines

```css
.pattern-lines {
  background-image: repeating-linear-gradient(
    -45deg,
    transparent,
    transparent 4px,
    hsl(var(--shadow-color) / 0.03) 4px,
    hsl(var(--shadow-color) / 0.03) 5px
  );
}
```

### Graph Paper

```css
.pattern-grid {
  background-image:
    linear-gradient(hsl(var(--shadow-color) / 0.05) 1px, transparent 1px),
    linear-gradient(90deg, hsl(var(--shadow-color) / 0.05) 1px, transparent 1px);
  background-size: var(--s2) var(--s2);
}
```

**Performance:** CSS gradients are rendered by the GPU. Even complex repeating patterns have negligible performance cost. They are resolution-independent — no blur on retina displays.

---

## 4. Text Treatments

Typographic texture without decorative fonts or JavaScript.

### Small Caps for Labels

```css
.label {
  font-variant-caps: small-caps;
  letter-spacing: 0.05em;
  font-weight: 600;
}
```

### Tabular Numbers for Data

```css
.data-value {
  font-variant-numeric: tabular-nums;
}
```

### Balanced Headings

```css
h1, h2, h3 {
  text-wrap: balance; /* ELP_030 */
}
```

### Drop Cap

```css
.article-body > p:first-of-type::first-letter {
  font-size: 3.375em; /* --s3 equivalent */
  float: inline-start;
  line-height: 0.8;
  margin-inline-end: var(--s-1);
  font-weight: 700;
  color: var(--br-color-accent);
}
```

**Note:** `float: inline-start` is the logical property equivalent of `float: left`. The drop cap floats correctly in both LTR and RTL.

---

## 5. Border Treatments

Borders as visual texture, not just containers.

### Accent Top Border

```css
.box[data-accent] {
  border-block-start: 3px solid var(--br-color-accent);
}
```

### Gradient Border (via background-clip)

```css
.box[data-gradient-border] {
  border: 2px solid transparent;
  background-origin: border-box;
  background-clip: padding-box, border-box;
  background-image:
    linear-gradient(var(--gl-color-bg), var(--gl-color-bg)),
    linear-gradient(135deg, var(--br-color-accent), var(--br-color-muted));
}
```

### Dashed Separator

```css
.separator {
  border: none;
  border-block-start: 2px dashed var(--gl-color-muted);
  margin-block: var(--s2);
}
```

---

## 6. Backdrop Effects

`backdrop-filter` applies effects to the area *behind* an element. Useful for sticky headers, overlays, and modals.

### Frosted Glass Header

```css
.header-sticky {
  position: sticky;
  inset-block-start: 0;
  background: hsl(var(--gl-bg-hsl) / 0.85);
  backdrop-filter: blur(8px);
  -webkit-backdrop-filter: blur(8px);
}

/* Fallback: opaque background if backdrop-filter unsupported */
@supports not (backdrop-filter: blur(1px)) {
  .header-sticky {
    background: var(--gl-color-bg);
  }
}
```

### Overlay Dim

```css
.imposter-backdrop {
  background: hsl(0deg 0% 0% / 0.5);
  backdrop-filter: blur(4px);
}
```

**Performance:** `backdrop-filter` is composited (GPU). The `blur()` radius should stay under 16px — larger values cause visible performance degradation on mobile.

---

## 7. Color Mixing

`color-mix()` creates derived colors from tokens without defining new variables.

### Hover Darkening

```css
.button:hover {
  background-color: color-mix(in oklch, var(--br-color-accent) 85%, black);
}
```

### Subtle Tinting

```css
.surface-tinted {
  background-color: color-mix(in oklch, var(--gl-color-bg) 95%, var(--br-color-accent));
}
```

### Muted Text

```css
.text-muted {
  color: color-mix(in oklch, var(--gl-color-fg) 60%, var(--gl-color-bg));
}
```

**Why `oklch`:** The `oklch` color space produces perceptually uniform mixing — 50% mix looks like 50% to the human eye, unlike `srgb` which skews toward darker tones.

---

## Texture Recipes by Posture

| Posture | Shadows | Background | Borders | Type treatment |
|---------|---------|------------|---------|----------------|
| `editorial-restraint` | `--elevation-1` max | Warm paper gradient | Accent top border | Drop cap, small caps |
| `research-dense` | None | Flat, no gradient | 1px solid borders | Tabular nums, tight letter-spacing |
| `quiet-utility` | `--elevation-1` | Cool steel gradient | None | Clean, no treatments |
| `warm-utility` | `--elevation-2` | Accent glow | Gradient borders | Balanced headings |
| `structured-grid` | `--elevation-1` | Dot grid pattern | None | Monospace labels |

---

## Anti-Patterns

| Bad | Why | Fix |
|-----|-----|-----|
| `filter: drop-shadow()` on many elements | Triggers repaint on every frame during scroll | Use `box-shadow` (composited) |
| `backdrop-filter: blur(40px)` | Visible jank on mobile GPUs | Keep blur under 16px |
| Gradient with 5+ color stops | Visual noise, hard to maintain | 2-3 stops maximum |
| `mix-blend-mode` on scrolling content | Can cause compositing layer explosion | Use on static elements only |
| Hard-coded colors in gradients | Breaks theming, dark mode | Use token-sourced `hsl()` values |
| `background-attachment: fixed` | Triggers full-page repaint on scroll in many browsers | Avoid entirely |
| Noise/grain texture via SVG filter | Performance-heavy, inconsistent cross-browser | Use CSS gradient patterns instead |
