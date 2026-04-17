# Layout Primitives -- Full Specifications

Version: 1.5.0

> **Scope — this file:** the *specification* for each of the 13 primitives — ID, parameters, CSS, `applies_when`, `fails_when`, verification tests, related principles. This is the source of truth for the primitive API surface.
> For variations, recipes, and end-to-end usage patterns, see `cookbook-primitives.md` and `cookbook-recipes.md`.

---

## Stack (ELC_STACK)

**Stack** (`ELC_STACK`) -- Consistent vertical spacing between sibling elements.

**Problem it solves:** Consistent vertical spacing between sibling elements

Tags: `spacing`, `flow`

Sources: Chapter `ch_10`, Window `w01`

HTML expectations: Block-level container with multiple children

Related principles: `ELP_008`, `ELP_005`

### CSS Recipe

```css
.stack { display: flex; flex-direction: column; justify-content: flex-start }
.stack > * { margin-block: 0 }
.stack > * + * { margin-block-start: var(--space, 1.5rem) }
```

### Custom Properties

| Property | Default | Purpose |
|----------|---------|---------|
| `space` | `var(--s1)` | Vertical space between children |
| `recursive` | `false` | Apply spacing to all descendants |
| `splitAfter` | `null` | Index after which to push remaining items to bottom |

### Key Behavior

- First child has no top margin due to the `* + *` (lobotomized owl) selector
- Subsequent siblings receive equal vertical spacing
- Recursive mode applies spacing to all descendants, not just direct children
- splitAfter pushes remaining items to the bottom of the container

### Failure Modes

- **First child has margin** -- Extra space at top. Fix: Ensure `* + *` selector is used.
- **Recursive unintentionally** -- Spacing on nested content. Fix: Use child combinator `>`.

### Best For

- Vertical flow of content blocks
- Form field groups
- Article body content

### Composes With

- Box (ELC_BOX) for padded stacked regions
- Center (ELC_CENTER) for centered stacked content

### Verification Test

> - First child element should have no top margin
> - All subsequent siblings should have equal spacing

---

## Box (ELC_BOX)

**Box** (`ELC_BOX`) -- Creating padded, bordered container regions.

**Problem it solves:** Creating padded, bordered container regions

Tags: `containment`, `spacing`

Sources: Chapter `ch_11`, Window `w01`

HTML expectations: Any block-level element

Related principles: `ELP_011`, `ELP_017`, `ELP_022`, `ELP_023`

### CSS Recipe

```css
.box { padding: var(--s1); border: var(--border-thin) solid; color: var(--color-dark); background-color: var(--color-light) }
.box[data-invert] { color: var(--color-light); background-color: var(--color-dark) }
```

### Custom Properties

| Property | Default | Purpose |
|----------|---------|---------|
| `padding` | `var(--s1)` | Internal padding |
| `borderWidth` | `var(--border-thin)` | Border thickness |
| `invert` | `false` | Swap foreground/background colors |

### Key Behavior

- Applies equal padding on all sides by default
- Border uses a solid style with configurable thickness
- Inversion swaps foreground and background colors via the `data-invert` attribute
- Colors are driven by custom properties, enabling theming

### Failure Modes

- **Hard-coded colors** -- Cannot invert. Fix: Use custom properties.

### Best For

- Card containers
- Alert/notification regions
- Highlighted content sections

### Composes With

- Stack (ELC_STACK) for vertically spaced boxes
- Sidebar (ELC_SIDEBAR) as sidebar or content panel

### Verification Test

> - Box should have equal padding on all sides by default
> - Inverted Box should swap foreground and background colors

---

## Center (ELC_CENTER)

**Center** (`ELC_CENTER`) -- Horizontally centering block-level content with max-width constraint.

**Problem it solves:** Horizontally centering block-level content with max-width constraint

Tags: `alignment`, `readability`

Sources: Chapter `ch_12`, Window `w01`

HTML expectations: Block-level container, typically for text content

Related principles: `ELP_006`

### CSS Recipe

```css
.center { box-sizing: content-box; max-inline-size: var(--measure); margin-inline: auto; padding-inline: var(--s1) }
```

### Custom Properties

| Property | Default | Purpose |
|----------|---------|---------|
| `max` | `var(--measure)` | Maximum content width |
| `gutters` | `var(--s1)` | Minimum padding on sides |
| `intrinsic` | `false` | Center based on content width |

### Key Behavior

