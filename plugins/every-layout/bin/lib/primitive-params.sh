# primitive-params.sh — the single source of truth for which custom properties
# may legitimately appear in an inline style="..." attribute.
#
# These are the documented per-instance parameters of the 13 ELC_* primitives
# (see skills/css-layout-engine/references/primitives.md). Carrying one of
# them inline is component parameterization, not bespoke styling; every other
# inline declaration is bespoke CSS outside @layer and fails ELA_002.
#
# Sourced by:
#   bin/css-lint-hook.sh   (PostToolUse warning hook)
#   bin/css-strict.sh      (hard gate — .html/.astro inline-attribute scan)
#   bin/ports-lint.sh      (CSS-in-JS detector — allowed style-object keys)
#
# Add new parameters here when a primitive gains one; never inline the list
# in a script again.

PRIMITIVE_PARAMS="--space --threshold --min --max --sidebar-min --ratio --measure --min-height --gutter --with-sidebar --side-width --content-min --padding --border-thin --item-width --margin --container-name --height --n --d --justify --align --border-width"
