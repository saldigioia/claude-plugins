#!/usr/bin/env bash
# lib-harness.sh — the sub-suite runner, factored out of regression.sh §27 so
# it is itself unit-testable (WO-1.15.8 / CHECKUP-2026-08-27 Class E; pinned
# by tests/regression.d/90-harness-honesty.sh). SOURCE this, don't run it.
#
# What the old inline loop structurally could not see (each measured):
#   E1  enrollment was +x-gated: `[ -x ] || continue` un-enrolled a case the
#       moment its exec bit drifted (F3 showed bits DO drift here), and a
#       deleted regression.d/ read "PASSED: 0  FAILED: 0", exit 0. One
#       chmod 644 could retire a defect's only guard invisibly.
#   E2  the harness trusted only the exit status: a case that breaks the
#       `[ "$fail" -eq 0 ]` tail convention counted PASS while the green row
#       itself printed "1 failed".
#   E3  capability/fixture skips exit 0 with no counter — a leaner bench
#       keeps the "N/N" shape while whole lanes stop being tested.
#
# run_subsuites DIR — runs EVERY DIR/*.sh via bash (no +x needed; a missing
# bit is an announced mode-drift note, never an un-enrollment), cross-checks
# each case's "name: X passed, Y failed" tail line against its exit status
# (a green exit with a nonzero failed-count, or with no recognizable tail at
# all, is a convention-breach FAILURE), counts SKIP announcements into
# HARNESS_SKIPS (green but VISIBLE — the caller prints the tally in its final
# banner), and treats a missing/empty DIR as a FAILURE. Uses the caller's
# ok()/no() reporters.
HARNESS_SKIPS=0

run_subsuites () {
  local dir="${1:?run_subsuites needs DIR}" t tn out rc tail1 tfail nsk seen=0
  HARNESS_SKIPS=0
  for t in "$dir"/*.sh; do
    [ -f "$t" ] || continue        # literal glob only
    seen=$((seen+1))
    tn="$(basename "$dir")/$(basename "$t")"
    [ -x "$t" ] || echo "  note: $tn is not executable (mode drift — E1/F3); enrolled anyway"
    if out=$(bash "$t" 2>&1); then rc=0; else rc=$?; fi
    tail1=$(printf '%s\n' "$out" | tail -1)
    # skips: count announcement openers — the sub-suite "(SKIP: …)" voice and
    # the lowercase "(skip: …)" one; deliberately NOT a bare /skip/i, which
    # would tally unrelated prose ("--no-idr-trim to skip", "idr_trim=skipped")
    nsk=$(printf '%s\n' "$out" | grep -cEi '\((SKIP|skip):' || true)
    HARNESS_SKIPS=$((HARNESS_SKIPS + ${nsk:-0}))
    # the tail convention: "<name>: X passed, Y failed" (suffix text allowed —
    # e.g. 45's synthesis-limit note). Extract Y; empty = no recognizable tail.
    tfail=$(printf '%s\n' "$tail1" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) failed.*/\1/p')
    if [ "$rc" -eq 0 ]; then
      if [ -z "$tfail" ]; then
        no "$tn — green exit but NO 'X passed, Y failed' tail line (convention breach, E2): '$tail1'"
        printf '%s\n' "$out" | tail -5 | sed 's/^/   /'
      elif [ "$tfail" -gt 0 ]; then
        no "$tn — exits 0 while its own tail counts $tfail failed (convention breach, E2)"
        printf '%s\n' "$out" | tail -5 | sed 's/^/   /'
      else
        if [ "${nsk:-0}" -gt 0 ]; then ok "$tn — $tail1 [skip announcements: $nsk]"
        else ok "$tn — $tail1"; fi
      fi
    else
      no "$tn"
      printf '%s\n' "$out" | sed 's/^/   /'
    fi
  done
  if [ "$seen" -eq 0 ]; then
    no "sub-suite lane UNWIRED: $dir is missing or empty — a deleted regression.d/ must never read 0/0 green (E1)"
  fi
  return 0
}

# --- shared by the standalone regression.d guards (ONE definition) -------------
# rtm_strip_comments [FILE...] — source with comments removed, for guards that
# must read CODE and not prose. A `#` opens a comment only at the start of a
# line or after whitespace: the bare `s/#.*//` form (pasted at 26 sites) cut
# code at `${#arr[@]}`, `${x#pat}`, `$#` and ffprobe's `-read_intervals '%+#1'`
# (20 live sites in scripts/), so 94 §6 cried wolf on a correct one-line
# `set +e … set -e` region and 91 §5 was blind to a `| head -1` after a
# first-packet query (both measured 2026-08-28). Not a tokenizer: a
# whitespace-preceded `#` inside a quoted string is still stripped.
rtm_strip_comments () { sed -E 's/(^|[[:space:]])#.*$//' "$@"; }

# grepq / grepqe PATTERN — read stdin to EOF, THEN answer. `x | grep -q PAT`
# closes the pipe on the first match and SIGPIPEs its writer: the same early-exit
# shape as the 1.15.2 `ffp … | head -1` field defect. Measured 2026-08-28 on
# verify.sh (95 KB): "printf: write error: Broken pipe", and under pipefail the
# non-zero pipeline flipped a PASS into a FALSE FAIL. Never `| grep -q` over
# source in this suite (94 §10 sweeps for it).
# A leading `--` is SWALLOWED, not searched for: converting a `grep -q -- PAT`
# call site left the `--` in place, so the pattern became "--" and the guard
# matched every long option in the file — PASS, guarding nothing. Measured
# 2026-08-28 (mutation-audit case G21). The `--` below is what protects a
# pattern that starts with a dash.
grepq  () { [ "${1:-}" = -- ] && shift; [ "$(grep -c  -- "$1")" -gt 0 ]; }
grepqe () { [ "${1:-}" = -- ] && shift; [ "$(grep -cE -- "$1")" -gt 0 ]; }
