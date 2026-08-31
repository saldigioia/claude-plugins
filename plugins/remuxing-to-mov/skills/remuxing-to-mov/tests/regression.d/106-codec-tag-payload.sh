#!/usr/bin/env bash
# 106-codec-tag-payload.sh — gate (i): the sample entry must describe the
# payload underneath it.
#
# WHY (measured 2026-08-29). A remux of MPEG-1 Layer II audio shipped with a
# '.mp3' sample entry. Apple documents '.mp3' as Layer *3*. The file was
# bit-identical to its source, so gates (a)/(b) proved it lossless; ffmpeg
# resolves '.mp3' to the mp3float decoder, which decodes Layer II happily, so
# gate (g)'s bounded decode found zero errors and the tag was on the
# allowlist. Every check the plugin had passed a mislabelled file.
#
# The fixture is minted by PATCHING the stsd fourcc of a real '.mp2' build,
# because ffmpeg's own muxer refuses to write the combination ("Tag .mp3
# incompatible with output codec id") — which is itself the evidence that the
# combination is wrong.
#
# Pins:
#   1. tag<->codec disagreement is a MISMATCH, and gate (i) FAILs the run;
#   2. the HONEST '.mp2' build passes — this gate must not cost a legal route;
#   3. an unreadable frame header is reported UNPROVEN by name, never passed;
#   4. AAC/PCM (no readable frame header) pass the half that is provable and
#      say the other half is not (II.1);
#   5. the standalone tool's exit contract: 0 clean, 1 mismatch.
#
# Standalone: bash tests/regression.d/106-codec-tag-payload.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
command -v python3 >/dev/null || { echo "SKIP: python3 absent — gate (i) cannot run here"; echo "codec-tag-payload: 0 passed, 0 failed"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -y -v error "$@"; }

echo "== 0. fixtures: an honest Layer II build, and the same build mislabelled =="
S="$WORK/src.ts"
ff -f lavfi -i "sine=1000:r=48000" -t 2 -c:a mp2 -b:a 192k -f mpegts "$S" || { echo "mint failed"; exit 2; }
python3 "$TESTS/mint-counterexamples.py" --out "$WORK/ce" --mp2 "$S" >/dev/null 2>&1
GOOD="$WORK/ce/mislabelled-audio.good.mov"; BAD="$WORK/ce/mislabelled-audio.mov"; REF="$WORK/ce/mislabelled-audio.src.ts"
[ -s "$GOOD" ] && [ -s "$BAD" ] || { echo "SKIP: the counter-example could not be minted here"; echo "codec-tag-payload: 0 passed, 0 failed"; exit 0; }
gt=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_tag_string -of csv=p=0 "$GOOD")
bt=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_tag_string -of csv=p=0 "$BAD")
[ "$gt" = ".mp2" ] && ok "the honest build carries a '.mp2' sample entry" || no "honest tag=$gt want .mp2"
[ "$bt" = ".mp3" ] && ok "the mislabelled build carries a '.mp3' sample entry over Layer II" || no "bad tag=$bt want .mp3"

echo
echo "== 1. the standalone tool: mismatch is exit 1 and says which layer =="
o=$(python3 "$SC/codec-id.py" "$BAD" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "codec-id.py exits 1 on a mismatch" || no "rc=$rc want 1"
has "$o" "CI_MISMATCH=1" "one mismatched stream reported"
has "$o" "verdict=MISMATCH" "the row carries the verdict"
has "$o" "Layer 3" "the refusal names the layer the ENTRY declares"
has "$o" "Layer 2" "…and the layer the PAYLOAD actually is"

echo
echo "== 2. no false refusal: the honest build is clean =="
o=$(python3 "$SC/codec-id.py" "$GOOD" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "codec-id.py exits 0 on the honest build" || { no "rc=$rc want 0"; echo "$o" | head -4; }
has "$o" "CI_MISMATCH=0" "no mismatch reported"
has "$o" "payload frame headers confirm" "the pass is a MEASUREMENT, not an assumption"

echo
echo "== 3. through verify.sh: the mislabelled build FAILs, the honest one does not =="
o=$(bash "$SC/verify.sh" "$REF" "$BAD" 2>&1)
has "$o" "VERIFY_LEDGER gate=i verdict=fail" "gate (i) FAILs the mislabelled build"
has "$o" ">> FAIL" "…and the run's verdict is FAIL"
has "$o" "VERIFY_LEDGER gate=g verdict=pass" "gate (g) still PASSES it — which is exactly why (i) had to exist"
o=$(bash "$SC/verify.sh" "$REF" "$GOOD" 2>&1)
has "$o" "VERIFY_LEDGER gate=i verdict=pass" "gate (i) passes the honest '.mp2' build"

echo
echo "== 4. what cannot be proven from the payload says so (II.1) =="
A="$WORK/aac.ts"
ff -f lavfi -i "sine=1000:r=48000" -t 1 -c:a aac -f mpegts "$A"
ff -i "$A" -map 0:a:0 -c copy "$WORK/aac.mov"
o=$(python3 "$SC/codec-id.py" "$WORK/aac.mov" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "AAC in esds is not accused of anything" || no "aac rc=$rc want 0"
has "$o" "i2 unprovable" "the unprovable half is named, not silently passed"
has "$o" "tag 'mp4a' agrees with codec aac" "the provable half IS proven"

echo
echo "== 5. an unreadable file is UNPROVEN, never 'nothing wrong' (EMPTY != ABSENT) =="
: > "$WORK/empty.mov"
o=$(python3 "$SC/codec-id.py" "$WORK/empty.mov" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "an unreadable file exits 2, not 0" || no "empty rc=$rc want 2"
has "$o" "CI_READ=no" "the machine row says the file could not be read"
hasnt "$o" "CI_MISMATCH=1" "…and nothing is accused on no evidence"

echo
echo "codec-tag-payload: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