- Uses `content-box` sizing so gutters do not reduce the content area
- `margin-inline: auto` centers the element horizontally
- `max-inline-size` constrains content width for readability
- Gutters (padding-inline) ensure content never touches viewport edges
- Intrinsic mode centers based on actual content width rather than max-width

### Failure Modes

- **border-box sizing** -- Gutters reduce content area. Fix: Use content-box.
- **No gutters** -- Content touches edges. Fix: Add padding-inline.

### Best For

- Article/prose content
- Page-level content wrappers
- Readable text columns

### Composes With

- Stack (ELC_STACK) for centered stacked content
- Cover (ELC_COVER) as the centered principal element

### Verification Test

> - Centered content should have equal margins on left and right
> - Content should not exceed max-inline-size

---

## Cluster (ELC_CLUSTER)

**Cluster** (`ELC_CLUSTER`) -- Horizontal wrapping layout with consistent gaps, like inline elements with better spacing.

**Problem it solves:** Horizontal wrapping layout with consistent gaps, like inline elements with better spacing

Tags: `alignment`, `spacing`, `flow`

Sources: Chapter `ch_13`, Window `w01`

HTML expectations: Container with inline-like items (tags, buttons, links)

Related principles: `ELP_012`

### CSS Recipe

```css
.cluster { display: flex; flex-wrap: wrap; gap: var(--space, 1rem); justify-content: flex-start; align-items: center }
```

### Custom Properties

| Property | Default | Purpose |
|----------|---------|---------|
| `justify` | `flex-start` | Horizontal distribution |
| `align` | `center` | Vertical alignment |
| `space` | `var(--s1)` | Gap between items |

### Key Behavior

- Items wrap naturally to new lines when container is too narrow
- Gap property ensures consistent spacing in both directions
- Justify and align control distribution and cross-axis alignment
- No need for margin hacks; gap handles all inter-item spacing

### Failure Modes

- **No flex-wrap** -- Items overflow. Fix: Add `flex-wrap: wrap`.

### Best For

- Tag lists
- Button groups
- Navigation links
- Badges and labels

### Composes With

- Box (ELC_BOX) as a padded cluster container
- Stack (ELC_STACK) for vertical separation between clusters

### Verification Test

> - Items should wrap to new line when container is too narrow
> - Spacing should be consistent between items and rows

---

## Sidebar (ELC_SIDEBAR)

**Sidebar** (`ELC_SIDEBAR`) -- Two-element layout where one has fixed width and the other fills remaining space.

**Problem it solves:** Two-element layout where one has fixed width and the other fills remaining space

Tags: `responsiveness`, `intrinsic-sizing`

Sources: Chapter `ch_14`, Window `w01`

HTML expectations: Container with exactly two children

Related principles: `ELP_009`, `ELP_002`

### CSS Recipe

```css
.with-sidebar { display: flex; flex-wrap: wrap; gap: var(--s1) }
.with-sidebar > :first-child { flex-basis: 20rem; flex-grow: 1 }
.with-sidebar > :last-child { flex-basis: 0; flex-grow: 999; min-inline-size: 50% }
```

### Custom Properties

| Property | Default | Purpose |
|----------|---------|---------|
| `sideWidth` | `null` | Sidebar intrinsic width |
| `contentMin` | `50%` | Minimum content width before wrapping |
| `space` | `var(--s1)` | Gap between sidebar and content |
| `noStretch` | `false` | Prevent vertical stretching |

### Key Behavior

- First child acts as the sidebar with a configurable flex-basis
- Second child fills remaining space with `flex-grow: 999`
- Layout wraps to vertical when the content area would be narrower than `contentMin`
- No media queries needed; the layout is entirely intrinsic
- `noStretch` prevents children from stretching to equal height

### Failure Modes

- **More than 2 children** -- Unexpected layout. Fix: Use only 2 direct children.
- **Sidebar never wraps** -- Content too narrow. Fix: Adjust contentMin.

### Best For

- Sidebar navigation with main content
- Form label + input pairs
- Thumbnail + description layouts

### Composes With

- Stack (ELC_STACK) for stacked content within sidebar or main area
- Box (ELC_BOX) as either the sidebar or content panel

### Verification Test

> - Sidebar should maintain fixed width until wrapping
> - Layout should wrap to vertical when content area is too narrow

---

## Switcher (ELC_SWITCHER)

**Switcher** (`ELC_SWITCHER`) -- Equal-width columns that switch to stacked layout below a threshold.

**Problem it solves:** Equal-width columns that switch to stacked layout below a threshold

