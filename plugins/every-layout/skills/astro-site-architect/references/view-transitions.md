# Cross-Document View Transitions — The Zero-JS Alternative

`<ClientRouter />` buys smooth page transitions for ~3 KB of JavaScript (see
`SKILL.md` → "View Transitions" and `references/performance.md`). Modern CSS
has a native, zero-JS route to the same effect for plain MPA navigation:
cross-document view transitions, opted into with a single at-rule. This
reference covers the pattern, when to reach for it instead of the router,
and how to keep it archival-grade under **ELA_006**.

---

## 1. The Zero-JS Pattern

Cross-document view transitions activate with one declaration, present in the
global CSS of **both** the departure and arrival documents:

```css
/* src/styles/global.css — applies to every static page */
@view-transition {
  navigation: auto;
}
```

That's the entire opt-in. No island, no `client:*` directive, no script tag —
this is markup-adjacent CSS, fully within **ELA_005** (CSS-Dominant
Composition). The browser snapshots the outgoing document, snapshots the
incoming one, and cross-fades between them automatically.

### Naming persisting elements

Elements that should visually morph across the navigation (not just
cross-fade) need a shared `view-transition-name` on both pages. A site
header is the canonical case — it exists on every route, so give it a stable
identity:

```css
/* global.css — matches the Cover shell's header on every page (ELC_COVER) */
header {
  view-transition-name: site-header;
}
```

`view-transition-name` must be unique per element **on a given page** — if a
list renders many cards, derive the name per item (e.g. from a data
attribute selector), never hardcode the same name twice on one document.

### Styling the transition pseudo-elements

The browser exposes `::view-transition-old()` and `::view-transition-new()`
(plus the unnamed root pair) for customizing the cross-fade. Only
motion-allowlist properties may be touched here — this is not a special case,
it is the same rule that governs every other transition in this system (see
`css-design-system/references/motion-allowlist.md`):

```css
@media (prefers-reduced-motion: no-preference) {
  ::view-transition-old(root),
  ::view-transition-new(root) {
    animation-duration: 250ms;
    animation-timing-function: ease-in-out;
  }

  ::view-transition-old(site-header),
  ::view-transition-new(site-header) {
    animation-duration: 200ms;
  }
}
```

`opacity` and `transform` are what the browser's default cross-fade already
animates — you are tuning duration and easing on the built-in animations, not
introducing new properties. If you replace the default animation with a
custom `@keyframes`, the keyframe body is held to the same allowlist as any
other animation: `opacity`, `transform`, `color`, `background-color`,
`outline-color`, `box-shadow`. Nothing that forces layout.

### The no-preference gate is non-negotiable

Per **ELP_028** (Motion Safety), every declaration above lives inside
`@media (prefers-reduced-motion: no-preference)`. This is not a style
choice — it is the contract:

- Users who set `prefers-reduced-motion: reduce` get an **instant swap**
  between pages. No cross-fade, no morph, no exception.
- The `@view-transition { navigation: auto; }` at-rule itself is not gated —
  gating lives entirely in the pseudo-element animation declarations. If you
  supply no custom styling at all, the browser's default transition still
  runs a cross-fade; you must add the reduced-motion reset below to force
  the instant swap, exactly as the global motion reset already does for
  every other animation in the system:

```css
@media (prefers-reduced-motion: reduce) {
  ::view-transition-group(*),
  ::view-transition-old(*),
  ::view-transition-new(*) {
    animation: none !important;
  }
}
```

This mirrors the canonical WCAG reset in `motion-allowlist.md` and is exempt
from the `!important` prohibition under the same clause in **ELA_003**: a
`prefers-reduced-motion: reduce` block outranks the exception-based-styling
axiom by design.

---

## 2. Decision Table: Cross-Document View Transitions vs. `<ClientRouter />`

| | Cross-document View Transitions | `<ClientRouter />` |
|---|---|---|
| JS cost | **0 KB** | ~3 KB gzipped, counted against the 15 KB route budget |
| Mechanism | Native browser navigation (MPA) | Intercepts navigation, fetches + diffs DOM (same-document) |
| Fallback | A normal instant navigation — full functionality | Requires JS; without it, links still work (plain `<a href>`) but transitions don't |
| Client state across navigations | Not preserved (each page is a fresh document load) | Can preserve via `transition:persist` (islands, media playback position) |
| Registration required | **No** — see §3 | Only if it pushes the route over budget (`ESC_JS_EXCESS`) |
| Right for | Archive pages, articles, index/detail flows — anything where each URL is a real, independently-loadable document | A component must survive the navigation itself: an audio/video player mid-playback, an open `<dialog>`, in-progress form state |

