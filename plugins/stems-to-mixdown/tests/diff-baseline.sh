#!/usr/bin/env bash
# Compare current pipeline outputs against tests/baselines/*.json for byte
# equivalence (modulo non-deterministic fields). Used after Phase 3 refactors
# to confirm the decomposition didn't change behavior. Exits 0 if every
# fixture matches; 1 if any drift is detected.
set -uo pipefail
cd "$(dirname "$0")/.."

# Strip non-deterministic / environment-dependent fields before comparing.
# - plan.generated_at is wall-clock.
# - .directory and master_reference.path / stems[].path / source paths
#   embed the host's absolute path to the plugin checkout, which differs
#   between Sal's machine, the marketplace clone, and CI runners.
# - reference_bundle.directory / .members[].source / .output_path inherit
#   the same absolute-path leak when a master is present.
# - groups[].output_path / scout_filter_graph / filter_graph also embed
#   absolute paths to inputs.
strip() {
    jq '
        walk(
            if type == "string" then
                gsub("/[^ ]*?/tests/fixtures/"; "TESTROOT/tests/fixtures/")
            else . end
        )
        | del(.generated_at)
    ' "$1"
}

any_fail=0
for fix in mono-stems mixed-rates dirty-inputs 24-in-32 with-master; do
    a_baseline=tests/baselines/${fix}.analysis.json
    p_baseline=tests/baselines/${fix}.plan.json
    [ -f "$a_baseline" ] || { echo "[skip] no baseline for $fix"; continue; }

    a_now=/tmp/_now_${fix}.analysis.json
    p_now=/tmp/_now_${fix}.plan.json
    python3 stems_to_mixdown/analyze.py --dir "tests/fixtures/$fix" --force > "$a_now" 2>/dev/null
    python3 stems_to_mixdown/plan.py --analysis "$a_now" > "$p_now" 2>/dev/null

    if ! diff -q <(strip "$a_baseline") <(strip "$a_now") > /dev/null; then
        echo "[fail] $fix analysis.json drifted"
        diff <(strip "$a_baseline") <(strip "$a_now") | head -40
        any_fail=1
        continue
    fi
    if ! diff -q <(strip "$p_baseline") <(strip "$p_now") > /dev/null; then
        echo "[fail] $fix plan.json drifted"
        diff <(strip "$p_baseline") <(strip "$p_now") | head -40
        any_fail=1
        continue
    fi
    echo "[ok] $fix"
done
exit $any_fail
