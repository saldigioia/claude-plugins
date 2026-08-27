#!/usr/bin/env bash
# 89-timebase-ticks.sh — WO-1.15.7 / CHECKUP-2026-08-27 B3: the scanners' tick
# math assumed time_base numerator == 1.
#
# Measured A/B (the checkup's recipe): an IDENTICAL 15-frame drop minted into
# mpegts (tb 1/90000) and AVI (tb 1001/30000). The mpegts control reported
# `forward gaps=1 (~0.500s dropped)` rc=10; the AVI read `forward gaps=0` and
# misrouted to "Rung 2 genpts" — because `tickrate=${tb##*/}` kept the
# DENOMINATOR only, so the expected frame duration was computed as ~1001
# ticks against a 1-tick-per-frame cadence and every real gap sat far below
# the threshold. The fix parses num/den and computes real ticks-per-second
# (den/num); mkv 1/1000 and mpegts 1/90000 are unchanged by construction
# (num==1). lead-check.sh carried the same idiom and gets the same parse.
#
# Pins are relationships: the SAME drop reads as a comparable gap-seconds
# figure through both containers; no `${TB##*/}`-only idiom remains in the
# two scanners.
#
# Standalone: bash tests/regression.d/89-timebase-ticks.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
ff () { ffmpeg -nostdin -y -v error "$@"; }
kvget () { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

echo "== 0. the A/B fixtures: one 15-frame drop, two timebases =="
ff -f lavfi -i testsrc2=s=320x240:r=30000/1001 -t 4 -c:v mpeg2video -pix_fmt yuv420p \
   -bsf:v 'noise=drop=between(n\,60\,74)' -f mpegts "$WORK/gap.ts" || { echo "mint failed"; exit 2; }
ff -f lavfi -i testsrc2=s=320x240:r=30000/1001 -t 4 -c:v mpeg2video -pix_fmt yuv420p \
   -bsf:v 'noise=drop=between(n\,60\,74)' "$WORK/gap.avi" || { echo "mint failed"; exit 2; }
atb=$(ffprobe -v error -select_streams v:0 -show_entries stream=time_base -of default=nw=1:nk=1 "$WORK/gap.avi" | head -1)
case "$atb" in
  1/*) echo "  (SKIP: this ffmpeg's AVI muxer wrote tb=$atb — numerator 1; the B3 shape"
       echo "   is not mintable here, so only the idiom pins below run.)"
       AVI_OK=0;;
  */*) ok "AVI fixture carries a numerator!=1 timebase ($atb) — the B3 shape"; AVI_OK=1;;
  *)   echo "  (SKIP: unreadable AVI timebase '$atb')"; AVI_OK=0;;
esac

echo
echo "== 1. the mpegts control still sees the drop =="
kv=$(bash "$SC/ts-health.sh" "$WORK/gap.ts" --kv 2>&1) || true
g_ts=$(kvget "$kv" TSH_GAPS); s_ts=$(kvget "$kv" TSH_GAP_SECS)
[ "${g_ts:-0}" -ge 1 ] && ok "mpegts: forward gaps=$g_ts (>=1)" || no "mpegts control lost the gap (gaps=$g_ts)"
awk "BEGIN{exit !((${s_ts:-0}) > 0.3 && (${s_ts:-0}) < 0.8)}" \
  && ok "mpegts: ~half a second dropped ($s_ts s)" || no "mpegts gap seconds off: $s_ts"

if [ "$AVI_OK" -eq 1 ]; then
  echo
  echo "== 2. the SAME drop through tb ${atb}: no longer invisible =="
  kv=$(bash "$SC/ts-health.sh" "$WORK/gap.avi" --kv 2>&1) || true
  g_av=$(kvget "$kv" TSH_GAPS); s_av=$(kvget "$kv" TSH_GAP_SECS)
  [ "${g_av:-0}" -ge 1 ] && ok "avi: forward gaps=$g_av (>=1) — pre-round measured 0" \
    || no "avi gaps=$g_av, want >=1 (the B3 blindness)"
  awk "BEGIN{exit !((${s_av:-0}) > 0.3 && (${s_av:-0}) < 0.8)}" \
    && ok "avi: gap seconds agree with the control ($s_av s vs $s_ts s)" \
    || no "avi gap seconds off: $s_av (control $s_ts)"
  o=$(bash "$SC/ts-health.sh" "$WORK/gap.avi" 2>&1) || true
  has "$o" "forward gap" "the human report names the gap finding on the AVI too"
fi

echo
echo "== 3. the idiom is gone from both scanners =="
for s in ts-health.sh lead-check.sh; do
  if grep -q 'tb##\*/}\|TB##\*/}' "$SC/$s" && ! grep -q 'tbnum\|TBNUM' "$SC/$s"; then
    no "$s still keeps only the timebase denominator (numerator-blind)"
  else
    ok "$s parses the full num/den timebase"
  fi
done

echo
echo "timebase-ticks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
