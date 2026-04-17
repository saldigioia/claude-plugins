# Cookbook — Anti-Patterns

# Anti-Pattern: Fixed Widths

## The Problem

Using fixed pixel widths for layouts causes overflow and content truncation on varying viewport sizes.

## Bad Example

```css
/* DON'T DO THIS */
.card {
  width: 300px;
}

.sidebar {
  width: 250px;
}

.container {
  width: 1200px;
}
```

## Why It's Bad

1. **Overflow on small screens**: Fixed widths don't adapt
2. **Wasted space on large screens**: Content doesn't expand
3. **Brittle with varying content**: Text may overflow or truncate
4. **Requires media queries**: Must manually adjust at breakpoints

## The Fix

Use intrinsic sizing with Every Layout primitives:

### Instead of Fixed Card Width

```html
<!-- Grid handles width automatically -->
<div class="grid" style="--min: 15rem">
  <div class="card">...</div>
  <div class="card">...</div>
</div>
```

### Instead of Fixed Sidebar Width

```html
<!-- Sidebar handles width and switching -->
<div class="with-sidebar" style="--side-width: 15rem; --content-min: 60%">
  <aside>Sidebar</aside>
  <main>Content</main>
</div>
```

### Instead of Fixed Container Width

```html
<!-- Center constrains with max-width, not width -->
<div class="center" style="--measure: 65ch">
  <p>Content that doesn't overflow</p>
</div>
```

## Legitimate Uses

Fixed widths are acceptable for:
- Icons: `width: 1.5rem`
- Avatars: `width: 3rem`
- Logos: `width: 120px` (with max-width: 100%)

Even then, consider using `max-width` or responsive units.

## Related Principles

- **ELP_002**: Intrinsic Sizing Over Extrinsic Sizing
- **ELP_009**: Algorithmic Self-Governing Layout

## Verification

Check your layout at:
- 320px viewport width
- 1920px viewport width
- With 2x zoomed text
- With very long content strings

---

# Anti-Pattern: Icon-Only Buttons Without Labels

## The Problem

Using icons as the sole affordance for interactive controls — no visible text label, no accessible name, or a tooltip that's inaccessible to keyboard/touch users.

## Bad Example

```html
<!-- DON'T DO THIS -->
<button>
  <svg viewBox="0 0 24 24"><!-- gear icon --></svg>
</button>

<button title="Settings">
  <svg viewBox="0 0 24 24"><!-- gear icon --></svg>
</button>

<button>
  <i class="fa fa-trash"></i>
</button>
```

## Why It's Bad

1. **Accessibility violation (ELP_015)**: Screen readers announce "button" with no label. `title` is not reliably exposed to assistive technology
2. **Cognitive load**: Icons are ambiguous — a gear could mean Settings, Preferences, Admin, Configuration, or Tools. Without text, users guess
3. **Touch target ambiguity**: On mobile, small icon-only buttons are hard to tap and easy to confuse with adjacent icons
4. **Internationalization**: Icons don't translate — a mailbox icon means nothing in cultures without mailboxes. Text labels are translatable
5. **Discoverability**: Icon-only toolbars require learned conventions. New users can't discover functionality

## The Fix

### Always Provide a Visible Text Label

The best icon button has both an icon and a visible label:

```html
<button class="cluster" style="--space: 0.5em">
  <svg class="icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
    <!-- gear icon paths -->
  </svg>
  Settings
</button>
```

Note: the icon has `aria-hidden="true"` because the text provides the label. The Icon primitive (ELC_ICON) handles sizing via `.icon` + `.with-icon`.

### If Space Genuinely Prevents a Visible Label

Use `aria-label` as a last resort, and ensure a tooltip is keyboard-accessible:

```html
<button aria-label="Settings" class="icon-button">
  <svg class="icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
    <!-- gear icon paths -->
  </svg>
</button>
```

```css
.icon-button {
  position: relative;
  padding: var(--s-1);
  min-inline-size: 44px; /* WCAG 2.5.8 target size */
  min-block-size: 44px;
}
```

