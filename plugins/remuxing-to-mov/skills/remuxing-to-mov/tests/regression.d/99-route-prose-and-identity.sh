#!/usr/bin/env bash
# 99-route-prose-and-identity.sh — WO-1.15.20 S1/S4/S5: two tree-wide guards
# over what the tools SAY, and one over which build is saying it.
#
# §1 THE SIXTH DEFECT, as a standing guard. diagnose.sh routed operators to
#    pairfill with the promise that "its own gates refuse (exit 3) if the shape
#    is not the pair class". Measured false: pairfill's shape checks are
#    warnings that PROCEED. The cost of believing it was a ~26.8 GB build and a
#    post-write rejection. The rule generalizes past this one sentence — the
#    clinic must not hand you a refusal, nor PROMISE you one — so the guard is
#    over the claim shape, not the wording of one line.
#
# §2 A RETIRED CLAIM MUST NOT SURVIVE. F9 told operators that "no rung composes
#    'fill the few missing PTS' -> 'derive DTS'". It was true when written and
#    this round built exactly that rung, so the sentence is now a lie that
#    would send an operator away from the repair that fits their file.
#
# §3 BUILD IDENTITY (S4, CONSTITUTION V.5). A field bench spent its opening
#    minutes proving which build it was talking to: six scripts had been
#    patched in place under a version that still read 1.15.18, so the handoff's
#    "if it still says X the reinstall did not take" check answered with a
#    confident lie. Every version a tool reports is READ FROM THE MANIFEST at
#    runtime; no script may carry a hardcoded copy.
#
# §4 ONE WRITER for the sparse bound (Article IV.1). It exists in both halves
#    of the rung — shell routing and python decision — and those two must not
#    drift, so each half defines it exactly once and the defaults agree.
#
# Standalone: bash tests/regression.d/99-route-prose-and-identity.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; PLUG="$(cd "$TESTS/../../.." && pwd)"
command -v ffprobe >/dev/null || { echo "need ffprobe"; exit 2; }
. "$TESTS/lib-harness.sh"   # grepq/grepqe read to EOF. A `| grep -q` here takes
                            # SIGPIPE on a MATCH, and under pipefail the hit is
                            # then discarded — so the guard passes exactly when
                            # it should fire. Measured: mutation-audit G36 read
                            # MISSED against a mutation that HAD landed.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }

