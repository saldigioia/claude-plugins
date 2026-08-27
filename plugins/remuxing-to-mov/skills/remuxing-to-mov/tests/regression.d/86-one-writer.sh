#!/usr/bin/env bash
# 86-one-writer.sh — WO-1.15.6 / CHECKUP-2026-08-27 A2: one writer per OUT,
# atomic bless.
#
# The measured defect: rtm_part minted a DETERMINISTIC part name and no lock
# existed anywhere, so run B's `ffmpeg -y` truncated run A's part mid-census
# and A blessed foreign bytes rc=0 (delivered file undecodable) — and the
# SEQUENTIAL half: a stale .part kept as FAIL evidence was silently truncated
# by the next run's -y. Both halves of the checkup's rule 2 land: unique part
# names (pid+epoch, extension-keeping as ever — D6 is about the SUFFIX, not
# determinism) and a per-OUT mkdir writer lock with dead-holder steal and
# driver re-entrancy (RTM_LOCK_HELD).
#
# The true RACE is not reproducible deterministically in a suite; what is
# pinned is the MECHANISM: a live foreign lock refuses pre-flight exit 2
# writing nothing; an empty-pid lock is never stolen (the holder's
# mkdir-to-pid-write window); a dead-pid lock is stolen with an announcement;
# the lock is released on success, on failure, and on signals; a kept FAIL
# .part survives the next run byte-identical.
#
# Standalone: bash tests/regression.d/86-one-writer.sh
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
echo "== 1. rtm_part: unique across processes, extension-keeping as ever =="
p1=$(bash -c ". '$SC/lib-mux.sh'; rtm_part /a/b/out.mov")
p2=$(bash -c ". '$SC/lib-mux.sh'; rtm_part /a/b/out.mov")
[ "$p1" != "$p2" ] && ok "two processes mint two different part names" \
  || no "part names collide across processes ($p1) — the A2 truncation shape"
case "$p1" in /a/b/out.part*.mov) ok "shape: same dir, stem.part…, real extension last ($p1)";;
  *) no "part name shape wrong: $p1";; esac
case "$p1" in /a/b/out.mov.part*) no "old extension-hiding shape returned";; *) ok "no extension-hiding (D6 held)";; esac
p3=$(bash -c ". '$SC/lib-mux.sh'; rtm_part /a/b/cut.ts")
case "$p3" in /a/b/cut.part*.ts) ok "non-mov target keeps ITS extension ($p3)";; *) no "ts part shape: $p3";; esac
s1=$(bash -c ". '$SC/lib-mux.sh'; rtm_sidecar /a/b/out.mov autobest")
[ "$s1" = /a/b/out.autobest.mov ] && ok "rtm_sidecar stays DETERMINISTIC (autobest must be re-derivable; the lock owns cross-run safety)" \
  || no "rtm_sidecar changed: $s1"

