#!/usr/bin/env bash
# 14-exit-codes.sh — work-order 1.4: exit-code normalization at every entry point.
#
# Pins the measured defect: dual-track.sh returned 234 on a probe failure — a
# raw AVERROR byte escaping through `set -e` fallthrough, outside the documented
# contract (Ground Rule 3: 0 DONE, 10 REVIEW, 1 FAIL, 2 usage, 11 REFUSED), so
# callers switched on garbage. Same class: 143 from a TERM mid-mux kill, 127
# from command-not-found, 141 from a SIGPIPE under pipefail. Every entry-point
# script now sources scripts/lib-exit.sh: an ERR trap (deliberately not EXIT —
# on bash 3.2 an EXIT trap sees $?=0 on a ${1:?}/set -u expansion death and
# would report a FAIL as DONE) fires exactly where `set -e` kills, with the
# true status: documented codes pass through untouched (10/11 are never
# flattened), anything else becomes 1, and INT/TERM/HUP route to 1. Three
# scripts carry a documented pre-contract code 3 the main suite pins
# (pairfill/rebuild REFUSE, playable-check SKIP) and widen their allowlist.
#
# Asserted here:
#   1. the mapping mechanism itself (lib-exit.sh sourced into throwaway
#      scripts, one per death class): a stray 234 from a bare command at top
#      level / in an assignment / inside a function -> 1; a documented child
#      code propagating by set -e survives (11); ${1:?} and unbound-variable
#      deaths keep bash's native in-contract 1 (not 0); explicit documented
#      exits untouched; a suppressed if-context does not fire; a set +e
#      section keeps its captured code; the widened allowlist keeps 3; a
#      TERM kill lands as 1;
#   2. forced failures on EVERY entry-point script return only that script's
#      documented codes: no args at all; a nonexistent input (exactly 2, the
#      explicit guards); an existing-but-garbage media file (membership);
#   3. intentional codes survive the trap end-to-end: resync.sh's mid-stream
#      layout guard -> exactly 11 (1.11: BOTH backhaul arms demoted — 4:2:2
#      to post-build proof, timeline rot to warn + verify — so the layout
#      guard is the surviving REFUSED exemplar), gop-probe open-GOP
#      cut -> exactly 10, pairfill non-H.264 -> 3;
#   4. a TERM mid-mux kill of a real auto.sh run exits inside the contract
#      (pre-fix: 143). The assertion is timing-independent: whenever the kill
#      lands — probe, mux, verify, or after completion — every legal outcome
#      is in-contract, so the test cannot flake.
#
# Standalone: bash tests/regression.d/14-exit-codes.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env/fixture failure.
# Regenerates its fixtures via make-fixtures.sh when missing. Scratch goes to
# mktemp (auto-cleaned); the repo tree is never written to.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

# fixtures: regenerate any that are missing (media never ships in git)
need=""
# 1.11: both backhaul arms demoted (4:2:2 -> post-build proof; rot -> warn +
# verify, WO 4.2) — the exit-11 exemplar is resync's layout guard on m2v420.ts
for f in m2v420.ts; do [ -f "$FIX/$f" ] || need="$need $f"; done
if [ -n "$need" ]; then
  echo "== regenerating missing fixtures:$need =="
  # shellcheck disable=SC2086  # word splitting is the point
  bash "$TESTS/make-fixtures.sh" $need || { echo "fixture build failed"; exit 2; }
fi

# the contract, and the per-script allowlist (the three suite-pinned legacy 3s)
CONTRACT="0 1 2 10 11"
allowed () { case "$1" in
  # derive-dts joined the documented-3 family in 1.14 (Phase 3, decision Q1):
  # signature refusals exit 3 like its sibling rungs; venv-absent is 10.
  pairfill-paff|rebuild-paff|playable-check|derive-dts) echo "$CONTRACT 3";;
  *) echo "$CONTRACT";;
esac; }
in_set () { # in_set RC "C C C..."
  local rc="$1" c; for c in $2; do [ "$rc" = "$c" ] && return 0; done; return 1; }

