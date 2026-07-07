# Escape registry — archive-site demo

Registered intentional deviations, read directly by `bin/css-strict.sh` and
`bin/js-budget.sh` (see `escapes.md.template` at the plugin root for the
field rules). This demo ships **zero JavaScript on every route except one**:
the `/react-port` page deliberately hydrates three React islands to
demonstrate the framework-port pattern, which drags in the React 19 runtime
and blows the ELA_005 budget by design. That overage is registered here so a
built `dist/` still passes `js-budget.sh` honestly instead of never being
measured.

## Active escapes

| ESC ID | Target (glob) | Axiom | Lines | Expires | Owner | Justification |
|--------|---------------|-------|-------|---------|-------|---------------|
| ESC_JS_EXCESS | `_astro/*.js` | ELA_005 | - | 2099-12-31 | @rare-data-club | React-port demo page: React 19 runtime + three client:visible islands exist to demonstrate the port pattern; every other route ships 0 KB JS. Far-future review date per the no-permanent-escapes rule. |
| ESC_JS_EXCESS | `page-total` | ELA_005 | - | 2099-12-31 | @rare-data-club | Dist-total proxy exceeds 30 KB solely because of the react-port demo chunks registered above. |
