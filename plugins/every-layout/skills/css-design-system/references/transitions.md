# Transition and Animation Rules

Source: `decisions.md` §10

## Duration Scale

| Token | Value | Use |
|-------|-------|-----|
| `--transition-fast` | `0.1s` | Hover color/opacity changes |
| `--transition-normal` | `0.2s` | Expand/collapse, toast entrance |
| `--transition-slow` | `0.4s` | Page-level transitions, skeleton fade |

## Rules

- All `transition-duration` and `animation-duration` values must reference a duration token.
- Every transition or animation rule must live inside `@media (prefers-reduced-motion: no-preference)` so motion applies only to users who have not opted out. Provide a separate `@media (prefers-reduced-motion: reduce)` block with `animation: none` and `transition: none` so users who have opted out get an instant state change.
- Only properties on the canonical allowlist (`references/motion-allowlist.md`) may be transitioned.
- The easing function `ease-out` is the default for entrances; `ease-in` for exits. Never use `linear` on UI animations.

## Micro-Interaction: Active Press

All interactive elements use `translate: 0 1px` on `:active` for tactile feedback. This is a physical property with no logical equivalent -- accepted as a necessary exception since transforms are spatial, not directional.

| Rule | Detail |
|------|--------|
| Pattern | `:active { translate: 0 1px; }` |
| Scope | All clickable elements: buttons, card links, filter items |
| Exception | `translate` is physical -- no logical CSS equivalent exists. Exempt from ELP_004. |
