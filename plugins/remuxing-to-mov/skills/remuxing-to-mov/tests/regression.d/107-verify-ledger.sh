#!/usr/bin/env bash
# 107-verify-ledger.sh — gate (n): a verifier states what it could not prove.
#
# WHY. Before 1.16.0 a gate that could not run left NO TRACE in the report.
# The reader saw the gates that spoke and had no way to learn which ones had
# stayed silent — so "verified" meant "everything that ran was happy", and on
# 2026-08-28 everything that ran WAS happy about two unusable builds. A gate
# that is skipped without saying so is indistinguishable from a gate that
# passed, and that is the quiet assumption this round exists to close.
#
# The ledger prints one row per gate INCLUDING the ones that could not run,
# and a human sentence per unproven gate saying what it leaves unproven.
#
# THE VOCABULARY IS LOAD-BEARING and this suite pins the distinction:
#   unproven  the gate was owed and could not be evaluated -> downgrades to REVIEW
#   n/a       the gate does not apply to this input        -> changes nothing
# Collapse them and either every run reads REVIEW (and the signal is worthless)
# or an unreadable track passes as clean (and the signal is a lie).
#
# Pins:
#   1. every gate letter files exactly one row;
#   2. a clean run says so explicitly ("nothing is left unproven");
#   3. THE MUTATION (the plan's own test): remove a gate's tool from PATH and
#      the ledger must SAY the gate could not run — not omit it, not pass it;
#   4. an unproven gate downgrades a PASS to REVIEW, and never touches a FAIL;
#   5. `n/a` rows never downgrade anything;
#   6. the machine summary counts what the rows say.
#
# Standalone: bash tests/regression.d/107-verify-ledger.sh
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
rows () { printf '%s\n' "$1" | grep -c '^VERIFY_LEDGER gate=' || true; }
row_of () { printf '%s\n' "$1" | sed -n "s/^VERIFY_LEDGER gate=$2 verdict=\\([a-z\\/]*\\) .*/\\1/p" | head -1; }

echo "== 0. fixture + a clean build =="
S="$WORK/src.ts"
ff -f lavfi -i testsrc2=s=160x120:r=25 -f lavfi -i sine=1000 -t 2 \
   -c:v libx264 -g 25 -pix_fmt yuv420p -c:a aac -f mpegts "$S" || { echo "mint failed"; exit 2; }
ff -i "$S" -map 0:v:0 -map 0:a:0 -c copy -tag:v avc1 "$WORK/o.mov"
CLEAN=$(bash "$SC/verify.sh" "$S" "$WORK/o.mov" 2>&1)

echo
echo "== 1. every gate files exactly one row =="
for g in a b c d e f g h i j k l m; do
  n=$(printf '%s\n' "$CLEAN" | grep -c "^VERIFY_LEDGER gate=$g " || true)
  [ "${n:-0}" -eq 1 ] && ok "gate ($g) files exactly one row" || no "gate ($g) filed $n rows (want exactly 1)"
done

echo
echo "== 2. a clean run says so, in words and in the machine summary =="
has "$CLEAN" "nothing is left unproven" "the clean run states that nothing is unproven"
has "$CLEAN" "VERIFY_LEDGER_SUMMARY" "the machine summary is emitted"
has "$CLEAN" "unproven=0" "…and counts zero unproven gates"
has "$CLEAN" ">> OK" "the verdict is OK"

echo
echo "== 3. THE MUTATION: take a gate's tool away and the ledger must say so =="
# python3 is gate (i)'s tool. A PATH without it must produce an UNPROVEN row
# naming the reason — never a missing row, and never a pass.
# The shim is the REAL PATH minus python3 — enumerating a hand-written tool
# list instead made verify.sh unrunnable, and a mutation that breaks the script
# proves nothing about the ledger (it has to be the one tool, not the world).
SHIM="$WORK/shim"; mkdir -p "$SHIM"
IFS=: read -r -a _pdirs <<< "$PATH"
for d in "${_pdirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -x "$f" ] && [ ! -d "$f" ] || continue
    b=$(basename "$f")
    case "$b" in python3*|python|pypy*) continue;; esac
    [ -e "$SHIM/$b" ] || ln -sf "$f" "$SHIM/$b"
  done
done
command -v python3 >/dev/null && ! PATH="$SHIM" command -v python3 >/dev/null \
  && ok "the mutation is real: python3 is absent from the shimmed PATH" \
  || no "the shimmed PATH did not actually remove python3 — this lane proves nothing"
MUT=$(PATH="$SHIM" bash "$SC/verify.sh" "$S" "$WORK/o.mov" 2>&1)
iv=$(row_of "$MUT" i)
[ "$iv" = unproven ] && ok "gate (i) reports UNPROVEN when python3 is gone" || no "gate (i) row reads '${iv:-MISSING}' with no python3 (want unproven)"
has "$MUT" "python3" "…and the row names the missing tool"
has "$MUT" "UNPROVEN (i)" "the human sentence for the unproven gate is printed"
case "$MUT" in
  *">> REVIEW"*) ok "an unproven gate downgrades the run to REVIEW" ;;
  *">> OK"*)     no "an unproven gate was reported as OK — a silently skipped gate is indistinguishable from a passing one" ;;
  *)             ok "an unproven gate does not report OK" ;;
esac
n=$(printf '%s\n' "$MUT" | grep -c "^VERIFY_LEDGER gate=i " || true)
[ "${n:-0}" -eq 1 ] && ok "the gate is still listed — never silently dropped" || no "gate (i) filed $n rows under the mutation"

echo
echo "== 4. n/a never downgrades: an audio-only deliverable is not 'unproven' =="
A="$WORK/a.ts"
ff -f lavfi -i "sine=1000:r=48000" -t 1 -c:a aac -f mpegts "$A"
ff -i "$A" -map 0:a:0 -c copy "$WORK/a.mov"
AO=$(bash "$SC/verify.sh" "$A" "$WORK/a.mov" 2>&1)
for g in d h k; do
  v=$(row_of "$AO" "$g")
  [ "$v" = "n/a" ] && ok "gate ($g) is n/a on an audio-only output, not unproven" || no "gate ($g) reads '${v:-MISSING}' on an audio-only output (want n/a)"
done
hasnt "$AO" "UNPROVEN (d)" "no n/a gate is announced as unproven"

echo
echo "== 5. the summary count agrees with the rows it summarises =="
declared=$(printf '%s\n' "$CLEAN" | sed -n 's/.*VERIFY_LEDGER_SUMMARY gates=\([0-9]*\).*/\1/p' | head -1)
actual=$(rows "$CLEAN")
[ "${declared:-x}" = "${actual:-y}" ] && ok "summary gates=$declared matches the $actual rows printed" \
  || no "summary says gates=$declared but $actual rows were printed"
du=$(printf '%s\n' "$MUT" | sed -n 's/.*VERIFY_LEDGER_SUMMARY .*unproven=\([0-9]*\).*/\1/p' | head -1)
au=$(printf '%s\n' "$MUT" | grep -c '^VERIFY_LEDGER gate=[a-z]* verdict=unproven' || true)
[ "${du:-x}" = "${au:-y}" ] && ok "summary unproven=$du matches the $au unproven rows" \
  || no "summary says unproven=$du but $au unproven rows were printed"

echo
echo "verify-ledger: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
