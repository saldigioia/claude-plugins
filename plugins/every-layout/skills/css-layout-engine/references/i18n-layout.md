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

## Testing Checklist

When building for multilingual audiences, test each page in these configurations:

- [ ] `dir="ltr"` (default) — baseline verification
- [ ] `dir="rtl"` — check Cluster, Sidebar, Grid, Reel, Icon for visual order issues
- [ ] Browser zoom at 400% — verify no horizontal scrolling (WCAG 1.4.10)
- [ ] `lang` attribute set on `<html>` — required for proper hyphenation and voice synthesis
- [ ] Directional icons mirrored in RTL — arrows, chevrons, play buttons
- [ ] No `text-align: left` or `text-align: right` — use `start` and `end`
- [ ] No `float: left` or `float: right` — use logical equivalents or Sidebar
