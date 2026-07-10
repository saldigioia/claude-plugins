# Motion Allowlist

The narrow set of acceptable transitions and animations within Every Layout's motion safety framework (ELP_028). This turns the principle from a restriction into a recipe.

---

## Core Rule

All motion must be gated:

```css
@media (prefers-reduced-motion: no-preference) {
  /* motion declarations go here */
}
```

No exceptions. Users who prefer reduced motion see zero motion.

---

## Allowed Properties

Only these CSS properties may be transitioned or animated:

| Property | Reason | Typical use |
|----------|--------|-------------|
| `opacity` | Composited (GPU), no layout recalc | Fade in/out, hover reveals |
| `transform` | Composited (GPU), no layout recalc | Subtle scale, translate, rotate |
| `color` | Paint-only, cheap | Hover state color shifts |
| `background-color` | Paint-only, cheap | Button hover, active states |
| `outline-color` | Paint-only | Focus ring transitions |
| `box-shadow` | Paint-only (if no spread change) | Elevation changes on hover |

### Forbidden Properties

These trigger layout recalculation and must never be transitioned:

| Property | Why forbidden |
|----------|---------------|
| `width` / `height` / `inline-size` / `block-size` | Forces layout recalc of all siblings |
| `margin` / `padding` | Forces layout recalc |
| `top` / `left` / `inset-*` | Forces layout recalc (use `transform` instead) |
| `font-size` | Forces text relayout |
| `grid-*` / `flex-*` | Forces layout recalc |
| `all` | Transitions every property — unpredictable, includes layout properties |

**`transition: all` is always an error.** The hook flags it.

---

## Allowed Durations

| Context | Duration | Easing |
|---------|----------|--------|
| Hover/focus state change | 150ms | `ease-out` |
| Content appearing | 200ms | `ease-out` |
| Content disappearing | 150ms | `ease-in` |
| Page transition (View Transitions API) | 250ms | `ease-in-out` |
| Maximum for any transition | 300ms | — |

Durations longer than 300ms feel sluggish and fail users with cognitive disabilities who find sustained motion distracting.

---

## Reduced Motion Reset

Every project must include this global reset:

```css
@media (prefers-reduced-motion: reduce) {
  *,
  *::before,
  *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
    scroll-behavior: auto !important;
  }
}
```

Use `0.01ms`, not `0s`. A zero duration can prevent `animationend` and `transitionend` events from firing, breaking JavaScript that depends on them.

---

## Allowed Patterns

### 1. Hover Opacity

```css
@media (prefers-reduced-motion: no-preference) {
  .card {
    transition: opacity 150ms ease-out;
  }
  .card:hover {
    opacity: 0.8;
  }
}
```

### 2. Focus Ring Transition

```css
@media (prefers-reduced-motion: no-preference) {
  :focus-visible {
    transition: outline-color 150ms ease-out;
    outline: 3px solid var(--color-accent);
    outline-offset: 2px;
  }
}
```

### 3. Button Scale on Press

```css
@media (prefers-reduced-motion: no-preference) {
  button {
    transition: transform 150ms ease-out;
  }
  button:active {
    transform: scale(0.97);
  }
}
```

### 4. Fade-In for Lazy-Loaded Content

```css
@media (prefers-reduced-motion: no-preference) {
  [data-loaded] {
    animation: fade-in 200ms ease-out;
  }
  @keyframes fade-in {
    from { opacity: 0; }
    to { opacity: 1; }
  }
}
```

---

## Forbidden Patterns

| Pattern | Why | Alternative |
|---------|-----|------------|
| `transition: all` | Transitions layout properties | List specific properties |
| Scroll-jacking (`wheel` event override) | Violates ELP_010 (browser delegation) | Native scroll + optional `scroll-snap` |
| Parallax scrolling | Triggers motion sickness, layout-heavy | Static backgrounds |
| Auto-playing carousels | WCAG 2.2.2 failure | User-initiated Reel scroll |
| Infinite looping animations | Distracting, inaccessible | Single-run with `animation-iteration-count: 1`; status/progress indication is the sole exception (see below) |
| Animated counters / number tickers | Distracting, content inaccessible during animation | Show final value immediately |
| Page-entry animations longer than 300ms | Blocks perceived interactivity | Keep under 200ms |
| `@scroll-timeline` without motion gate | New API, easy to forget the gate | Always wrap in `prefers-reduced-motion: no-preference` |

---

## The Infinite-Motion Rule

`animation-iteration-count: infinite` is allowed **only when the animation indicates status or progress** — a loading spinner, an indeterminate progress pulse, a live-recording dot. There, perpetual motion *is* the information: it says "still working."

**Decorative infinite motion is a violation even under `prefers-reduced-motion: no-preference`.** A bouncing hero badge or a perpetually flipping headline word is not gated content — it is a permanent attention tax on every user who did not opt out, and `no-preference` is the browser default, not an opt-in. The field case that produced this rule: a hero ran two perpetual animations (a word-flip and a bounce) through every review because the reduced-motion gate was present and nothing asked *what* was looping forever.

Mark the legitimate exception with an adjacent comment so the lint tier can tell status from decoration:

```css
@media (prefers-reduced-motion: no-preference) {
  .loading-spinner {
    /* motion: status */
    animation: spin 1s linear infinite;
  }
}
```

`bin/css-lint-hook.sh` warns on any `animation … infinite` without a `/* motion: status */` marker on the same or the preceding line. The marker is a claim reviewers can audit: if the animation does not report system status or progress, the marker is a lie and the animation goes.

Status animations still obey every other rule on this page: allowlisted properties only, reduced-motion gated, and they stop when the status resolves.

---

## Quick Reference

```
Allowed: opacity, transform, color, background-color, outline-color, box-shadow
Duration: 150ms-300ms max
Easing: ease-out (enter), ease-in (exit)
Gate: ALWAYS @media (prefers-reduced-motion: no-preference)
Reset: ALWAYS 0.01ms global reset in prefers-reduced-motion: reduce
Forbidden: transition: all, layout properties, scroll-jacking, parallax, auto-play
Infinite: status/progress indication ONLY, marked /* motion: status */
```

---

## Watch-tier motion features

Two emerging capabilities interact with this allowlist; their adoption status
lives in `css-layout-engine/references/baseline-registry.md` (both currently
escape-gated / watch):

- **Scroll-driven animations** (`animation-timeline: scroll()/view()`) — when
  they reach Baseline they still animate ONLY allowlisted properties
  (opacity/transform), remain inside `@media (prefers-reduced-motion:
  no-preference)` (ELP_028), and no layout may depend on them (ELA_001).
- **`interpolate-size` / `calc-size()`** — makes `block-size: auto` a legal
  transition endpoint (the details/accordion case in
  `native-interaction.md`). Note it does NOT make the transition cheap: the
  layout recalc cost is why block-size stays off the allowlist; any use is a
  documented exception, `@supports`-gated, reduced-motion-gated.