echo "== 1. lib-exit.sh mapping mechanism (one throwaway script per death class) =="
rc_of () {  # rc_of 'BODY' -> exit code of a set -euo pipefail script sourcing the lib
  printf '#!/usr/bin/env bash\nset -euo pipefail\n. "%s/lib-exit.sh"\n%s\n' "$SC" "$1" > "$WORK/class.sh"
  bash "$WORK/class.sh" </dev/null >/dev/null 2>&1; echo $?
}
mech () { # mech DESC BODY WANT
  local got; got=$(rc_of "$2")
  [ "$got" = "$3" ] && ok "$1 -> $got" || no "$1 -> $got, want $3"
}
mech "stray 234 from a bare command (the measured dual-track class)" 'bash -c "exit 234"; echo ran' 1
mech "stray 234 inside a \$( ) assignment"                    'x=$(exit 234); echo ran' 1
mech "stray 234 inside a function (errtrace reaches it)"      'f(){ bash -c "exit 234"; }; f; echo ran' 1
mech "documented 11 from a child propagates un-flattened"     'bash -c "exit 11"; echo should-not-run' 11
mech "\${1:?} usage abort keeps bash's native 1 (not 0)"      ': "${1:?usage}"; echo ran' 1
mech "set -u unbound death keeps 1 (not 0)"                   'echo "$RTM_NO_SUCH_VAR_XYZ"; echo ran' 1
mech "success stays 0"                                        'true' 0
mech "explicit documented exit 10 untouched"                  'exit 10' 10
mech "suppressed if-context never fires the guard"            'if bash -c "exit 234"; then :; fi' 0
mech "set +e section keeps its captured out-of-contract code" 'set +e; bash -c "exit 3"; rc=$?; set -e; [ "$rc" = 3 ]' 0
mech "pipefail SIGPIPE stray (141) -> 1"                      'bash -c "exit 141"; echo ran' 1
mech "widened allowlist keeps a script-local documented 3"    'RTM_EXIT_OK="0 1 2 3 10 11"; exit 3' 3
mech "TERM routes through the trap chain -> 1 (never 143)"    'kill -TERM $$; sleep 2' 1

echo
echo "== 2. every entry point: forced failures return only documented codes =="
# 6.3 fold-in: qt-groups (WO 5.3) and trim-to-idr (WO 2.2) postdate the loop's
# WO 1.4 birth — every entry point means every entry point, new ones included
ENTRY="auto batch derive-dts diagnose doctor dual-track gop-probe metadata mov pairfill-paff playable-check probe qt-groups rebuild-paff remux resync rung4 seam-check trim-to-idr ts-health verify waiver"
# playable-check's qlmanage render is deadline-bounded (WO 1.4: it hangs forever
# on undecodable garbage); keep the garbage case fast here, and pin the knob.
export RTM_QL_TIMEOUT=10
G="$WORK/garbage.bin"   # exists, is not media
printf 'not media — exit-code audit payload\n' > "$G"; head -c 8192 /dev/zero >> "$G"
X="$WORK/does-not-exist.ts"; O="$WORK/o.mov"
# argument shapes: probe/scan tools take INPUT; builders take INPUT OUTPUT; the
# attested/field tools need their mandatory extras to get past arg parsing
args_for () { case "$1" in
  diagnose|gop-probe|playable-check|probe|ts-health) printf '%s\n' "$2";;
  metadata)      printf '%s\n%s\n--title\nT\n' "$2" "$O";;
  rebuild-paff)  printf '%s\n%s\n60000/1001\n' "$2" "$O";;
  rung4)         printf '%s\n%s\n--profile\nh264\n' "$2" "$O";;
  seam-check)    printf '%s\n1.0\n' "$2";;
  verify)        printf '%s\n%s\n' "$2" "$2";;
  waiver)        printf '%s\n%s\n--attest\na\n--coverage\nc\n--proof\np\n' "$2" "$2";;
  batch)         printf '%s\n' "$2";;
  *)             printf '%s\n%s\n' "$2" "$O";;   # auto dual-track mov qt-groups remux resync trim-to-idr
