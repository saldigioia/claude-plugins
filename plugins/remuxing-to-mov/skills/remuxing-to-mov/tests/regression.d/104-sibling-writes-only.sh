#!/usr/bin/env bash
# 104-sibling-writes-only.sh — TIERS.md T1.11: a writer may write beside the
# source, never onto it.
#
# WHY. Constitution I.2 says the source is never modified. Until now that was
# enforced by string comparisons in the two scripts somebody remembered to put
# them in — `"$(cd dirname && pwd)/$(basename)" != …` in remux.sh and auto.sh —
# which is the IV.1 shape exactly: one fact, several copies, and the copies
# that were never written are the ones that matter. A string compare also does
# not answer the question. `/a/./x.ts`, a symlink into the same file, and a
# hard link all name the source while comparing unequal.
#
# So the fact gets ONE writer (rtm_sibling_guard, lib-mux.sh), it resolves
# identity by INODE as well as by canonical path, it covers the atomic .part
# and the deterministic sidecars a builder derives from OUT, and every builder
# reaches it through rtm_writer_preflight rather than modelling it.
#
# Pins:
#   1. OUT == IN refuses, exit 2, source untouched — through the shared guard;
#   2. `/dir/./name` and a symlink to the source refuse too (canonical, not textual);
#   3. a HARD LINK to the source refuses (same inode, different name);
#   4. a genuine sibling in the same directory still builds (no false refusal);
#   5. the sidecar/part names derived from OUT cannot land on the source;
#   6. the refusal names I.2 and emits RTM_SIBLING for a caller to read.
# §7 is the tree-wide half and lives in 94-rot-sweep.sh §12: no script may
# carry a second copy of this test.
#
# Standalone: bash tests/regression.d/104-sibling-writes-only.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -y -v error "$@"; }
sumof () { cksum < "$1" | awk '{print $1"-"$2}'; }

echo "== 0. fixture =="
S="$WORK/src.ts"
ff -f lavfi -i testsrc2=s=160x120:r=25 -t 1 -c:v libx264 -g 25 -bf 0 -pix_fmt yuv420p -f mpegts "$S" \
  || { echo "fixture mint failed"; exit 2; }
SRC_SUM=$(sumof "$S")

# every builder that takes IN and OUT and goes through the shared pre-flight
BUILDERS="remux.sh dual-track.sh metadata.sh trim-to-idr.sh"

echo
echo "== 1. OUT == IN refuses, in EVERY builder, source untouched =="
for b in $BUILDERS; do
  [ -f "$SC/$b" ] || continue
  o=$(bash "$SC/$b" "$S" "$S" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && ok "$b: writing onto the source refuses (exit 2)" || no "$b: rc=$rc, want 2"
  [ "$(sumof "$S")" = "$SRC_SUM" ] && ok "$b: the source is byte-identical afterwards" \
    || { no "$b: THE SOURCE CHANGED"; exit 1; }
done

echo
echo "== 2. the same file named differently: /dir/./name and a symlink =="
o=$(bash "$SC/remux.sh" "$S" "$WORK/./src.ts" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "a dot-path naming the source refuses (canonical, not textual)" || no "dot-path rc=$rc, want 2"
ln -s "$S" "$WORK/link.ts"
o=$(bash "$SC/remux.sh" "$S" "$WORK/link.ts" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "a symlink to the source refuses" || no "symlink rc=$rc, want 2"
[ "$(sumof "$S")" = "$SRC_SUM" ] && ok "the source survived both" || { no "THE SOURCE CHANGED"; exit 1; }

echo
echo "== 3. a HARD LINK to the source refuses (same inode, different name) =="
ln "$S" "$WORK/hard.ts" 2>/dev/null || { echo "  (hard links unavailable here — skipping §3)"; }
if [ -f "$WORK/hard.ts" ]; then
  o=$(bash "$SC/remux.sh" "$S" "$WORK/hard.ts" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && ok "a hard link to the source refuses (inode identity)" || no "hard link rc=$rc, want 2"
  has "$o" "RTM_SIBLING" "machine row emitted"
  [ "$(sumof "$S")" = "$SRC_SUM" ] && ok "the source survived the hard-link attempt" || { no "THE SOURCE CHANGED"; exit 1; }
fi

echo
echo "== 4. no false refusal: a genuine sibling in the same directory builds =="
o=$(bash "$SC/remux.sh" "$S" "$WORK/sibling.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK/sibling.mov" ]; } && ok "a real sibling output builds (rc=0)" \
  || { no "sibling build rc=$rc"; echo "$o" | tail -5; }

echo
echo "== 5. the refusal names the rule and the remedy =="
o=$(bash "$SC/remux.sh" "$S" "$S" 2>&1)
has "$o" "RTM_SIBLING" "machine row emitted"
has "$o" "verdict=refused" "machine row says refused"
has "$o" "the source is never modified" "the refusal states the rule it is enforcing (I.2)"

echo
echo "== 6. the measured incident: a source named like the ladder's own park file =="
# 2026-08-29, reproduced before the fix: auto.sh derives BEST_SAVE as
# rtm_sidecar(OUT, autobest) — for OUT=x.mov that is x.autobest.mov — and the
# ladder opens with `rm -f "$BEST_SAVE"` to clear a stale park. A source with
# that exact name was DELETED, and the run then printed ">> FAIL … Source
# untouched." Quiet, irreversible, and falsely reported.
P="$WORK/park"; mkdir -p "$P"
ff -f lavfi -i testsrc2=s=160x120:r=25 -t 1 -c:v libx264 -g 25 -bf 0 -pix_fmt yuv420p -f mpegts "$P/x.autobest.mov"
PSUM=$(sumof "$P/x.autobest.mov")
o=$(bash "$SC/auto.sh" "$P/x.autobest.mov" "$P/x.mov" 2>&1); rc=$?
if [ -f "$P/x.autobest.mov" ] && [ "$(sumof "$P/x.autobest.mov")" = "$PSUM" ]; then
  ok "the source survives a park-file name collision (the 2026-08-29 incident)"
else
  no "THE SOURCE WAS DESTROYED BY THE PARK-FILE COLLISION"
fi
[ "$rc" -eq 2 ] && ok "the collision refuses at pre-flight (exit 2), before any rung runs" || no "collision rc=$rc, want 2"
has "$o" "RTM_SIBLING verdict=refused" "the collision emits the machine row"
case "$o" in *"autobest"*) ok "the refusal names the colliding sidecar by tag";; *) no "the refusal does not name the sidecar";; esac
# the refusal quotes the incident's own false claim, so the meaningful pin is
# that no rung RAN and no verdict was reached: nothing to be honest or dishonest about
hasnt "$o" "-- attempting" "no rung is attempted — the collision is caught before any work"
hasnt "$o" "AUTO_SUMMARY" "no ladder verdict is reached at all"

echo
echo "== 7. a source named like the atomic .part shape is refused too =="
ff -f lavfi -i testsrc2=s=160x120:r=25 -t 1 -c:v libx264 -g 25 -bf 0 -pix_fmt yuv420p -f mpegts "$P/y.part-999-1.mov"
o=$(bash "$SC/remux.sh" "$P/y.part-999-1.mov" "$P/y.mov" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "a source matching this builder's .part name shape refuses" || no "part-shape rc=$rc, want 2"
[ -f "$P/y.part-999-1.mov" ] && ok "that source is still there" || no "THE .part-SHAPED SOURCE WAS DESTROYED"

echo
echo "sibling-writes-only: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