> **Warning**: `aria-label` is invisible to sighted users. It also doesn't translate with page translation tools. Always prefer a visible label.

### Icon Sizing with the Icon Primitive

Use the Icon primitive (ELC_ICON) to ensure icons scale with text:

```html
<button class="with-icon">
  <svg class="icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
    <!-- icon paths -->
  </svg>
  Delete item
</button>
```

The `.icon` class sizes the SVG to `1cap` (with `0.75em` fallback), keeping it aligned with the text baseline.

## Minimum Requirements for Any Icon Button

| Requirement | How |
|-------------|-----|
| Accessible name | Visible text label (preferred) or `aria-label` |
| Icon `aria-hidden="true"` | Prevents duplicate announcements |
| `focusable="false"` on SVG | Prevents SVG receiving focus in IE/Edge legacy |
| Touch target ≥ 44×44px | `min-inline-size: 44px; min-block-size: 44px` (WCAG 2.5.8) |
| Focus visibility (ELP_029) | `:focus-visible` outline on the button, not the icon |

## Related Principles

- **ELP_015**: Accessible Icons — icons are decorative; text provides meaning
- **ELP_024**: Typography-Relative Icon Sizing — icons scale with text via `cap`/`em`
- **ELP_029**: Focus Visibility — focus ring on the interactive element

## Verification

1. Tab to the button — is the focus ring visible and appropriately sized?
2. Activate screen reader — does it announce a meaningful label?
3. Remove CSS — is the button text still readable?
4. Zoom to 200% — is the button still tappable without overlapping neighbors?
5. Test touch target with a 44×44px overlay — does the button meet minimum size?

---

# Anti-Pattern: Infinite Scroll Without Escape

## The Problem

Implementing infinite scroll (or "load more" that replaces pagination) as the only navigation mechanism for large content lists, without providing an accessible alternative.

## Bad Example

```js
/* DON'T DO THIS */
window.addEventListener('scroll', () => {
  if (nearBottom()) {
    loadMoreItems(); // Appends to DOM endlessly
  }
});
```

```html
<!-- No pagination, no landmarks, no "end" -->
<div class="feed" id="feed">
  <!-- Items appended by JavaScript, forever -->
</div>
<footer>
  <!-- User can never reach this -->
</footer>
```

## Why It's Bad

1. **Footer and below-fold content is unreachable**: If new items load before the user reaches the bottom, the footer, legal links, contact info, and other content are effectively hidden
2. **Keyboard trap**: Screen reader and keyboard users have no way to skip past the infinite list to reach other page landmarks
3. **No bookmarkable position**: The user's position in the list is not reflected in the URL — refreshing the page resets to the top
4. **Memory exhaustion**: Continuously appending DOM nodes without virtualisation causes performance degradation and eventual crashes
5. **Violates progressive enhancement (ELP_027)**: Without JavaScript, there is no content at all — no `<noscript>` fallback, no server-rendered list
6. **Scroll jacking adjacent**: Many infinite scroll implementations override native scroll timing or add loading spinners that disrupt scroll momentum

## The Fix

### Paginated Navigation (Preferred)

Server-rendered pagination with proper URLs:

```html
<div class="stack">
  <ul class="grid" style="--min: 20rem" role="list">
    <li class="box">Item 1</li>
    <li class="box">Item 2</li>
    <!-- 20 items per page -->
  </ul>

  <nav aria-label="Pagination" class="cluster" style="--justify: center">
    <a href="/items?page=1" aria-current="page">1</a>
    <a href="/items?page=2">2</a>
    <a href="/items?page=3">3</a>
    <span aria-hidden="true">...</span>
    <a href="/items?page=12">12</a>
  </nav>
</div>
```

Benefits:
- Bookmarkable URLs
- Footer always reachable
- Works without JavaScript (ELP_027)
- Screen readers can navigate by landmark

### "Load More" Button (Acceptable Compromise)

If infinite scroll is a product requirement, provide a manual trigger instead of auto-loading:

