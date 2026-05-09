#!/usr/bin/env bash
# JSON-baseline drift detector — ADVISORY, not a gate.
#
# Compares analyze.json / plan.json output against the committed baselines
# in tests/baselines/. Useful for spotting structural drift in the JSON
# contract during refactors, but the baselines were captured against a
# specific environment (a particular mediainfo / wavinfo / ffmpeg combo)
# and false-positive drift is common when those tools change.
#
# Use this script as a hint that something has changed; the real gate is
# `pytest tests/test_perceptual_outputs.py` which asserts perceptual
# invariants (format, true peak, recombine null) and is environment-
# independent.
#
# Exits 0 always. Drift is reported on stderr.
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

any_drift=0
for fix in mono-stems mixed-rates dirty-inputs 24-in-32 with-master; do
    a_baseline=tests/baselines/${fix}.analysis.json
    p_baseline=tests/baselines/${fix}.plan.json
    [ -f "$a_baseline" ] || { echo "[skip] no baseline for $fix"; continue; }

    a_now=/tmp/_now_${fix}.analysis.json
    p_now=/tmp/_now_${fix}.plan.json
    python3 stems_to_mixdown/analyze.py --dir "tests/fixtures/$fix" --force > "$a_now" 2>/dev/null
    python3 stems_to_mixdown/plan.py --analysis "$a_now" > "$p_now" 2>/dev/null

    if ! diff -q <(strip "$a_baseline") <(strip "$a_now") > /dev/null; then
        echo "[drift] $fix analysis.json drifted"
        diff <(strip "$a_baseline") <(strip "$a_now") | head -40
        any_drift=1
        continue
    fi
    if ! diff -q <(strip "$p_baseline") <(strip "$p_now") > /dev/null; then
        echo "[drift] $fix plan.json drifted"
        diff <(strip "$p_baseline") <(strip "$p_now") | head -40
        any_drift=1
        continue
    fi
    echo "[ok] $fix"
done

if [ "$any_drift" -ne 0 ]; then
    echo ""
    echo "Drift detected. This is advisory — perceptual invariants are the gate."
    echo "Run \`python3 -m pytest tests/test_perceptual_outputs.py\` for the real test."
fi
exit 0
