# Every Layout Hooks

Memory lines for quick recall of principles and primitives.

---

## Principle Hooks

### Composition (ELP_001)
> Combine simple primitives; never build monoliths.

### Intrinsic Sizing (ELP_002)
> Let content determine size; avoid fixed dimensions.

### Border-Box (ELP_003)
> Always border-box. No exceptions. Ever.

### Logical Properties (ELP_004)
> Inline and block, not left and right.

### Modular Scale (ELP_005)
> One ratio rules all spacing.

### Measure (ELP_006)
> 45-75 characters. The ch unit is your friend.

### Global Styles (ELP_007)
> Element selectors for universal truths.

### Child-Only Effects (ELP_008)
> Primitives affect children, not grandchildren.

### Algorithmic Layout (ELP_009)
> Design rules, not breakpoints.

### Browser Delegation (ELP_010)
> Trust the browser's algorithms.

### Custom Properties (ELP_011)
> Configuration via CSS variables.

### Gap Over Margin (ELP_012)
> Gap property: cleaner, no collapse.

### Container Queries (ELP_013)
> When components need context, not viewport.

### Intrinsic First (ELP_014)
> Try intrinsic before reaching for queries.

### Accessible Icons (ELP_015)
> No icon without a name.

### Theme-Aware Color Tokens (ELP_016)
> Define once, adapt everywhere.

### Surface Elevation via Lightness (ELP_017)
> In darkness, rise through light.

### Derived Color Variants (ELP_018)
> One color, infinite variations.

### Container Query Measurement Invariance (ELP_019)
> Never change what you measure; styles inside queries must not alter the queried dimension.

### Inline-Size Containment Default (ELP_020)
> Use inline-size containment; preserve height, query width.

### Subgrid for Cross-Item Alignment (ELP_021)
> Subgrid shares structure; content aligns across columns.

### Consistent Shadow Light Source (ELP_022)
> Same offset ratio everywhere; one light illuminates all.

### Layered Shadow Realism (ELP_023)
> Stack shadows with progressive blur; single shadows look flat.

### Typography-Relative Icon Sizing (ELP_024)
> Size icons in cap, em, or lh; they scale with text automatically.

### Progressive Enhancement (ELP_027)
> HTML first, CSS enhances, JS augments; each layer works without the one above.

### Motion Safety (ELP_028)
> Respect reduced motion; one media query disarms all animation.

### Focus Visibility (ELP_029)
> :focus-visible for keyboards; never remove outline without a replacement.

### Text Wrap Balance (ELP_030)
> Balance headings with text-wrap: balance; even lines beat widow words.

### Scroll Snap Enhancement (ELP_031)
> Snap is a progressive enhancement; the reel must scroll smoothly without it.

### Font-Display Contract (ELP_032)
> Use font-display: optional when --measure uses ch units; if brand fonts must show on first paint, tune size-adjust and ascent-override to match the fallback.

---

## Container Query Hooks

### Wrapper Requirement (ELH_046)
> Container queries need a wrapper; an element cannot query itself.

### Logical Properties in Modern CSS (ELH_047)
> Modern CSS speaks in logical terms; inline-size means width.

### Rem Units for Queries (ELH_048)
> Query breakpoints in rem, respect user font choices.

---

## Subgrid Hooks

### Gap Inheritance (ELH_049)
> Subgrid inherits parent's gap; override with gap: 0 when needed.

### Grid Container Prerequisite (ELH_050)
> Subgrid needs display: grid first; it's a value, not a display type.

---

## Shadow Design Hooks

### Elevation Scaling (ELH_051)
> Higher elevation: larger offset, larger blur, lower opacity.

### Color-Matched Shadows (ELH_052)
> Color-match shadows to background hue; black desaturates.

### Shadow Tokenization (ELH_053)
> Tokenize elevations with --shadow-color for context adaptation.

---

## Component Architecture Hooks

### Configuration Block (ELH_054)
> Configuration block: group custom properties at component start.

### Data Attributes for State (ELH_055)
> Data attributes enforce finite state; classes allow conflicts.

### Explicit Button Borders (ELH_056)
> Explicit borders ensure matching heights between solid and ghost buttons.

### Icon Flex Protection (ELH_057)
> flex: none on icons prevents unwanted shrinking in tight containers.

---

## Progressive Enhancement Hooks

### HTML-First Content (ELH_061)
> Semantic HTML carries content; CSS is decoration, JS is behavior.