```html
<div class="stack">
  <ul class="grid" style="--min: 20rem" role="list" aria-live="polite">
    <!-- Initial items server-rendered -->
    <li class="box">Item 1</li>
    <!-- ... -->
  </ul>

  <button type="button" class="load-more">
    Load more items
    <span class="visually-hidden">(currently showing 20 of 240)</span>
  </button>
</div>

<footer>
  <!-- Always reachable -->
</footer>
```

Key requirements:
- **`aria-live="polite"`** on the list so screen readers announce new items
- **Visible count** of items shown vs. total
- **Footer remains reachable** — the button is between the list and the footer, not an auto-trigger
- **URL state**: Update `history.pushState` so the position is bookmarkable

### If Auto-Loading Is Unavoidable

Gate it with intersection observer (not scroll events) and add an escape hatch:

```html
<nav aria-label="Skip infinite feed" class="visually-hidden-focusable">
  <a href="#after-feed">Skip to footer</a>
</nav>

<div class="feed stack" role="feed" aria-busy="false">
  <!-- Items -->
</div>

<div id="after-feed"></div>
<footer><!-- Content --></footer>
```

```css
.visually-hidden-focusable {
  position: absolute;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  inline-size: 1px;
  block-size: 1px;
  margin: -1px;
  padding: 0;
  border: 0;
}

.visually-hidden-focusable:focus-within {
  position: static;
  overflow: visible;
  clip: auto;
  inline-size: auto;
  block-size: auto;
  margin: 0;
}
```

## Related Principles

- **ELP_027**: Progressive Enhancement — pagination must work without JS
- **ELP_010**: Browser Delegation — don't override scroll events
- **ELP_028**: Motion Safety — loading spinners and skeleton screens should respect `prefers-reduced-motion`

## Verification

1. Disable JavaScript — is any content visible?
2. Tab through the page with keyboard — can you reach the footer?
3. Use a screen reader — are new items announced? Can you skip past the list?
4. Copy the URL mid-scroll — does pasting it return you to the same position?
5. Load 500+ items — does the page remain responsive?

---

# Anti-Pattern: Media Query Abuse

## The Problem

Using media queries as the primary mechanism for responsive layouts when intrinsic solutions exist.

## Bad Example

```css
/* DON'T DO THIS */
.cards {
  display: flex;
  flex-wrap: wrap;
}

.card {
  width: 100%;
}

@media (min-width: 600px) {
  .card {
    width: 50%;
  }
}

@media (min-width: 900px) {
  .card {
    width: 33.333%;
  }
}

@media (min-width: 1200px) {
  .card {
    width: 25%;
  }
}
```

## Why It's Bad

1. **Viewport ≠ Component width**: Media queries know viewport, not container
2. **Arbitrary breakpoints**: Magic numbers like 600px don't relate to content
3. **Maintenance burden**: More breakpoints = more code to maintain
4. **Doesn't compose**: Breakpoints don't adapt when component is reused
5. **Poor DX**: Requires mental mapping between viewport and layout

## The Fix

Use intrinsic layouts that self-govern:

### Grid (Responsive Cards)

```html
<!-- Automatic column count based on available space -->
<div class="grid" style="--min: 15rem">
  <div>Card 1</div>
  <div>Card 2</div>
  <div>Card 3</div>
  <div>Card 4</div>
</div>
```

### Switcher (Column Switch)

```html
<!-- Switches from horizontal to vertical at threshold -->
<div class="switcher" style="--threshold: 30rem">
  <div>Column 1</div>
  <div>Column 2</div>
  <div>Column 3</div>
</div>
```

### Sidebar (Two-Column Switch)

```html
<!-- Intrinsic switching based on content needs -->
<div class="with-sidebar" style="--side-width: 15rem; --content-min: 50%">
  <aside>Sidebar</aside>
  <main>Content</main>
</div>
```

## When Media Queries Are Appropriate

