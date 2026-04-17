# Layout Principles — Full Specifications

## Composition Over Inheritance (ELP_001)

**Combine simple, single-purpose layout primitives to create complex layouts rather than building monolithic components**

**Applies when:** Building layout systems or component libraries

**Fails when:** Primitives have interdependencies or cannot be nested

**Tradeoffs:** More HTML nesting in exchange for greater flexibility and reusability

**Sources:**

1. Chapter `ch_05`, window `w01`

**Tags:** composition

> Any primitive should work correctly when nested inside any other primitive

---

## Intrinsic Sizing Over Extrinsic Sizing (ELP_002)

**Allow elements to size themselves based on their content rather than explicit dimensions**

**Applies when:** Defining element dimensions, especially for dynamic content

**Fails when:** Specific dimensions are required for design consistency (e.g., icons, avatars)

**Tradeoffs:** Less predictable dimensions in exchange for content adaptability

**Sources:**

1. Chapter `ch_09`, window `w01`

**Tags:** intrinsic-sizing, responsiveness

> Layout should adapt to content changes without modification

---

## Universal Border-Box (ELP_003)

**Apply box-sizing: border-box to all elements via universal selector**

**Applies when:** Always; part of global stylesheet setup

**Fails when:** Never - no legitimate reason to use content-box

**Tradeoffs:** None; strictly better than content-box for layout calculations

**Sources:**

1. Chapter `ch_04`, window `w01`

**Tags:** containment

> Element with padding and border should not exceed declared width

---

## Logical Properties (ELP_004)

**Use logical properties (inline/block) instead of physical properties (left/right/top/bottom)**

**Applies when:** Setting dimensions, margins, padding, or positioning

**Fails when:** Physical direction is explicitly required regardless of writing mode

**Tradeoffs:** Slightly less familiar syntax in exchange for internationalization support

**Sources:**

1. Chapter `ch_04`, window `w03`

**Tags:** flow, accessibility

> Layout should work correctly in RTL writing mode

---

## Modular Scale Spacing (ELP_005)

**Use a consistent modular scale ratio for all spacing values**

**Applies when:** Defining margins, padding, gaps, and other spacing

**Fails when:** Design requirements dictate specific non-scale values

**Tradeoffs:** Reduced flexibility in exchange for visual harmony

**Sources:**

1. Chapter `ch_08`, window `w01`

**Tags:** spacing

> All spacing values should be derivable from the modular scale

---

## Measure Constraint (ELP_006)

**Limit text line length to 45-75 characters using the ch unit**

**Applies when:** Setting max-width on text containers

**Fails when:** Non-text content that requires wider display

**Tradeoffs:** Narrower content areas in exchange for improved readability

**Sources:**

1. Chapter `ch_06`, window `w02`

**Tags:** readability

> Text container should not exceed 75ch width

---

## Global Element Styles (ELP_007)

**Use element selectors for universal baseline styles that should apply everywhere**

**Applies when:** Setting up foundational styles like responsive images

**Fails when:** Style needs to be component-specific or contextual

**Tradeoffs:** Less specificity control in exchange for consistency and DRYness

**Sources:**

1. Chapter `ch_07`, window `w01`

**Tags:** composition

> Images should not exceed container width by default

---

## Child-Only Layout Effects (ELP_008)

**Layout primitives should only affect their direct children, not grandchildren**

**Applies when:** Implementing layout components

**Fails when:** Recursive effect is explicitly desired (e.g., recursive Stack)

**Tradeoffs:** Requires explicit nesting in exchange for predictable behavior

**Sources:**

1. Chapter `ch_05`, window `w02`

**Tags:** composition, containment

> Layout primitive should not affect grandchildren elements

---

## Algorithmic Self-Governing Layout (ELP_009)

**Design layouts that adapt automatically to content and context without manual intervention**

**Applies when:** Creating responsive layouts

**Fails when:** Specific behavior at specific breakpoints is required

**Tradeoffs:** Less precise control in exchange for robustness

**Sources:**

1. Chapter `ch_09`, window `w02`

**Tags:** responsiveness, intrinsic-sizing

> Layout should function without any media queries

---

## Browser Delegation (ELP_010)

**Delegate layout decisions to the browser's algorithms where possible**

**Applies when:** Choosing between manual and automatic approaches

**Fails when:** Browser defaults don't match requirements

**Tradeoffs:** Less explicit control in exchange for optimized performance

**Sources:**

1. Chapter `ch_09`, window `w03`

**Tags:** responsiveness

> Layout should work correctly with browser defaults

---

## Custom Properties for Configuration (ELP_011)

**Use CSS custom properties for configurable values in layout primitives**

**Applies when:** Creating reusable components with variable parameters

**Fails when:** Value is truly constant and never varies