Tags: `responsiveness`, `intrinsic-sizing`

Sources: Chapter `ch_15`, Window `w01`

HTML expectations: Container with multiple equal-importance children

Related principles: `ELP_009`, `ELP_002`

### CSS Recipe

```css
.switcher { display: flex; flex-wrap: wrap; gap: var(--s1) }
.switcher > * { flex-grow: 1; flex-basis: calc((var(--threshold, 30rem) - 100%) * 999) }
```

### Custom Properties

| Property | Default | Purpose |
|----------|---------|---------|
| `threshold` | `30rem` | Container width at which to switch |
| `space` | `var(--s1)` | Gap between items |
| `limit` | `4` | Maximum items before forcing stack |

### Key Behavior

- Items are horizontal when the container exceeds the threshold
- Items stack vertically when the container is below the threshold
- The `calc()` trick with `* 999` creates a binary switch effect
- All items share equal width when horizontal
- The limit parameter prevents too many narrow columns

### Failure Modes

- **Too many children** -- Items too narrow. Fix: Use limit parameter or reduce items.

### Best For

- Feature comparison columns
- Pricing cards
- Equal-weight content sections

### Composes With

- Stack (ELC_STACK) for content within each switched column
- Box (ELC_BOX) for bordered/padded columns

### Verification Test

> - Items should be horizontal when container exceeds threshold
> - Items should stack vertically when container is below threshold

---

## Cover (ELC_COVER)

**Cover** (`ELC_COVER`) -- Vertically centering a principal element with optional header and footer.

**Problem it solves:** Vertically centering a principal element with optional header and footer

Tags: `alignment`, `flow`

Sources: Chapter `ch_16`, Window `w01`

HTML expectations: Container with principal element and optional header/footer

Related principles: `ELP_008`

### CSS Recipe

```css
.cover { display: flex; flex-direction: column; min-block-size: 100vh; padding: var(--s1) }
.cover > * { margin-block: var(--s1) }
.cover > :first-child:not(.principal) { margin-block-start: 0 }
.cover > :last-child:not(.principal) { margin-block-end: 0 }
.cover > .principal { margin-block: auto }
```

### Custom Properties

| Property | Default | Purpose |
|----------|---------|---------|
| `centered` | `h1` | Selector for principal element |
| `space` | `var(--s1)` | Minimum space around elements |
| `minHeight` | `100vh` | Minimum Cover height |
| `noPad` | `false` | Remove padding |

### Key Behavior

- The principal element is vertically centered via `margin-block: auto`
- Header (first child) is pushed to the top
- Footer (last child) is pushed to the bottom
- Minimum height ensures the cover fills at least the viewport
- Padding provides internal spacing when `noPad` is not set

### Failure Modes

- **Principal not identified** -- No centering. Fix: Add principal class/selector.

### Best For

- Hero sections
- Landing page headers
- Full-viewport introductions

### Composes With

- Center (ELC_CENTER) for horizontally centered principal content
- Stack (ELC_STACK) for spaced content within the cover

### Verification Test

> - Principal element should be vertically centered
> - Cover should be at least 100vh tall

---

## Grid (ELC_GRID)

**Grid** (`ELC_GRID`) -- Responsive grid of equal-width items without media queries.

**Problem it solves:** Responsive grid of equal-width items without media queries

Tags: `responsiveness`, `intrinsic-sizing`

Sources: Chapter `ch_17`, Window `w01`

HTML expectations: Container with multiple similar items (cards, products)

Related principles: `ELP_009`, `ELP_012`, `ELP_021`

### CSS Recipe

```css
.grid { display: grid; gap: var(--s1); grid-template-columns: repeat(auto-fit, minmax(min(var(--min, 15rem), 100%), 1fr)) }
```

### Custom Properties

| Property | Default | Purpose |
|----------|---------|---------|
| `min` | `15rem` | Minimum column width |
| `space` | `var(--s1)` | Gap between grid items |

### Key Behavior

- Columns are created automatically based on available space
- Each column has a minimum width; columns wrap when space is insufficient
- The `min()` function with `100%` prevents overflow on narrow containers
- All columns share equal width within each row
- No media queries are needed; the grid is entirely intrinsic

### Failure Modes

- **Items too wide** -- Horizontal overflow. Fix: Use `min()` with 100% fallback.
- **No min width** -- Items collapse. Fix: Set minimum column width.

### Best For

- Product grids
- Card layouts
- Image galleries
- Dashboard widgets

