# Internationalization Layout Guide

Per-primitive behavior in RTL and vertical writing modes. Every Layout's logical property mandate (ELP_004) handles most i18n concerns automatically, but these edge cases require explicit attention.

---

## RTL Behavior by Primitive

Every Layout primitives use logical properties, so most work correctly in `dir="rtl"` without modification. These notes cover the exceptions and verification points.

### Stack (ELC_STACK) — No issues
Vertical stacking is writing-mode-independent. `margin-block-start` works identically in LTR and RTL.

### Box (ELC_BOX) — No issues
`padding` shorthand is direction-neutral. `border` is direction-neutral.

### Center (ELC_CENTER) — No issues
`margin-inline: auto` centers in both directions. `padding-inline` adds gutters on the correct sides. `max-inline-size` constrains the correct axis.

### Cluster (ELC_CLUSTER) — Verify visual order
`flex-wrap: wrap` respects `direction`. Items flow right-to-left in RTL. **Verify:** If the visual order of items carries meaning (e.g., breadcrumbs: Home > Section > Page), the reversed flow in RTL may create confusion. Use `dir="ltr"` on the element if the order is semantic, not presentational.

### Sidebar (ELC_SIDEBAR) — Verify semantic side
`:first-child` is the sidebar, `:last-child` is the content. In RTL, the sidebar appears on the right (inline-start) by default. **Verify:** If the sidebar contains navigation that should always be on a specific side regardless of direction, use `dir` attribute to override, or swap child order.

### Switcher (ELC_SWITCHER) — No issues
The `calc((var(--threshold) - 100%) * 999)` formula is direction-neutral. Columns reorder correctly in RTL.

### Cover (ELC_COVER) — No issues
Vertical centering via `margin-block: auto` is direction-neutral.

### Grid (ELC_GRID) — Verify reading order
`auto-fit` grids flow items in document order, which reverses in RTL. **Verify:** For grids where item order carries temporal or sequential meaning (timelines, numbered steps), the reversed flow may confuse readers. Add `dir="ltr"` to the grid element if the order is semantic.

### Frame (ELC_FRAME) — No issues
`aspect-ratio` and `object-fit` are direction-neutral.

### Reel (ELC_REEL) — Verify scroll direction
`overflow-x: auto` respects `direction`. In RTL, the reel scrolls right-to-left (new content to the left). **Verify:** Scroll snap points and the visual start position reverse. If the reel is a timeline or ordered sequence, this reversal may be confusing. Test with actual RTL content.

### Imposter (ELC_IMPOSTER) — No issues
`inset-inline-start: 50%` + `transform: translate(-50%, -50%)` centers correctly in both directions. Note: `transform` values are physical (X/Y), but centering transforms are symmetrical so they work in both directions.

### Icon (ELC_ICON) — Verify icon direction
The `with-icon` wrapper uses `inline-flex` + `gap`, which respects direction. **Verify:** Directional icons (arrows, play buttons, chevrons) may need mirroring in RTL. Use CSS `transform: scaleX(-1)` on the icon SVG in RTL contexts, or provide separate RTL icon variants.

### Container (ELC_CONTAINER) — No issues
`container-type: inline-size` resolves to the correct axis in both directions.

---

## Vertical Writing Modes

Vertical writing modes (`writing-mode: vertical-rl`, `writing-mode: vertical-lr`) swap the inline and block axes. This has significant implications for several primitives.

### Known Limitations

| Primitive | Issue in vertical mode | Workaround |
|-----------|----------------------|------------|
| Stack | `flex-direction: column` stacks along the *block* axis, which becomes horizontal in vertical mode. The Stack becomes a horizontal row. | Acceptable if intentional. If vertical stacking is needed, use `flex-direction: row` in vertical mode. |
| Center | `max-inline-size: 65ch` constrains the vertical dimension (now inline). `margin-inline: auto` centers vertically. | The behavior is correct per logical properties — but test that the visual result matches intent. |
| Sidebar | `min-inline-size: 50%` threshold applies to the vertical dimension. | Test stacking behavior carefully. |
| Reel | `overflow-x` becomes `overflow-inline`. The reel scrolls vertically. | May be desirable for vertical text. Test explicitly. |

