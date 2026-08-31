#!/usr/bin/env bash
# lib-exit.sh — exit-code normalization for every entry-point script. SOURCED,
# never executed (like lib-probe.sh / lib-paff.sh / lib-attest.sh).
#
# WHY (WO 1.4, measured): the exit-code contract is API —
#     0 DONE | 10 REVIEW | 1 FAIL | 2 usage | 11 REFUSED
# — yet under `set -e` a failing bare command exits the script with the
# command's OWN status. dual-track.sh was measured returning 234 (a raw
# AVERROR byte from a probe failure) and a TERM mid-mux kill returns 143;
# 127 (command not found) and 141 (SIGPIPE under pipefail) are the same class.
# Callers (batch.sh verdict rows, mov.sh's `exit "$rc"`, operators scripting
# the plugin) switch on the contract, so every stray is garbage to them.
#
# MECHANISM — an ERR trap, deliberately NOT an EXIT trap. The ERR trap fires
# exactly where `set -e` kills (same suppression rules: never inside if/&&/||
# conditions), and it sees the TRUE failing status. An EXIT trap cannot do
# this job on macOS bash 3.2: a shell-initiated expansion death (a `${1:?}`
# usage abort, a set -u unbound variable) hands the EXIT trap $?=0 —
# indistinguishable from success, so mapping there turns a FAIL into a DONE
# (measured on 3.2.57: `set -e` + any EXIT trap + ${1:?} exits 0). With no
# EXIT trap in the way, those expansion deaths keep bash's native status 1 —
# already in contract. `set -o errtrace` extends the ERR trap into functions,
# command substitutions and subshells, where the strays are actually born.
#
# The guard passes documented codes through untouched (a child's deliberate
# 10 REVIEW / 11 REFUSED propagating via set -e is never flattened), maps
# anything else to 1 (FAIL), and declines to act while `set +e` is in force
# (a script that suppressed errexit to capture a code gets to keep it — e.g.
# auto.sh reading playable-check's Linux SKIP 3). INT/TERM/HUP (a mid-mux
# kill) are trapped to `exit 1` so a killed run reports FAIL, never 130/143;
# an entry-ignored signal (nohup) stays ignored — bash refuses the trap there.
#
# Usage — source right after `set -euo pipefail`, BEFORE the first command
# that can fail:
#     SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
#     . "$SELF_DIR/lib-exit.sh"
#
# A script with a script-local documented code widens the allowlist AFTER
# sourcing (the guard reads it at fire time). Today that is only the
# pre-contract, suite-pinned 3s (pairfill/rebuild REFUSE, playable-check SKIP):
#     RTM_EXIT_OK="0 1 2 3 10 11"
#
# Deliberately NOT an env knob: the allowlist resets on every source, so an
# exported RTM_EXIT_OK can never loosen a child's contract from outside.
#
# KNOWN RESIDUAL (bash 3.2, pre-existing): a script that installs a plain
# cleanup EXIT trap (diagnose/playable-check/seam-check/ts-health) reports 0
# on an expansion death occurring AFTER that install — the quirk above, and
# the reason this lib refuses to own an EXIT trap. Their arg guards all run
# before the cleanup trap exists, so the reachable usage paths are unaffected;
# a post-install unbound-variable death is a programming bug, same as 1.10.0.
RTM_EXIT_OK="0 1 2 10 11"

rtm_err_guard () {  # fires on the failing command set -e is about to die on
  local rc=$? c
  case $- in *e*) ;; *) return 0;; esac   # set +e section: the script is handling codes itself
  # shellcheck disable=SC2086  # word splitting is the point
  for c in $RTM_EXIT_OK; do [ "$rc" = "$c" ] && return 0; done   # documented: let set -e exit with it
  exit 1   # undocumented stray (raw ffmpeg/ffprobe/shell code) -> FAIL
}
set -o errtrace   # the ERR trap reaches functions/substitutions/subshells
trap rtm_err_guard ERR
trap 'exit 1' INT TERM HUP

# --- suspending the contract to read a code by hand -------------------------
# THE DEFECT THESE EXIST TO RETIRE (measured 2026-08-31, pre-existing since the
# guard landed). The ERR trap fires on ANY failing command, not only where
# `set -e` would kill — that is why rtm_err_guard has to test `$-` itself. So
# in the tree's standard capture idiom:
#
#     set +e; child | sed 's/^/   /'; rc=${PIPESTATUS[0]}; set -e
#
# the trap RUNS between the pipeline and the read, and running any command
# rewrites PIPESTATUS. `rc` therefore came back 0 for every non-zero child, at
# five sites. Measured on poc-remux.sh: a REFUSED (exit 3) child was read as
# success, so the driver fell through to "the rung reported success and wrote
# nothing" and reported FAIL — collapsing exactly the two verdicts TIERS.md
# T3.12 exists to keep apart. No pipe, no bug: an unpiped `cmd; rc=$?` is
# unaffected, which is why this hid for so long.
#
# PIPESTATUS cannot be saved and restored (bash 3.2 has no way to write it), so
# the fix is to disarm rather than to repair. That costs nothing: inside a
# `set +e` section the guard already returns 0 immediately, so it was doing no
# work — only damage.
#
#     rtm_hold; child | sed 's/^/   /'; rc=${PIPESTATUS[0]}; rtm_resume
#
# Pinned by tests/regression.d/94-rot-sweep.sh (no PIPESTATUS read may sit in a
# bare `set +e` section) and mutation-audited.
rtm_hold ()   { set +e; trap - ERR; }               # I am reading codes myself
rtm_resume () { trap rtm_err_guard ERR; set -e; }   # the contract is back on

# --- build identity (WO-1.15.20 S4) -----------------------------------------
# The installed plugin's version, READ AT RUNTIME from the manifest — never a
# hardcoded copy in a script, which is how a stale string gets believed. A
# field bench re-testing a patched install burned its first minutes on exactly
# that: the handoff's "if it still says 1.15.18 the reinstall did not take"
# check read as a FALSE NEGATIVE, because the scripts had been edited in place
# without a bump (2026-08-28 re-test report).
# EMPTY != ABSENT: an unreadable or missing manifest reads `unknown`, never a
# fabricated number and never a silent empty — a version string nobody can
# trust is worse than one that admits it does not know.
rtm_plugin_version () {
  local mf v
  mf="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/../../../.claude-plugin/plugin.json"
  [ -r "$mf" ] || { echo unknown; return 0; }
  v=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$mf" | awk 'NR<=1')
  [ -n "$v" ] || v=unknown
  echo "$v"
}
