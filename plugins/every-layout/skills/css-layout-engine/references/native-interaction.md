# Native Interaction — The Zero-JS Catalog

ELA_005 says JavaScript participates only when CSS/HTML cannot express the intent. This file is the inventory that makes that clause enforceable: what native HTML/CSS *can now express*, so an island doesn't get reached for out of habit. Each entry gives the markup contract, the CSS hooks, its Baseline status, the no-support fallback (ELP_027 — every layer must work without the layers above it), and the JS pattern it retires.

Cite these IDs when recommending an entry: **ELA_005** (CSS-dominant), **ELA_006** (archival durability — Baseline-gated), **ELP_027** (progressive enhancement), **ELP_028** (motion safety), **ELP_029** (focus visibility). Never invent new IDs — this file adds no `ELC_`/`ELP_` entries of its own; it explains how to reach existing ones with less code.

---

## 1. Disclosure — `<details>` / `<summary>`, exclusive accordions via `name`

**Markup contract:**

```html
<details name="faq">
  <summary>What is Every Layout?</summary>
  <p>A methodology of composable, algorithmic CSS layout primitives.</p>
</details>
<details name="faq">
  <summary>Do I need JavaScript?</summary>
  <p>No — disclosure and exclusivity are both native.</p>
</details>
```

Every `<details>` sharing one `name` becomes a radio-button-style group: opening one closes the others. Zero JS, zero ARIA needed — `<summary>` carries an implicit `button` role and `aria-expanded` state for free.

**CSS hooks:**

```css
details {
  border-block-start: var(--border-thin) solid var(--br-color-border, currentColor);
  padding-block: var(--s0);
}

summary {
  cursor: pointer;
  font-weight: bold;
}

summary:focus-visible {
  outline: 3px solid var(--br-color-focus, currentColor);
  outline-offset: var(--s-5);
}

details > :not(summary) {
  margin-block-start: var(--s0);
}
```

Selector depth stays at 0-1-0 throughout (ELA_003).

**Baseline:** newly available 2025 (`name` on `<details>` reached cross-engine support September 2025; an earlier 2024 date was optimistic) — additive tier per `baseline-registry.md`. Verified 2026-07-07.

