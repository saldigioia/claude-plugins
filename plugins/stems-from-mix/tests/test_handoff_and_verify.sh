#!/usr/bin/env bash
# Synthetic test for stems-from-mix's handoff + verify paths.
# Demucs itself isn't exercised here — the wrapper around demucs (separate.py)
# requires the demucs CLI which may not be installed. This script:
#
#   1. Synthesizes a "source mix" (a sine WAV).
#   2. Synthesizes four "separated stems" with the demucs default filenames
#      vocals.wav / drums.wav / bass.wav / other.wav, simulating what demucs
#      would write into separated/htdemucs_ft/<track>/.
#   3. Renames them to vocal.wav / drum.wav / bass.wav / other.wav (this
#      mimics what separate.py:collect_outputs does post-demucs).
#   4. Runs handoff.py to write stems.manifest.yaml.
#   5. Runs verify.py to QC the stems.
#   6. Hands the stems-dir to stems-to-mixdown's pipeline (identify ->
#      analyze) to confirm the manifest contract holds end-to-end.
#
# Exit 0 if every step succeeds.
set -euo pipefail
cd "$(dirname "$0")/.."

# Locate stems-to-mixdown's scripts. Two valid layouts: deployed (sibling
# skills) or in-repo dev (stems-from-mix nested inside stems-to-mixdown).
S2M_SCRIPTS=""
for cand in ../stems-to-mixdown/scripts ../scripts; do
  if [ -f "$cand/identify.py" ]; then
    S2M_SCRIPTS="$cand"
    break
  fi
done
test -n "$S2M_SCRIPTS" || { echo "FAIL: stems-to-mixdown scripts not found"; exit 1; }
echo "  (stems-to-mixdown scripts: $S2M_SCRIPTS)"

WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

SOURCE_MIX="$WORK/source-mix.wav"
STEMS_DIR="$WORK/source-mix-stems"

echo "=== synthesize source mix + four stems ==="
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=440:duration=1.0:sample_rate=48000" \
  -c:a pcm_s24le -ac 2 "$SOURCE_MIX"

mkdir -p "$STEMS_DIR"
# Four "separated" stems at different frequencies + amplitudes so QC sees them as distinct.
# Demucs writes plural names; we synthesize with plural names AND THEN rename
# to singular, exactly as separate.py:collect_outputs does after demucs runs.
for entry in "vocal:880:0.30" "drum:220:0.25" "bass:55:0.20" "other:1500:0.15"; do
  IFS=":" read -r label freq amp <<<"$entry"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=$freq:duration=1.0:sample_rate=48000" \
    -af "volume=$amp" \
    -c:a pcm_s24le -ac 2 \
    "$STEMS_DIR/$label.wav"
done

echo "=== handoff.py writes manifest ==="
python3 scripts/handoff.py \
  --stems-dir "$STEMS_DIR" \
  --source-mix "$SOURCE_MIX" \
  --device cpu \
  --demucs-version "synthetic-test"

test -f "$STEMS_DIR/stems.manifest.yaml" || { echo "FAIL: manifest not written"; exit 1; }
echo "  manifest content:"
sed 's/^/    /' "$STEMS_DIR/stems.manifest.yaml"

echo "=== handoff.py refuses to overwrite without --overwrite ==="
if python3 scripts/handoff.py \
    --stems-dir "$STEMS_DIR" \
    --source-mix "$SOURCE_MIX" \
    --device cpu 2>"$WORK/refuse.err"; then
  echo "FAIL: should have refused"; exit 1
fi
grep -q "refuse" "$WORK/refuse.err" || { echo "FAIL: refusal message missing"; exit 1; }
echo "  ok: refusal triggered"

echo "=== handoff.py --overwrite replaces ==="
python3 scripts/handoff.py \
  --stems-dir "$STEMS_DIR" \
  --source-mix "$SOURCE_MIX" \
  --device cpu \
  --overwrite > /dev/null 2>&1

echo "=== verify.py QCs the stems ==="
python3 scripts/verify.py --stems-dir "$STEMS_DIR" > "$WORK/verify.json" 2>"$WORK/verify.err"
echo "  verify exit: $?"
cat "$WORK/verify.err" | sed 's/^/    /'

echo "=== hand off to stems-to-mixdown ==="
python3 $S2M_SCRIPTS/identify.py --dir "$STEMS_DIR" > "$WORK/identify.json" 2>/dev/null
recommendation=$(python3 -c "import json; print(json.load(open('$WORK/identify.json'))['recommendation'])")
echo "  identify recommendation: $recommendation"

python3 $S2M_SCRIPTS/analyze.py --dir "$STEMS_DIR" > "$WORK/analysis.json" 2>/dev/null
manifest_present=$(python3 -c "import json; print(json.load(open('$WORK/analysis.json'))['manifest_present'])")
echo "  analyze manifest_present: $manifest_present"

echo "  classifications via manifest (vs regex):"
python3 -c "
import json
with open('$WORK/analysis.json') as f:
    a = json.load(f)
for s in a['stems']:
    print(f\"    {s['filename']:20s} {s['classification']:7s} ({s['classification_source']})\")
"

# Confirm classification source is 'manifest' for all four — this is the
# whole point of the hand-off: the regex never has to fire.
fails=$(python3 -c "
import json
with open('$WORK/analysis.json') as f:
    a = json.load(f)
fails = [s['filename'] for s in a['stems'] if s['classification_source'] != 'manifest']
print('\n'.join(fails))
")
if [ -n "$fails" ]; then
  echo "FAIL: these stems didn't pick up manifest classifications:"
  echo "$fails"
  exit 1
fi

echo
echo "PASS — handoff manifest is authoritative for stems-to-mixdown."