echo
echo "== 2. a LIVE foreign lock refuses pre-flight: exit 2, nothing written =="
O="$WORK/out.mov"
mkdir "$O.lock"; printf '%s\n' "$$" > "$O.lock/pid"; hostname > "$O.lock/host"
o=$(bash "$SC/remux.sh" "$S" "$O" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "second writer refused, exit 2 (pre-flight family)" || no "refusal rc=$rc, want 2"
has "$o" "ONE WRITER" "refusal names the rule"
has "$o" "$$" "refusal names the holder pid"
has "$o" "RTM_LOCK" "machine row emitted"
has "$o" "verdict=refused" "machine row says refused"
if ls "$WORK"/out.mov "$WORK"/out.part* >/dev/null 2>&1; then no "refused writer wrote something"; else ok "refused writer wrote nothing"; fi
[ -f "$O.lock/pid" ] && ok "the held lock was not disturbed" || no "refusal damaged the foreign lock"

echo
echo "== 3. an EMPTY-pid lock is never stolen (the mkdir-to-pid-write window) =="
rm -rf "$O.lock"; mkdir "$O.lock"   # no pid file: a holder mid-creation
o=$(bash "$SC/remux.sh" "$S" "$O" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "empty-pid lock treated as LIVE: refused (never-corrupt beats auto-heal)" \
  || no "empty-pid lock rc=$rc, want 2"
has "$o" "rm -rf" "the refusal names the manual remedy for a truly-orphaned lock"
[ -d "$O.lock" ] && ok "empty-pid lock left in place" || no "empty-pid lock was stolen"

echo
echo "== 4. a DEAD-pid lock on this host is stolen, announced, and the build proceeds =="
rm -rf "$O.lock"; mkdir "$O.lock"
sleep 0 & dead=$!; wait "$dead" 2>/dev/null || true   # a real, provably dead pid
printf '%s\n' "$dead" > "$O.lock/pid"; hostname > "$O.lock/host"
o=$(bash "$SC/remux.sh" "$S" "$O" 2>&1); rc=$?
has "$o" "stale writer lock" "the steal announces itself"
{ [ "$rc" -eq 0 ] && [ -f "$O" ]; } && ok "build proceeds after the steal (rc=0)" || no "post-steal build rc=$rc"
[ -d "$O.lock" ] && no "lock left behind after a successful build" || ok "lock released on success"

echo
echo "== 5. release on FAILURE + the kept .part survives the next run byte-identical =="
O2="$WORK/out2.mov"
CONF="$WORK/confess.log"
printf '%s\n' "[vost#0:0 @ 0x1] pts has no value" > "$CONF"
o=$(RTM_MUX_LOG_APPEND="$CONF" bash "$SC/remux.sh" "$S" "$O2" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "confession hard-stop still FAILs (rc=1)" || no "hard-stop rc=$rc, want 1"
[ -d "$O2.lock" ] && no "lock left behind after a FAIL exit" || ok "lock released on failure too"
kept=$(ls "$WORK"/out2.part* 2>/dev/null | head -1)
if [ -n "$kept" ]; then
  ok "FAIL evidence kept ($(basename "$kept"))"
  has "$o" "$(basename "$kept")" "the retention message names the kept file"
  cp "$kept" "$WORK/evidence.before"
  o=$(bash "$SC/remux.sh" "$S" "$O2" 2>&1); rc=$?
  { [ "$rc" -eq 0 ] && [ -f "$O2" ]; } && ok "the RETRY blesses cleanly (rc=0)" || no "retry rc=$rc"
  cmp -s "$kept" "$WORK/evidence.before" \
    && ok "the kept FAIL .part survived the retry BYTE-IDENTICAL (A2's sequential half)" \
    || no "the retry modified the kept FAIL evidence — the -y truncation class"
else
  no "hard-stop kept no .part evidence"
fi

echo
echo "== 6. driver re-entrancy: a child under RTM_LOCK_HELD neither re-locks nor releases =="
O3="$WORK/out3.mov"
d3="$(cd "$WORK" && pwd)"
mkdir "$d3/out3.mov.lock"; printf '%s\n' "$$" > "$d3/out3.mov.lock/pid"; hostname > "$d3/out3.mov.lock/host"
o=$(RTM_LOCK_HELD="$d3/out3.mov.lock" bash "$SC/remux.sh" "$S" "$O3" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$O3" ]; } && ok "child proceeds under the parent's lock (rc=0)" \
  || no "re-entrant child rc=$rc"
[ -d "$d3/out3.mov.lock" ] && ok "child did NOT release the parent's lock" \
  || no "child released a lock it does not own"
rm -rf "$d3/out3.mov.lock"

echo
echo "== 7. the drivers hold the lock too (a foreign live lock refuses mov.sh) =="
O4="$WORK/out4.mov"
mkdir "$O4.lock"; printf '%s\n' "$$" > "$O4.lock/pid"; hostname > "$O4.lock/host"
o=$(bash "$SC/mov.sh" "$S" "$O4" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "mov.sh under a foreign live lock refuses exit 2" || no "mov.sh lock refusal rc=$rc, want 2"
if ls "$WORK"/out4.mov "$WORK"/out4.part* "$WORK"/out4.idrtrim* >/dev/null 2>&1; then
  no "refused mov.sh run wrote something"
else ok "refused mov.sh run wrote nothing (idrtrim/premeta sidecars included)"; fi
rm -rf "$O4.lock"
gsrc=$(cat "$SC/auto.sh" "$SC/mp4-swap.sh" "$SC/waiver.sh")
has "$gsrc" "rtm_lock" "auto.sh / mp4-swap.sh / waiver.sh acquire the writer lock"
nb=$(grep -l 'rtm_writer_preflight' "$SC"/remux.sh "$SC"/dual-track.sh "$SC"/resync.sh \
     "$SC"/rebuild-paff.sh "$SC"/pairfill-paff.sh "$SC"/derive-dts.sh "$SC"/trim-to-idr.sh \
     "$SC"/metadata.sh "$SC"/rung4.sh "$SC"/zero-base.sh "$SC"/surgical-cut.sh 2>/dev/null | grep -c . || true)
[ "${nb:-0}" -eq 11 ] && ok "all 11 builders run the writer pre-flight ($nb/11)" \
  || no "writer pre-flight wired at $nb/11 builders"

echo
echo "one-writer: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
