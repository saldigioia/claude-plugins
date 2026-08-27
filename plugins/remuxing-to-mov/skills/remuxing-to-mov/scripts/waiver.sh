#!/usr/bin/env bash
# waiver.sh — record an operator-attested waiver sidecar (OUTPUT.waiver.json)
# for a verify.sh gate failure whose named independent proofs all pass.
# QTFF audit 5-4c.
#
# A waiver is scoped to ONE file and ONE exact failure signature (class +
# count) — never a class of errors, never another file. verify.sh consults the
# sidecar on FAIL: an exact match (same gate set, same counts, same file
# bytes-identity, verbatim attestation) exits 0 with a loud WAIVED(<gate>)
# line; ANY drift — new signature, changed count, changed file — voids the
# waiver and the FAIL stands.
#
# Usage:
#   scripts/waiver.sh SOURCE OUTPUT \
#     --attest   "<exact operator attestation string>" \
#     --coverage "<what the proofs cover and what they do NOT (stated plainly)>" \
#     --proof    "<proof result, with hashes>"   [--proof ...]
#
# Rules (all hard):
#   - The attestation must match lib-attest.sh's RTM_WAIVER_ATTEST verbatim.
#     It originates from the operator — this script never supplies it, and a
#     near-miss is refused, not corrected.
#   - At least one --proof and a --coverage statement are required: a waiver
#     without recorded evidence is not a waiver.
#   - OUTPUT must currently FAIL verify.sh on a waiver-eligible gate ((d)/(e)
#     count signatures only). Essence/identity failures ((b)/--full/--audio)
#     are never waivable — there the failing gate IS the lossless proof.
#   - Refuses to overwrite an existing sidecar: deleting a recorded waiver is
#     the operator's deliberate act, never a side effect.
set -euo pipefail
export LC_ALL=C   # comma-decimal locales disarm awk float parsing (CHECKUP-2026-08-27 A3; rationale in lib-probe.sh, which this script does not source)
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
SRC="${1:?usage: waiver.sh SOURCE OUTPUT --attest \"...\" --coverage \"...\" --proof \"...\" [--proof ...]}"
OUT="${2:?need OUTPUT}"; shift 2
ATT=""; COV=""; PROOFS=""
NL='
'
# waiver text is embedded in line-oriented JSON parsed without jq — keep it flat
txt_ok () { case "$1" in *'"'*|*'\'*|*"$NL"*) return 1;; esac; return 0; }
while [ $# -gt 0 ]; do case "$1" in
  --attest)   ATT="${2:?--attest needs a value}"; shift 2;;
  --coverage) COV="${2:?--coverage needs a value}"; shift 2;;
  --proof)    p="${2:?--proof needs a value}"
              txt_ok "$p" || { echo "waiver.sh: quotes, backslashes and newlines are not allowed in --proof text" >&2; exit 2; }
              PROOFS="${PROOFS:+$PROOFS$NL}$p"; shift 2;;
  *) echo "waiver.sh: unknown opt: $1" >&2; exit 2;;
esac; done
for f in "$SRC" "$OUT"; do [ -f "$f" ] || { echo "waiver.sh: no such file: $f" >&2; exit 2; }; done
txt_ok "$COV" || { echo "waiver.sh: quotes, backslashes and newlines are not allowed in --coverage text" >&2; exit 2; }
[ -n "$COV" ]    || { echo "waiver.sh: --coverage is required — state plainly what the proofs cover and what they do not." >&2; exit 2; }
[ -n "$PROOFS" ] || { echo "waiver.sh: at least one --proof is required — a waiver without recorded evidence is not a waiver." >&2; exit 2; }
. "$SELF_DIR/lib-attest.sh"
if [ "$ATT" != "$RTM_WAIVER_ATTEST" ]; then
  echo "waiver.sh: attestation mismatch — the exact string must come from the operator, verbatim." >&2
  echo "waiver.sh: no fuzzy accept; nothing written." >&2
  exit 2
fi
WVR="$OUT.waiver.json"
[ -f "$WVR" ] && { echo "waiver.sh: $WVR already exists — delete it deliberately first; never overwritten." >&2; exit 2; }

# The failure signature comes from a live verify.sh run — never hand-typed.
vrc=0
vout=$(bash "$SELF_DIR/verify.sh" "$SRC" "$OUT" 2>&1) || vrc=$?
case "$vrc" in
  0) echo "waiver.sh: verify.sh did not FAIL (PASS/REVIEW/already WAIVED) — nothing to waive." >&2; exit 2;;
  1) : ;;
  *) echo "waiver.sh: verify.sh errored (rc=$vrc) — fix the invocation first:" >&2
     printf '%s\n' "$vout" | tail -3 >&2; exit 2;;
esac
sigline=$(printf '%s\n' "$vout" | grep '^VERIFY_SIGNATURE ' | tail -1) || true
if [ -z "$sigline" ]; then
  echo "waiver.sh: this FAIL is NOT waiver-eligible — no count-signature line emitted." >&2
  echo "waiver.sh: essence/identity failures ((b)/--full/--audio) are never waivable." >&2
  printf '%s\n' "$vout" | tail -5 >&2
  exit 2
fi
wgate=$(printf '%s' "$sigline" | sed -n "s/.* gate=\([^ ]*\).*/\1/p")
wsig=$(printf '%s' "$sigline" | sed -n "s/.* sig='\([^']*\)'.*/\1/p")
osize=$(printf '%s' "$sigline" | sed -n "s/.* size=\([0-9]*\).*/\1/p")
vh=$(printf '%s' "$sigline" | sed -n "s/.* vhash=\([^ ]*\).*/\1/p")
{ [ -n "$wgate" ] && [ -n "$wsig" ] && [ -n "$osize" ] && [ -n "$vh" ]; } || {
  echo "waiver.sh: could not parse the VERIFY_SIGNATURE line: $sigline" >&2; exit 2; }

ffv=$(ffmpeg -nostdin -version 2>/dev/null | head -1 | awk '{print $1" "$2" "$3}') || ffv="ffmpeg unknown"
osv=""
[ "$(uname -s)" = Darwin ] && osv="; macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"
today=$(date +%F)

# line-oriented JSON, one key per line — parsed by verify.sh with awk, no jq dep
{
  printf '{\n'
  printf '  "waiver_format": 1,\n'
  printf '  "file": "%s",\n' "$(basename "$OUT")"
  printf '  "file_size": %s,\n' "$osize"
  printf '  "video_streamhash": "%s",\n' "$vh"
  printf '  "gate": "%s",\n' "$wgate"
  printf '  "signature": "%s",\n' "$wsig"
  printf '  "coverage": "%s",\n' "$COV"
  printf '  "proofs": [\n'
  first=1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$first" -eq 1 ] && first=0 || printf ',\n'
    printf '    "%s"' "$p"
  done <<EOF
$PROOFS
EOF
  printf '\n  ],\n'
  printf '  "tools": "%s%s",\n' "$ffv" "$osv"
  printf '  "date": "%s",\n' "$today"
  printf '  "attestation": "%s"\n' "$ATT"
  printf '}\n'
} > "$WVR.part"
mv "$WVR.part" "$WVR"

echo ">> waiver recorded: $WVR"
echo "   gate=$wgate"
echo "   signature=$wsig"
echo "   Scope: this file, this signature only. Re-run scripts/verify.sh to confirm —"
echo "   it must print WAIVED($wgate) and exit 0. The waiver is void the moment the"
echo "   file or its failure signature changes."