Media queries are fine for:
- **Global adjustments**: Base font size for different devices
- **Print styles**: `@media print`
- **Preference queries**: `prefers-color-scheme`, `prefers-reduced-motion`
- **Device-specific**: Landscape/portrait orientation

## The Container Query Alternative

If you need breakpoints, container queries are better than media queries:

```css
.container {
  container-type: inline-size;
}

@container (min-width: 30rem) {
  .card {
    flex-direction: row;
  }
}
```

But prefer intrinsic layouts first.

## Related Principles

- **ELP_009**: Algorithmic Self-Governing Layout
- **ELP_013**: Container Queries Over Media Queries
- **ELP_014**: Intrinsic Layout First

## Verification

Your layout should work without any media queries. Test by:
1. Removing all `@media` rules
2. Resizing the browser window
3. Moving component to different containers

---

# Anti-Pattern: Over-Animation

## The Problem

Adding animations and transitions to every element — page load sequences, hover effects on all cards, scroll-triggered reveals on every section, bouncing buttons, sliding navs.

## Bad Example

```css
/* DON'T DO THIS */
* {
  transition: all 0.3s ease;
}

.card {
  animation: fadeInUp 0.6s ease forwards;
}

.card:nth-child(1) { animation-delay: 0.1s; }
.card:nth-child(2) { animation-delay: 0.2s; }
.card:nth-child(3) { animation-delay: 0.3s; }
.card:nth-child(4) { animation-delay: 0.4s; }
/* etc., staggered delays on every card */

.button:hover {
  transform: scale(1.1) rotate(2deg);
  box-shadow: 0 10px 40px rgba(0,0,0,0.3);
}

nav a {
  transition: color 0.3s, background 0.3s, transform 0.3s, box-shadow 0.3s;
}
```

## Why It's Bad

1. **Motion safety violation (ELP_028)**: Vestibular disorders affect ~35% of adults over 40. Constant motion causes dizziness, nausea, and disorientation
2. **Performance**: `transition: all` triggers layout and paint on every property change. Staggered animations multiply this cost
3. **Cognitive overload**: When everything moves, nothing is important — animation loses its communicative value
4. **Delayed content access**: Staggered load animations force users to wait to read content that already exists in the DOM
5. **`prefers-reduced-motion` ignored**: Most over-animated sites don't check the preference at all

## The Fix

### Animate Purposefully, Not Decoratively

Only animate when the motion communicates something:

| Purpose | Example | Acceptable |
|---------|---------|-----------|
| State change feedback | Button press, toggle switch | Yes |
| Spatial relationship | Sidebar sliding in/out | Yes |
| Attention direction | New notification badge | Yes, sparingly |
| "Wow factor" | Staggered card entrance | No |
| "Polish" | Hover scale on every element | No |

### Respect Motion Preferences

Every animation must be gated:

```css
/* Default: no animation */
.modal {
  display: block;
}

/* Animation only for users who haven't opted out */
@media (prefers-reduced-motion: no-preference) {
  .modal[open] {
    animation: slide-up 200ms ease;
  }
}

@keyframes slide-up {
  from { translate: 0 0.5rem; opacity: 0; }
}
```

### Use Transitions, Not Animations, for Hover States

Subtle, short transitions on `:hover` and `:focus-visible` are acceptable — but keep them fast and specific:

```css
.button {
  /* Only transition what changes */
  transition: background-color 150ms ease;
}

@media (prefers-reduced-motion: reduce) {
  .button {
    transition: none;
  }
}
```

### Never Animate Layout Properties

If you must animate, stick to `transform` and `opacity` — never `width`, `height`, `margin`, `padding`, or `top`/`left`.

## Legitimate Uses

- **Loading indicators**: Spinner or skeleton screen (inherently communicative)
- **Focus ring transitions**: Subtle outline-offset animation for `:focus-visible`
- **Scroll-driven reveals**: Via CSS `animation-timeline`, gated by `prefers-reduced-motion`

## Related Principles

- **ELP_028**: Motion Safety — `prefers-reduced-motion` is not optional
- **ELP_010**: Browser Delegation — the browser handles scroll, transitions, and painting more efficiently than JS
- **ELP_027**: Progressive Enhancement — content works without animation; motion is an enhancement

