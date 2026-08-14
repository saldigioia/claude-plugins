#!/usr/bin/env bash
# 36-audio-gate.sh — work-order 3.6: verify.sh's audio-playability gate (g).
#
# The dead-HDMV-track class was INVISIBLE to verification: mov.sh 1.10.0
# copy-muxed Blu-ray LPCM (pcm_bluray) into a MOV audio track whose sample
# entry ([128][0][0][0]) NO decoder claims, and verify.sh had no audio gate —
# an 18.5 GB Blu-ray deliverable shipped "verified" with zero playable audio
# (entry 1, 2026-08-13). WO 3.1 fixed the ROUTING; gate (g) is the VERIFIER'S
# half: it must FAIL such a file by naming the tag, while every tag the
# plugin's own routes legitimately write keeps passing.
#
# Asserted:
#   1. a hand-built dead-track MOV FAILs verify.sh (rc=1) with the offending
#      sample-entry tag NAMED in the gate output. Primary build is the exact
#      entry-1 mechanism (ffmpeg -c copy of the pcm_bluray fixture — raw
#      ffmpeg as test tooling, sanctioned by the WO brief); if this bench
#      cannot mint that, the closest equivalent is built instead: a clean
#      sowt MOV whose stsd fourcc is byte-poked to 'HDMV' (any MOV audio tag
#      outside the allowlist exercises the same gate arm).
#   2. the allowlist covers the plugin's real deliverable shapes — each one
#      built by the actual scripts and run through verify.sh end-to-end:
#        mov.sh aac.ts        -> mp4a copy                (native copy)
#        mov.sh m2v420.ts     -> in24 access + .mp2 orig  (dual route, MP2)
#        dual-track.sh        -> in24 access + AC-3 orig  (copy-path tag is
#          multilang.ts          UPPERCASE on this bench — the case trap a
#                                lowercase-only allowlist would reintroduce)
#        mov.sh pcm_bluray    -> sowt access              (the entry-1 rescue)
#   3. container scoping: a non-QTFF output (MKV cross-check) is never
#      tag-FAILed — it has no sample entries; only the decode half applies.
#      (The MKV's OVERALL verdict is not asserted: matroska legitimately
#      carries N/A DTS on B-frame heads, a pre-existing gate-(d) matter.)
#
# Standalone: bash tests/regression.d/36-audio-gate.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
# Regenerates missing fixtures via make-fixtures.sh; pcm_bluray.m2ts is the
# one bench-dependent fixture (its absence downgrades case 1 to the poke
# build and skips the sowt-rescue case — announced, never silent).
# Scratch goes to mktemp (auto-cleaned); the repo tree is never written to.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
atag () { ffprobe -v error -select_streams "a:${2:-0}" -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1; }

# fixtures: regenerate the always-mintable ones when missing; pcm_bluray is
# best-effort (encoder is bench-dependent — make-fixtures SKIPs, announced)
for f in aac.ts multilang.ts m2v420.ts pcm_bluray.m2ts; do
  if [ ! -f "$FIX/$f" ]; then
    echo "== regenerating missing fixture: $f =="
    bash "$TESTS/make-fixtures.sh" "$f" || { echo "fixture build failed: $f"; exit 2; }
  fi
done
for f in aac.ts multilang.ts m2v420.ts; do
  [ -f "$FIX/$f" ] || { echo "fixture $f still missing after make-fixtures"; exit 2; }
done

echo "== 1. a hand-built dead-track MOV FAILs gate (g) with the tag named =="
DEAD=""; DEADSRC=""
if [ -f "$FIX/pcm_bluray.m2ts" ]; then
  # the exact entry-1 mechanism: the MOV muxer accepts the copy and writes a
  # sample entry no decoder claims (raw ffmpeg = sanctioned test tooling here)
  if ffmpeg -nostdin -y -v error -i "$FIX/pcm_bluray.m2ts" -c copy "$WORK/hdmv.mov" 2>"$WORK/hdmv.err"; then
    DEAD="$WORK/hdmv.mov"; DEADSRC="$FIX/pcm_bluray.m2ts"
    echo "   (dead track minted via the entry-1 copy-mux: tag '$(atag "$DEAD")')"
  else
    echo "   (this ffmpeg now REFUSES the pcm_bluray copy-mux — falling back to the poke build)"
  fi
else
  echo "   (pcm_bluray.m2ts unmintable on this bench — using the poke build)"
fi
if [ -z "$DEAD" ]; then
  # closest equivalent: clean sowt MOV, stsd fourcc byte-poked to 'HDMV' — an
  # audio sample entry outside the allowlist, exactly the gate's target class
  ffmpeg -nostdin -y -v error \
    -f lavfi -i "testsrc2=size=320x240:rate=25:duration=3" \
    -f lavfi -i "sine=frequency=440:duration=3:sample_rate=48000" \
    -map 0:v -map 1:a -c:v libx264 -preset veryfast -pix_fmt yuv420p \
    -c:a pcm_s16le -f mov "$WORK/clean.mov" 2>/dev/null \
    || { echo "cannot mint the fallback MOV"; exit 2; }
  cp "$WORK/clean.mov" "$WORK/poked.mov"
  for off in $(grep -abo sowt "$WORK/poked.mov" | cut -d: -f1); do
    printf 'HDMV' | dd of="$WORK/poked.mov" bs=1 seek="$off" conv=notrunc status=none
  done
  DEAD="$WORK/poked.mov"; DEADSRC="$WORK/clean.mov"
  echo "   (dead track minted via the stsd poke: tag '$(atag "$DEAD")')"
