# z-index Stacking Context

Source: `decisions.md` §8

| Layer | Token | Value | Use |
|-------|-------|-------|-----|
| Base content | `--z-base` | `0` | Default flow |
| Sticky header | `--z-sticky` | `10` | Sticky-positioned elements |
| Dropdown/popover | `--z-dropdown` | `20` | Menus, tooltips |
| Overlay | `--z-overlay` | `30` | Imposter, lightbox backdrop |
| Modal | `--z-modal` | `40` | Modal dialogs |
| Toast | `--z-toast` | `50` | Transient notifications |
| Skip link | `--z-skip` | `60` | Accessibility skip link (always on top) |

## Rules

- Never use arbitrary z-index values. Pick from the scale above.
- Every `position: sticky`, `fixed`, or `absolute` with z-index must reference a token.
- New stacking levels require adding a row to this table.
