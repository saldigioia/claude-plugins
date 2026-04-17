# Primitive Combinations

The default answer is always "one primitive." Reach for a combination only when a single primitive demonstrably cannot solve the problem.

## Common pairings

| Combination | When |
|---|---|
| **Stack + Center** | Centered article body with vertical rhythm |
| **Grid + Box** | Card grid with consistent interior padding |
| **Sidebar + Stack** | Sidebar nav with stacked links |
| **Cover + Center** | Hero section with vertically-centered, measure-capped content |
| **Frame + Reel** | Horizontal gallery where each item is aspect-ratio-bound |
| **Cover + Stack** | Full-viewport shell with header/main/footer rhythm |

## Avoid

- **Switcher inside Grid** — both decide column count; conflicting authority
- **Anything inside Frame** beyond a single media child — `overflow: hidden` clips siblings
- **Nested Centers** with larger inner `--measure` — outer caps always win

See `skills/css-layout-engine/references/composition-rules.md` for the full composition matrix and the 8 known composition hazards.