**Read this as a default, not a coin flip.** For this plugin's archival-site
shape (Cover > Center > Stack pages, each one a real document at a real URL
per `references/routing.md`'s URL-design principles), cross-document view
transitions are the correct default. Reach for `<ClientRouter />` only when
you have a concrete, nameable thing that must survive the navigation boundary
— e.g. a persistent audio player bar that should keep playing while the user
browses between tracklist pages. That persistence requirement is exactly the
kind of registered thinking **ELA_005** asks for: name the state that needs
to survive, confirm CSS alone cannot carry it across a full document
unload/reload, and only then accept the ~3 KB.

---

## 3. Baseline Honesty (ELA_006)

Cross-document view transitions are **newly available**, not yet inside this
plugin's "several years of unmaintained-widely-available" comfort zone:
Chrome/Edge 126 (2024), Safari 18.2 (2024), Firefox recent-stable. That is
squarely a Baseline-2024-or-later feature, one generation younger than the
`light-dark()` / logical-properties / `:focus-visible` set ELA_006 already
accepts as stable.

**And yet it needs no `escapes.md` entry.** Spell out why, because the
reasoning is the rule, not just this feature's exemption from it:

> An escape-hatch registration exists to make a **violation** visible,
> justified, and bounded. Cross-document view transitions are not a
> violation of anything — the declaration is additive. A browser that
> doesn't recognize `@view-transition` simply ignores it and performs the
> navigation it was always going to perform: a normal, instant page load.
> There is no degraded state to disclose, because the fallback **is** the
> baseline experience the site already had. This is exactly **ELP_027**
> (Progressive Enhancement) working as designed: the enhancement layer is
> allowed to be younger than the foundation it sits on top of, precisely
> because removing it changes nothing about whether the site works.

Contrast this with the pattern ELA_006's archival gate explicitly forbids:
wrapping a **must-work** feature in `@supports not (...)` to paper over a
gap. That pattern is a violation because the "must work" feature is load
bearing and the fallback is a compromise. `@view-transition` needs no
`@supports` guard at all — there is nothing to detect, because there is no
un-enhanced state that is worse than not having the rule.

**The rule, generalized:** a newly available CSS feature is an additive
enhancement — and therefore exempt from escape-hatch registration — exactly
when (a) the absence of browser support is silently ignored rather than
producing an error or broken layout, and (b) the resulting fallback is full,
unqualified functionality rather than a degraded stand-in. `@view-transition`
qualifies on both counts. A feature that changes layout-critical behavior, or
whose fallback is visibly worse (e.g. broken instead of merely un-animated),
does not qualify and needs the usual registered escape with an expiry.

---

## 4. Astro Specifics

### Works out of the box with `output: 'static'`

Cross-document view transitions require no Astro-specific wiring. Every
route rendered by `output: 'static'` (this plugin's default — see
`SKILL.md` → "Output Modes") is already a real, independently-served
document. Add the CSS in §1 to `src/styles/global.css`, import it from
`Base.astro`, and every static page gets the transition automatically —
there is no per-page opt-in beyond the one global rule.

### Do not combine with `<ClientRouter />` on the same pages

`<ClientRouter />` intercepts `click` and `popstate` navigation and performs
a same-document DOM diff instead of letting the browser navigate. On a page
where the router is active, the browser-native, cross-document navigation
that `@view-transition { navigation: auto; }` depends on **never fires** —
the router's interception happens first, and the CSS-triggered mechanism
only applies to full document loads. The two are not layered enhancements of
each other; they are two different transition mechanisms gated on two
different navigation paths. Pick one per page (or per site):

- **Cross-document VT** — the router is absent; the browser performs a real
  navigation; `@view-transition` fires.
- **`<ClientRouter />`** — same-document diffing intercepts the click; its
  own `transition:name` / `transition:animate` machinery runs instead.

**Astro 6's `<ClientRouter />` remains the supported API for same-document
transitions** — it is not deprecated by this reference. It is the right tool
specifically when you need `transition:persist` for cross-navigation state
(§2). This file documents the CSS-only sibling mechanism for the (larger, in
an archival site) set of pages that don't need that persistence.

---

## 5. Worked Example: Archive Detail Pages

An archive-site-shaped pair of pages — Cover > Center > Stack spine per
`SKILL.md`'s layout composition table — with a persistent header morph and
the mandatory reduced-motion reset. Both pages share the same
`Base.astro`, so this CSS lives once, in `global.css`.

```css
/* src/styles/global.css */

/* --- 1. Opt in to cross-document transitions, site-wide --- */
@view-transition {
  navigation: auto;
}

/* --- 2. Name the elements that persist across every route --- */
.cover > header {                    /* ELC_COVER's header slot */
  view-transition-name: site-header;
}

.cover > header .center {            /* ELC_CENTER inside the header */
  view-transition-name: site-header-inner;
}

/* --- 3. Motion, gated, allowlist-only properties --- */
@media (prefers-reduced-motion: no-preference) {
  ::view-transition-old(root),
  ::view-transition-new(root) {
    animation-duration: 200ms;
    animation-timing-function: ease-in-out;
  }

  ::view-transition-old(site-header),
  ::view-transition-new(site-header) {
    animation-duration: 150ms;
    animation-timing-function: ease-out;
  }
}

/* --- 4. Non-negotiable instant swap for reduced motion --- */
@media (prefers-reduced-motion: reduce) {
  ::view-transition-group(*),
  ::view-transition-old(*),
  ::view-transition-new(*) {
    animation: none !important;
  }
}
```

```astro
<!-- src/layouts/Base.astro — unchanged shell, styles above cover it -->
---
import '../styles/global.css';
interface Props {
  title: string;
}
const { title } = Astro.props;
---
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width" />
  <title>{title}</title>
</head>
<body>
  <div class="cover">                     <!-- ELC_COVER -->
    <header>
      <div class="center">                <!-- ELC_CENTER -->
        <slot name="header" />
      </div>
    </header>
    <main class="principal">
      <div class="center">
        <div class="stack">               <!-- ELC_STACK -->
          <slot />
        </div>
      </div>
    </main>
  </div>
</body>
</html>
```

```astro
<!-- src/pages/archive/[slug].astro — a real, independently-loadable document -->
---
import Base from '../../layouts/Base.astro';
import { getCollection, render } from 'astro:content';

export async function getStaticPaths() {
  const items = await getCollection('archive');
  return items.map((item) => ({ params: { slug: item.id }, props: { item } }));
}
const { item } = Astro.props;
const { Content } = await render(item);
---
<Base title={item.data.title}>
  <Fragment slot="header">
    <nav><a href="/archive">Back to archive</a></nav>
  </Fragment>
  <article class="stack" style="--space: var(--s1)">
    <h1>{item.data.title}</h1>
    <Content />
  </article>
</Base>
```

Navigating from `/archive` to `/archive/some-item` and back is a plain link
click — `<a href="/archive">`, no `onClick`, no fetch. With `@view-transition`
present, the header cross-fades into its new position (same element identity,
`site-header`) instead of flashing; with `prefers-reduced-motion: reduce` set,
the same click performs the exact instant swap it would have performed with
no CSS at all. No JavaScript shipped on either page.

**Gate cleanliness of the CSS above:**

- **Logical properties only** — no physical `width`/`margin-left` anywhere;
  the shell CSS (`.cover`, `.center`, `.stack`) is inherited unmodified from
  `SKILL.md`'s Base layout and already logical-properties-clean.
- **Scale tokens** — `--space: var(--s1)` is the only spacing value
  introduced here, drawn from the modular scale (**ELA_004**). Animation
  durations (150ms/200ms) are not spacing values and fall under the
  motion-allowlist's duration table, not the scale.
- **Selector specificity ≤ 0-2-0** — the highest-reach selector is
  `.cover > header .center`, two classes deep, well under the cap. The
  `::view-transition-*()` pseudo-elements do not count toward the 0-2-0 cap
  per **ELA_003**'s pseudo-element carve-out (the same carve-out that
  exempts `::before`/`::after` elsewhere in the system).
- **No `!important`** outside the `prefers-reduced-motion: reduce` block,
  which is the one place ELA_003 explicitly permits it.

---

## See Also

- `SKILL.md` → "View Transitions" — the short version, with the `<ClientRouter />`
  budget note this file expands on.
- `references/performance.md` → "View Transitions" — performance-implications
  summary for `<ClientRouter />` specifically.
- `css-design-system/references/motion-allowlist.md` — the full allowed/forbidden
  property and duration tables this file's animations must obey.
- `css-design-system/references/escape-hatch-registry.md` — the registration
  format that cross-document view transitions are, by design, exempt from.
- `css-layout-engine/references/axioms.md` — ELA_005, ELA_006, and the axiom
  hierarchy governing every tradeoff in §2–3.