**Tradeoffs:** Slightly more verbose in exchange for flexibility

**Sources:**

1. Chapter `ch_08`, window `w02`

**Tags:** composition

> Primitive should accept custom property overrides

---

## Prefer Gap Over Margin (ELP_012)

**Use gap property in Flexbox/Grid contexts instead of margin for spacing**

**Applies when:** Spacing items in flex or grid containers

**Fails when:** Need asymmetric spacing or non-flex/grid contexts

**Tradeoffs:** Slightly less browser support in exchange for cleaner code

**Sources:**

1. Chapter `ch_13`, window `w02`

**Tags:** spacing

> Spacing should be consistent without margin collapse issues

---

## Container Queries Over Media Queries (ELP_013)

**Use container queries instead of media queries for component-level responsive design**

**Applies when:** Component needs to adapt to its container, not viewport

**Fails when:** Intrinsic layout can achieve the same result without queries

**Tradeoffs:** Additional containment context in exchange for context-aware styling

**Sources:**

1. Chapter `ch_22`, window `w01`

**Tags:** responsiveness, containment

> Component should respond to container width, not viewport

---

## Intrinsic Layout First (ELP_014)

**Prefer intrinsic layouts over explicit breakpoints (media or container queries)**

**Applies when:** Designing responsive components

**Fails when:** Intrinsic approach cannot achieve required behavior

**Tradeoffs:** Less explicit control in exchange for less code and better compatibility

**Sources:**

1. Chapter `ch_22`, window `w02`

**Tags:** responsiveness, intrinsic-sizing

> Layout should work without any breakpoint queries

---

## Accessible Icons (ELP_015)

**Provide accessible labels for icons, especially when used alone without text**

**Applies when:** Using icons in interactive elements

**Fails when:** Icon is purely decorative

**Tradeoffs:** Additional markup in exchange for screen reader support

**Sources:**

1. Chapter `ch_21`, window `w02`

**Tags:** accessibility

> Icon-only controls should have accessible name

---

## Theme-Aware Color Tokens (ELP_016) → relocated

Moved to the `css-design-system` skill. See `css-design-system/references/principles.md` for the full definition. ID preserved for cross-reference stability.

---

## Surface Elevation via Lightness (ELP_017) → relocated

Moved to the `css-design-system` skill. See `css-design-system/references/principles.md`.

---

## Derived Color Variants (ELP_018) → relocated

Moved to the `css-design-system` skill. See `css-design-system/references/principles.md`.

---

## Container Query Measurement Invariance (ELP_019)

**CSS declarations inside a @container query must not cause the container's measured dimension to change**

**Applies when:** Writing @container queries or debugging unexpected container query behavior

**Fails when:** Using media queries (which query immutable global state) or intrinsic layout achieves the result

**Tradeoffs:** Requires awareness of which CSS properties affect container dimensions

**Sources:**

1. Article `ART_containerqueries`, section `s05` — "golden rule is that we can't change what we measure"

**Tags:** containment, responsiveness

> No flickering or layout instability when container query conditions are met

---

## Inline-Size Containment Default (ELP_020)

**Prefer container-type: inline-size over container-type: size to enable width-based container queries while preserving natural content-driven height**

**Applies when:** Setting up container query contexts where components need vertical flow with horizontal responsiveness

**Fails when:** Both width AND height queries are required or container has fixed height regardless of content

**Tradeoffs:** Cannot use min-height/max-height conditions; container width cannot respond to content

**Sources:**

1. Article `ART_containerqueries`, section `s05` — "height retains its default behaviour of growing/shrinking"

**Tags:** containment, responsiveness, intrinsic-sizing

> Container height grows with content while width-based @container queries fire correctly

---

## Subgrid for Cross-Item Alignment (ELP_021)

**Use CSS subgrid to align content sections across grid items by having children inherit the parent grid's row structure, achieving consistent horizontal reading lines without calculations**

**Applies when:** Grid items contain multiple sections (heading + content) that should align across columns, or variable-height content creates uneven reading lines

**Fails when:** Items have truly different content structures that shouldn't align, or flexibility in vertical placement is more important than strict alignment

**Tradeoffs:** Child elements must also be grid containers; explicit grid-row span needed when parent only defines columns; gap is inherited from parent and may need explicit override

**Sources:**

1. Andy Bell, "[A handy use of subgrid to enhance a simple layout](https://piccalil.li/blog/a-handy-use-of-subgrid-to-enhance-a-simple-layout/)" (2024-11-01, accessed 2026-01-25), section "Subgrid Implementation" — "all headings and summaries participate in the same layout structure"

**Tags:** alignment, responsiveness

> Content sections at the same index should align horizontally across grid items regardless of individual content heights

---

