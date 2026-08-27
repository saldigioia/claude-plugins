#!/usr/bin/env bash
# 12-probe-retry.sh — work-order 1.2: retry on probe-shaped mux failure.
#
# Pins the self-help contract layered on top of 1.1's raised defaults: some
# source will exceed ANY fixed window (or the operator lowers it via
# RTM_PROBESIZE), and pre-1.2 the result was a hard FAIL with no route out.
# Now, in every mux path (remux.sh, dual-track.sh, pairfill-paff.sh):
#   * a mux log carrying the probe-shaped tell — "dimensions not set" /
#     "Could not find codec parameters" — earns exactly ONE retry at a 1G
#     window, announced by the honest line
#       ** probe window exhausted at default; retrying with 1G — consider RTM_PROBESIZE
#   * any OTHER failure is never retried (a retry must not mask a genuinely
#     different error), and a second miss keeps the exit-code contract (1 FAIL);
#   * pf_detect (lib-paff.sh) self-heals the PROBE layer the same way: a video
#     stream the container names whose parameters never resolved widens the
#     eval'ing caller's FF_INPUT_OPTS to 1G — which is what keeps verify.sh's
#     VCL lossless arbiter from hashing an empty source and calling it a
#     MISMATCH after the mux retry saved the build.
#
# Asserted here, on the synthetic late-sps.ts (first SPS ~8 MB in):
#   1. ACCEPTANCE: RTM_PROBESIZE=5M mov.sh late-sps.ts now SUCCEEDS end to end
#      (rc 0|10 — 10 is the fixture-inherent A/V-skew REVIEW, same as the
#      default window), the retry line appears EXACTLY once, and verify proves
#      the copy (VCL MATCH — the probe self-heal reached verify's arbiter);
#   2. the direct mux paths retry too: remux.sh and dual-track.sh at 5M each
#      build (rc 0) with the retry line exactly once;
#   3. NEVER-MASK control: a genuinely different mux failure (garbage input)
#      is not retried — no retry line, one mux FAILED, rc 1, nothing written;
#   4. the retry never weakens the gates: pairfill-paff.sh at 5M self-heals the
#      probe (no probe-shaped death) yet its timeline gates still refuse this
#      non-pairfill stream (rc 1) — wider reads change what is READ, never
#      what gets blessed;
#   5. control: at the default window nothing fires — no retry line, no widen
#      note, same rc 0|10 as before 1.2.
#
# Standalone: bash tests/regression.d/12-probe-retry.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env/fixture failure.
# Regenerates its fixture via make-fixtures.sh when missing. Scratch goes to
# mktemp (auto-cleaned); the repo tree is never written to.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

RETRY_LINE="** probe window exhausted at default; retrying with 1G — consider RTM_PROBESIZE"

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
# count occurrences of the (fixed-string) retry line in $1; echoes the count
nretry () { printf '%s\n' "$1" | grep -cF "$RETRY_LINE" || true; }

# fixture: regenerate when missing (media never ships in git)
if [ ! -f "$FIX/late-sps.ts" ]; then
  echo "== regenerating missing fixture: late-sps.ts =="
  bash "$TESTS/make-fixtures.sh" late-sps.ts || { echo "fixture build failed"; exit 2; }
fi

echo "== 1. acceptance: RTM_PROBESIZE=5M mov.sh late-sps.ts succeeds via the retry =="
out=$(RTM_PROBESIZE=5M bash "$SC/mov.sh" "$FIX/late-sps.ts" "$WORK/acc.mov" 2>&1); rc=$?
case "$rc" in 0|10) ok "mov.sh succeeds at 5M (rc=$rc; 10 = fixture-inherent A/V-skew REVIEW)";;
  *) no "mov.sh rc=$rc at 5M — want 0 or 10 (pre-1.2 this was a hard FAIL)";; esac
n=$(nretry "$out")
[ "$n" -eq 1 ] && ok "retry line appears exactly once (count=$n)" \
  || no "retry line count=$n, want exactly 1"
