# Print Rules

Source: `decisions.md` §7

## Primitive Linearisation

| Rule | Detail |
|------|--------|
| Stack | Preserved as-is (vertical rhythm translates to print) |
| Box | `break-inside: avoid`. Borders kept for grouping. |
| Center | Remove gutters (`padding-inline: 0`). Page margins handle spacing. |
| Cluster, Sidebar, Switcher | Linearise to single column (`flex-direction: column`) |
| Cover | Collapse `min-block-size` to `auto` (no viewport on paper) |
| Grid | Force `grid-template-columns: 1fr` |
| Frame | Collapse `aspect-ratio: auto`, `object-fit: contain`, `max-block-size: 15cm` |
| Reel | Linearise to column, `overflow: visible`. Wide tables may clip — accepted limitation. |
| Imposter | Collapse to `position: static` |
| Container | Remove containment (`container-type: normal`) |

## Editorial Component Print Rules

| Component | Rule |
|-----------|------|
| Blockquote (EDC_BLOCKQUOTE) | `break-inside: avoid` |
| Pull-quote (EDC_PULLQUOTE) | Hidden entirely (`aria-hidden="true"` -> `display: none`) |

## General Rules

| Rule | Detail |
|------|--------|
| All links | Show URL after text: `a[href^="http"]::after { content: " (" attr(href) ")"; }` |
