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
# leak watch: macOS mktemp -d (no template) IGNORES TMPDIR (measured — it
# uses the darwin per-user temp dir), so the watch marks time and then looks
# for a NEW tmp.* dir still holding hlist's 's' file after the run.
TD="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"; TD="${TD:-${TMPDIR:-/tmp}}"
MARK="$WORK/mark"; touch "$MARK"; sleep 1
o=$(PATH="$WORK/shim:$PATH" bash "$SC/verify.sh" "$S" "$CP" --full 2>&1); rc=$?
has "$o" "FAILED mid-stream" "the mid-decode failure is DIAGNOSED (pre-fix: silent exit 1)"
has "$o" "INCONCLUSIVE" "the check calls itself inconclusive — UNPROVEN, not FAILED"
has "$o" ">> REVIEW" "a verdict line closes the run (pre-fix: none)"
[ "$rc" -eq 0 ] && ok "REVIEW-side exit 0 (never a bare FAIL off a broken ruler)" || no "rc=$rc"
leaked=$(find "$TD" -maxdepth 2 -type f -name s -newer "$MARK" -path '*/tmp.*' 2>/dev/null | head -1)
[ -z "$leaked" ] && ok "no mktemp leak (pre-fix: ~40 MB of framemd5 lists per occurrence)" \
  || { no "leaked hlist scratch survives: $leaked"; rm -rf "$(dirname "$leaked")"; }
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
echo "== A4 lockstep: the two confession vocabularies are byte-identical =="
narrow=$(sed -n 's/.*grep -ciE '\''\([^'\'']*\)'\''.*/\1/p' "$SC/lib-paff.sh" | head -1)
scoped=$(sed -n 's/.*grep -iE '\''\([^'\'']*\)'\''.*"\$log".*/\1/p' "$SC/lib-paff.sh" | head -1)
{ [ -n "$narrow" ] && [ "$narrow" = "$scoped" ]; } \
  && ok "mux_confessions and mux_confessions_scoped share one vocabulary (lockstep held)" \
  || no "confession regexes diverged (narrow=[$narrow] scoped=[$scoped])"
printf '[mov @ 0x1] Non-monotonous DTS in output stream 0:0; previous 5, current 3\n[mov @ 0x1] non monotonically increasing dts to muxer in stream 0\n' > "$WORK/44.log"
[ "$(mux_confessions "$WORK/44.log")" -eq 2 ] \
  && ok "the narrow copy counts the 4.4-era spellings (2/2)" \
  || no "4.4-era spellings missed: $(mux_confessions "$WORK/44.log")/2"

echo
echo "d1-d2-evidence-loss: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
