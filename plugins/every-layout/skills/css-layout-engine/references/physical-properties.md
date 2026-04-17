# Physical Property Migration

Source: `decisions.md` §13

`width`, `height`, `min-width`, `max-width`, `margin-left`, `border-left` etc. are prohibited by ELP_004. Use logical equivalents:

| Physical | Logical |
|----------|---------|
| `width` | `inline-size` |
| `height` | `block-size` |
| `min-width` | `min-inline-size` |
| `max-width` | `max-inline-size` |
| `min-height` | `min-block-size` |
| `max-height` | `max-block-size` |
| `margin-left` / `margin-right` | `margin-inline-start` / `margin-inline-end` |
| `border-left` | `border-inline-start` |
| `border-radius: 0 4px 4px 0` | `border-start-start-radius: 0; border-start-end-radius: 4px; border-end-end-radius: 4px; border-end-start-radius: 0;` |

## Accepted Exceptions

| Property | Context | Why |
|----------|---------|-----|
| `translate: 0 1px` | Active press micro-interaction | No logical equivalent for CSS transforms. Spatial, not directional. |
| `translateX(-50%)` | Centering (toast, Imposter) | No logical equivalent. Used only in conjunction with `inset-inline-start: 50%`. |
| SVG `width`/`height` attributes | Inline SVG in HTML | SVG attributes, not CSS properties. `inline-size`/`block-size` do not apply to SVG presentation attributes. |
| `<img width="" height="">` | HTML attributes for CLS prevention | These are HTML attributes, not CSS. They set intrinsic aspect ratio. |