**Fallback obligation:** None needed — `<details>` without `name` support (there isn't one; browsers without `<details>` itself are pre-Baseline) still discloses individually. Non-CSS browsers get an unstyled but fully functional expand/collapse. Nothing degrades below "reads and opens."

**Replaces this JS pattern:** Accordion widgets built on `aria-expanded` toggling, `hidden` attribute swaps, and a click handler per header — plus a second layer of hand-rolled "close the others" bookkeeping for exclusive accordions.

### Watch tier: animating the open/close transition

`<details>` snaps open/closed with no transition by default — `block-size: auto` cannot be animated by CSS. `interpolate-size: allow-keywords` plus `calc-size()` lifts that restriction, letting `auto` participate as a transition endpoint.

**This is a knowing exception to the motion allowlist, not an addition to it.** `motion-allowlist.md` forbids transitioning `block-size` because it forces layout recalculation of siblings on every frame — `interpolate-size` does not remove that cost, it only makes `auto` a legal endpoint. Reach for this pattern only where the open/close animation is worth a per-frame layout recalc (a handful of accordion panels, not a long list), and never outside the double gate below:

```css
/* WATCH TIER — not Baseline. Deliberate exception to motion-allowlist.md,
   gated behind @supports AND reduced-motion; do not lift block-size
   transitions out of this wrapper elsewhere. */
@supports (interpolate-size: allow-keywords) {
  :root {
    interpolate-size: allow-keywords;
  }

  @media (prefers-reduced-motion: no-preference) {
    details > :not(summary) {
      transition: block-size 200ms ease-out, opacity 150ms ease-out;
    }
  }
}
```

**Baseline:** Not yet Baseline as of 2026 — Chromium-only at time of writing. Do not ship this unguarded; the `@supports` wrapper is the fallback, not a bonus. Without it (or in `prefers-reduced-motion: reduce`), disclosure still works — it just snaps instead of sliding, which is the correct ELP_028 behavior, not a degraded one.

---

## 2. `<dialog>` — modal, `::backdrop`, and the one-line ELA_005 boundary

**Markup contract:**

```html
<dialog id="confirm">
  <form method="dialog" class="stack">
    <p>Discard unsaved changes?</p>
    <div class="cluster" style="--justify: flex-end">
      <button value="cancel">Cancel</button>
      <button value="confirm">Discard</button>
    </div>
  </form>
</dialog>

<button type="button" onclick="confirm.showModal()">Open</button>
```

`method="dialog"` closes the dialog and populates `.returnValue` with the pressed button's `value` — entirely without JS. Opening a **modal** dialog (focus-trapped, top-layer, backdrop) is the one place this catalog asks for a line of script: `dialogElement.showModal()`. There is no declarative equivalent — say so honestly rather than routing around it with a fake CSS-only modal (`:target` and `display` toggles cannot trap focus or occupy the top layer).

**This is the documented ELA_005 boundary for this feature.** One line, one purpose, no framework: `document.getElementById('confirm').showModal()` behind a `type="button"` (never a bare `<a>` or unstyled `<div>`) satisfies ELA_005's "only when CSS cannot express the intent" clause and needs no `escapes.md` entry — it is the catalog's documented exception, not a budget violation. A non-modal `<dialog>` (`.show()`, or the `open` attribute set directly in HTML) needs no JS at all but also doesn't trap focus or block the page — use it only for genuinely non-modal panels.

**CSS hooks:**

```css
dialog {
  border: none;
  border-radius: var(--s-4);
  padding: var(--s1);
  max-inline-size: 40ch;
}

dialog::backdrop {
  background-color: color-mix(in oklch, canvas 60%, transparent);
}

@media (prefers-reduced-motion: no-preference) {
  dialog {
    transition: opacity 200ms ease-out, transform 200ms ease-out;
  }
  dialog:not([open]) {
    opacity: 0;
    transform: scale(0.98);
  }
}
```

`::backdrop` is a pseudo-element — it does not count against the 0-2-0 specificity cap (ELA_003).

**Focus behavior:** `showModal()` moves focus to the first focusable element inside (or the dialog itself if none), traps Tab cycling within it, and returns focus to the invoking control on close — all native, all free. This is ELP_029 satisfied by the platform, not by hand-written focus-trap JS.

**Baseline:** 2022 (`<dialog>`, `showModal()`, `::backdrop`), widely available as of 2026.

**Fallback obligation:** A browser without `<dialog>` support renders it as a plain block element with no backdrop and no focus trap — content stays reachable, just not modal. Never rely on `<dialog>` for content that must be hidden from non-supporting browsers; treat the modal behavior as an enhancement over content that already makes sense in flow (ELP_027).

### Watch tier: `closedby`

The `closedby="any" | "closerequest" | "none"` attribute standardizes light-dismiss (click-outside, Esc) behavior that today requires a manual `close` button and/or a backdrop-click listener.

**Baseline:** Not Baseline as of 2026 — track before depending on it; keep the explicit `<button>` cancel action as the durable path regardless (ELA_006).

---

## 3. Popover API — declarative overlays, zero JS

**Markup contract:**

```html
<button type="button" popovertarget="menu">Options</button>
<div id="menu" popover>
  <ul class="stack" role="list">
    <li><button type="button">Rename</button></li>
    <li><button type="button">Delete</button></li>
  </ul>
</div>
```

`popover` on the target, `popovertarget` on the trigger — that's the whole contract. The browser handles top-layer promotion, light-dismiss (click outside, Esc), and `aria-expanded`/`aria-details` wiring between trigger and target automatically. `popovertargetaction="show" | "hide" | "toggle"` (default `toggle`) controls the verb without a line of script.

**CSS hooks:**

```css
[popover] {
  border: none;
  padding: var(--s0);
  border-radius: var(--s-4);
  inset: unset; /* clear UA default centering before Imposter positions it */
}

[popover]:popover-open {
  /* Imposter (ELC_IMPOSTER) positions the open popover relative to its trigger's container */
  position: absolute;
  inset-block-start: 100%;
  inset-inline-start: 0;
}

@media (prefers-reduced-motion: no-preference) {
  [popover] {
    transition: opacity 150ms ease-out, transform 150ms ease-out;
  }
  [popover]:not(:popover-open) {
    opacity: 0;
    transform: translateY(var(--s-4));
  }
}
```

This animates the fade/slide only — `display`/`overlay` are outside the motion allowlist (see `motion-allowlist.md`), so this recipe deliberately stops at `opacity`/`transform` rather than reaching for `transition-behavior: allow-discrete` + `@starting-style` to also animate the top-layer entry. The popover still opens and closes correctly without that refinement; it just cuts instantly at the very start/end of the fade instead of appearing to un-clip. Treat the fuller `allow-discrete` recipe as a candidate for a future escape-hatch-registered exception, not a default.

Position the popover today with the **Imposter** pattern (ELC_IMPOSTER) — absolute positioning relative to a `position: relative` ancestor, as shown above. `:popover-open` is a pseudo-class and does not add to the specificity cap beyond its one count.

**Baseline:** newly available January 2025 (the April 2024 Baseline announcement was formally retracted over a Safari/iOS light-dismiss bug) — additive tier per `baseline-registry.md`. Verified 2026-07-07.

**Fallback obligation:** A browser without Popover API support does not recognize the `popover` attribute; the element renders in normal flow (not hidden, not floating) and the `popovertarget` button becomes an inert attribute with no default behavior. That means content must make sense un-popped — do not put content-only-reachable-via-popover behind this without a fallback discoverability path (a real link, a details/summary, or a query param), per ELP_027.

**Replaces this JS pattern:** Dropdown menus, tooltips, and lightweight overlay panels built on `position: absolute` + a click-outside listener + a manual `z-index` fight against everything else on the page (see z-index.md) + manual Esc-key handling.

### Watch tier: CSS anchor positioning

`anchor-name` / `position-anchor` / `position-area` let a popover (or any absolutely positioned element) size and place itself relative to its trigger without a shared positioning-context ancestor — replacing the Imposter's `position: relative` wrapper requirement entirely.

**Baseline:** Not Baseline as of 2026 — Chromium-only. Keep Imposter as the durable positioning path; treat anchor positioning as a progressive enhancement behind `@supports (anchor-name: --a)`, never the only path.

---

## 4. Native form validation UX — `:user-valid` / `:user-invalid`

**Why not `:valid`/`:invalid`:** those match the instant a constraint is satisfiable — an empty `required` field is `:invalid` before the user has touched it, so styling on `:invalid` alone paints every empty field red on page load. `:user-valid` / `:user-invalid` only match **after the user has interacted** with the field (a change event, or a blur following interaction) — the same rule browsers apply to their own native bubble validation UI. This is the whole reason the pair exists: correct validation UX timing, natively.

**Markup contract:**

```html
<div class="stack" style="--space: var(--s-2)">
  <label for="email">Email</label>
  <input id="email" type="email" required aria-describedby="email-hint">
  <p id="email-hint" class="field-hint">We'll only use this to send your receipt.</p>
</div>
```

Pair with the constraint attributes the platform already validates: `required`, `pattern`, `minlength`/`maxlength`, `min`/`max`, `step`, `type="email"`/`"url"`/`"tel"`. Each is a zero-JS validation rule the browser enforces on submit and exposes to `:user-invalid` after interaction.

**CSS hooks:**

```css
input:user-invalid {
  outline: 2px solid var(--br-color-error);
  outline-offset: var(--s-5);
}

input:user-valid {
  outline: 2px solid var(--br-color-success, currentColor);
  outline-offset: var(--s-5);
}

@media (prefers-reduced-motion: no-preference) {
  input {
    transition: outline-color 150ms ease-out;
  }
}

input:focus-visible {
  outline: 3px solid var(--br-color-focus, currentColor);
  outline-offset: var(--s-5);
}
```

`:focus-visible` must still win visually on focus regardless of validity state (ELP_029) — put it last, or scope the validity outline to non-focus states if your cascade order can't guarantee it.

**Baseline:** 2023 (`:user-valid`/`:user-invalid`), widely available as of 2026.

**The honest boundary:** this pair gets you correctly-timed *styling*. It does not get you custom error *text*. The browser's built-in bubble ("Please fill out this field") is untranslatable-by-CSS and unstyleable beyond a handful of `::-webkit-` non-standard pseudo-elements with no cross-browser guarantee. Custom error copy ("Enter a valid email so we can send your receipt") still requires:

1. A visible `<p role="alert">` or `aria-live="polite"` region tied via `aria-describedby` (see form-patterns.md Pattern 5 for positioning), and
2. A small amount of JS — a `change`/`invalid` event listener that reads `validationMessage` or a custom message and writes it into that region.

That JS is legitimate under ELA_005: CSS cannot inject text content or manage an ARIA live region's announcement timing. Register it under `ESC_JS_EXCESS` only if it pushes the page over budget — a single delegated listener rarely will.

---

## 5. `<datalist>` — native combobox/suggestions

**Markup contract:**

```html
<label for="browser">Preferred browser</label>
<input id="browser" list="browsers" name="browser">
<datalist id="browsers">
  <option value="Firefox">
  <option value="Safari">
  <option value="Chrome">
  <option value="Edge">
</datalist>
```

The `list` attribute on the input points to the `datalist`'s `id`. The browser renders a native suggestion dropdown filtered as the user types — no custom listbox, no keyboard-navigation JS, no ARIA combobox pattern to hand-roll.

**CSS hooks:** `<datalist>` itself is not rendered (`display: none` by the UA stylesheet) and exposes almost nothing stylable — the suggestion popup is native browser chrome, matching OS conventions. Style only the input:

```css
input[list] {
  inline-size: 100%;
}
```

This is not a limitation to work around — the whole point is the browser draws the picker, so it stays consistent with every other autofill UI (ELP_010, browser delegation).

**Baseline:** 2020, widely available as of 2026.

**Fallback obligation:** A non-supporting browser (effectively none left, but archivally: assume one exists in five years) renders a plain text `<input>` — the `list`/`datalist` pairing is inert, not broken. Never make `datalist` the only way to enter a valid value; it suggests, it does not constrain, so this fallback is automatic rather than a separate code path.

**Replaces this JS pattern:** Custom autocomplete/combobox widgets — a filtered dropdown built on keydown handlers, a manually managed `aria-activedescendant`, and a fetch-or-filter-as-you-type loop.

---

## 6. `accent-color` — native control theming from a brand token

**Markup contract:** none needed — this styles existing native controls (`checkbox`, `radio`, `range`, `progress`) in place.

**CSS hooks:**

```css
:root {
  accent-color: var(--br-color-accent);
}
```

One declaration, inherited, themes every checkbox, radio button, range slider, and progress bar on the page to match the brand accent — while leaving the control's native hit-target size, keyboard behavior, and OS-consistent chrome (light/dark mode, high-contrast mode, forced-colors mode) completely intact. Setting it on `:root` keeps specificity at 0-0-0 and lets any subtree override by re-declaring the same property closer in (ELP_011).

**Baseline:** NOT Baseline as of 2026-07 (verified 2026-07-07) — despite shipping everywhere in 2021–22, a Safari contrast-adjustment bug on control marks has blocked the Baseline determination since 2022. **Escape-gated per `baseline-registry.md`:** the no-support/buggy-support fallback is the browser's default control colors (fully functional), so the `escapes.md` row is one line — but it is required until the registry promotes the row.

**Fallback obligation:** A non-supporting browser renders the OS-default control color instead of the brand color. This is a pure aesthetic degrade — no functionality is lost, so no fallback code path is needed at all.

**Replaces this JS pattern:** Custom-styled checkbox/radio/range components — hiding the native input with `appearance: none` or `opacity: 0` and drawing a fake control with a `<span>` or `<div>`, then re-implementing keyboard operation, `:indeterminate` state, and forced-colors-mode support by hand.

---

## 7. `field-sizing: content` — auto-growing textareas

**Markup contract:**

```html
<label for="notes">Notes</label>
<textarea id="notes" rows="1"></textarea>
```

**CSS hooks:**

```css
/* WATCH TIER — not Baseline. Gate behind @supports. */
@supports (field-sizing: content) {
  textarea {
    field-sizing: content;
    max-block-size: var(--s5);
  }
}
```

`field-sizing: content` makes the `<textarea>` grow with its content up to `max-block-size`, then scroll — the same behavior currently reached for with a `scrollHeight`-measuring `input` event listener resizing `block-size` on every keystroke.

**Baseline:** Not Baseline as of 2026 — Chromium-only. This is a watch-tier enhancement, not a default pattern: ship the `@supports` wrapper, and let non-supporting browsers keep the `rows="1"` starting size with native scroll inside the textarea (which is itself a complete, working fallback — nothing needs a JS shim to compensate).

**Fallback obligation:** Non-supporting browsers get a fixed-size, natively scrollable `<textarea>` — fully functional, just not auto-growing. That is an acceptable ELP_027 fallback on its own; do not pair this with a JS auto-grow polyfill, which would reintroduce the JS this entry exists to remove.

**Replaces this JS pattern:** Auto-resizing textarea scripts that read `scrollHeight` on every `input` event and write it back as `style.height`.

---

## The boundary that remains

This catalog shrinks the set of things that "need" JS; it does not empty it. What still genuinely requires script, and should be scoped honestly in `escapes.md` under `ESC_JS_*` rather than justified away:

| Need | Why CSS/HTML stops short | Scope as |
|------|--------------------------|----------|
| `dialog.showModal()` | No declarative way to invoke the top-layer, focus-trapped modal path | One line, documented ELA_005 boundary (§2) — not an escape, the catalog's stated exception |
| Custom validation error **text** | `:user-invalid` styles; it cannot author message copy or manage live-region announcement timing | `ESC_JS_EXCESS` only if it pushes the page over the ELA_005 JS budget — usually it will not |
| Non-trivial state (multi-step wizards, undo stacks, optimistic UI, cross-field conditional logic) | Beyond what any single pseudo-class or attribute selector can express | `ESC_JS_EXCESS` with justification and expiry, per ELA_005 |
| Fetching/writing data without a full navigation | HTML forms `POST`/`GET`; anything beyond that (partial updates, streaming) is inherently scripted | `ESC_JS_EXCESS`, and prefer a `<form>` fallback per ELP_027 regardless |

Every entry above one line of `showModal()` gets an `escapes.md` row with an expiry date — no permanent escapes (see `escape-hatch-registry.md`). The point of this file is that the row should be rare, not that it should never exist.
