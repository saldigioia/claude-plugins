# Primitive Decision Tree

Walk the questions in order. Stop at the first "yes" — that's your primitive. If none apply, re-read the problem statement; you may be describing something a single primitive can't solve, in which case see `combinations.md`.

## Q1 — Is this about spacing between elements?
- **Vertical spacing between siblings** → **ELC_STACK**
- **Horizontal spacing with wrapping** → **ELC_CLUSTER**
- **Both directions uniformly** → **ELC_GRID**

## Q2 — Is this a two-element layout?
- **One fixed, one flexible (nav + content)** → **ELC_SIDEBAR**
- **Equal elements that flip between side-by-side and stacked** → **ELC_SWITCHER**

## Q3 — Is this a grid of items?
- **Equal columns, responsive auto-fit** → **ELC_GRID**
- **Horizontal scrolling row** → **ELC_REEL**

## Q4 — Is this about centering?
- **Horizontal centering with a measure cap** → **ELC_CENTER**
- **Vertical centering on a full-viewport shell** → **ELC_COVER**
- **Overlay / modal centering over arbitrary content** → **ELC_IMPOSTER**

## Q5 — Is this about containment or aspect?
- **Aspect-ratio media or embed** → **ELC_FRAME**
- **Padded / bordered region** → **ELC_BOX**
- **Element that needs its own container-query context** → **ELC_CONTAINER**

## Q6 — Is this about inline elements?
- **Icon paired with text** → **ELC_ICON**

---

## Quick reference

| Need | Primitive | ID |
|---|---|---|
| Vertical gaps | Stack | ELC_STACK |
| Padded box | Box | ELC_BOX |
| Centered content | Center | ELC_CENTER |
| Tag / button row | Cluster | ELC_CLUSTER |
| Sidebar + content | Sidebar | ELC_SIDEBAR |
| Card columns that fold | Switcher | ELC_SWITCHER |
| Card columns by width | Grid | ELC_GRID |
| Hero / full-viewport shell | Cover | ELC_COVER |
| Aspect-ratio media | Frame | ELC_FRAME |
| Horizontal scroller | Reel | ELC_REEL |
| Modal / overlay | Imposter | ELC_IMPOSTER |
| Inline icon + text | Icon | ELC_ICON |
| Container-query context | Container | ELC_CONTAINER |

See `skills/css-layout-engine/references/primitives.md` for the full card for each ID.
