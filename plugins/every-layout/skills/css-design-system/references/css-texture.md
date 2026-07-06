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

## 8. Shadows in Dark Mode

ELP_022 (Consistent Shadow Light Source) and ELP_023 (Layered Shadow Realism) assume a light surface where transparent-black shadows read as depth. On dark surfaces, transparent black shadows mostly disappear or muddy the surface instead of lifting it — ELP_017 already established that dark mode should signal elevation through **lightness**, not shadow. These three principles are not in conflict; they apply in sequence: use ELP_017's lightness step as the primary elevation signal in dark mode, then layer a much-reduced, hue-matched shadow (ELP_022/ELP_023) on top for edge definition.

### The reconciliation recipe

1. **Lead with lightness, follow with shadow.** In dark mode, the lightness step (`--gl-elevation-step`) does the elevation work ELP_017 requires. Shadow becomes a secondary, subtle cue — reduce alpha and offset/blur distance versus the light-mode values, rather than reusing them at full strength.
2. **Color-match, don't blacken.** Transparent black (`hsl(0deg 0% 0% / 0.2)`) on a dark surface reads as murk, not depth. Use `color-mix()` to tint the shadow with the surface's own hue instead, keeping ELP_022's single-light-source ratio intact while making the shadow legible against a dark background.
3. **Keep the layering, shrink the range.** ELP_023's progressive offset/blur/opacity layering still applies — dark-mode shadows should still be built from 2-3 layers, just compressed (smaller max offset, tighter opacity range) so they don't compete with the lightness step.

### Two-Mode Shadow Token Set

Extend the `--elevation-1/2/3` scale from Section 1 with a `light-dark()`-aware variant rather than replacing it. This is additive: light mode keeps the existing layered values unchanged; dark mode substitutes reduced, hue-matched layers.

```css
:root {
  /* Existing light-mode shadow color from Section 1 */
  --shadow-color: 0deg 0% 0%;

  /* Surface hue for dark-mode shadow tinting — match to --gl-color-bg's hue */
  --shadow-color-dark: 220deg 13% 4%;

  --br-shadow-raised: light-dark(
    /* light: unchanged from --elevation-1 */
    0 1px 2px hsl(var(--shadow-color) / 0.04),
    0 1px 3px hsl(var(--shadow-color) / 0.06),
    /* dark: reduced offset/blur, hue-matched via color-mix(), lower alpha ceiling */
    0 1px 2px color-mix(in oklch, hsl(var(--shadow-color-dark)) 40%, transparent),
    0 1px 2px color-mix(in oklch, hsl(var(--shadow-color-dark)) 30%, transparent)
  );

  --br-shadow-elevated: light-dark(
    /* light: unchanged from --elevation-2 */
    0 1px 2px hsl(var(--shadow-color) / 0.03),
    0 3px 6px hsl(var(--shadow-color) / 0.05),
    0 6px 12px hsl(var(--shadow-color) / 0.04),
    /* dark: compressed range, still layered per ELP_023, still color-matched */
    0 2px 4px color-mix(in oklch, hsl(var(--shadow-color-dark)) 35%, transparent),
    0 4px 8px color-mix(in oklch, hsl(var(--shadow-color-dark)) 25%, transparent)
  );
}
```

**Usage:**
```css
.box[data-elevated] {
  background: var(--gl-color-bg); /* carries the ELP_017 lightness step per elevation level */
  box-shadow: var(--br-shadow-raised);
}
```

Each `light-dark()` shadow token still satisfies ELP_022 — the offset-to-blur ratio per layer is unchanged between modes, only magnitude and color shift. The token stays within the Tier 2 (`--br-*`) naming rule (`token-rules.md`) since it is a semantic mapping a brand could override, while `--gl-elevation-step` remains the Tier 1 mathematical constant driving the lightness side of the equation.

### Transitioning between elevation states

If elevation changes on interaction (e.g. `[data-elevated]` toggling on hover/focus), gate the transition per the motion allowlist — `box-shadow` is paint-only and permitted *only* when the spread value doesn't change between states, which holds here since both tokens share the same layer count and spread:

```css
@media (prefers-reduced-motion: no-preference) {
  .box {
    transition: box-shadow 150ms ease-out;
  }
}
```

No `!important`, no selector past 0-2-0 (`.box[data-elevated]` is a single class + one attribute), and the reduced-motion gate means users who opt out see the final elevation state with no transition — consistent with every other pattern in this file.

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