### Recommendation

Vertical writing modes are rare in web content but critical for CJK vertical text and some artistic layouts. **Do not add media queries or writing-mode-specific overrides.** The logical property system handles axis swapping correctly — the layout just needs visual verification.

If a vertical layout produces unexpected results, the fix is usually adjusting the custom property values (wider `--measure`, different `--min` on Grid), not adding conditional CSS.

---

## Mixed-Direction Content

Everything above assumes a page has one direction, set once via `dir` on `<html>` or a container. Real content mixes directions inline — a Cluster of tags where some are Arabic and some are Latin, a Sidebar whose nav items are user-submitted in different scripts, a quoted product name embedded in a paragraph of the opposite direction. ELP_004's logical-property mandate already solved the *layout* half of this problem: because every primitive is written in `inline-*`/`block-*` terms, none of them need to know or care which way text runs — only the content itself carries direction, and only at the point where scripts change. This section covers that content-level direction management.

### `dir="auto"` for user-generated content

Any element whose content is unknown at author time — user-generated text, quoted material, database-sourced strings — should carry `dir="auto"` rather than inheriting a fixed direction from its container:

```html
<blockquote dir="auto">مرحبا بكم في الموقع</blockquote>
<p dir="auto">{{ user_submitted_comment }}</p>
```

`dir="auto"` inspects the first strong directional character in the element's text and sets direction from it, per-element. This is a content concern, not a layout concern — it composes with any primitive (Stack, Box, Cluster) without any primitive-level change, because the primitive still only lays out in logical terms.

### `<bdi>` for isolating names and handles

When a direction-unknown string is embedded *inline* among other content — a username in a list, a handle in a mention, a product name in a sentence — wrap it in `<bdi>` (bidirectional isolate) rather than `dir="auto"` on a block ancestor. `<bdi>` prevents the embedded string's direction from leaking into and reordering the surrounding punctuation and neighboring words.

**Worked example — Cluster (ELC_CLUSTER) of mixed-script tags:**

```html
<ul class="cluster">
  <li><bdi>#javascript</bdi></li>
  <li><bdi>#تطوير-الويب</bdi></li>
  <li><bdi>#React</bdi></li>
  <li><bdi>#برمجة</bdi></li>
</ul>
```

```css
.cluster {
  display: flex;
  flex-wrap: wrap;
  gap: var(--s0);
}
```

Without `<bdi>`, an RTL tag like `#تطوير-الويب` sitting next to LTR tags can pull trailing punctuation or adjacent characters across the boundary, visually corrupting neighboring tags. `<bdi>` isolates each tag's bidi algorithm run so the Cluster's own layout (a direction-agnostic flex-wrap, per ELP_004) never has to compensate for content-level direction — the isolation happens purely at the text level, inside each item.

### `unicode-bidi: isolate` and when `plaintext` applies

`<bdi>` has a CSS equivalent, `unicode-bidi: isolate`, which is in fact the default UA stylesheet value applied to `<bdi>` itself (`bdi { unicode-bidi: isolate; }`) — using the element is preferred over the property for semantic clarity, but the property is useful when isolation needs to apply to an existing element that cannot take a `<bdi>` wrapper (e.g. a generated `<span>` from a templating system).

`unicode-bidi: plaintext` goes further: instead of inheriting the surrounding paragraph's direction as a default before checking the content, it derives direction *purely* from the Unicode bidi algorithm on the element's own text, ignoring the ambient `dir`. This matters for isolated fragments — chat messages, notification strings, table cells — that may have no reliable ambient direction to inherit and should be judged strictly on their own first-strong-character content, the same way `dir="auto"` works but as a CSS-level tool for elements you don't control the markup of.

### Punctuation and parenthesis mirroring pitfalls

