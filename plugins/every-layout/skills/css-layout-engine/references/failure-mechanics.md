# Failure Mechanics — The Spec-Trap Family

A spec-mechanics trap is legal CSS that hides a browser default nobody wrote down. The property validates, the layout renders, review passes — and then a container gets narrow, or a string gets long, or a sibling gets tall, and the hidden default fires. These are not composition mistakes (see `composition-rules.md`'s hazards table for those — Frame swallowing text, nested Centers, Box-in-Box padding). A composition hazard is two primitives disagreeing. A spec-mechanics trap is one property doing something the spec always said it would, that nobody reads until it breaks.

Most of this family shares a signature: **works wide, clips narrow** (or its rotations — works short, breaks long; works alone, breaks nested). The bug is invisible at the width/length/nesting depth someone tested and real at every other one. ELP_033 (Neutralized Auto-Minimum, `principles.md`) is the founding member — read it and the "Bare Fraction Tracks" entry in `cookbook-antipatterns.md` before this file; both are cited below, not restated.

Each trap: **Mechanism** (the spec behavior), **Symptom signature** (what gets reported), **Defense** (the rule, in gate-clean CSS), **Cite** (existing IDs only).

---

## 1. The Automatic Minimum Size

**Mechanism:** A flex or grid item's automatic minimum size is `auto` — content-based, not `0` — unless something overrides it. Bare `1fr` is `minmax(auto, 1fr)`; the hidden floor lets one child veto the whole track's shrink.

**Symptom signature:** "Works wide, clips narrow" — see ELP_033 and the "Bare Fraction Tracks" anti-pattern for the full mechanism, the swatch-grid field report, and the fix. Not restated here.

**The flex-column twin:** the same automatic-minimum rule applies on the block axis inside a `flex-direction: column` container — `min-height`/`min-block-size: auto`, not `0`. A Stack (ELC_STACK) is `flex-direction: column`; if one of its children is a Frame (ELC_FRAME) or any block with intrinsic content height, and the Stack itself sits inside a block-size constraint (a fixed-height panel, a `dvh`-capped Cover), the child refuses to shrink below its own content height and overflows the constraint — the vertical version of the same bug.

**Defense:**

```css
.stack {
  display: flex;
  flex-direction: column;
}
.stack > .can-shrink {
  min-block-size: 0; /* only where shrinking is intended */
}
```

Don't reach for `min-block-size: 0` reflexively — most Stacks aren't block-constrained, so the `auto` floor never fires. Apply it only to the specific child inside a height-constrained Stack, or better: don't constrain the Stack's block size at all and let it grow (ELP_002).

**Cite:** ELP_033, ELC_STACK, ELC_FRAME

---

## 2. Unbreakable Tokens Raise Min-Content

**Mechanism:** A track's `min-content` size is the widest single unbreakable token inside it — a long URL, a hash, a compound-hyphenated word, a SKU. Normal word-wrap breaks between words, not inside one; a zero-floor track (`minmax(0, 1fr)`) still can't shrink a box below its longest unbreakable run.

**Symptom signature:** The ELP_033 fix is applied — tracks carry `minmax(0, 1fr)`, children carry `min-inline-size: 0` — and the layout *still* overflows, because the remaining floor is the token, not the auto-minimum. Reported as "I did the fix and it's still clipping."

**Defense:**

```css
.content-container {
  overflow-wrap: break-word; /* breaks inside the token as a last resort */
}
```

`hyphens: auto` is a sharper tool for prose (breaks at real syllable points instead of an arbitrary character) but only fires with `lang` set on the element or an ancestor — the browser needs to know which hyphenation dictionary to load. No `lang`, no hyphenation, silently. Per-language coverage varies (CJK and some scripts have no UA dictionary at all), so treat `hyphens: auto` as an enhancement layered on top of `overflow-wrap: break-word`, never a replacement for it.

```css
.prose {
  overflow-wrap: break-word;
  hyphens: auto; /* requires lang on html or this element */
}
```

This is the same fix already shipped in the Fixed-N Equal Columns recipe (`cookbook-recipes.md`) — apply it anywhere content is untrusted-length, not just swatch grids. It also bears on the Measure (ELP_006): a `65ch` measure assumes wrapping prose; an unbroken 80-character token defeats the measure the same way it defeats a grid track.

**The blanket-permission trap:** the defense above belongs on the *token's container* — and only there. The tempting shortcut is to grant it once, globally:

```css
body {
  overflow-wrap: break-word; /* DON'T — this is a site-wide license */
}
```

Because these properties inherit, a `body`/`:root`/`*` grant converts every narrow heading into a fracture site: display type cashes the license in at whatever width the author never tested, opening a line with a single orphan letter mid-word. The overflow the global grant "fixes" was the useful signal — visible overflow at one container points to the one container that needs the grant. Scope the permission to the prose/data container that actually holds unbreakable tokens; never grant it through `body`, `:root`, `*`, or heading selectors (ELP_034 — `bin/css-strict.sh` fails the global form, and `cookbook-antipatterns.md` "Body-Wide Word-Break" dissects the signature).

**Cite:** ELP_033, ELP_034, ELP_006

---

## 3. `aspect-ratio` Feedback

**Mechanism:** `aspect-ratio` is bidirectional — set one axis, the ratio derives the other, in either direction, continuously. Give a ratio'd box a definite inline size and it derives a block size (the common, intentional use). But if the block size grows instead — a label wraps to a second line, a Stack sibling pushes it taller — the same ratio derives a *larger inline minimum* to match. That derived minimum feeds directly into trap 1's automatic-minimum-size calculation, which is exactly the mechanism the swatch-grid field report hit (`principles.md` ELP_033, "Bare Fraction Tracks" in `cookbook-antipatterns.md`).

**Symptom signature:** A ratio'd grid/flex child clips or overflows only when its content wraps to an extra line — intermittent, content-dependent, and easy to miss because most test content doesn't wrap.

**Defense:** This is ELP_033's territory for the *feedback* half (definite track floor + `min-inline-size: 0`); the trap worth naming separately is **containment intent**. Frame (ELC_FRAME) sets `aspect-ratio` + `overflow: hidden` *on purpose* — cropping via `object-fit: cover` is the whole point, and the composition-rules.md hazards table already flags what not to put inside it (text-only components, Reel). Elsewhere in a codebase, `aspect-ratio` on a non-Frame element with growable content is accidental clipping wearing containment's clothes — same properties, opposite intent. When reviewing a ratio'd box that clips, ask: is this Frame (containment is correct) or an ad-hoc ratio a Stack/Grid child picked up (containment is a bug — see trap 7 for the general `overflow` case)?

```css
.frame {
  aspect-ratio: var(--n, 16) / var(--d, 9);
  overflow: hidden; /* intentional — cropping is the mechanism */
}
```

**Cite:** ELP_033, ELC_FRAME, ELC_GRID

---

## 4. Percentage Padding Resolves Against Inline Size

**Mechanism:** `padding-top`/`padding-bottom` (and their logical equivalents `padding-block-start`/`padding-block-end`) expressed as a percentage resolve against the **inline size** of the containing block — never the block size — on both axes. This is spec behavior from CSS 2.1, unrelated to `aspect-ratio` and older than it. It's also the entire mechanism behind the pre-`aspect-ratio` "padding-top hack" (`padding-top: 56.25%` for a 16:9 box): it works *because* percentage padding ignores the block axis and reads the inline one.

**Symptom signature:** Code from before `aspect-ratio` shipped (or copy-pasted from an old tutorial) that still carries a `padding-top: NN%` ratio box. It works, which is the trap — it's legal, it renders the right ratio, and it survives review because nothing looks wrong. It just means: an extra wrapper element, a `position: absolute` inner element, and a box-model calculation nobody chose deliberately, all obsolete since `aspect-ratio` reached Baseline (`baseline-registry.md` — `aspect-ratio` is **allowed**, widely available since 2023).

**Defense:** Never write a percentage-padding ratio box. Use `aspect-ratio` — it's the primitive Frame (ELC_FRAME) already builds on:

```css
/* DON'T — percentage padding as an aspect-ratio hack */
.old-ratio-box { padding-block-start: 56.25%; }

/* DO — direct, no wrapper, no absolute positioning */
.frame { aspect-ratio: 16 / 9; }
```

**Cite:** ELC_FRAME

---

## 5. `auto` Margins Consume Space Before `justify-content`

**Mechanism:** Flexbox resolves free-space distribution in two passes: `auto` margins claim their share of free space **first**, absorbing as much as they can; whatever remains (usually nothing) is what `justify-content` has left to distribute. An `auto` margin on a flex item isn't a participant in `justify-content` — it pre-empts it.

**Symptom signature:** A flex container has both a `justify-content` value and an `auto` margin on one item, and the `justify-content` value appears to do nothing — because there's no free space left for it to act on by the time it runs.

**Defense:** This is exactly the mechanism Cover (ELC_COVER) uses on purpose — `margin-block: auto` on `.principal` claims all remaining vertical space in the flex column, which *is* the centering:

```css
.cover { display: flex; flex-direction: column; }
.cover > .principal { margin-block: auto; } /* consumes free space — this IS the centering */
```

The rule cuts both ways: it's why Cover works, and why adding a `justify-content` declaration alongside `.principal`'s auto margin is dead code, not a stronger centering. Pick one mechanism per axis — auto margins for "push this one element," `justify-content`/`align-items`/`gap` for "distribute all children" — and don't mix them on the same axis of the same container.

**Cite:** ELC_COVER

---

## 6. Margin Collapse Does Not Happen in Flex/Grid Formatting Contexts

**Mechanism:** Adjacent-sibling margin collapse is a normal-flow (block formatting context) behavior only. Establishing `display: flex` or `display: grid` on a container creates a flex/grid formatting context for its children, and collapse simply does not apply inside one — margins on flex/grid items always take full effect, stacked, never merged.

**Symptom signature:** The same `* + *` margin rule behaves differently depending on the parent's `display`. Nobody expects a selector's meaning to change with an unrelated property, so this reads as inconsistent behavior rather than the two-context rule it actually is.

**Defense:** This is why the Stack owl selector is safe to rely on unconditionally: Stack (ELC_STACK) is `display: flex; flex-direction: column`, so its `* + *` margins are guaranteed non-collapsing by the formatting context alone — no `overflow: hidden` trick or padding buffer required, unlike the same selector in plain block flow. See `composition-rules.md`'s hazards table and ELP_012 (Prefer Gap Over Margin) for the adjacent margin-vs-gap tradeoff generally; this entry only explains *why* Stack's specific choice is safe.

```css
.stack { display: flex; flex-direction: column; } /* flex context: no collapse, ever */
.stack > * + * { margin-block-start: var(--s1, 1.5rem); }
```

**Cite:** ELC_STACK, ELP_012

---

## 7. Non-Visible `overflow` Creates a New Formatting Context — and Clips

**Mechanism:** Any `overflow` value other than `visible` (`hidden`, `auto`, `scroll`, `clip`) does two things at once, unconditionally: it establishes a new block formatting context for the element, **and** it clips descendant content to the padding box. These are spec-bundled, not two separate opt-ins — you cannot get containment without clipping, or clipping without containment.

**Symptom signature (two distinct reports, same root cause):**

- A `position: sticky` descendant several levels down stops sticking, with no `position` or `top` change anywhere near it. The actual cause is an ancestor picking up `overflow: hidden`/`auto` for an unrelated reason (clipping a rounded corner, containing a float) — sticky positioning is scoped to its nearest scrolling ancestor, and the new formatting context *is* that ancestor now.
- A focus ring on an element with an **inset** outline (`outline-offset: negative`, common on Box's `outline`/`outline-offset: calc(... * -1)` pattern) gets clipped flush against the edge, or disappears entirely, when a parent has `overflow: hidden` for a rounded-corner mask.

**Defense:** Name the tradeoff instead of discovering it. Frame (ELC_FRAME) takes `overflow: hidden` deliberately — cropping via `object-fit: cover` is the mechanism, not a side effect, and the composition-rules.md hazards table already documents what must never go inside it. Elsewhere, prefer the narrowest tool:

```css
.frame {
  aspect-ratio: var(--n, 16) / var(--d, 9);
  overflow: hidden; /* containment AND clip, both wanted here */
}
```

For the focus-ring case specifically, `overflow: clip` plus `overflow-clip-margin` is the modern, purpose-built escape — it clips only past an authored margin instead of flush at the border edge, so an inset ring stays visible while rounded corners still crop the image. Per `baseline-registry.md`, `overflow-clip-margin` is **escape-gated** (Safari has never shipped it) — prefer non-inset rings where support matters, and any reliance on this property needs an `escapes.md` row until the registry promotes it.

```css
.frame[data-focusable] {
  overflow: clip;
  overflow-clip-margin: var(--s-1, 0.667rem); /* ring gets room; corners still crop */
}
```

For the sticky case: there is no CSS escape once an ancestor needs `overflow: hidden` for its own reasons — the fix is architectural (move the sticky element outside that ancestor, or find a different way to achieve the ancestor's containment, e.g. `clip-path` for a corner mask instead of `overflow: hidden`).

**Cite:** ELC_FRAME, ELP_029

---

**Field-report pipeline.** ELP_033 started as a real incident, not a hypothetical. See CLAUDE.md → Development Workflow → Field reports for the convention that turns an incident into a principle, a fixture, and an entry here.
