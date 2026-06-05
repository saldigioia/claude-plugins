# Fixture: Choose-Primitive Scenarios

Scenario bank for the `choose_primitive` eval. Each item is a layout requirement
with the single correct Every Layout primitive (`ELC_*`) and the near-miss
alternative a good answer should explicitly rule out. Drawn from the decision
tree in `eval/prompts/choose_primitive.md`; covers all 13 primitives.

EXPECTED AUDIT RESULT: a correct run identifies the expected primitive for each
scenario (see `## Scoring (0-10)` in the prompt). Score = primitive correctness
across the 13 scenarios, plus alternatives reasoning and configuration quality.

| # | Layout requirement | Expected primitive | Near-miss to rule out |
|---|--------------------|--------------------|-----------------------|
| 1 | Even vertical rhythm between stacked form fields | `ELC_STACK` | Cluster (wrong axis) |
| 2 | A row of filter tags that wraps onto multiple lines and stays evenly gapped | `ELC_CLUSTER` | Stack (no wrap / wrong axis) |
| 3 | Fixed-measure nav beside a main column that takes the remaining space, collapsing when cramped | `ELC_SIDEBAR` | Switcher (Sidebar is asymmetric) |
| 4 | Two equal cards side by side that stack together once the container gets narrow | `ELC_SWITCHER` | Sidebar (Switcher is symmetric) |
| 5 | A responsive gallery of equal product cards with a sensible minimum column width | `ELC_GRID` | Reel (Grid wraps, doesn't scroll) |
| 6 | A horizontally scrolling strip of thumbnails | `ELC_REEL` | Grid (Reel scrolls on one axis) |
| 7 | An article body centered in the viewport with a comfortable max measure | `ELC_CENTER` | Box (Center constrains measure) |
| 8 | A full-viewport-height hero with its content vertically centered | `ELC_COVER` | Center (Cover handles block-axis) |
| 9 | A modal dialog centered over the page regardless of content height | `ELC_IMPOSTER` | Cover (Imposter overlays) |
| 10 | Hold a 16:9 aspect ratio for an embedded video across widths | `ELC_FRAME` | Box (Frame fixes ratio) |
| 11 | Consistent padding and a border around a callout, theme-aware | `ELC_BOX` | Center (Box is padding/border) |
| 12 | A card that adapts its internal layout to its own container width, not the viewport | `ELC_CONTAINER` | Grid (Container = query context) |
| 13 | An inline icon that scales with the adjacent text size and inherits its color | `ELC_ICON` | Frame (Icon is text-relative) |
