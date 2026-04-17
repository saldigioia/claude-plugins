# Semantic HTML Rules — Editorial Components

Source: `decisions.md` §6 (EDC_* components only)

## Components

| Component | Element | Why |
|-----------|---------|-----|
| Blockquote (EDC_BLOCKQUOTE) | `<blockquote cite="..." lang="...">` | External citation. `cite` attr = URL. `lang` when quoting other languages. |
| Pull-quote (EDC_PULLQUOTE) | `<aside aria-hidden="true">` | Visual repetition of existing text. `aria-hidden` prevents duplicate reading. **Only use when text already appears in article body.** |
| Figure (EDC_FIGURE) | `<figure>` + `<figcaption><small>` | Self-contained media. `<small>` = side comment (semantically correct for captions). |
| Data table (EDC_DATATABLE) | `<table>` with `<caption>`, `scope` on all `<th>` | Tabular data. Reel wrapper needs `tabindex="0"` + `role="region"` + `aria-labelledby`. |
| SVG in figure | `role="img"` + `aria-labelledby` -> `<title>` + `<desc>` | Prevents screen readers traversing every SVG node. |
| Video in figure | `<track kind="captions">` | WCAG 1.2.2 requirement. Not optional. |
| Sortable table header | `<button>` inside `<th>` + `aria-sort` | Not a div. Not a span. A button. |

## Anti-Patterns

| Do Not | Because | Instead |
|--------|---------|---------|
| `<blockquote>` for pull-quotes | Tells AT "external source" when it's not | `<aside aria-hidden="true">` |
| `<figure>` for pull-quotes | Figure is self-contained; pull-quote is bound to position | `<aside>` |
| Stacking table columns vertically | Destroys comparative value of tabular data | Reel (horizontal scroll) |
| `aria-hidden` on inner element of pull-quote | Leaves empty visible landmark wrapper | Put `aria-hidden` on the `<aside>` itself |
| Custom JS audio/video controls without native fallback | Keyboard inaccessible, no screen reader support | Use native `<audio controls>` or web component with built-in a11y |
| Wrapping audio in a Frame | Audio has no visual aspect ratio; Frame clips/distorts controls | Use Box (padding + border) for audio player containment |
