#!/usr/bin/env bash
# 103-final-out-noclobber.sh — TIERS.md T1.10: the FINAL-OUT no-clobber.
#
# WHY. The writer lock (WO-1.15.6) makes two CONCURRENT writers impossible.
# It says nothing about a SEQUENTIAL one: run a build today into OUT.mov, run
# another tomorrow into the same OUT.mov, and yesterday's verified deliverable
# is replaced without a word. That is the Tier-1 shape exactly — irreversible,
# and quiet — and it cost nothing to close, because refusing it blocks no
# legitimate attempt: the operator either meant to replace it (and says so) or
# did not (and is glad to hear about it).
#
# THE DISCRIMINATOR IS THE LOCK, and that is the whole design. A ladder
# replaces its OWN artifact across rungs constantly — auto.sh's Rung 2 must be
# able to overwrite Rung 0's build. So the claim is made ONCE, by the process
# that ACQUIRES the lock, before any work; a child builder re-entering under
# the driver's lock (RTM_LOCK_HELD) is writing the driver's artifact and is
# never re-asked.
#
# Pins:
#   1. a builder into an existing OUT refuses at pre-flight, exit 2;
#   2. the existing file is byte-for-byte untouched, and no .part is left;
#   3. the refusal names RTM_OVERWRITE=1 and the size it declined to replace;
#   4. RTM_OVERWRITE=1 proceeds and ANNOUNCES the replacement (never silent);
#   5. a child under a held lock does NOT re-refuse (the ladder still works);
#   6. the lock is released on the refusal (no orphan lockdir);
#   7. the machine row RTM_CLOBBER is emitted for a caller to read.
#
# Standalone: bash tests/regression.d/103-final-out-noclobber.sh
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

echo "== 0. fixture =="
S="$WORK/src.ts"
ff -f lavfi -i testsrc2=s=160x120:r=25 -t 1 -c:v libx264 -g 25 -bf 0 -pix_fmt yuv420p -f mpegts "$S" \
  || { echo "fixture mint failed"; exit 2; }

echo
echo "== 1. a first build into a fresh OUT is unaffected =="
O="$WORK/deliverable.mov"
o=$(bash "$SC/remux.sh" "$S" "$O" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$O" ]; } && ok "fresh OUT builds normally (rc=0)" || { no "fresh build rc=$rc"; echo "$o" | tail -5; }
FIRST_SUM=$(cksum < "$O" | awk '{print $1"-"$2}')
FIRST_BYTES=$(wc -c < "$O" | tr -d ' ')

echo
echo "== 2. a SECOND build into the same OUT refuses at pre-flight =="
o=$(bash "$SC/remux.sh" "$S" "$O" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "existing OUT refuses pre-flight (exit 2)" || no "second build rc=$rc, want 2"
NOW_SUM=$(cksum < "$O" | awk '{print $1"-"$2}')
[ "$NOW_SUM" = "$FIRST_SUM" ] && ok "the existing deliverable is byte-identical after the refusal" \
  || no "the refused run CHANGED the existing deliverable ($FIRST_SUM -> $NOW_SUM)"
if ls "$WORK"/deliverable.part*.mov >/dev/null 2>&1; then no "refused run left a .part behind"; else ok "no .part left behind"; fi
has "$o" "RTM_OVERWRITE=1" "the refusal names the operator's override"
has "$o" "$FIRST_BYTES" "the refusal names the size it declined to replace"
has "$o" "RTM_CLOBBER" "machine row emitted"
has "$o" "verdict=refused" "machine row says refused"
[ -d "$O.lock" ] && no "writer lock left behind after the no-clobber refusal" || ok "writer lock released on the refusal"

echo
echo "== 3. RTM_OVERWRITE=1 proceeds, and says so out loud =="
o=$(RTM_OVERWRITE=1 bash "$SC/remux.sh" "$S" "$O" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$O" ]; } && ok "override builds (rc=0)" || { no "override build rc=$rc"; echo "$o" | tail -5; }
has "$o" "will be REPLACED" "the replacement is ANNOUNCED, never silent"
has "$o" "verdict=overwrite" "machine row records the override"

echo
echo "== 4. a child under a held lock is never re-asked (the ladder still replaces its own artifact) =="
# RTM_LOCK_HELD is what a driver exports across its children. With it set to
# OUT's lockdir, the builder is a child: the claim was the driver's to make.
LOCKDIR="$(cd "$(dirname "$O")" && pwd)/$(basename "$O").lock"
o=$(RTM_LOCK_HELD="$LOCKDIR" bash "$SC/remux.sh" "$S" "$O" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$O" ]; } && ok "a child under the driver's lock builds over the driver's own OUT (rc=0)" \
  || { no "child build rc=$rc"; echo "$o" | tail -5; }
hasnt "$o" "RTM_CLOBBER verdict=refused" "the child is not re-asked the claim question"

echo
echo "== 5. the ladder end-to-end: auto.sh claims once, then escalates freely =="
A="$WORK/ladder.mov"
o=$(bash "$SC/auto.sh" "$S" "$A" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] || [ "$rc" -eq 10 ]; } && ok "auto.sh builds into a fresh OUT (rc=$rc)" || { no "auto rc=$rc"; echo "$o" | tail -6; }
o=$(bash "$SC/auto.sh" "$S" "$A" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "auto.sh refuses to silently replace its own earlier deliverable (exit 2)" || no "auto second run rc=$rc, want 2"
has "$o" "RTM_OVERWRITE=1" "the driver's refusal names the override too"

echo
echo "== 6. a directory in the way is refused, not clobbered =="
D="$WORK/adir.mov"; mkdir -p "$D"
o=$(bash "$SC/remux.sh" "$S" "$D" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "an existing directory at OUT refuses (exit 2)" || no "directory OUT rc=$rc, want 2"
[ -d "$D" ] && ok "the directory is still there" || no "the directory was removed"

echo
echo "final-out-noclobber: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
