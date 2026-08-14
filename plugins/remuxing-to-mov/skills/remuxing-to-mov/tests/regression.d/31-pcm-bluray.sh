#!/usr/bin/env bash
# 31-pcm-bluray.sh — work-order 3.1: pcm_bluray/pcm_dvd are container-framed
# LPCM, NOT raw PCM. The pre-1.11 `pcm_*` glob classified them QuickTime-native,
# so mov.sh copy-muxed them into an HDMV-tagged MOV track that NO decoder
# claims — even ffmpeg cannot decode the file it just wrote — and the driver
# reported success (entry 1, real 18.5 GB Blu-ray case: a silent "verified"
# deliverable). Three-site fix pinned here:
#   * mov.sh native_c: pcm_bluray|pcm_dvd excluded BEFORE the pcm_* arm;
#   * mov.sh mode_for (MODE selector): both route to pcm, never copy;
#   * remux.sh --audio auto: both decode to raw PCM alongside mp2/dts.
#
# Asserted, on the pcm_bluray.m2ts fixture (H.264 + Blu-ray LPCM, BDAV m2ts):
#   1. the defect MECHANISM is real on this bench: a forced copy
#      (remux.sh --audio copy, the documented mux-only escape hatch) still
#      yields an audio track no decoder claims — proof the fixture exercises
#      the entry-1 class, so the default routing below is what saves the user;
#   2. sourced-function units (RTM_TEST=1 sourcing guard in mov.sh):
#      native_c pcm_bluray/pcm_dvd -> 1 (non-native) with the raw-PCM glob
#      intact, mode_for pcm_bluray/pcm_dvd -> pcm with the neighbor arms
#      (copy/dual/pcm) intact — the case-ORDER trap a reorder would reintroduce;
#   3. remux.sh default auto announces the conversion and lands raw PCM;
#   4. mov.sh end-to-end: MODE=pcm (announced), MOV_SUMMARY mode=pcm, verified
#      DONE, and the output's audio is a DECODABLE raw-PCM track
#      (sowt/twos/lpcm-class), never an HDMV-tagged copy; a full ffmpeg decode
#      of the output returns 0 error lines (the acceptance bar).
#
# Standalone: bash tests/regression.d/31-pcm-bluray.sh
# Exit 0 = all assertions pass (or a genuine fixture SKIP — the pcm_bluray
# encoder is bench-dependent); 1 = a regression; 2 = env failure.
# Regenerates its fixture via make-fixtures.sh when missing. Scratch goes to
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

# fixture: regenerate when missing (media never ships in git). make-fixtures
# SKIPs (exit 0, no file) on an ffmpeg without the pcm_bluray encoder — that
# is the one sanctioned skip here, announced, never a silent pass-by-absence.
if [ ! -f "$FIX/pcm_bluray.m2ts" ]; then
  echo "== regenerating missing fixture: pcm_bluray.m2ts =="
  bash "$TESTS/make-fixtures.sh" pcm_bluray.m2ts || { echo "fixture build failed"; exit 2; }
fi
if [ ! -f "$FIX/pcm_bluray.m2ts" ]; then
  echo "SKIP: pcm_bluray.m2ts unmintable on this ffmpeg (no pcm_bluray encoder) — entry-1 class untested here"
  exit 0
fi
SRC="$FIX/pcm_bluray.m2ts"

# sourced-function unit harness: mov.sh's RTM_TEST guard stops the sourced file
# right after the classifier definitions, so each probe runs in a throwaway
# shell (mov.sh's set -euo pipefail / lib-exit trap never touch this harness).
ncl () { RTM_TEST=1 bash -c '. "$1/mov.sh"; set +e; native_c "$2"; echo $?' _ "$SC" "$1" 2>/dev/null; }
mfor () { RTM_TEST=1 bash -c '. "$1/mov.sh"; mode_for "$2"' _ "$SC" "$1" 2>/dev/null; }

echo "== 1. the defect mechanism is real: a forced copy is a track nothing decodes =="
# --audio copy is the documented mux-only escape hatch; on this class the mux
# "succeeds" into an HDMV tag with no claiming decoder. Either shape — a mux
# refusal on a future ffmpeg, or a written file whose audio cannot decode —
# proves the class is live; a copy that DECODES would mean ffmpeg learned
# HDMV-in-MOV and the whole gate deserves a fresh look.
cp=$(bash "$SC/remux.sh" "$SRC" "$WORK/copy.mov" --audio copy 2>&1); cprc=$?
if [ "$cprc" -ne 0 ] || [ ! -f "$WORK/copy.mov" ]; then
  ok "forced copy refused outright by this ffmpeg (mux rc=$cprc) — class still undecodable in MOV"
else
  cname=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$WORK/copy.mov" 2>/dev/null | head -1)
  derr=$(ffmpeg -nostdin -v error -i "$WORK/copy.mov" -map 0:a:0 -f null - 2>&1 | grep -c . || true)
  { [ "$cname" != pcm_bluray ] || [ "${derr:-0}" -gt 0 ]; } \
    && ok "forced copy yields no decodable audio (probe says '$cname', ${derr:-0} decode error line(s)) — the entry-1 trap is live" \
    || no "forced HDMV copy now DECODES on this ffmpeg — revisit the WO 3.1 gate (codec=$cname)"
