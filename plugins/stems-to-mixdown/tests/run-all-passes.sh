#!/usr/bin/env bash
# Smoke test — runs every fixture through identify → analyze → plan → mix → verify.
# Smoke means "the pipeline executes end-to-end without crashing"; correctness
# is checked separately by tests/diff-baseline.sh (byte-equivalence) and
# tests/test_format_decision.py (matrix coverage).
#
# Exit 0 if every fixture's pipeline completes (warnings allowed; rate_mismatch
# is expected on mixed-rates and exits 1 on analyze without --force).
set -uo pipefail
cd "$(dirname "$0")/.."

any_fail=0
for fix_dir in tests/fixtures/*/; do
    fix=$(basename "$fix_dir")
    # Skip any mixdown output dir that leaked into tests/fixtures/ from an
    # ad-hoc debug run (the .gitignore catches these for git, but the runner
    # shouldn't try to "test" them as fixtures).
    case "$fix" in
        *-mixdowns) continue ;;
        .*) continue ;;
    esac
    echo "=== $fix ==="

    out_root="/tmp/_s2m_smoke_$fix"
    rm -rf "$out_root"
    mkdir -p "$out_root"

    # Pass 0a — identify (always allowed to succeed)
    if ! python3 stems_to_mixdown/identify.py --dir "$fix_dir" > "$out_root/identify.json" 2> "$out_root/identify.err"; then
        echo "  [fail] identify"
        cat "$out_root/identify.err"
        any_fail=1
        continue
    fi

    # Pass 1+2 — analyze. --force so rate_mismatch / depth_mismatch don't fail
    # the smoke run; the existence and content of red flags is verified by
    # the EXPECTED.md per fixture and the diff-baseline check.
    if ! python3 stems_to_mixdown/analyze.py --dir "$fix_dir" --force > "$out_root/analysis.json" 2> "$out_root/analyze.err"; then
        echo "  [fail] analyze"
        cat "$out_root/analyze.err"
        any_fail=1
        continue
    fi

    # Pass 3 — plan. Output dir overridden so we don't litter ../-mixdowns
    # for every fixture beside the source.
    if ! python3 stems_to_mixdown/plan.py --analysis "$out_root/analysis.json" --output-dir "$out_root/mixdowns" \
        > "$out_root/plan.json" 2> "$out_root/plan.err"; then
        echo "  [fail] plan"
        cat "$out_root/plan.err"
        any_fail=1
        continue
    fi

    # Pass 4 — mix
    if ! python3 stems_to_mixdown/mix.py --plan "$out_root/plan.json" --yes > "$out_root/mix.json" 2> "$out_root/mix.err"; then
        echo "  [fail] mix"
        tail -20 "$out_root/mix.err"
        any_fail=1
        continue
    fi

    # Pass 5 — verify
    if ! python3 stems_to_mixdown/verify.py --plan "$out_root/plan.json" > "$out_root/verify.json" 2> "$out_root/verify.err"; then
        echo "  [fail] verify"
        cat "$out_root/verify.err"
        any_fail=1
        continue
    fi

    groups=$(jq -r '.results[] | "\(.group):\(.status)"' "$out_root/verify.json" | tr '\n' ' ')
    echo "  [ok] $groups"
done

exit $any_fail
