#!/usr/bin/env bash
# 117-mp2-per-os-claim.sh — gate (g)'s MP2 claim is per-OS empirical, not
# categorical, and BOTH measurements stay dated wherever the topic appears.
#
# THE DEFECT (1.16.7, WO-1.16.6 Item 1). Gate (g) asserted a categorical:
# "AVFoundation has no MPEG Layer II path for mp4a/.mp2 tracks: no positive
# report of Layer II decode in QuickTime X/AVFoundation exists in any container,
# and this bench measured silence" (D3, 1.13). On 2026-08-29 this project
# produced the positive report — the feed.ts deliverable (avc1 + a .mp2 Layer II
# track, NO PCM access track) plays in QuickTime, audio included — and then
# watched the gate assert the opposite over that very measurement.
#
# THE PRECEDENT IS IN-HOUSE. The categorical "QuickTime cannot decode 4:2:2"
# refusal was falsified by a bench measurement and demoted in 1.11 (WO 4.1) to
# per-file, per-OS empirical proof (C56 REVERSED, C72). This is that demotion,
# applied to C102. Decode support drifts by OS in BOTH directions (C63), so the
# D3 silence measurement is not called a lie — it is dated and kept, exactly as
# C56's 26.5.2-era failure record was kept when its 4:2:2 half reversed.
#
# WHAT THIS ROUND DOES NOT CHANGE: the verdict CLASS. An MP2 track with no PCM
# access track was an advisory REVIEW before and is an advisory REVIEW now.
# This round changes what is SAID, not what is scored — §2 pins that, so a
# future edit cannot quietly promote or demote the finding while reworded.
#
# Standalone: bash tests/regression.d/117-mp2-per-os-claim.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env/fixture failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; REF="$TESTS/../references"; SKILL="$TESTS/../SKILL.md"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT INT TERM HUP
pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

echo "== 0. fixture: an MP2 track in a QTFF file with NO PCM access track =="
ffmpeg -nostdin -v error -f lavfi -i "testsrc2=size=320x240:rate=25" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 3 \
  -c:v libx264 -pix_fmt yuv420p -c:a mp2 -b:a 192k -f mpegts "$WORK/src.ts" -y 2>/dev/null \
  || { echo "fixture mux failed"; exit 2; }
ffmpeg -nostdin -v error -i "$WORK/src.ts" -map 0:v -map 0:a -c copy -f mov "$WORK/out.mov" -y 2>/dev/null \
  || { echo "fixture remux failed"; exit 2; }
tag=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$WORK/out.mov")
[ "$tag" = ".mp2" ] && ok "fixture carries a .mp2 sample entry and no PCM track" || no "tag=$tag, want .mp2"

REP="$WORK/verify.out"
bash "$SC/verify.sh" "$WORK/src.ts" "$WORK/out.mov" >"$REP" 2>&1
grep -q "MP2 audio with NO PCM access track" "$REP" \
  && ok "gate (g) fired on the fixture" || { no "gate (g) did not fire"; }

echo "== 1. the claim is stated as PER-OS EMPIRICAL =="
grep -qi "PER-OS EMPIRICAL" "$REP" && ok "the gate says the question is per-OS" || no "no per-OS framing"
grep -qi "PROVE IT ON YOUR TARGET MACHINE" "$REP" \
  && ok "the gate tells the operator to prove it on the target" || no "no prove-it instruction"

echo "== 2. BOTH measurements are present and DATED (neither erased) =="
grep -q "2026-08-29" "$REP" && ok "the positive report is dated (2026-08-29)" || no "positive report undated/absent"
grep -q "2026-08-15" "$REP" && ok "the D3 silence measurement is dated (2026-08-15)" || no "D3 measurement undated/absent"
grep -qi "measured PLAYING" "$REP" && ok "the positive report is stated as measured" || no "no measured-playing statement"
grep -qi "measured SILENT" "$REP" && ok "the negative report is kept, not erased" || no "D3 silence dropped"

