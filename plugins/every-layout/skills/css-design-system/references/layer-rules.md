# Layer Rules

Source: `decisions.md` §2

## Canonical Order

```css
@layer global, brand, components, bespoke.legacy, bespoke.dataviz, bespoke.editorial, bespoke.embed;
```

| Rule | Rationale |
|------|-----------|
| Consumer CSS stays unlayered (highest priority) | Unlayered beats all layers -- this is by design |
| Brand tokens use `[data-brand]` selectors, never `:root` in overrides | Enables sub-page brand sections via inheritance |
| Bespoke sublayers don't count toward the 4-layer soft warning | Only top-level layers (global, brand, components, bespoke) count |
| Brand mechanism works via custom property inheritance, not layer priority | Brand layer sets tokens; components inherit them. Layer order is irrelevant to this resolution. |

## System Variants vs. Escape Hatches

Data-attribute modifiers on primitives (`data-ragged`, `data-invert`, `data-snap`, `data-no-stretch`, etc.) are **system variants**, not escape hatches. No `@escape` comment required. They follow the primitive's own logic with a single-property behavioral change.

## Consumer Sizing Vocabularies

Domain-specific `data-size` attributes (e.g., `compact`, `prominent`, `hero`) that map to `--min` on Grid are consumer-layer concerns. They belong in the consumer's own CSS (unlayered), not in the skillpack. Consumer CSS beats all layers by default.

## Brand Nesting

When `data-brand` attributes are nested, missing tokens inherit from the *parent brand*, not the default. Every brand file must define ALL 9 required interface tokens. Partial brand files are not supported.