hasnt "$out" "mux FAILED" "no mux FAILED in the transcript (the retry saved the build)"
[ -f "$WORK/acc.mov" ] && ok "output written" || no "no output file written"
wd=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$WORK/acc.mov" 2>/dev/null | head -1)
[ "${wd:-}" = 1280 ] && ok "output carries the real dimensions (width=1280)" \
  || no "output width='$wd', want 1280"
has "$out" "VCL MATCH" "verify proves the copy (probe self-heal reached the VCL arbiter)"

echo
echo "== 2. direct mux paths: remux.sh and dual-track.sh retry on their own =="
out=$(RTM_PROBESIZE=5M bash "$SC/remux.sh" "$FIX/late-sps.ts" "$WORK/rx.mov" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "remux.sh builds at 5M (rc=0)" || no "remux.sh rc=$rc at 5M (want 0)"
n=$(nretry "$out"); [ "$n" -eq 1 ] && ok "remux.sh retry line exactly once" || no "remux.sh retry line count=$n, want 1"
out=$(RTM_PROBESIZE=5M bash "$SC/dual-track.sh" "$FIX/late-sps.ts" "$WORK/dt.mov" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "dual-track.sh builds at 5M (rc=0)" || no "dual-track.sh rc=$rc at 5M (want 0)"
n=$(nretry "$out"); [ "$n" -eq 1 ] && ok "dual-track.sh retry line exactly once" || no "dual-track.sh retry line count=$n, want 1"

echo
echo "== 3. never-mask control: a different failure is NOT retried =="
# RE-PINNED 1.15.4 (WO-1.15.4 A1): an input ffprobe cannot read no longer
# reaches the muxer at all — the audio-manifest pre-flight refuses it (exit 2,
# "REFUSED (pre-flight)", nothing written) instead of the old mux-stage
# "mux FAILED" rc 1. The control's PROPERTY is unchanged and still pinned:
# a failure that is not probe-window-shaped fires NO retry and is reported
# honestly, once, with nothing written.
printf 'this is not a media file — negative control for the probe-shaped gate\n' > "$WORK/bad.ts"
out=$(RTM_BACKHAUL_GATED=1 bash "$SC/remux.sh" "$WORK/bad.ts" "$WORK/bad.mov" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "unreadable input refuses pre-flight (rc=2; was mux-stage rc=1 pre-1.15.4)" || no "garbage input rc=$rc (want 2)"
n=$(nretry "$out"); [ "$n" -eq 0 ] && ok "no retry line on a non-probe-shaped failure" || no "retry fired on a different error (count=$n)"
has "$out" "REFUSED (pre-flight)" "the failure is reported once, honestly (the A1 refusal)"
[ ! -f "$WORK/bad.mov" ] && ok "nothing written on failure" || no "failure left an output file"

echo
echo "== 4. retry never weakens the gates: pairfill still refuses the wrong class =="
out=$(RTM_PROBESIZE=5M bash "$SC/pairfill-paff.sh" "$FIX/late-sps.ts" "$WORK/pf.mov" --rate 60000/1001 2>&1); rc=$?
hasnt "$out" "dimensions not set" "no probe-shaped death at 5M (pf_detect self-heals the window)"
has "$out" "re-probing wide" "the probe self-heal announced itself (stderr note)"
{ [ "$rc" -eq 1 ] && case "$out" in *"TIMELINE GATES FAILED"*) true;; *) false;; esac; } \
  && ok "timeline gates still refuse the non-pairfill stream (rc=1) — nothing wrongly blessed" \
  || no "pairfill gate behavior changed (rc=$rc) — retry must not bless a wrong timeline"
[ ! -f "$WORK/pf.mov" ] && ok "refused output not blessed under the real name" || no "refused output was blessed"

echo
echo "== 5. control: nothing fires at the default window =="
out=$(bash "$SC/mov.sh" "$FIX/late-sps.ts" "$WORK/def.mov" 2>&1); rc=$?
case "$rc" in 0|10) ok "default window unchanged (rc=$rc)";; *) no "default window rc=$rc (want 0 or 10)";; esac
n=$(nretry "$out"); [ "$n" -eq 0 ] && ok "no retry line at the default window" || no "retry fired at the default window (count=$n)"
hasnt "$out" "re-probing wide" "no probe self-heal note at the default window"

echo
echo "probe-retry: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
