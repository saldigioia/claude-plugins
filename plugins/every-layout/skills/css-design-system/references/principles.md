# CSS Design System Principles

> Design-system principles: the subset relocated from the layout-engine catalog (theming, tokens, shadows, icon sizing — IDs preserved so existing cross-references stay valid; `css-layout-engine/references/principles.md` retains pointer stubs at each relocated slot) plus principles born design-system-native (ELP_035+). This file defines ELP_016–018, ELP_022–024, and ELP_035; the complete ELP_001–035 catalog spans both files.

---

## Theme-Aware Color Tokens (ELP_016)

**Define color tokens using light-dark() with color-scheme property to create theme-responsive values from a single declaration**

**Applies when:** Creating color systems that need to adapt to user theme preferences

**Fails when:** Component must maintain fixed colors regardless of theme context

**Tradeoffs:** Requires color-scheme property declaration for light-dark() to function

**Sources:**

1. Article `ART_colours`, section `s03` — "light-dark() relies on the color-scheme property"

**Tags:** responsiveness, composition

> Changing color-scheme on :root should update all light-dark() values

---

## Surface Elevation via Lightness (ELP_017)

**In dark themes, indicate elevation hierarchy through increasing background lightness rather than relying on shadows**

**Applies when:** Creating nested surface hierarchy in dark mode designs

**Fails when:** Light mode where shadows provide sufficient contrast

**Tradeoffs:** Different visual language between light and dark modes

**Sources:**

1. Article `ART_colours`, section `s06` — "shadows on dark backgrounds don't do very much"

**Tags:** composition, accessibility

> Nested surfaces in dark mode should be visually distinguishable without shadows

---

## Derived Color Variants (ELP_018)

**Use relative colors to derive transparency, tint, and shade variants from base color custom properties rather than defining each variant explicitly**

**Applies when:** Component needs multiple related color values (border, background, shadow from same hue)

**Fails when:** Colors are independently chosen without relationship

**Tradeoffs:** Requires understanding of relative color syntax

**Sources:**

1. Article `ART_colours`, section `s02` — "create lighter and darker versions of a base colour"

**Tags:** composition

> Changing base color should update all derived variants automatically

---

## Consistent Shadow Light Source (ELP_022)

**All box-shadows in an application should use the same ratio between horizontal and vertical offsets to simulate a consistent light source direction**

**Applies when:** Applying shadows to any element, establishing shadow design system

**Fails when:** Intentionally simulating multiple light sources for artistic effect

**Tradeoffs:** Requires planning shadow system upfront rather than ad-hoc per-element styling

**Sources:**

1. Josh W. Comeau, "[Designing Shadows](https://www.joshwcomeau.com/css/designing-shadows/)" (2021-04-01, accessed 2026-01-25), section "A cohesive world" — "every shadow should share the same ratio"

**Tags:** composition

> Extract horizontal and vertical offsets from all shadows; ratio should be consistent

---

## Layered Shadow Realism (ELP_023)

**Use multiple layered box-shadows with progressively increasing offsets and blur radiuses rather than a single shadow to create more realistic shadow appearance**

**Applies when:** Creating shadows that need to appear natural and life-like

**Fails when:** Performance is critical and multiple shadows add unacceptable overhead, or design calls for intentionally flat/stylized shadows

**Tradeoffs:** More verbose CSS declarations in exchange for significantly more realistic shadow appearance

**Sources:**

1. Josh W. Comeau, "[Designing Shadows](https://www.joshwcomeau.com/css/designing-shadows/)" (2021-04-01, accessed 2026-01-25), section "Layering" — "stack a handful on top of each other, with slightly-different offsets"

**Tags:** composition

> Shadow should have multiple comma-separated values with progressive blur values

---

## Typography-Relative Icon Sizing (ELP_024)

**Size inline icons using typography units (cap, em, lh) so they scale proportionally with surrounding text without manual adjustment**

**Applies when:** Icons appear alongside text in buttons, links, or other inline contexts

**Fails when:** Icon has fixed design specification regardless of text size, or icon is purely decorative background element

**Tradeoffs:** cap unit has narrower browser support than em; may need fallback strategy

**Sources:**

1. Andy Bell, "[How I build a button component](https://piccalil.li/blog/how-i-build-a-button-component/)" (2024-09-18, accessed 2026-01-25), section "Sizing the icon" — "as the text size increases or decreases, icon will size relative"

**Tags:** intrinsic-sizing, accessibility

> Increasing font-size on parent should proportionally scale icon without CSS changes

---

## Painted Ground (ELP_035)

**The document canvas gets an explicit `background-color` on the root; gradients and images are decoration layered above the painted ground, never a substitute for it**

The UA canvas is not a color you chose. With `color-scheme: light dark` (ELP_016) an unpainted canvas follows the user's preference — white for light-preference users, near-black for dark-preference users — and without `color-scheme` it is whatever the browser defaults to. A `background-image` or gradient with `background-size` / `no-repeat` covers only the region it is told to; everywhere it stops, the canvas shows through. The field-report failure: a body painted a 600px-tall gradient over a transparent canvas, so every dark-preferring browser rendered the entire site below the fold on black — invisible in every light-mode screenshot the project ever took.

**Applies when:** Any `body`/`html`/`:root` rule declares `background-image`, a `background:` shorthand containing `gradient()`/`url()`, or `background-size`

**Fails when:** The ground is already in the shorthand — `background: #eff6ff url(…) no-repeat` paints color and decoration in one declaration; or the design deliberately adopts the UA canvas as its ground (`background-color: Canvas` with `color-scheme` set), which is a recorded decision, not an omission

**Tradeoffs:** An explicit ground must itself be theme-aware (`light-dark()`) or it fights `color-scheme` — painting `#ffffff` under a dark-preference user is honest but jarring, so the ground token belongs in the same `light-dark()` regime as the ink tokens (ELP_016 pairs with this principle: `color-scheme` decides what an *unpainted* canvas would have been; ELP_035 says never to find out by accident)

**Sources:**

1. Field report `CURATION-RETRO.md` (2026-07-09, Window Classics): 600px body gradient over a transparent canvas — UA-canvas black below the fold in dark-preference contexts, shipped because every screenshot was light-mode
2. CSS Color Adjustment Module Level 1, [Preferred Color Schemes](https://drafts.csswg.org/css-color-adjust-1/#color-scheme-prop) (accessed 2026-07-10) — the canvas surface color is determined by the used color scheme when no author background is set
3. ELP_016 (Theme-Aware Color Tokens) — the companion principle this one has mechanical teeth for

**Tags:** composition, responsiveness

> With `prefers-color-scheme: dark` emulated and no site CSS overridden, no route shows the UA canvas as ground — scroll past any hero gradient and sample the body's bottom pixel: it is a color the stylesheet painted, not the UA default