## Verification

1. Enable `prefers-reduced-motion: reduce` in your OS or browser dev tools
2. Reload the page — **zero** animations should play
3. Navigate with keyboard — focus movement should not trigger distracting effects
4. Run Lighthouse — check for layout shift caused by animations

---

# Anti-Pattern: Scroll Jacking

## The Problem

Overriding native scroll behavior with JavaScript to create custom scroll effects (parallax, scroll-driven animations that hijack momentum, snapping every section to the viewport).

## Bad Example

```js
/* DON'T DO THIS */
window.addEventListener('scroll', (e) => {
  e.preventDefault();
  // Custom scroll physics, momentum override
  smoothScrollTo(calculateSection(window.scrollY));
});
```

```css
/* DON'T DO THIS */
html {
  overflow: hidden; /* Disable native scroll */
}

.scroll-container {
  height: 100vh;
  overflow-y: scroll;
  scroll-snap-type: y mandatory; /* Force snap on EVERY section */
}

.scroll-container > section {
  height: 100vh;
  scroll-snap-align: start;
}
```

## Why It's Bad

1. **Breaks browser delegation (ELP_010)**: The browser's scroll implementation handles momentum, accessibility, touch, trackpad, keyboard, and assistive technology. Overriding it means reimplementing (and breaking) all of these
2. **Motion safety violation (ELP_028)**: Custom scroll effects often ignore `prefers-reduced-motion` and cause vestibular discomfort
3. **Keyboard and AT breakage**: Custom scroll containers lose `Page Up`/`Page Down`, `Space`, `Home`/`End`, screen reader virtual cursor, and switch control scanning
4. **Touch inconsistency**: Custom momentum never matches the device's native feel — it always feels "wrong"
5. **Performance**: JS-driven scroll handlers cause jank, especially on mobile

## The Fix

### Let the Browser Scroll

Remove scroll overrides entirely. Content flows naturally:

```html
<div class="stack" style="--space: var(--s3)">
  <section><!-- Section 1 --></section>
  <section><!-- Section 2 --></section>
  <section><!-- Section 3 --></section>
</div>
```

### If You Need Scroll Snap, Use It Sparingly

Only on horizontal Reel containers (ELP_031), and only with `proximity`:

```html
<div class="reel" data-snap="proximity">
  <div class="box">Slide 1</div>
  <div class="box">Slide 2</div>
  <div class="box">Slide 3</div>
</div>
```

### Scroll-Driven Animations (If Truly Needed)

Use native CSS `animation-timeline: scroll()` — it respects `prefers-reduced-motion` and doesn't block the main thread:

```css
@media (prefers-reduced-motion: no-preference) {
  .reveal {
    animation: fade-in linear both;
    animation-timeline: view();
    animation-range: entry 0% entry 100%;
  }

  @keyframes fade-in {
    from { opacity: 0; }
    to { opacity: 1; }
  }
}
```

## Legitimate Uses

- **Reel scroll snap** (horizontal, opt-in): `data-snap` on `.reel`
- **CSS scroll-driven animations**: With `prefers-reduced-motion` guard
- **`scroll-behavior: smooth`**: A CSS hint, not an override — the browser retains control

## Related Principles

- **ELP_010**: Browser Delegation — trust the browser's scroll implementation
- **ELP_028**: Motion Safety — all scroll effects must respect reduced motion
- **ELP_031**: Scroll Snap Enhancement — snap is progressive, not mandatory

## Verification

- Disconnect your mouse. Can you navigate all content with keyboard alone?
- Enable `prefers-reduced-motion`. Do all custom effects disappear?
- Test with a screen reader. Is all content reachable via virtual cursor?
- Test on iOS Safari, Android Chrome, and a trackpad — does scroll feel native?

---

# Anti-Pattern: Zoom Prevention

## The Problem