## Consistent Shadow Light Source (ELP_022) → relocated

Moved to the `css-design-system` skill. See `css-design-system/references/principles.md`.

---

## Layered Shadow Realism (ELP_023) → relocated

Moved to the `css-design-system` skill. See `css-design-system/references/principles.md`.

---

## Typography-Relative Icon Sizing (ELP_024) → relocated

Moved to the `css-design-system` skill. See `css-design-system/references/principles.md`.

---

## Fluid Sizing via Clamp (ELP_025)

**Use CSS clamp(min, preferred, max) for responsive values that scale smoothly between defined bounds without media queries, where the preferred value typically combines a static unit with a viewport or container unit**

**Applies when:** Creating typography scales, spacing, or component dimensions that should adapt smoothly to available space

**Fails when:** Discrete steps are preferred over smooth scaling, or browser support constraints require fallbacks

**Tradeoffs:** Less predictable intermediate values in exchange for smooth, breakpoint-free scaling; values between min and max are determined algorithmically

**Sources:**

1. Andy Bell, "[Fluid typography with CSS clamp](https://piccalil.li/tutorial/fluid-typography-with-css-clamp)" (2021-01-01, accessed 2026-01-25), section "Digging in to the CSS" — "clamp() function takes a minimum value, an ideal value and a maximum value"

**Tags:** responsiveness, intrinsic-sizing

> Value should equal min at small sizes, max at large sizes, and scale smoothly between

---

## Accessibility-Safe Fluid Values (ELP_026)

**When using viewport units (vw, vh, vi, vb) in fluid sizing, always combine them with a rem value via calc() to ensure browser zoom functionality remains effective for accessibility compliance**

**Applies when:** Any clamp() or calc() using viewport units for font-size, spacing, or dimensions

**Fails when:** Fixed sizing is required regardless of zoom level, or viewport units are not involved

**Tradeoffs:** Slightly more complex syntax in exchange for WCAG zoom compliance

**Sources:**

1. Andy Bell, "[Fluid typography with CSS clamp](https://piccalil.li/tutorial/fluid-typography-with-css-clamp)" (2021-01-01, accessed 2026-01-25), section "FYI - Accessibility" — "if you just use a viewport unit, it can cause problems in zooming"

**Tags:** accessibility, responsiveness

> Zooming browser to 200% should visibly increase font-size; pure viewport units fail this test

---

## Progressive Enhancement (ELP_027)

**Build from semantic HTML upward: CSS enhances presentation, JavaScript augments interaction. Every layer must be functional without the layers above it.**

**Applies when:** Designing any component or layout; choosing between CSS-only and JS-dependent solutions

**Fails when:** A JavaScript framework is the mandatory runtime and no-JS fallback is impractical (e.g., SPA-only contexts)

**Tradeoffs:** Additional planning to ensure each layer works independently in exchange for maximum resilience and accessibility

**Sources:**

1. Jeremy Keith, "[Resilient Web Design](https://resilientwebdesign.com/)" (2016-12-01, accessed 2026-01-25), section "Chapter 1: Foundations" — "The three-layer approach: structure (HTML), presentation (CSS), behaviour (JavaScript)"

**Tags:** composition, accessibility

> Component should display readable content with CSS disabled; interactive features should function without JavaScript where possible

---

## Motion Safety (ELP_028)

**Respect prefers-reduced-motion by disabling or reducing all animations, transitions, and auto-playing motion for users who request reduced motion**

**Applies when:** Any use of animation, transition, scroll-behavior, or auto-playing media

**Fails when:** Motion is essential to understanding content (e.g., a physics simulation) and cannot be replaced with a static alternative

**Tradeoffs:** Requires maintaining two motion states in exchange for WCAG 2.1 SC 2.3.3 compliance and vestibular safety

**Sources:**

1. W3C, "[SC 2.3.3 Animation from Interactions](https://www.w3.org/WAI/WCAG21/Understanding/animation-from-interactions.html)" (2023-10-05, accessed 2026-01-25), section "SC 2.3.3 Animation from Interactions" — "Motion animation triggered by interaction can be disabled"
2. MDN Web Docs, "[prefers-reduced-motion](https://developer.mozilla.org/en-US/docs/Web/CSS/@media/prefers-reduced-motion)" (2024-01-01, accessed 2026-01-25), section "prefers-reduced-motion" — "used to detect if a user has enabled a setting to minimize non-essential motion"

**Tags:** accessibility

> With prefers-reduced-motion: reduce enabled, no element should animate or transition; scroll-behavior should be auto

---

## Focus Visibility (ELP_029)

**Use :focus-visible for keyboard-triggered focus rings and never remove outline without providing an equivalent or better alternative indicator**

**Applies when:** Styling interactive elements (links, buttons, inputs, custom controls)

