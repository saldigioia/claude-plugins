# Escape Hatch Rules

Source: `decisions.md` §4

| Rule | Detail |
|------|--------|
| Mark HTML | `data-bespoke="{editorial\|embed\|dataviz\|legacy}"` |
| Mark CSS | `@layer bespoke.*`, all selectors descend from `[data-bespoke]` |
| Mark comment | `/* @escape ESC_{CODE} ... */` with author, date, justification |
| Never break | ELP_003 (border-box), ELP_028 (reduced motion), ELP_029 (focus visibility) |
| Conditional: logical properties | Physical properties OK inside `[data-bespoke="dataviz"]` for coordinate axes only |
| Conditional: modular scale | Arbitrary values OK inside bespoke boundary; modular scale required for outer spacing |
| ESC_LEGACY requires | A migration ticket. No ticket, no escape. |
| Audit | `grep -c "@escape ESC_"` quarterly. Flag if >15% of component count. |
| Byte limits | ESC_EDITORIAL: 5KB/instance, 20KB total. ESC_DATAVIZ: 3KB/instance, 15KB total. ESC_LEGACY: 10KB/instance, 30KB total. |
| Bespoke selectors must not target | System primitive class names (`.stack`, `.center`, `.grid`, etc.) |
