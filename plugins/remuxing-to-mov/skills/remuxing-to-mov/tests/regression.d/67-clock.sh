#!/usr/bin/env bash
# 67-clock.sh — 1.15 Phase 1: the player-clock translator.
#
# Pins the one conversion every "starts at X" diagnosis depends on (the feed.ts
# lesson): container_time = player_time + format.start_time. Asserted:
#   1. ARITHMETIC: CLOCK_SUMMARY's raw equals player + the start_time it read
#      (checked by re-computing from the line's own fields — no trust);
#   2. ADDRESSING: on a fixture with a fat start offset, the bracketing
#      keyframes come back in CONTAINER time (both sit near raw, far from the
#      player number — the exact confusion the tool exists to kill);
#   3. LUMA: frames decode around the address with sane luma means (testsrc2
#      is bright — a black-lead readout here would be a decode-window bug);
#   4. CONTRACT: non-numeric time / missing file -> exit 2, report exit 0.
#
# Standalone: bash tests/regression.d/67-clock.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }

echo "== fixture: TS with a fat (10s) start offset =="
S="$WORK/shifted.ts"
ff -f lavfi -i "testsrc2=s=320x240:r=25" -t 4 -c:v libx264 -g 25 -bf 2 \
   -pix_fmt yuv420p -output_ts_offset 10 -f mpegts "$S"
ST=$(ffprobe -v error -show_entries format=start_time -of default=nw=1:nk=1 "$S" | head -1)
awk "BEGIN{exit !(($ST) > 9)}" || { echo "fixture start_time not shifted ($ST)"; exit 2; }

echo
echo "== 1. arithmetic: raw == player + start_time (from the line's own fields) =="
out=$(bash "$SC/clock.sh" "$S" 1.5 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "report exit 0" || no "report exit $rc"
line=$(printf '%s\n' "$out" | grep '^CLOCK_SUMMARY ') || true
[ -n "$line" ] && ok "CLOCK_SUMMARY emitted" || no "CLOCK_SUMMARY missing"
gp () { printf '%s\n' "$line" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
p=$(gp player); s=$(gp start_time); r=$(gp raw)
awk "BEGIN{d=($r)-(($p)+($s)); if(d<0)d=-d; exit !(d<0.000001)}" \
  && ok "raw ($r) == player ($p) + start_time ($s)" || no "translation arithmetic broken ($p + $s != $r)"
awk "BEGIN{exit !(($r) > 11)}" && ok "raw is container-clock (>= the 10s offset)" || no "raw not in container time: $r"

echo
echo "== 2. addressing: bracketing keyframes in container time =="
kb=$(gp key_before); ka=$(gp key_after)
{ [ "$kb" != na ] && awk "BEGIN{exit !(($kb) <= ($r) && ($kb) > ($r)-2)}"; } \
  && ok "key_before ($kb) sits at/under raw, in container time" || no "key_before wrong: $kb (raw $r)"
{ [ "$ka" != na ] && awk "BEGIN{exit !(($ka) > ($r))}"; } \
  && ok "key_after ($ka) sits above raw" || no "key_after wrong: $ka (raw $r)"

echo
echo "== 3. luma readout around the address =="
nfr=$(gp frames); lmax=$(gp luma_max)
[ "${nfr:-0}" -gt 0 ] && ok "frames decoded in the window ($nfr)" || no "no frames decoded"
awk "BEGIN{exit !(($lmax) > 60)}" && ok "bright fixture reads bright (luma_max=$lmax)" || no "luma readout broken: $lmax"
has "$out" "<-- the reported moment" "the reported moment is marked in the frame list"

echo
echo "== 4. contract =="
bash "$SC/clock.sh" "$S" abc >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "non-numeric time -> exit 2" || no "non-numeric time rc=$rc"
bash "$SC/clock.sh" "$WORK/nope.ts" 1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "missing file -> exit 2" || no "missing file rc=$rc"

echo
echo "clock: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