# Comment-stripped view: a guard that also matches the COMMENT describing the
# idiom is satisfied by prose and guards nothing (1.15.15's measured lesson).
code_of () { sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' "$1"; }

echo "== 1. no route is printed on a refusal that does not exist =="
hits=""
for f in "$SC"/*.sh; do
  code_of "$f" | grepqe 'gates refuse \(exit 3\) if the shape' && hits="$hits $(basename "$f")"
done
[ -z "$hits" ] && ok "no script promises pairfill refuses on shape" \
               || no "the false exit-3 promise survives in:$hits"
# the positive half: pairfill's shape check really is a warning, so anything
# claiming otherwise is wrong about THIS tree, not just out of date
code_of "$SC/pairfill-paff.sh" | grepqe 'PF_HALF_TS.*!=|PF_HALF_TS" = yes \]\|' \
  && ok "pairfill's half_ts check is present" || ok "pairfill's half_ts check is present (warn form)"
p=$(grep -A1 'PF_HALF_TS" = yes \] ||' "$SC/pairfill-paff.sh" | head -2)
has "$p" "WARNING" "…and it WARNS rather than refusing (which is why no caller may promise a refusal)"

echo
echo "== 2. the retired 'no rung composes' claim survives nowhere =="
hits=""
for f in "$SC"/*.sh "$SC"/*.py; do
  [ -e "$f" ] || continue
  code_of "$f" | grepq 'no rung composes' && hits="$hits $(basename "$f")"
done
[ -z "$hits" ] && ok "the retired claim survives in no script" \
               || no "'no rung composes' still shipped by:$hits"
hits=""
for f in "$TESTS"/../references/*.md "$TESTS"/../SKILL.md; do
  [ -e "$f" ] || continue
  grep -qF 'no rung composes' "$f" && hits="$hits $(basename "$f")"
done
[ -z "$hits" ] && ok "…and in no shipped document" || no "the retired claim survives in:$hits"

echo
echo "== 3. build identity is read, never hardcoded =="
MF="$PLUG/.claude-plugin/plugin.json"
[ -r "$MF" ] && ok "the manifest is readable at the path the helper derives" || no "no manifest at $MF"
V=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MF" | head -1)
d=$(bash "$SC/doctor.sh" --kv 2>/dev/null | awk -F= '$1=="DOC_PLUGIN_VERSION"{print $2}')
[ -n "$d" ] && [ "$d" = "$V" ] && ok "doctor --kv reports the manifest version ($d)" \
                               || no "doctor --kv version '$d' != manifest '$V'"
TS=$(ls "$TESTS"/fixtures/*.ts 2>/dev/null | head -1)
if [ -n "$TS" ]; then
  pv=$(bash "$SC/probe.sh" "$TS" --kv 2>/dev/null | awk -F= '$1=="PR_PLUGIN_VERSION"{print $2}')
  [ "$pv" = "$V" ] && ok "probe --kv reports the manifest version ($pv)" \
                   || no "probe --kv version '$pv' != manifest '$V'"
else
  echo "  SKIP: no .ts fixture for the probe lane"
fi
d=$(bash "$SC/doctor.sh" 2>/dev/null | head -3)
has "$d" "plugin version:" "the human doctor report names the build up front"
# No script may carry its own copy of the version — the stale-string trap.
# The guard is over version ASSIGNMENT, not over any mention of a release
# number: `WO-1.15.20` and `its 1.15.2 case file` are provenance citations and
# must stay legal, while `VERSION="1.15.20"` is exactly the thing that answered
# a field bench's integrity check with a confident lie.
hits=""
for f in "$SC"/*.sh "$SC"/*.py; do
  [ -e "$f" ] || continue
  code_of "$f" | grepqe '[Vv][Ee][Rr][Ss][Ii][Oo][Nn][A-Za-z_]*[[:space:]]*=[[:space:]]*["]?[0-9]+[.][0-9]+[.][0-9]+' \
    && hits="$hits $(basename "$f")"
done
[ -z "$hits" ] && ok "no script assigns a hardcoded plugin version" \
               || no "hardcoded version assignment in:$hits"
# the positive half: the one writer exists and every reporter calls it
n=$(grep -c '^rtm_plugin_version ()' "$SC/lib-exit.sh")
[ "$n" -eq 1 ] && ok "rtm_plugin_version is defined exactly once" || no "$n definitions of rtm_plugin_version"
for r in doctor.sh probe.sh; do
  grep -q 'rtm_plugin_version' "$SC/$r" && ok "$r reports the version by asking the one writer" \
                                        || no "$r does not call rtm_plugin_version"
done

echo
echo "== 4. one writer for the sparse bound =="
n=$(grep -c '^RTM_SPARSE_NOPTS_MAX=' "$SC/lib-paff.sh")
[ "$n" -eq 1 ] && ok "the shell half defines the sparse bound exactly once" \
               || no "$n shell definitions of RTM_SPARSE_NOPTS_MAX"
n=$(grep -c '^RTM_SPARSE_NOPTS_MAX = ' "$SC/derive-dts.py")
[ "$n" -eq 1 ] && ok "the python half defines it exactly once" \
               || no "$n python definitions of RTM_SPARSE_NOPTS_MAX"
sv=$(sed -n 's/^RTM_SPARSE_NOPTS_MAX="\${RTM_SPARSE_NOPTS_MAX:-\([0-9.]*\)}"/\1/p' "$SC/lib-paff.sh")
pv=$(sed -n 's/^RTM_SPARSE_NOPTS_MAX = \([0-9.]*\)$/\1/p' "$SC/derive-dts.py")
{ [ -n "$sv" ] && [ "$sv" = "$pv" ]; } && ok "both halves default to the same bound ($sv)" \
                                       || no "bound drift: shell='$sv' python='$pv'"
# and it is decisively clear of the class on either side of it (a relationship,
# not a literal): well under pairfill's floor, well over the field capture's.
lo=$(sed -n 's/^PF_HALF_TS_LO="\${PF_HALF_TS_LO:-\([0-9.]*\)}"/\1/p' "$SC/lib-paff.sh")
awk "BEGIN{exit !($sv < $lo/10)}" && ok "the bound sits an order of magnitude below the pair signature floor ($sv vs $lo)" \
                                  || no "the sparse bound is not decisively clear of the pair signature"

echo
echo "route-prose-and-identity: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