### Composes With

- Box (ELC_BOX) for bordered grid items
- Stack (ELC_STACK) for content within grid cells
- Frame (ELC_FRAME) for aspect-ratio-constrained media in grid items

### Verification Test

> - Grid should create more columns when container is wider
> - All columns should have equal width

---

## Frame (ELC_FRAME)

**Frame** (`ELC_FRAME`) -- Constraining media to a specific aspect ratio with cropping.

**Problem it solves:** Constraining media to a specific aspect ratio with cropping

Tags: `containment`

Sources: Chapter `ch_18`, Window `w01`

HTML expectations: Container with single media element (img or video)

Related principles: `ELP_015`

### CSS Recipe

```css
.frame { aspect-ratio: var(--n, 16) / var(--d, 9); overflow: hidden; display: flex; justify-content: center; align-items: center }
.frame > img, .frame > video { inline-size: 100%; block-size: 100%; object-fit: cover }
```

### Custom Properties

| Property | Default | Purpose |
|----------|---------|---------|
| `ratio` | `16:9` | Aspect ratio as width:height |

### Key Behavior

- Maintains a fixed aspect ratio regardless of content dimensions
- Media is cropped (not distorted) via `object-fit: cover`
- Overflow is hidden to enforce the frame boundary
- Flexbox centering ensures the focal point of the media stays centered
- Works with both images and videos

### Failure Modes

- **No object-fit** -- Image distorted. Fix: Add `object-fit: cover`.
- **Multiple children** -- Unexpected layout. Fix: Use single child.

### Best For

- Thumbnail images
- Video embeds
- Hero images with fixed proportions

### Composes With

- Grid (ELC_GRID) for grids of framed media
- Reel (ELC_REEL) for horizontally scrolling framed items

### Verification Test

> - Frame should maintain specified aspect ratio regardless of content
> - Media should fill frame without distortion

---

## Reel (ELC_REEL)

**Reel** (`ELC_REEL`) -- Horizontal scrolling container for browsing items.

**Problem it solves:** Horizontal scrolling container for browsing items

Tags: `flow`, `containment`

Sources: Chapter `ch_19`, Window `w01`

HTML expectations: Container with multiple items (cards, images, links)

Related principles: `ELP_015`

### CSS Recipe

```css
.reel { display: flex; block-size: var(--height, auto); overflow-x: auto; overflow-y: hidden }
.reel > * { flex: 0 0 var(--item-width, auto) }
.reel > * + * { margin-inline-start: var(--space, 1rem) }
```

### Custom Properties

| Property | Default | Purpose |
|----------|---------|---------|
| `itemWidth` | `auto` | Width of each item |
| `space` | `var(--s0)` | Space between items |
| `height` | `auto` | Reel height |
| `noBar` | `false` | Hide scrollbar |

### Key Behavior

- Items scroll horizontally when they overflow the container
- Each item has `flex-shrink: 0` to prevent compression
- Overflow is contained to the reel; the page does not scroll horizontally
- Scrollbar can be hidden for a cleaner appearance
- Item width can be fixed or intrinsic

### Failure Modes

- **Items shrink** -- No overflow. Fix: Add `flex-shrink: 0`.
- **Page scrolls** -- Bad UX. Fix: Contain overflow on Reel.

### Best For

- Image carousels
- Horizontal card browsing
- Timeline displays
- Data tables (via EDC_DATATABLE composition)

### Composes With

- Frame (ELC_FRAME) for aspect-ratio items within the reel
- Box (ELC_BOX) for padded reel items

### Verification Test

> - Items should scroll horizontally when overflowing
> - Page should not scroll horizontally due to Reel

---

## Imposter (ELC_IMPOSTER)

**Imposter** (`ELC_IMPOSTER`) -- Positioning an element centrally over other content.

**Problem it solves:** Positioning an element centrally over other content

Tags: `alignment`, `containment`

Sources: Chapter `ch_20`, Window `w01`

HTML expectations: Element inside a position: relative container

Related principles: (none)

### CSS Recipe

```css
.imposter { position: var(--positioning, absolute); inset-block-start: 50%; inset-inline-start: 50%; transform: translate(-50%, -50%) }
.imposter.contain { overflow: auto; max-inline-size: calc(100% - (var(--margin) * 2)); max-block-size: calc(100% - (var(--margin) * 2)) }
```

### Custom Properties

