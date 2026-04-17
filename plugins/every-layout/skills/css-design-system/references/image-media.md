# Image and Media Rules

Source: `decisions.md` §12 (universal rules only)

## Image Sizing

| Rule | Detail |
|------|--------|
| Always provide `width` and `height` attributes | Prevents CLS. Source values from database/metadata. |
| Use `loading="lazy"` on below-fold images | Browser handles intersection. No JS required. |
| Use `decoding="async"` on all images | Prevents main-thread decode blocking. |
| Use `inline-size: 100%; block-size: auto;` | NOT `width: 100%; height: auto;` (physical property violation). |
| Background placeholder | Set `background: var(--color-surface)` on images to show surface color during load. |

## Responsive Images

| Rule | Detail |
|------|--------|
| `srcset` + `sizes` | Required for any image served at multiple resolutions. |
| Art direction | Use `<picture>` with `<source media="...">` only when cropping changes per viewport. For simple scaling, `srcset` is sufficient. |