esac; }
run_with () {  # run_with SCRIPT INPUT -> rc (args read newline-safe from args_for)
  local s="$1" in="$2" a=() line
  while IFS= read -r line; do a+=("$line"); done <<EOF
$(args_for "$s" "$in")
EOF
  bash "$SC/$s.sh" "${a[@]}" </dev/null >/dev/null 2>&1; echo $?
}
for s in $ENTRY; do
  # (a) no args at all (doctor legitimately runs: argless is its normal call)
  rc=$(bash "$SC/$s.sh" </dev/null >/dev/null 2>&1; echo $?)
  in_set "$rc" "$(allowed "$s")" && ok "$s: no args -> $rc (in contract)" || no "$s: no args -> $rc (OUT of contract)"
  # (b) nonexistent input: the explicit guards say exactly 2 (usage)
  if [ "$s" != doctor ]; then
    rc=$(run_with "$s" "$X")
    [ "$rc" = 2 ] && ok "$s: nonexistent input -> 2" || no "$s: nonexistent input -> $rc, want 2"
  fi
  # (c) existing-but-garbage media: whatever the verdict, it stays in contract
  if [ "$s" != doctor ]; then
    rc=$(run_with "$s" "$G")
    in_set "$rc" "$(allowed "$s")" && ok "$s: garbage input -> $rc (in contract)" || no "$s: garbage input -> $rc (OUT of contract)"
  fi
  rm -f "$O"
done
rc=$(bash "$SC/remux.sh" "$X" "$O" --bogus-flag >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] && ok "unknown option -> 2 (usage path intact)" || no "unknown option -> $rc, want 2"

echo
echo "== 3. intentional codes are not flattened by the trap =="
# 1.11: rot refusal demoted to warn + verify (WO 4.2) — mov.sh no longer exits
# 11 for ANY backhaul arm, so the 11-not-flattened probe rides the SURVIVING
# refusal: resync.sh's incident-derived mid-stream layout guard (the ~17-min
# silence-injection class, explicitly kept), via the RTM_LAYOUTS_FILE
# injection hook the main suite's section 24d uses.
printf '2,stereo\n6,5.1(side)\n' > "$WORK/layouts11.txt"
rc=$(RTM_LAYOUTS_FILE="$WORK/layouts11.txt" bash "$SC/resync.sh" "$FIX/m2v420.ts" "$WORK/lay11.mov" >/dev/null 2>&1; echo $?)
[ "$rc" = 11 ] && ok "resync layout guard -> exactly 11 (REFUSED preserved through the trap)" || no "resync layout guard -> $rc, want 11"
printf '1,0.000000,I\n0,0.040000,B\n0,0.840000,B\n0,0.880000,P\n1,1.000000,I\n0,0.920000,B\n1,2.000000,I\n0,2.040000,B\n' > "$WORK/gop.csv"
rc=$(GOP_PROBE_CSV="$WORK/gop.csv" bash "$SC/gop-probe.sh" DUMMY 1.3 >/dev/null 2>&1; echo $?)
[ "$rc" = 10 ] && ok "gop-probe open-GOP cut -> exactly 10 (REVIEW-class preserved)" || no "gop-probe open cut -> $rc, want 10"
rc=$(bash "$SC/pairfill-paff.sh" "$FIX/m2v420.ts" "$WORK/pf.mov" >/dev/null 2>&1; echo $?)
[ "$rc" = 3 ] && ok "pairfill non-H.264 -> 3 (script-local documented code kept)" || no "pairfill non-H.264 -> $rc, want 3"

echo
echo "== 4. TERM mid-mux kill of a real run exits inside the contract =="
# set -m gives the background job its own process group, so the kill reaches
# the whole tree (auto.sh + its ffmpeg/ffprobe children) without touching this
# harness. Pre-fix a TERM'd script surfaced 143; now every possible landing
# point (probe, mux, verify, or a photo-finish DONE) is a documented code.
(
  set -m
  bash "$SC/auto.sh" "$FIX/m2v420.ts" "$WORK/kill.mov" >/dev/null 2>&1 &
  kpid=$!
  sleep 0.5
  kill -s TERM -- -"$kpid" 2>/dev/null
  wait "$kpid"; echo $? > "$WORK/kill.rc"
)
krc=$(cat "$WORK/kill.rc" 2>/dev/null || echo none)
in_set "$krc" "$CONTRACT" && ok "auto.sh killed mid-run -> $krc (in contract; pre-fix: 143)" \
  || no "auto.sh killed mid-run -> $krc (OUT of contract)"

echo
echo "exit-codes: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