echo "== 3. the sidecar note (.mp2 is not an Apple-documented sample entry) =="
grep -qi "not an Apple-documented" "$REP" && ok "the spec-conformance note survives the reversal" \
  || no "sidecar note missing"
grep -qi "sidecar" "$REP" && ok "the note says it belongs in a sidecar" || no "no sidecar pointer"

echo "== 4. the CATEGORICAL sentences are gone from the gate =="
# The gate wraps its prose, so these sentences span line breaks in the report.
# Match against a whitespace-collapsed copy or the assertion is decorative:
# unflattened, "no positive report of Layer II decode" passes on the very tree
# that prints it, because the line ends after "Layer II".
FLAT="$WORK/flat.txt"; tr '\n' ' ' < "$REP" | tr -s ' ' > "$FLAT"
if grep -qi "no positive report of Layer II decode" "$FLAT"; then
  no "the categorical 'no positive report' sentence is still printed"
else ok "'no positive report ... in any container' is gone"; fi
if grep -qi "has no playable audio in QuickTime" "$FLAT"; then
  no "the categorical 'no playable audio' claim is still printed"
else ok "'this file has no playable audio in QuickTime' is gone"; fi
if grep -qi "AVFoundation has no MPEG Layer II path" "$FLAT"; then
  no "the categorical 'has no MPEG Layer II path' claim is still printed"
else ok "'AVFoundation has no MPEG Layer II path' is gone"; fi

echo "== 5. the verdict CLASS is unchanged: advisory REVIEW, not FAIL =="
v=$(grep -oE "^>> (OK|REVIEW|FAIL)" "$REP" | head -1 | awk '{print $2}')
[ "$v" = REVIEW ] && ok "verdict is REVIEW (what is SAID changed, not what is scored)" \
  || no "verdict is '$v', want REVIEW"

echo "== 6. the sweep (V.1): no categorical MP2 claim survives anywhere in the tree =="
# The claim registry deliberately KEEPS the old sentence inside its reversal
# record — that is the house idiom (a registry records reversals, it does not
# erase them), so lines carrying the reversal marker are exempt.
PAT="no positive report of Layer II|undecodable by AVFoundation|has no MPEG Layer II path|not optional for this source class"
. "$TESTS/lib-harness.sh" 2>/dev/null || { echo "cannot source lib-harness.sh"; exit 2; }
rogue=0
while IFS= read -r hit; do
  case "$hit" in *REVERSED*|*"until a counterexample"*) continue;; esac
  echo "     $(printf '%s' "$hit" | cut -c1-160)"; rogue=$((rogue+1))
done < <({
    # docs: raw (prose IS the artifact here), minus the reversal record
    grep -rniE "$PAT" "$SKILL" "$REF" 2>/dev/null
    # scripts: through the stripper, so a "never do X" comment naming the
    # categorical stays CLEAN — the prose lane has to be able to name it
    for f in "$SC"/*.sh "$SC"/*.py; do
      rtm_strip_comments "$f" 2>/dev/null | grep -niE "$PAT" | sed "s|^|$f:|"
    done
  })
[ "$rogue" -eq 0 ] && ok "no categorical MP2-unplayable claim outside the reversal record" \
  || no "$rogue categorical claim(s) survive"

echo "== 7. both dates appear wherever the topic is documented =="
for d in "$SKILL" "$REF/ingest-compatibility.md" "$REF/verification-safety.md" "$REF/qtff-claims.md"; do
  b=$(basename "$d")
  if grep -q "2026-08-29" "$d" && grep -q "2026-08-15" "$d"; then
    ok "$b carries both dated measurements"
  else
    no "$b is missing one of the two dates"
  fi
done

echo
echo "== 117 summary: $pass passed, $fail failed =="
[ "$fail" -eq 0 ] || exit 1
exit 0
