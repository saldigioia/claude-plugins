#!/usr/bin/env bash
# 79-poc-gate-standalone.sh — WO-1.15.3 Item 3: the operator playbook's step 7
# ("re-run the gate against the .part standalone") described a capability NO
# script provided — the field run did it by hand-sourcing lib-paff.sh. Now
# scripts/poc-gate.sh is that capability, and it doubles as the unit lane's
# entry point (--table judges a prepared idr,poc,pts CSV — test 76's tables
# drive it as-is).
#
# Exit contract under test — the 5.1 principle applied locally (the same
# verdict honestly carries different exits in different contexts):
#   0 on-lattice · 1 off-lattice · 10 UNPROVEN (standalone makes no bless
#   decision; "could not evaluate" is REVIEW semantics, verify.sh the house
#   reference) · 2 usage. Inside pairfill the SAME UNPROVEN keeps exit 1 +
#   .part retention — unchanged, and now with a machine row + re-judge route.
#
# Standalone: bash tests/regression.d/79-poc-gate-standalone.sh
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
PG="$SC/poc-gate.sh"
[ -f "$PG" ] || { no "scripts/poc-gate.sh does not exist"; echo "poc-gate-standalone: $pass passed, $((fail)) failed"; exit 1; }

echo "== 1. fixtures =="
ff -f lavfi -i testsrc2=r=25:s=320x240:d=2 -c:v libx264 -bf 3 -g 25 -pix_fmt yuv420p -f mpegts "$WORK/poc0.ts" \
  || { echo "mint failed"; exit 2; }
ff -f lavfi -i testsrc2=r=25:s=320x240:d=2 -c:v libx264 -bf 0 -g 25 -pix_fmt yuv420p -f mpegts "$WORK/poc2.ts" \
  || { echo "mint failed"; exit 2; }
ff -i "$WORK/poc0.ts" -map 0:v:0 -c copy "$WORK/clean.mov" || { echo "copy failed"; exit 2; }
ff -i "$WORK/poc2.ts" -map 0:v:0 -c copy "$WORK/t2.mov"    || { echo "copy failed"; exit 2; }

echo
echo "== 2. clean type-0 artifact -> 0, human line + machine row =="
o=$(bash "$PG" "$WORK/clean.mov" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "clean artifact -> exit 0" || no "clean artifact rc=$rc, want 0"
has "$o" "on_slot=" "prints the same on_slot human line as pairfill's gate"
has "$o" "PP_POC_LATTICE on_slot=" "prints the PP_POC_LATTICE machine row"
has "$o" " off=0" "every picture on its slot"

echo
echo "== 3. type-2 artifact -> 10 UNPROVEN (never 1: no bless decision here) =="
o=$(bash "$PG" "$WORK/t2.mov" 2>&1); rc=$?
[ "$rc" -eq 10 ] && ok "type-2 artifact -> exit 10 (UNPROVEN, REVIEW semantics)" || no "type-2 artifact rc=$rc, want 10"
has "$o" "UNPROVEN" "verdict text says UNPROVEN"
has "$o" "PP_POC_LATTICE unproven=1 why=poc_type" "machine row: unproven=1 why=poc_type"

echo
echo "== 4. --table: the unit lane's entry point (test 76's table shapes) =="
# test 76's negative-control recipe: one picture genuinely off-lattice
awk 'BEGIN{ half=1800; base=126000
            for(i=0;i<2000;i++){ pts=base+2*i*half; if(i==900) pts+=900
              printf "%d,%d,%d\n", (i==0?1:0), 2*i, pts } }' > "$WORK/bad.csv"
o=$(bash "$PG" --table "$WORK/bad.csv" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "off-lattice table via --table -> exit 1" || no "bad table rc=$rc, want 1"
has "$o" "PP_POC_LATTICE on_slot=" "machine row emitted on the evaluated --table path"
# test 76's wrap table + --maxlsb: the SPS path is a flag here
awk 'BEGIN{ M=512; half=1800; base=126000
            for(i=0;i<2000;i++){ poc=(2*i)%M; pts=base+2*i*half
              printf "%d,%d,%d\n", (i==0?1:0), poc, pts } }' > "$WORK/wrap.csv"
o=$(bash "$PG" --table "$WORK/wrap.csv" --maxlsb 512 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "wrapping table with --maxlsb 512 -> exit 0 (unwrap + explicit SPS value)" \
  || no "wrap table rc=$rc, want 0"
# an empty table is UNPROVEN, not FAIL
: > "$WORK/empty.csv"
o=$(bash "$PG" --table "$WORK/empty.csv" 2>&1); rc=$?
[ "$rc" -eq 10 ] && ok "empty table -> exit 10 (UNPROVEN, not an accusation)" || no "empty table rc=$rc, want 10"

echo
echo "== 5. usage contract =="
o=$(bash "$PG" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "no arguments -> exit 2 (usage)" || no "no-args rc=$rc, want 2"
o=$(bash "$PG" "$WORK/definitely-absent.mov" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "missing file -> exit 2 (pre-flight)" || no "missing file rc=$rc, want 2"

echo
echo "== 6. the companion one-liners in pairfill (grep pins) =="
psrc=$(cat "$SC/pairfill-paff.sh")
has "$psrc" "PP_POC_LATTICE unproven=1" "pairfill's UNPROVEN branch gained its machine row"
n=$(grep -c 're-judge: scripts/poc-gate.sh' "$SC/pairfill-paff.sh" || true)
[ "${n:-0}" -ge 2 ] && ok "both retention messages name the re-judge route ($n sites)" \
  || no "re-judge route on $n retention site(s), want >= 2"

echo
echo "== 7. the exit-context split is stated in the script header =="
gsrc=$(cat "$PG")
has "$gsrc" "10" "header documents exit 10"
has "$gsrc" "UNPROVEN" "header documents the UNPROVEN semantics"
has "$gsrc" "verify.sh" "header cites the house reference for the split"
has "$gsrc" "pairfill" "header states the pairfill context keeps exit 1 + retention"

echo
echo "poc-gate-standalone: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