Unicode's bidi algorithm mirrors certain "mirrorable" characters — parentheses, brackets, quotation marks, and some math operators — when they occur inside an RTL run, so `(text)` becomes visually `)text(` while remaining semantically "open paren, text, close paren" in the DOM. This is correct and automatic for RTL-native content. The pitfall is *mixed* runs: a parenthetical aside in Latin script embedded inside an RTL sentence can end up with its parentheses mirrored against the outer RTL direction while the Latin text inside stays LTR, producing a visually asymmetric result (e.g., the opening paren appearing to "point the wrong way" relative to the Latin text it encloses). There is no CSS fix for this — it is a content-authoring concern. The mitigation is isolating the embedded run with `<bdi>` or `unicode-bidi: isolate` so its own mirroring resolves independently of the outer paragraph's direction, rather than trying to override mirroring with characters like U+200E (LRM) or U+200F (RLM) sprinkled ad hoc, which is brittle and invisible in source.

### Numbers in RTL contexts

Digits (0-9, "European digits") are always rendered left-to-right even inside an RTL run — `العدد هو 42` reads the Arabic right-to-left but "42" itself reads left-to-right within that run, per the bidi algorithm's handling of numbers as a distinct character class. This is standard and requires no CSS intervention. Where it becomes a layout question is `font-variant-numeric: tabular-nums` (Section 4 of `css-texture.md`) combined with RTL: tabular figures still lay out left-to-right internally, so a column of RTL-labeled numeric data aligns correctly as long as the container itself is not forcing a text-align that fights the numeral run — use logical `text-align: start`/`end` (never `left`/`right`) so the numeral block aligns to the correct edge regardless of direction.

### Worked example — Sidebar (ELC_SIDEBAR) direction flip

Sidebar's DOM order is its only ordering signal: `:first-child` is the sidebar, `:last-child` is the content (see "Sidebar (ELC_SIDEBAR) — Verify semantic side" above). Because the primitive is written in `flex` with no physical `left`/`right`, the *visual* side the sidebar appears on is entirely a function of `direction`, and DOM order alone is sufficient — no direction-specific markup or CSS is needed:

```html
<div class="sidebar" dir="rtl">
  <aside><!-- nav content --></aside>
  <main><!-- page content --></main>
</div>
```

In this RTL example the `<aside>` (still the first child) renders on the right — inline-start in RTL — with zero CSS changes from the LTR version. This is ELP_004 working exactly as intended: the primitive never encodes "left" or "right," so reversing `direction` reverses the visual side automatically, and DOM order continues to equal logical (inline-start-to-inline-end) order in both directions. The only thing that needs verification per the earlier Sidebar entry is *semantic* intent — if the sidebar must stay physically pinned regardless of direction (e.g., a fixed brand rail), that is a deliberate exception to flag, not the default expectation.

---

## Testing Checklist

When building for multilingual audiences, test each page in these configurations:

- [ ] `dir="ltr"` (default) — baseline verification
- [ ] `dir="rtl"` — check Cluster, Sidebar, Grid, Reel, Icon for visual order issues
- [ ] Browser zoom at 400% — verify no horizontal scrolling (WCAG 1.4.10)
- [ ] `lang` attribute set on `<html>` — required for proper hyphenation and voice synthesis
- [ ] Directional icons mirrored in RTL — arrows, chevrons, play buttons
- [ ] No `text-align: left` or `text-align: right` — use `start` and `end`
- [ ] No `float: left` or `float: right` — use logical equivalents or Sidebar
- [ ] User-generated/quoted content carries `dir="auto"` — comments, reviews, database strings of unknown direction
- [ ] Inline names/handles/tags in mixed-script lists are wrapped in `<bdi>` — verify a Cluster of mixed LTR/RTL tags doesn't bleed punctuation across items
- [ ] Embedded parentheticals or asides in the opposite script from their surrounding paragraph are isolated (`<bdi>` or `unicode-bidi: isolate`) — check for mirrored-punctuation artifacts at the boundary
