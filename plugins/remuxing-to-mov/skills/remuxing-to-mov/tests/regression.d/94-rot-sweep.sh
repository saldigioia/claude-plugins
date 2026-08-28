#!/usr/bin/env bash
# 94-rot-sweep.sh — the standing sweep. Every defect class this plugin has
# actually shipped, enumerated MECHANICALLY over the whole tree, every run.
#
# Why it exists: 1.15.10/.11/.12 were each found by tripping over them, and
# 1.15.12 in particular was found only because a suite run happened to share a
# machine with a 24 GB build. Finding a CLASS and then waiting to meet its next
# INSTANCE is not a method. Once a class is named, enumerating it is mechanical
# — so it belongs here, not in the next field run's luck.
#
# Ground rules for anything added below:
#   * PRECISE, not broad. A tree-wide guard that cries wolf gets disabled, and
#     then the class is unguarded AND believed guarded. Every detector here was
#     tuned until it reported zero false positives on the tree as it stands.
#   * classes already pinned elsewhere are NOT re-pinned (that would be this
#     file committing the very duplication it audits): `ffp … | head -1` is
#     test 91 §5; the audio-manifest single-writer is test 92 §4; the
#     entry-point roster is test 14; pix_fmt refusals are test 41.
#
# Standalone: bash tests/regression.d/94-rot-sweep.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

echo "== 1. quoting: every script parses (catches the apostrophe-in-awk trap) =="
# A ' inside a single-quoted awk program silently ends the shell string and the
# rest of the program is parsed as shell. Hit TWICE in one session (1.15.10
# `remux.sh's`, 1.15.14 `rtm_aud_manifest's`). `bash -n` is the exact,
# zero-false-positive detector for it, so the guard is simply: everything parses.
qbad=""
for f in "$SC"/*.sh "$TESTS"/regression.d/*.sh "$TESTS"/*.sh; do
  [ -f "$f" ] || continue
  bash -n "$f" 2>/dev/null || qbad="$qbad $(basename "$f")"
done
[ -z "$qbad" ] && ok "every script and test parses under bash -n" || no "syntax errors (apostrophe-in-awk class?):$qbad"

echo
echo "== 2. the awk bare-counter-subscript trap (1.15.10) =="
# An UNINITIALIZED awk variable used as an array subscript is the empty string,
# not 0 — record 0 lands at C[""] while n++ still counts it. Any awk that both
# subscripts by a counter and increments it must initialize it.
sub_bad=""
for f in "$SC"/*.sh; do
  # comments stripped FIRST: the pattern is also how the idiom is DESCRIBED in
  # prose, so an un-stripped grep is satisfied by a comment mentioning it —
  # measured vacuous, caught by mutation test.
  code=$(sed 's/#.*//' "$f")
  printf '%s' "$code" | grep -q '[A-Za-z_]\[n\]=' || continue
  printf '%s' "$code" | grep -q 'n++' || continue
  printf '%s' "$code" | grep -q 'BEGIN{ *n=0' || sub_bad="$sub_bad $(basename "$f")"
done
[ -z "$sub_bad" ] && ok "every counter-subscripted awk initializes its counter" \
  || no "uninitialized counter used as array subscript in:$sub_bad"

echo
echo "== 3. scanner jurisdiction over shared ground (1.15.12) =="
# The 1.15.12 defect precisely: a watcher SCANNED the shared per-user temp dir
# for anything matching a pattern, then rm -rf'd what it found — and deleted
# the live scratch of a running 24 GB build. The detectable, zero-false-positive
# form of the rule is the scan itself: nothing in this tree may take
# jurisdiction over shared temp ground. A process may only look where it wrote.
# (Deliberately NOT "audit every rm -rf": that guard false-positived on .lock
# paths, on a string assertion, and on this file — and a tree-wide guard that
# cries wolf gets disabled, which is worse than no guard. Narrow and true beats
# broad and ignored.)
# The sanctioned way to watch a child's scratch is the mktemp PATH shim in
# test 84: force the code under test to write where the test can see.
scan_bad=""
for f in "$SC"/*.sh "$TESTS"/regression.d/*.sh; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in 94-rot-sweep.sh) continue;; esac
  sed 's/#.*//' "$f" | grep -qE 'find +"?\$(TD|TMPDIR)|find +"?\$\{?(TD|TMPDIR)|DARWIN_USER_TEMP_DIR[^)]*\)?"?[^=]*$|find +/tmp|find +"?\$HOME' 2>/dev/null \
    && scan_bad="$scan_bad $(basename "$f")"
done
[ -z "$scan_bad" ] && ok "nothing scans shared temp ground for files it did not write" \
  || no "scanner with no jurisdiction (the 1.15.12 class) in:$scan_bad"

echo
echo "== 4. census_rc contract lockstep (9 true variants across 10 builders) =="
# The post-mux census contract — rc 0 or 10 is acceptable, anything else is a
# census failure — is re-implemented in 10 builders, in 9 genuinely different
# forms. The wrapping differs legitimately per builder; the SEMANTIC must not.
# This is the lockstep guard the mux_confession vocabularies already have:
# duplication that is not being refactored today is duplication that must at
# least be held in step.
cen_bad=""
for f in "$SC"/*.sh; do
  grep -q 'census_rc' "$f" 2>/dev/null || continue
  grep -q 'census_rc" -ne 10' "$f" 2>/dev/null || cen_bad="$cen_bad $(basename "$f")"
done
n_cen=$(grep -l 'census_rc' "$SC"/*.sh 2>/dev/null | wc -l | tr -d ' ')
[ -z "$cen_bad" ] && ok "all $n_cen census_rc consumers treat rc=10 as REVIEW, not error" \
  || no "census_rc consumers missing the -ne 10 guard:$cen_bad"

echo
echo "== 5. no NEW duplicate of a shared-writer fact =="
# Facts that have been given a single home must not sprout a second copy. Add
# a line here whenever a fact is centralized; that is the cost of centralizing.
for pair in "rtm_aud_manifest:lib-probe.sh:the audio manifest" \
            "rtm_disk_preflight:lib-mux.sh:the disk pre-flight" \
            "rtm_lock:lib-mux.sh:the writer lock"; do
  fn="${pair%%:*}"; rest="${pair#*:}"; home="${rest%%:*}"; what="${rest#*:}"
  # count DEFINITIONS, not files: grep -l would miss a second copy pasted into
  # the same file (measured vacuous, caught by mutation test).
  defs=$(cat "$SC"/*.sh 2>/dev/null | sed 's/#.*//' | grep -c "^$fn *() *{")
  [ "$defs" = 1 ] && ok "$what is defined exactly once ($fn)" \
    || no "$what has $defs definitions — a shared writer has been copied"
done

echo
echo "rot-sweep: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