fi

echo
echo "== 2. sourced units: native_c excludes container-framed LPCM before the pcm_* glob =="
[ "$(ncl pcm_bluray)" = 1 ] && ok "native_c pcm_bluray -> 1 (non-native)" || no "native_c pcm_bluray = $(ncl pcm_bluray), want 1"
[ "$(ncl pcm_dvd)"    = 1 ] && ok "native_c pcm_dvd -> 1 (non-native)"    || no "native_c pcm_dvd = $(ncl pcm_dvd), want 1"
[ "$(ncl pcm_s16le)"  = 0 ] && ok "native_c pcm_s16le -> 0 (raw-PCM glob intact)" || no "native_c pcm_s16le = $(ncl pcm_s16le), want 0"
[ "$(ncl eac3)"       = 0 ] && ok "native_c eac3 -> 0 (DD+ still native)" || no "native_c eac3 = $(ncl eac3), want 0"

echo
echo "== 3. sourced units: mode_for routes both to pcm; the neighbor arms hold =="
[ "$(mfor pcm_bluray)" = pcm  ] && ok "mode_for pcm_bluray -> pcm (never a dead-on-arrival copy)" || no "mode_for pcm_bluray = $(mfor pcm_bluray), want pcm"
[ "$(mfor pcm_dvd)"    = pcm  ] && ok "mode_for pcm_dvd -> pcm"          || no "mode_for pcm_dvd = $(mfor pcm_dvd), want pcm"
[ "$(mfor pcm_s16le)"  = copy ] && ok "mode_for pcm_s16le -> copy (raw PCM stays native)" || no "mode_for pcm_s16le = $(mfor pcm_s16le), want copy"
[ "$(mfor ac3)"        = dual ] && ok "mode_for ac3 -> dual (TN2429 route untouched)" || no "mode_for ac3 = $(mfor ac3), want dual"
[ "$(mfor flac)"       = pcm  ] && ok "mode_for flac -> pcm (not-copyable arm intact)" || no "mode_for flac = $(mfor flac), want pcm"
# guard honesty: an EXECUTED mov.sh with RTM_TEST=1 in the env must still run
# the normal flow (reach the usage guard), never early-return like a source
uo=$(RTM_TEST=1 bash "$SC/mov.sh" 2>&1); urc=$?
{ [ "$urc" -ne 0 ] && case "$uo" in *usage:*) true;; *) false;; esac; } \
  && ok "RTM_TEST guard fires on source only (executed run still reaches the usage guard, rc=$urc)" \
  || no "RTM_TEST guard leaked into executed runs (rc=$urc, out=$(printf '%s' "$uo" | head -1))"

echo
echo "== 4. remux.sh --audio auto: announced conversion, raw PCM in the output =="
out=$(bash "$SC/remux.sh" "$SRC" "$WORK/auto.mov" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "auto remux exits 0" || { no "auto remux rc=$rc"; printf '%s\n' "$out" | tail -4 | sed 's/^/   /'; }
has "$out" "pcm_bluray -> PCM" "conversion announced (no silent mapping decisions)"
acod=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$WORK/auto.mov" 2>/dev/null | head -1)
case "$acod" in pcm_*) ok "auto output audio is raw PCM ($acod)";; *) no "auto output audio is '$acod', want pcm_*";; esac

echo
echo "== 5. mov.sh end-to-end: MODE=pcm, decodable sowt/twos/lpcm track, verified DONE =="
out=$(bash "$SC/mov.sh" "$SRC" "$WORK/e2e.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && case "$out" in *">> DONE"*) true;; *) false;; esac; } \
  && ok "mov.sh -> verified DONE (rc=0)" \
  || { no "mov.sh rc=$rc (want 0 + DONE)"; printf '%s\n' "$out" | tail -6 | sed 's/^/   /'; }
has "$out" "single PCM access track" "MODE=pcm route announced"
has "$out" "MOV_SUMMARY mode=pcm" "MOV_SUMMARY carries mode=pcm (machine row)"
acod=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$WORK/e2e.mov" 2>/dev/null | head -1)
atag=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$WORK/e2e.mov" 2>/dev/null | head -1)
case "$acod" in
  pcm_bluray|unknown|"") no "output audio is still the undecodable copy (codec=$acod tag=$atag)";;
  pcm_*)                 ok "output audio is decodable raw PCM (codec=$acod)";;
  *)                     no "output audio is '$acod', want pcm_* raw PCM";;
esac
case "$atag" in
  sowt|twos|lpcm|in24|in32) ok "audio sample-entry is lpcm-class ($atag), not an HDMV tag";;
  *)                        no "audio tag '$atag' is not sowt/twos/lpcm-class";;
esac
errs=$(ffmpeg -nostdin -v error -i "$WORK/e2e.mov" -f null - 2>&1 | grep -c . || true)
[ "${errs:-1}" -eq 0 ] && ok "full decode of the output: 0 error lines (the acceptance bar)" \
  || no "output decode threw ${errs:-?} error line(s)"
[ -f "$SRC" ] && ok "source untouched" || no "source vanished"

echo
echo "pcm-bluray: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