**Fails when:** A custom focus indicator (e.g., background change, border, shadow) already provides equivalent visibility

**Tradeoffs:** Focus rings may not match design aesthetic in exchange for WCAG 2.4.7 (Focus Visible) and 2.4.11 (Focus Appearance) compliance

**Sources:**

1. W3C, "[SC 2.4.7 Focus Visible](https://www.w3.org/WAI/WCAG22/Understanding/focus-visible.html)" (2023-10-05, accessed 2026-01-25), section "SC 2.4.7 Focus Visible" — "any keyboard operable user interface has a mode of operation where the keyboard focus indicator is visible"
2. MDN Web Docs, "[:focus-visible](https://developer.mozilla.org/en-US/docs/Web/CSS/:focus-visible)" (2024-01-01, accessed 2026-01-25), section ":focus-visible" — "matches when an element matches the :focus pseudo-class and the UA determines that the focus should be made evident"

**Tags:** accessibility

> Tabbing through interactive elements with keyboard should show visible focus indicator; clicking with mouse should not show focus ring on buttons

---

## Text Wrap Balance (ELP_030)

**Apply text-wrap: balance to headings and short text blocks to distribute words evenly across lines, preventing typographic widows and orphans**

**Applies when:** Headings, pull quotes, captions, and other short text blocks (typically under 6 lines) that benefit from even line distribution

**Fails when:** Long-form body text where balanced wrapping would hurt performance, or when a specific ragged-right rhythm is intentionally designed

**Tradeoffs:** Slightly less predictable line breaks in exchange for visually balanced text blocks; performance cost limits practical use to short content

**Sources:**

1. CSS Working Group, "[text-wrap: balance](https://drafts.csswg.org/css-text-4/#text-wrap)" (2023-05-01, accessed 2026-01-25), section "text-wrap: balance" — "The inline content is balanced to minimize the variation in inline-size of the lines"
2. Adam Argyle, "[CSS text-wrap: balance](https://developer.chrome.com/blog/css-text-wrap-balance)" (2023-04-06, accessed 2026-01-25), section "Introduction" — "A simple CSS addition that improves text layouts"

**Tags:** typography

> A heading split across two lines should distribute words roughly evenly between lines rather than having a near-full first line and a single-word second line

---

## Scroll Snap Enhancement (ELP_031)

**Use CSS scroll-snap on horizontally scrolling containers (Reel) as a progressive enhancement: snap behavior improves the experience but the container must scroll smoothly without it**

**Applies when:** Horizontal scrolling containers (Reel), carousels, image galleries, or any content that pages through discrete items

**Fails when:** Continuous scrolling is preferred (e.g., maps, timelines) or items have highly variable widths where snapping would feel jarring

**Tradeoffs:** Constrains free-scroll behavior in exchange for predictable item-by-item navigation; must be tested with trackpad, touch, and keyboard

**Sources:**

1. CSS Working Group, "[scroll-snap-type](https://drafts.csswg.org/css-scroll-snap-1/)" (2024-01-18, accessed 2026-01-25), section "scroll-snap-type" — "specifies whether a scroll container is a scroll snap container, how strictly it snaps, and which axes are considered"
2. MDN Web Docs, "[CSS scroll snap](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_scroll_snap)" (2024-01-01, accessed 2026-01-25), section "CSS scroll snap" — "CSS scroll snap provides snap positions -- points that the scrolling of a scroll container's scrollport is forced to land on"

**Tags:** composition, responsiveness

> With snap enabled, releasing a scroll gesture should settle the container so that an item edge aligns with the container edge; without snap, free scrolling should still work

---

## Font-Display Contract (ELP_032)

**Use font-display: optional to prevent ch-unit CLS when Center (ELC_CENTER) uses --measure. If brand fonts are required on first paint, ship @font-face with size-adjust and ascent-override tuned to the fallback font metrics**

**Applies when:** Any project using ch-based --measure for Center or other intrinsic-width primitives, and loading custom web fonts

**Fails when:** Only system fonts are used, or no primitive relies on ch units for sizing

**Tradeoffs:** font-display: optional may cause FOIT (flash of invisible text) on slow connections; size-adjust/ascent-override require per-font metric tuning but eliminate layout shift

**Sources:**

1. CSS Working Group, "[font-display](https://drafts.csswg.org/css-fonts-4/#font-display-desc)" (2024-02-15, accessed 2026-03-31), section "font-display" — "The font-display descriptor determines how a font face is displayed based on whether and when it is downloaded and ready to use"

**Tags:** performance, layout-stability

> Load a page using Center with --measure: 65ch while throttling network to Slow 3G. With font-display: optional, the layout must not shift when the web font loads (CLS = 0 for the Center element)
