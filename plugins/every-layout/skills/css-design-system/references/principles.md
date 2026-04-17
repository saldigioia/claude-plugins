# CSS Design System Principles

> Design-system principles that were previously numbered within the layout-engine catalog but belong semantically to theming, tokens, shadows, and icon sizing. IDs are preserved to keep existing cross-references valid. The `css-layout-engine/references/principles.md` file retains pointer stubs at each relocated slot.

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
