#!/usr/bin/env bash
# 91-flags-parsers-docs.sh — WO-1.15.9 / CHECKUP-2026-08-27 F2, F5, F6, F7 +
# the D3 hygiene sweep: flags that lie, parsers that shrug, docs that teach
# the retired route.
#
# Measured pre-round: F5 --mp4-swap was accepted and silently ignored on the
# PAFF path (parsed at mov.sh:137, consumed only in the non-PAFF branch) and
# a PAFF REVIEW build (rc=10) silently skipped requested metadata; F6
# `diagnose.sh IN --deep` was a no-op (a flag clean.sh legitimately has),
# `ts-health.sh IN --kvv` fell back to human mode (a --kv consumer gets zero
# rows), and `mov.sh in.ts -full` treated the typo as the OUTPUT filename and
# built a file named "-full"; F2 the retired pre-1.14 routing doctrine
# ("reordered -> pairfill", no Rung 3-DERIVE anywhere) survived verbatim in
# README/mov-SKILL/SKILL hard-won facts and timeline-repair.md; F7 README
# promised decoded-pixel identity for "every output" (--full only) and
# dual-track-quicktime.md still listed E-AC-3 as a dual-track class; D3 55
# `ffp … | head -1` sites carried the exact preconditions of the 1.15.2
# SIGPIPE field defect (ffp1 exists, is doctrine, was used at 2 sites).
#
# Standalone: bash tests/regression.d/91-flags-parsers-docs.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; DOCS="$TESTS/.."; ROOT="$TESTS/../../.."
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
ff -f lavfi -i testsrc2=s=160x120:r=25 -t 2 -c:v mpeg2video -pix_fmt yuv420p -f mpegts "$S" || { echo "mint failed"; exit 2; }