| Property | Default | Purpose |
|----------|---------|---------|
| `breakout` | `false` | Allow element to exceed container |
| `margin` | `0` | Gap between element and container edges |
| `fixed` | `false` | Position relative to viewport |

### Key Behavior

- Centered over its positioning context using `translate(-50%, -50%)`
- Uses `inset-block-start` and `inset-inline-start` for logical positioning
- Contain mode adds max dimensions and overflow handling to prevent content from exceeding the container
- Fixed mode positions relative to the viewport instead of the nearest positioned ancestor
- Margin parameter creates a gap between the imposter and container edges

### Failure Modes

- **No positioning context** -- Positioned to document. Fix: Add `position: relative` to ancestor.
- **Content overflows** -- Obscures other content. Fix: Use contain mode.

### Best For

- Modals and dialogs
- Tooltips
- Overlay notifications
- Lightbox overlays

### Composes With

- Box (ELC_BOX) for padded overlay content
- Stack (ELC_STACK) for structured content within the overlay
- Cover (ELC_COVER) as a full-viewport overlay backdrop

### Verification Test

> - Imposter should be centered over its positioning container
> - Imposter should not exceed container when contained

---

## Icon (ELC_ICON)

**Icon** (`ELC_ICON`) -- Inline SVG icons that scale and align with text.

**Problem it solves:** Inline SVG icons that scale and align with text

Tags: `alignment`, `accessibility`

Sources: Chapter `ch_21`, Window `w01`

HTML expectations: Inline SVG element, optionally with accompanying text

Related principles: `ELP_015`, `ELP_024`

### CSS Recipe

```css
.icon { height: 0.75em; height: 1cap; width: 0.75em; width: 1cap }
.with-icon { display: inline-flex; align-items: baseline }
.with-icon .icon { margin-inline-end: var(--space, 0.5em) }
```

### Custom Properties

| Property | Default | Purpose |
|----------|---------|---------|
| `space` | `null` | Gap between icon and text |
| `label` | `null` | Accessible label for icon |

### Key Behavior

- Icon scales proportionally with the surrounding font-size using `em`/`cap` units
- The `1cap` unit (with `0.75em` fallback) aligns the icon to the capital letter height
- `inline-flex` with `baseline` alignment ensures text and icon share the same baseline
- Icon color inherits from the surrounding text color via `currentColor`
- Accessible label should be provided when the icon conveys meaning

### Failure Modes

- **No accessible label** -- Screen readers ignore. Fix: Add `aria-label` or visible text.
- **Icon doesn't scale** -- Fixed size. Fix: Use em-based sizing.

### Best For

- Button icons
- Navigation icons
- Status indicators
- Inline decorative elements

### Composes With

- Cluster (ELC_CLUSTER) for icon + text groups in a row
- Stack (ELC_STACK) for vertically listed icon + text items

### Verification Test

> - Icon should scale proportionally with font-size
> - Icon color should match surrounding text color

---

## Container (ELC_CONTAINER)

**Container** (`ELC_CONTAINER`) -- Establishing container query context for responsive components.

**Problem it solves:** Establishing container query context for responsive components

Tags: `responsiveness`, `containment`

Sources: Chapter `ch_22`, Window `w01`

HTML expectations: Any element that should serve as query target

Related principles: `ELP_013`, `ELP_014`, `ELP_019`, `ELP_020`

### CSS Recipe

```css
.container { container-type: inline-size }
.container[data-name] { container: var(--name) / inline-size }
```

### Custom Properties

| Property | Default | Purpose |
|----------|---------|---------|
| `name` | `null` | Named container identifier |

### Key Behavior

- Establishes a containment context for descendant container queries
- Descendants can use `@container` rules to respond to this element's width
- Named containers allow targeting a specific ancestor from any depth
- Should be used only when intrinsic layouts (Sidebar, Switcher, Grid) are insufficient
- Adds inline-size containment, which may affect layout in some edge cases

### Failure Modes

- **Used unnecessarily** -- Extra complexity. Fix: Prefer intrinsic layouts first.

### Best For

- Components that need to adapt based on their container, not the viewport
- Widget-style components embedded in varying contexts
- When Sidebar/Switcher/Grid cannot achieve the required responsive behavior

### Composes With

- Grid (ELC_GRID) for container-aware grid layouts
- Switcher (ELC_SWITCHER) for container-aware switching
- Sidebar (ELC_SIDEBAR) for container-aware sidebar behavior

### Verification Test

> - Container query should respond to container width, not viewport
> - Named container should be queryable from any descendant
