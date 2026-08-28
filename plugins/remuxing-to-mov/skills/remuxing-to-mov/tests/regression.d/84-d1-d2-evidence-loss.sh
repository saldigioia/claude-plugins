#!/usr/bin/env bash
# 84-d1-d2-evidence-loss.sh — CHECKUP-2026-08-27 D1/D2 (+the A4 lockstep
# guard) / WO-1.15.4: the FAILURE path must not destroy its own evidence.
#
#   D1  the confession hard-stop's frequency summary
#       (grep|sort|uniq -c|sort -rn|head -4) SIGPIPEd its producer on large
#       muxlogs (>~64 KB of matching lines) and the ERR trap exited BEFORE
#       the "kept at $PART (log: $MUXLOG)" pointer — MUXLOG is a mktemp path,
#       unfindable without it. Reproduced here with a 30k-line log through
#       remux.sh (measured red on the pre-fix tree this bench). The reader is
#       now awk 'NR<=4' (reads to EOF — the ffp1 doctrine on a display
#       pipeline); a class guard pins that no confession summary pipes into
#       head again (remux.sh + pairfill-paff.sh).
#   D2  verify.sh --full: a mid-decode failure was a SILENT exit 1 (no
#       verdict line) that leaked the mktemp dir of framemd5 lists. Injected
#       via an ffmpeg shim that produces real output then exits 1 — the
#       "I/O error at 90%" shape. Now: an INCONCLUSIVE diagnostic, a REVIEW
#       verdict (UNPROVEN, not FAILED), and no leak under a private TMPDIR.
#       Sibling captures (lead-check astats, qt-groups essence proofs) are
#       pinned by class guards, the test-73 §2 pattern.
#   A4  the one-liner round broadened mux_confessions to the scoped
#       vocabulary with a "keep in lockstep" comment and no guard — the
#       comment-rot class. The two regexes are asserted byte-identical, and
#       the narrow copy must count the 4.4-era spellings.
#
# Standalone: bash tests/regression.d/84-d1-d2-evidence-loss.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

. "$TESTS/lib-harness.sh"   # grepq/grepqe + rtm_strip_comments: one definition (tests/lib-harness.sh)
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }

. "$SC/lib-probe.sh"
. "$SC/lib-paff.sh"

S="$WORK/src.ts"
ff -f lavfi -i testsrc2=s=320x240:r=25 -t 4 -c:v libx264 -g 25 -bf 2 -pix_fmt yuv420p -f mpegts "$S" || { echo "mint failed"; exit 2; }