echo
echo "== 1. F6: parsers reject what they used to shrug at =="
o=$(bash "$SC/diagnose.sh" "$S" --deep 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "diagnose.sh IN --deep -> exit 2 (was a silent no-op)" || no "diagnose extra-arg rc=$rc, want 2"
has "$o" "unknown" "…and names the rejected argument"
rc=$(bash "$SC/clock.sh" "$S" 1.0 extra >/dev/null 2>&1; echo $?)
[ "$rc" -eq 2 ] && ok "clock.sh with a stray third arg -> exit 2" || no "clock extra-arg rc=$rc, want 2"
rc=$(bash "$SC/gop-probe.sh" "$S" 1.0 extra >/dev/null 2>&1; echo $?)
[ "$rc" -eq 2 ] && ok "gop-probe.sh with a stray third arg -> exit 2" || no "gop-probe extra-arg rc=$rc, want 2"
rc=$(bash "$SC/ts-health.sh" "$S" --kvv >/dev/null 2>&1; echo $?)
[ "$rc" -eq 2 ] && ok "ts-health.sh --kvv (mode typo) -> exit 2 (was silent human mode: a --kv consumer got zero rows)" \
  || no "ts-health mode-typo rc=$rc, want 2"
rc=$(bash "$SC/ts-health.sh" "$S" --kv extra >/dev/null 2>&1; echo $?)
[ "$rc" -eq 2 ] && ok "ts-health.sh --kv with a stray third arg -> exit 2" || no "ts-health extra-arg rc=$rc, want 2"
# negative controls: the legitimate shapes still work
rc=$(bash "$SC/ts-health.sh" "$S" --kv >/dev/null 2>&1; echo $?)
{ [ "$rc" -eq 0 ] || [ "$rc" -eq 10 ]; } && ok "ts-health --kv still works (rc=$rc)" || no "ts-health --kv broke (rc=$rc)"
rc=$(bash "$SC/diagnose.sh" "$S" >/dev/null 2>&1; echo $?)
{ [ "$rc" -eq 0 ] || [ "$rc" -eq 10 ]; } && ok "diagnose.sh IN still works (rc=$rc)" || no "diagnose broke (rc=$rc)"
o=$( cd "$WORK" && bash "$SC/mov.sh" "$S" -full 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && ok "mov.sh IN -full -> exit 2 (the typo no longer becomes the OUTPUT filename)" \
  || no "mov.sh -full rc=$rc, want 2"
[ -f "$WORK/-full" ] && no "a file named '-full' was built" || ok "no file named '-full' exists"

echo
echo "== 2. F5: --mp4-swap and metadata are honoured on the PAFF path =="
msrc=$(sed 's/#.*//' "$SC/mov.sh")
has "$msrc" 'auto.sh" "$IN" "$OUT" $FULL $MSFLAG' "the PAFF branch passes --mp4-swap through to auto.sh (which owns the swap)"
usage=$(grep -m1 'usage: mov.sh' "$SC/mov.sh")
has "$usage" "mp4-swap" "the usage string names --mp4-swap"
pblk=$(sed -n '/field-coded: hand the timeline repair/,/^fi$/p' "$SC/mov.sh")
has "$pblk" '-eq 10' "PAFF metadata applies on REVIEW (rc=10) too, not only on 0 (the non-PAFF path applies unconditionally)"

echo
echo "== 3. F2: the retired routing doctrine is gone from the teaching docs =="
tr_doc=$(cat "$DOCS/references/timeline-repair.md")
has "$tr_doc" "3-DERIVE" "timeline-repair.md (SKILL.md's 'full repair ladder') finally teaches Rung 3-DERIVE"
has "$tr_doc" "derive-dts.sh" "…by its script name"
has "$tr_doc" "run of exactly TWO" "…and the widened (2026-08-18) junction precondition, not just strict alternation"
readme=$(cat "$ROOT/README.md")
has "$readme" "derive" "README's ladder names the DTS re-derivation rung"
hasnt "$readme" "pair-mate PTS fill for pair-timestamped/reordered PAFF" "README no longer routes 'reordered' to pairfill (the 1.14 misroute as instructions)"
mv_doc=$(cat "$ROOT/skills/mov/SKILL.md")
has "$mv_doc" "derive" "/mov's skill names the derive route"
hasnt "$mv_doc" "pair-timestamped/reordered streams get the pair-mate PTS fill" "…and no longer teaches reordered->pairfill"
sk=$(cat "$DOCS/SKILL.md")
hasnt "$sk" "pair-timestamped or reordered → \`pairfill-paff.sh\`" "SKILL.md hard-won facts no longer route reordered to pairfill"

echo
echo "== 4. F7: promises match the gates =="
hasnt "$readme" "decoded-pixel identity (timestamp-agnostic" "README no longer promises decoded-pixel identity for every output"
has "$readme" "--full" "…the decoded/presentation proofs are scoped to --full"
dtq=$(cat "$DOCS/references/dual-track-quicktime.md")
has "$dtq" "E-AC-3 is QuickTime-native" "dual-track doc states the E-AC-3 copy-single classification"

echo
echo "== 5. D3 hygiene: no single-pipe 'ffp … | head -1' sites remain =="
d3_bad=""
for s in "$SC"/*.sh; do
  n=$(sed 's/#.*//' "$s" | grep -cE 'ffp [^|]*\| *head -1' || true)
  [ "${n:-0}" -eq 0 ] || d3_bad="$d3_bad $(basename "$s"):$n"
done
[ -z "$d3_bad" ] && ok "every single-pipe ffp|head-1 site converted to ffp1 (the 1.15.2 SIGPIPE class)" \
  || no "ffp|head-1 sites remain:$d3_bad"
# the D1 sibling: dim-scan's FIRST_CH assignment no longer grep|head|awk's
dsrc=$(sed 's/#.*//' "$SC/dim-scan.sh")
hasnt "$dsrc" "grep '^CHANGE ' \"\$TMP/scan\" | head -1" "dim-scan's assignment-position pipeline (D1 sibling) is gone"

echo
echo "91: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