fi
dtag=$(atag "$DEAD")
case "$dtag" in
  sowt|twos|lpcm|in24|in32|fl32|mp4a|alac|.mp3|ec-3|EC-3|ac-3|AC-3|dtsc|.mp2|"")
    no "dead-track construction did not leave the allowlist (tag='$dtag') — test tooling broke";;
  *) ok "dead-track file carries out-of-allowlist tag '$dtag'";;
esac
vout=$(bash "$SC/verify.sh" "$DEADSRC" "$DEAD" 2>&1); vrc=$?
[ "$vrc" -eq 1 ] && ok "verify.sh FAILs the dead-track file (rc=1)" || no "verify.sh rc=$vrc on the dead-track file, want 1 (FAIL)"
has "$vout" "-- (g) audio playability" "gate (g) present in the default tier"
has "$vout" "tag='$dtag'" "the offending tag is NAMED in the gate output"
has "$vout" "NOT on the QTFF audio allowlist" "FAIL is attributed to the allowlist arm"
has "$vout" ">> FAIL" "overall verdict is FAIL, not REVIEW (pre-3.6 this file sailed through)"
hasnt "$vout" "WAIVED" "a dead audio track is never waivable (essence class)"

echo
echo "== 2. every legitimate route's tags keep passing (built by the real scripts) =="
run_good () { # run_good LABEL SRC OUT EXPECT_TAGS(comma list, in a: order)
  local label="$1" src="$2" outf="$3" want="$4" got i vo vr
  i=0; got=""
  while :; do
    t=$(atag "$outf" "$i"); [ -n "$t" ] || break
    got="${got:+$got,}$t"; i=$((i+1))
  done
  [ "$got" = "$want" ] && ok "$label: audio tags are $got" || no "$label: audio tags are '$got', want '$want' (route changed? update WO 3.6 expectations)"
  vo=$(bash "$SC/verify.sh" "$src" "$outf" 2>&1); vr=$?
  { [ "$vr" -eq 0 ] && case "$vo" in *">> OK"*) true;; *) false;; esac; } \
    && ok "$label: verify.sh passes (rc=0, >> OK)" \
    || { no "$label: verify.sh rc=$vr (want 0 + OK)"; printf '%s\n' "$vo" | grep -E '^>>|   a:[0-9]' | sed 's/^/   /'; }
  hasnt "$vo" "NOT on the QTFF audio allowlist" "$label: gate (g) never fires on this deliverable"
}
if bash "$SC/mov.sh" "$FIX/aac.ts" "$WORK/aac.mov" >"$WORK/aac.log" 2>&1; then
  run_good "mp4a copy (aac.ts)" "$FIX/aac.ts" "$WORK/aac.mov" "mp4a"
else no "mov.sh failed on aac.ts ($(tail -1 "$WORK/aac.log"))"; fi
if bash "$SC/mov.sh" "$FIX/m2v420.ts" "$WORK/m2v420.mov" >"$WORK/m2v420.log" 2>&1; then
  run_good "MP2 dual route (m2v420.ts)" "$FIX/m2v420.ts" "$WORK/m2v420.mov" "in24,.mp2"
else no "mov.sh failed on m2v420.ts ($(tail -1 "$WORK/m2v420.log"))"; fi
if bash "$SC/dual-track.sh" "$FIX/multilang.ts" "$WORK/dual.mov" >"$WORK/dual.log" 2>&1; then
  # copy-path AC-3 is UPPERCASE on this bench (fresh encodes get 'ac-3') — the
  # case trap: a lowercase-only allowlist FAILs every dual-track deliverable
  run_good "AC-3 dual-track (multilang.ts)" "$FIX/multilang.ts" "$WORK/dual.mov" "in24,AC-3"
else no "dual-track.sh failed on multilang.ts ($(tail -1 "$WORK/dual.log"))"; fi
if [ -f "$FIX/pcm_bluray.m2ts" ]; then
  if bash "$SC/mov.sh" "$FIX/pcm_bluray.m2ts" "$WORK/rescue.mov" >"$WORK/rescue.log" 2>&1; then
    run_good "entry-1 rescue (pcm_bluray.m2ts)" "$FIX/pcm_bluray.m2ts" "$WORK/rescue.mov" "sowt"
  else no "mov.sh failed on pcm_bluray.m2ts ($(tail -1 "$WORK/rescue.log"))"; fi
else
  echo "  (skip: pcm_bluray.m2ts unmintable — sowt-rescue case covered only on benches with the encoder)"
fi

echo
echo "== 3. container scoping: a non-QTFF output is never tag-FAILed =="
ffmpeg -nostdin -y -v error -i "$FIX/aac.ts" -c copy "$WORK/cross.mkv" 2>/dev/null \
  || { echo "cannot mint the MKV cross-check"; exit 2; }
mko=$(bash "$SC/verify.sh" "$FIX/aac.ts" "$WORK/cross.mkv" 2>&1) || true
has "$mko" "no QTFF sample entries" "gate (g) declares the tag allowlist N/A on matroska"
hasnt "$mko" "NOT on the QTFF audio allowlist" "no tag FAIL on a container without sample entries"
has "$mko" "tag N/A (non-QTFF); head decode clean" "the decode half still ran and passed"

for f in aac.ts multilang.ts m2v420.ts; do
  [ -f "$FIX/$f" ] || no "fixture $f vanished during the run"
done
ok "sources untouched"

echo
echo "audio-gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
