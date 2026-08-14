#!/usr/bin/env bash
# 37-drc.sh — work-order 3.7: DRC control on remux.sh's decode path.
#
# The pre-3.7 defect (entry 1 open question): remux.sh's AC-3 -> PCM decode
# ran at ffmpeg's decoder default drc_scale=1.0, baking broadcast dynamic-range
# compression INTO the PCM samples — audible on a concert mix — while
# dual-track.sh already shipped the audiophile default (--drc auto =
# -drc_scale 0). The fix plumbs the same --drc auto|off|on flag through
# remux.sh, applied as a DECODER INPUT option only when a kept ac3/eac3 track
# actually decodes to PCM: never on a copy (nothing is decoded), never on a
# non-AC-3 decode (mp2/dts decoders have no drc_scale — an unconsumed option
# litters the mux log with "not used for any stream").
#
# SYNTHESIS LIMIT (the regression.sh tradition, stated not hidden): lavfi-
# encoded AC-3 carries no meaningful DRC gain words, so decoded SAMPLES do not
# differ between drc_scale 0 and 1.0 on these fixtures — audibility was the
# real-world concert-mix observation. What IS provable locally is the
# plumbing: the constructed ffmpeg argv (bash -x trace of the actual mux
# invocation) either carries -drc_scale 0 or it does not. That argv assertion
# is therefore the acceptance, plus the announced decision line (no silent
# choices about what lands in the samples).
#
# Asserted:
#   1. default (no flag) on multilang.ts (3x AC-3): the mux argv carries
#      -drc_scale 0; the decision is announced; output is 3x pcm_s16le,
#      decoding 0-error. NOTE this is the documented pre-1.11 difference:
#      1.10 decoded the same source at drc_scale=1.0.
#   2. --drc on: 1.0-class behavior = the decoder default, so NO -drc_scale
#      in the argv; the kept-broadcast-DRC decision is still announced.
#   3. --drc off: -drc_scale 0, same as auto (dual-track.sh semantics).
#   4. bad value -> usage error (exit 2, contract rule 3).
#   5. --audio copy: nothing is decoded -> no -drc_scale anywhere in the argv.
#   6. a non-AC-3 decode (dupe_lang.ts --audio-keep 0 keeps only the MP2
#      track -> mp2 -> PCM): the source HAS an AC-3 track but it is not kept,
#      so no -drc_scale and no DRC announcement — the flag follows the
#      decode, not the source.
#
# Standalone: bash tests/regression.d/37-drc.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
# Regenerates its fixtures via make-fixtures.sh when missing. Scratch goes to
# mktemp (auto-cleaned); the repo tree is never written to.
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
acods () { ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$1" 2>/dev/null | paste -sd, -; }
aderr () { # aderr FILE TRACK — decode-error line count for one audio track
  ffmpeg -nostdin -v error -i "$1" -map "0:a:$2" -f null - 2>&1 | grep -c . || true
}
# the constructed command log: run remux.sh under bash -x and pull the traced
# ffmpeg MUX invocation (the one writing -f mov; ffprobe/gate calls don't) —
# this is the actual argv, not an echo the script could get out of sync with
muxargv () { printf '%s\n' "$1" | grep -E '^\++ ffmpeg ' | grep -e '-f mov' | tail -1; }

# fixtures: regenerate when missing (media never ships in git)
for f in multilang.ts dupe_lang.ts; do
  if [ ! -f "$FIX/$f" ]; then
    echo "== regenerating missing fixture: $f =="
    bash "$TESTS/make-fixtures.sh" "$f" || { echo "fixture build failed"; exit 2; }
  fi
  [ -f "$FIX/$f" ] || { echo "$f still missing after make-fixtures"; exit 2; }
done
SRC="$FIX/multilang.ts"

echo "== 1. default: AC-3 -> PCM decodes at -drc_scale 0 (the 1.11 audiophile default) =="
out=$(bash -x "$SC/remux.sh" "$SRC" "$WORK/def.mov" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "remux exits 0" || { no "remux rc=$rc"; printf '%s\n' "$out" | tail -4 | sed 's/^/   /'; }
argv=$(muxargv "$out")
[ -n "$argv" ] && ok "mux argv captured from the trace" || no "no traced ffmpeg mux invocation found"
has "$argv" "-drc_scale 0" "constructed mux command carries -drc_scale 0 by default"
has "$out" "audio DRC: ac3/eac3 -> PCM decodes at -drc_scale 0" "the DRC decision is announced (no silent choices)"
[ "$(acods "$WORK/def.mov")" = "pcm_s16le,pcm_s16le,pcm_s16le" ] \
  && ok "output shape 3x pcm_s16le" || no "output shape: $(acods "$WORK/def.mov")"
[ "$(aderr "$WORK/def.mov" 0)" -eq 0 ] && [ "$(aderr "$WORK/def.mov" 2)" -eq 0 ] \
  && ok "PCM tracks decode 0-error" \
  || no "decode errors: a:0=$(aderr "$WORK/def.mov" 0) a:2=$(aderr "$WORK/def.mov" 2)"

echo
echo "== 2. --drc on: broadcast DRC kept = decoder default, NO -drc_scale in the argv =="
out=$(bash -x "$SC/remux.sh" "$SRC" "$WORK/on.mov" --drc on 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "--drc on exits 0" || no "--drc on rc=$rc"
argv=$(muxargv "$out")
hasnt "$argv" "drc_scale" "--drc on leaves the decoder at its 1.0 default (no -drc_scale)"
has "$out" "audio DRC: broadcast DRC kept" "the kept-DRC decision is still announced"

echo
echo "== 3. --drc off: same -drc_scale 0 as auto (dual-track.sh semantics) =="
out=$(bash -x "$SC/remux.sh" "$SRC" "$WORK/off.mov" --drc off 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "--drc off exits 0" || no "--drc off rc=$rc"
has "$(muxargv "$out")" "-drc_scale 0" "--drc off -> -drc_scale 0 in the mux argv"

echo
echo "== 4. bad value is a usage error (contract rule 3) =="
out=$(bash "$SC/remux.sh" "$SRC" "$WORK/bad.mov" --drc bogus 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "--drc bogus -> exit 2" || no "--drc bogus rc=$rc, want 2"
has "$out" "bad --drc: bogus" "usage error names the bad value"
[ ! -f "$WORK/bad.mov" ] && ok "nothing written on the usage error" || no "usage error wrote an output"

echo
echo "== 5. never on copies: --audio copy decodes nothing -> no -drc_scale =="
out=$(bash -x "$SC/remux.sh" "$SRC" "$WORK/copy.mov" --audio copy 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "--audio copy exits 0" || no "--audio copy rc=$rc"
hasnt "$(muxargv "$out")" "drc_scale" "copied AC-3 rides without a decoder option"

echo
echo "== 6. never on non-AC-3 decodes: kept MP2 -> PCM, unkept AC-3 doesn't trigger it =="
out=$(bash -x "$SC/remux.sh" "$FIX/dupe_lang.ts" "$WORK/mp2.mov" --audio-keep 0 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "mp2-only build exits 0" || no "mp2-only build rc=$rc"
argv=$(muxargv "$out")
has "$argv" "pcm_s16le" "the MP2 track does decode to PCM"
hasnt "$argv" "drc_scale" "no -drc_scale on a non-AC-3 decode (option follows the decode, not the source)"
hasnt "$out" "audio DRC:" "no DRC announcement when no ac3/eac3 decode is live"

[ -f "$SRC" ] && ok "source untouched" || no "source vanished"

echo
echo "drc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
