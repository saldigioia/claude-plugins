#!/usr/bin/env bash
# Master-reference end-to-end test (Cmd 19).
#
# Asserts:
# 1. Pass 1+2 with manifest source.master_reference: master probed, no errors.
# 2. Pass 3 plans a reference_bundle with master + instrumental + acapella.
# 3. Pass 4 writes the bundle dir with three FLACs and a bundle.log.md sidecar.
# 4. Pass 5 reference battery's recombine null verdict is "pass" (the master
#    is the unity sum of the stems by construction; residual must be ≤ -90 dBTP
#    within dither noise).
# 5. Mismatched master (different rate/depth/duration) fires the right errors
#    and returns exit 1 from analyze (without --force).
#
# Set -e so any unexpected failure aborts immediately. The Cmd-19 refusal
# tests use explicit `if !` blocks because we want exit 1 to be a pass.

set -uo pipefail
cd "$(dirname "$0")/.."

FIX=tests/fixtures/with-master
OUT=/tmp/_s2m_master_test
rm -rf "$OUT"
mkdir -p "$OUT"

fail=0
fail_with() { echo "  [fail] $*"; fail=1; }

echo "=== 1. Pass 1+2 with manifest master_reference ==="
if ! python3 stems_to_mixdown/analyze.py --dir "$FIX" > "$OUT/a.json" 2> "$OUT/a.err"; then
    fail_with "analyze exited nonzero"
    cat "$OUT/a.err"
fi
master_present=$(jq -r '.master_reference != null' "$OUT/a.json")
if [ "$master_present" != "true" ]; then
    fail_with "analysis.json.master_reference is null but manifest declares it"
fi
errors=$(jq -r '[.red_flags[] | select(.severity=="error")] | length' "$OUT/a.json")
if [ "$errors" != "0" ]; then
    fail_with "expected zero errors; got $errors"
    jq '.red_flags' "$OUT/a.json"
fi

echo "=== 2. Pass 3 plans the reference bundle ==="
python3 stems_to_mixdown/plan.py --analysis "$OUT/a.json" --output-dir "$OUT/mixdowns" \
    > "$OUT/p.json" 2> "$OUT/p.err"
bundle_present=$(jq -r '.reference_bundle != null' "$OUT/p.json")
if [ "$bundle_present" != "true" ]; then
    fail_with "plan.reference_bundle is null"
fi
bundle_members=$(jq -r '.reference_bundle.members | length' "$OUT/p.json")
if [ "$bundle_members" != "3" ]; then
    fail_with "expected 3 bundle members (master + instrumental + acapella); got $bundle_members"
fi

echo "=== 3. Pass 4 writes the bundle ==="
python3 stems_to_mixdown/mix.py --plan "$OUT/p.json" --yes > "$OUT/m.json" 2> "$OUT/m.err"
bundle_dir="$OUT/mixdowns/reference-bundle"
for role in master instrumental acapella; do
    f="$bundle_dir/with-master_$role.flac"
    if [ ! -f "$f" ]; then
        fail_with "bundle missing $role file at $f"
    fi
done
if [ ! -f "$bundle_dir/bundle.log.md" ]; then
    fail_with "bundle missing bundle.log.md"
fi

echo "=== 4. Pass 5 reference battery — recombine null = pass ==="
python3 stems_to_mixdown/verify.py --plan "$OUT/p.json" > "$OUT/v.json" 2> "$OUT/v.err"
verdict=$(jq -r '.reference_battery.headline_verdict' "$OUT/v.json")
if [ "$verdict" != "pass" ]; then
    fail_with "expected headline verdict 'pass'; got '$verdict'"
    jq '.reference_battery' "$OUT/v.json"
fi
recombine_residual=$(jq -r '.reference_battery.recombine.residual_dbtp' "$OUT/v.json")
echo "  recombine residual: $recombine_residual dBTP"

echo "=== 5. Mismatched master fires Cmd 19 refusal ==="
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=3:sample_rate=44100" -ac 2 \
    -c:a pcm_s16le -bits_per_raw_sample 16 "$OUT/bad_master.wav" 2> /dev/null
# Expect exit 1 because of master_rate / depth / duration mismatch.
if python3 stems_to_mixdown/analyze.py --dir "$FIX" --master "$OUT/bad_master.wav" \
    > "$OUT/bad.json" 2> "$OUT/bad.err"; then
    fail_with "analyze with bad master exited 0; expected 1 (master_*_mismatch errors)"
fi
codes=$(jq -r '[.red_flags[] | select(.severity=="error") | .code] | sort | join(",")' "$OUT/bad.json")
expected="master_depth_mismatch,master_duration_mismatch,master_rate_mismatch"
if [ "$codes" != "$expected" ]; then
    fail_with "expected error codes [$expected]; got [$codes]"
fi

if [ "$fail" -eq 0 ]; then
    echo ""
    echo "=== PASS — master-reference pipeline (Cmd 19) verified ==="
    exit 0
else
    echo ""
    echo "=== FAIL ==="
    exit 1
fi