Preventing or breaking browser zoom through viewport meta restrictions, fixed font sizes, or layouts that overflow or collapse when zoomed.

## Bad Example

```html
<!-- DON'T DO THIS -->
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
```

```css
/* DON'T DO THIS */
html {
  font-size: 16px; /* Fixed, not scalable */
}

.sidebar {
  width: 250px; /* Overflows when zoomed */
}

.container {
  overflow: hidden; /* Hides zoomed content */
}
```

## Why It's Bad

1. **WCAG failure (1.4.4 Resize Text)**: Users must be able to zoom text to 200% without loss of content or functionality
2. **WCAG failure (1.4.10 Reflow)**: At 400% zoom (320px equivalent), content must reflow to a single column without horizontal scrolling
3. **Punishes users with low vision**: ~2.2 billion people globally have a vision impairment. Zoom is their primary tool
4. **Breaks ELP_002 (Intrinsic Sizing)**: Fixed pixel values can't adapt to zoomed viewports
5. **`user-scalable=no` is ignored** by many browsers (iOS Safari, Chrome) for accessibility reasons — so it's both harmful and ineffective

## The Fix

### Correct Viewport Meta

```html
<meta name="viewport" content="width=device-width, initial-scale=1">
<!-- That's it. No maximum-scale, no user-scalable. -->
```

### Use `rem` for Font Sizes

```css
html {
  font-size: 100%; /* Respects browser default, typically 16px */
}

h1 {
  font-size: var(--step-4, 2.44rem); /* Scales with zoom */
}

p {
  font-size: var(--step-0, 1rem);
}
```

### Use Intrinsic Layouts That Reflow

Every Layout primitives handle zoom naturally:

- **Sidebar** (ELC_SIDEBAR): wraps to single column when `--content-min` threshold is reached — zoom reduces available space, triggering the wrap
- **Switcher** (ELC_SWITCHER): stacks when container drops below `--threshold`
- **Grid** (ELC_GRID): columns collapse as `minmax()` minimum can no longer fit

```html
<!-- This grid reflows automatically at any zoom level -->
<div class="grid" style="--min: 15rem">
  <div class="box">Card 1</div>
  <div class="box">Card 2</div>
  <div class="box">Card 3</div>
</div>
```

### Fluid Typography Handles Zoom

The fluid type scale (`implementations/vanilla/fluid-type.css`) uses `clamp()` with `rem` + `vw` units. Because `rem` scales with zoom, the minimum value of `clamp()` activates at higher zoom levels, preventing text from becoming unusably large:

```css
/* At 200% zoom, --step-0 resolves closer to the 1rem minimum */
--step-0: clamp(1.00rem, calc(0.96rem + 0.22vw), 1.25rem);
```

## Common Zoom-Hostile Patterns

| Pattern | Problem | Fix |
|---------|---------|-----|
| `user-scalable=no` | Disables pinch zoom | Remove from viewport meta |
| `font-size: 14px` | Doesn't scale with zoom | Use `rem` |
| `width: 300px` on containers | Overflows at zoom | Use `max-inline-size` or intrinsic primitives |
| `overflow: hidden` on body/main | Clips zoomed content | Use `overflow: visible` or `auto` |
| `position: fixed` navbars | Consume screen space at zoom | Consider `position: sticky` or collapsible nav |
| `vh` for heights | Doesn't account for zoom | Use `min-block-size` with flexible units |

## Related Principles

- **ELP_002**: Intrinsic Sizing — content determines dimensions, not fixed values
- **ELP_009**: Algorithmic Layout — primitives reflow algorithmically at any zoom level
- **ELP_026**: Accessibility-Safe Fluid Values — `clamp()` minimum is a `rem` value that zooms correctly

## Verification

1. Set browser zoom to 200% — all text readable, no content lost?
2. Set browser zoom to 400% — content reflows to single column, no horizontal scroll?
3. Pinch-zoom on mobile — zoom works?
4. Check viewport meta — no `maximum-scale` or `user-scalable`?
5. Search CSS for `px` font sizes — should find none (except borders and shadows)