### Principle of Least Power (ELH_062)
> Choose the least powerful language for the job; HTML over CSS, CSS over JS.

---

## Accessibility Safety Hooks

### Motion Reset Pattern (ELH_063)
> One prefers-reduced-motion block with !important disarms all motion globally.

### Animation Duration Trick (ELH_064)
> Set duration to 0.01ms, not 0s; some events need the animation to technically complete.

### Focus-Visible vs Focus (ELH_065)
> :focus-visible fires on keyboard; :focus fires on everything. Style the former.

### Outline Offset (ELH_066)
> outline-offset: 3px separates the ring from the element; breathing room is legibility.

---

## Text Wrap & Scroll Snap Hooks

### Balance for Short Text (ELH_067)
> text-wrap: balance on headings and captions; skip it on body text (performance cost).

### Widow Prevention (ELH_068)
> text-wrap: pretty for body paragraphs; it fixes orphans without the cost of balance.

### Snap Type Choice (ELH_069)
> mandatory snaps to nearest; proximity snaps only when close. Mandatory for cards, proximity for mixed widths.

### Snap Alignment (ELH_070)
> scroll-snap-align: start puts the item edge at the container edge; center puts it in the middle.

---

## Fluid Type Scale Hooks

### Step System (ELH_071)
> Eight fluid steps (--step--2 to --step-5); each one clamp(min, preferred, max).

### Dual Ratios (ELH_072)
> Minor third at small screens, perfect fourth at large; the scale tightens on mobile.

---

## Article Grid & Sidenotes Hooks

### Named Grid Lines (ELH_073)
> content / breakout / full: three zones from narrow to edge-to-edge. Default to content.

### Sidenote Media Query Exception (ELH_074)
> Sidenotes need a media query — a documented exception. Per-paragraph placement can't be intrinsic.

---

## Fluid Typography Hooks

### Clamp Trio (ELH_058)
> clamp() is the trio that lets values breathe: floor, ideal, ceiling—no breakpoints needed.

### Zoom-Safe Fluid Values (ELH_059)
> Viewport-only sizing breaks zoom; add rem to restore accessibility.

### Growth Rate Control (ELH_060)
> Bigger viewport unit = faster growth; tune the target to control the rate.

---

## Primitive Hooks

### Stack (ELC_STACK)
> Owl selector + flex column = consistent vertical rhythm.

### Box (ELC_BOX)
> The bordered, padded container primitive.

### Center (ELC_CENTER)
> Horizontal centering with measure constraint.

### Cluster (ELC_CLUSTER)
> Inline items with gap that wrap gracefully.

### Sidebar (ELC_SIDEBAR)
> One fixed, one flexible, wrap when needed.

### Switcher (ELC_SWITCHER)
> Equal columns above threshold, stacked below.

### Cover (ELC_COVER)
> Vertical centering with header/footer option.

### Grid (ELC_GRID)
> RAM: Repeat, Auto-fit, Minmax. No queries needed.

### Frame (ELC_FRAME)
> Aspect ratio container that crops media.

### Reel (ELC_REEL)
> Horizontal scroll without page overflow.

### Imposter (ELC_IMPOSTER)
> Centered overlay positioning.

### Icon (ELC_ICON)
> Scales with text, aligns with baseline.

### Container (ELC_CONTAINER)
> Container query context. Use sparingly.

---

## Emergency Quick-Reference

| Need | Use | ID |
|------|-----|-----|
| Vertical spacing | Stack | ELC_STACK |
| Horizontal wrapping | Cluster | ELC_CLUSTER |
| Card grid | Grid | ELC_GRID |
| Two-column + stack | Sidebar | ELC_SIDEBAR |
| Hero centering | Cover | ELC_COVER |
| Content centering | Center | ELC_CENTER |
| Media aspect ratio | Frame | ELC_FRAME |
| Carousel | Reel | ELC_REEL |
| Modal positioning | Imposter | ELC_IMPOSTER |

---

## The Three Questions

Before writing CSS, ask:

1. **"Can intrinsic sizing handle this?"** (ELP_002, ELP_009)
2. **"Which primitive solves this problem?"** (See docs/chooser.md)
3. **"Am I composing or inheriting?"** (ELP_001)

---

## Red Flags in Code Review

- `width: 300px` on containers
- `@media` for layout switching
- `margin-left` instead of `margin-inline-start`
- `gap: 17px` (arbitrary, not from scale)
- Deeply nested selectors for layout
- Component-specific breakpoints