echo "== D1: the 30k-line confession log keeps its 'kept at … log:' pointer =="
awk 'BEGIN{for(i=0;i<30000;i++) printf "[vost#0:0 @ 0x7f] Non-monotonic DTS; previous %d, current %d; changing to %d\n", i+5, i, i+6}' > "$WORK/big.log"
o=$(RTM_MUX_LOG_APPEND="$WORK/big.log" bash "$SC/remux.sh" "$S" "$WORK/d1.mov" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "hard stop exits 1" || no "hard stop rc=$rc"
has "$o" "HARD STOP" "the confession hard stop fired"
has "$o" "kept at" "the .part pointer SURVIVES a 30k-line summary (pre-fix: SIGPIPE ate it)"
has "$o" "log: " "the mktemp muxlog pointer survives too"
has "$o" "diagnose.sh" "the routing lines after the pointer survive"
# class guard, scoped to the two confession-report sites this round fixed
# (remux.sh + pairfill-paff.sh; the OTHER display pipelines that end in head
# — diagnose/probe/ts-health — are the recorded D1-sibling leftovers in
# WO-1.15.4, not this guard's business)
offenders=$(grep -l 'uniq -c | sort -rn | head' "$SC/remux.sh" "$SC/pairfill-paff.sh" 2>/dev/null || true)
[ -z "$offenders" ] && ok "neither confession summary pipes into head (the armed shape)" \
  || no "head-terminated confession summary reintroduced in: $offenders"

echo
echo "== D2: --full mid-decode failure -> diagnostic + REVIEW + no mktemp leak =="
CP="$WORK/cp.mov"
ff -i "$S" -map 0:v:0 -c copy -movflags +faststart -f mov "$CP"
REAL_FFMPEG="$(command -v ffmpeg)"
# the "I/O error at 90%" shim: the framemd5 pass produces its output, then dies
mkdir "$WORK/shim"
cat > "$WORK/shim/ffmpeg" <<EOF
#!/bin/bash
case "\$*" in *"-f framemd5"*) "$REAL_FFMPEG" "\$@"; exit 1;; esac
exec "$REAL_FFMPEG" "\$@"
EOF
chmod +x "$WORK/shim/ffmpeg"
# leak watch. macOS `mktemp -d` (no template) IGNORES TMPDIR (re-measured
# 2026-08-27: bare -d AND -t both land in the darwin per-user temp dir; only
# an explicit template honours it), so this watch USED TO mark time and scan
# the whole shared temp dir for any new tmp.*/s. That gave it no jurisdiction:
# it false-FAILed on any concurrent run that happened to create one inside the
# window (measured — a suite run alongside a 24 GB build), and worse, its
# else-arm `rm -rf`'d the directory it found, which it did not own. A test
# that deletes another process's live scratch is a hazard, not a check.
# Fix: shim `mktemp` beside the ffmpeg shim (the code under test calls it
# bare, so PATH interception is exact) and force ITS scratch into a
# test-owned dir. The watch then looks only where this run could have written
# — jurisdiction stated, no time window, no foreign deletion.
REAL_MKTEMP="$(command -v mktemp)"
SCRATCH="$WORK/scratch"; mkdir -p "$SCRATCH"
cat > "$WORK/shim/mktemp" <<EOF
#!/bin/bash
# every -d call that names no path (bare, or -t NAME — the template only NAMES
# the dir) is forced into the test-owned scratch; a path template is the
# caller's own jurisdiction and passes through. Each interception is LOGGED:
# the watch below asserts the shim fired, so a scratch call that changes form
# turns this test red instead of leaving the leak watch silently vacuous
# (measured: \`mktemp -d -t x\` slipped past an exact "-d" match, the watch
# found nothing in an empty dir, and "no mktemp leak" PASSed over a real leak).
d=0; p=0
for a in "\$@"; do case "\$a" in -d) d=1;; /*) p=1;; esac; done
if [ "\$d" = 1 ] && [ "\$p" = 0 ]; then
  printf '%s\n' "\$*" >> "$WORK/mktemp.calls"
  exec "$REAL_MKTEMP" -d "$SCRATCH/tmp.XXXXXXXXXX"
fi
exec "$REAL_MKTEMP" "\$@"
EOF
chmod +x "$WORK/shim/mktemp"
# a FOREIGN scratch dir, created in the shared temp dir during the window —
# stands in for the concurrent build that tripped the old watch.
# TD is read by nothing below any more — it stays ONLY as the negative control
# CONSTITUTION V.2 names for 94 §3 (point the watch at $TD and §3 must go red).
TD="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"; TD="${TD:-${TMPDIR:-/tmp}}"
FOREIGN="$("$REAL_MKTEMP" -d)"; : > "$FOREIGN/s"
trap 'rm -rf "$WORK" "$FOREIGN"' EXIT   # ours to remove on every exit path, not only the happy one
o=$(PATH="$WORK/shim:$PATH" bash "$SC/verify.sh" "$S" "$CP" --full 2>&1); rc=$?
has "$o" "FAILED mid-stream" "the mid-decode failure is DIAGNOSED (pre-fix: silent exit 1)"
has "$o" "INCONCLUSIVE" "the check calls itself inconclusive — UNPROVEN, not FAILED"
has "$o" ">> REVIEW" "a verdict line closes the run (pre-fix: none)"
[ "$rc" -eq 0 ] && ok "REVIEW-side exit 0 (never a bare FAIL off a broken ruler)" || no "rc=$rc"
# jurisdiction, proven not assumed: the watch is only as good as the shim's
# reach, and an empty $SCRATCH is what BOTH "no leak" and "never intercepted"
# look like
nfired=$(grep -c . "$WORK/mktemp.calls" 2>/dev/null || true)
[ "${nfired:-0}" -gt 0 ] && ok "the mktemp shim fired ($nfired scratch call(s)) — the leak watch has jurisdiction, not just an empty dir" \
  || no "the mktemp shim never fired: verify.sh's scratch call changed form and the leak watch below is vacuous"
leaked=$(find "$SCRATCH" -maxdepth 2 -type f -name s 2>/dev/null | head -1)
[ -z "$leaked" ] && ok "no mktemp leak (pre-fix: ~40 MB of framemd5 lists per occurrence)" \
  || { no "leaked hlist scratch survives: $leaked"; rm -rf "$(dirname "$leaked")"; }
# jurisdiction: the code under test must NOT delete scratch that is not this
# run's — the half that could have corrupted a live build. (The other half,
# "the watch does not look outside $SCRATCH", is true by construction of the
# find above — a `case "$leaked" in "$FOREIGN"*` pin on it could never fail
# and was removed.)
[ -d "$FOREIGN" ] && ok "foreign scratch left intact (never rm -rf what you do not own)" \
  || no "the run DELETED a directory it did not own: $FOREIGN"
# control: unshimmed --full on the same pair still settles green
o=$(bash "$SC/verify.sh" "$S" "$CP" --full 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && case "$o" in *">> OK"*) true;; *) false;; esac; } \
  && ok "control: unshimmed --full still lands >> OK" || no "control regressed (rc=$rc)"
# sibling class guards (same D2 shape, fixed the same way):
grep -q 'arms_rc=\$?' "$SC/lead-check.sh" \
  && ok "lead-check's astats probe is rc-captured (no silent exit-1 'cannot measure')" \
  || no "lead-check astats capture missing"
{ grep -q 'v_rc=\$?' "$SC/qt-groups.sh" && grep -q 'a_rc=\$?' "$SC/qt-groups.sh"; } \
  && ok "qt-groups' essence proofs are rc-captured (UNPROVEN keeps the evidence pointer)" \
  || no "qt-groups proof captures missing"

echo
echo "== A4: the confession vocabulary has ONE writer =="
# Was a lockstep pin over the two regex LITERALS in lib-paff.sh. 1.15.17 found
# the same alternation in three more places (derive-dts.sh, remux.sh,
# pairfill-paff.sh display greps) that this pin never saw — five copies, two
# guarded. There is one definition now (RTM_CONFESSION_RE); the tree-wide count
# is test 94 §7, and what stays here is the BEHAVIOUR the lockstep protected.
grep -q '^RTM_CONFESSION_RE=' "$SC/lib-paff.sh" \
  && ok "the confession vocabulary is defined once, in lib-paff.sh" \
  || no "RTM_CONFESSION_RE is not defined in lib-paff.sh"
for _fn in mux_confessions mux_confessions_scoped; do
  # the grep's PATTERN ARGUMENT must be exactly the shared token: a bare
  # token-presence read passed an appended alternation
  # ("$RTM_CONFESSION_RE|dts discontinuity") and a re-inlined literal with a
  # comment naming the variable — the drift A4 exists to catch (measured
  # 2026-08-28; mutation-audit cases G31/P31).
  _pat=$(sed -n "/^$_fn *() *{/,/^}/p" "$SC/lib-paff.sh" | rtm_strip_comments \
         | sed -n 's/.*grep -c\{0,1\}iE \("[^"]*"\).*/\1/p' | head -1)
  [ "$_pat" = '"$RTM_CONFESSION_RE"' ] \
    && ok "$_fn reads the shared vocabulary, and nothing else" \
    || no "$_fn carries a private copy or a widened pattern (grep argument: ${_pat:-<none>})"
done
printf '[mov @ 0x1] Non-monotonous DTS in output stream 0:0; previous 5, current 3\n[mov @ 0x1] non monotonically increasing dts to muxer in stream 0\n' > "$WORK/44.log"
[ "$(mux_confessions "$WORK/44.log")" -eq 2 ] \
  && ok "the narrow copy counts the 4.4-era spellings (2/2)" \
  || no "4.4-era spellings missed: $(mux_confessions "$WORK/44.log")/2"

echo
echo "d1-d2-evidence-loss: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
