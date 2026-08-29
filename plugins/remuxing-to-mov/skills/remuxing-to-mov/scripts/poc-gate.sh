#!/usr/bin/env bash
# poc-gate.sh — standalone POC-lattice judge (WO-1.15.3 Item 3). The operator
# playbook's step 7 ("re-run the gate against the .part standalone — 26 minutes
# instead of a 60-minute rebuild") described a capability no script provided;
# the field run did it by hand-sourcing lib-paff.sh. This is that capability:
# a thin driver over the existing pieces — pf_poc_extract (the gate's own
# direct-output extraction) + pf_poc_lattice (the §8.2.1.1-unwrapping checker,
# 1.15.2 Defect D, pinned by test 76) — printing the same on_slot= human line
# and PP_POC_LATTICE machine row pairfill's burial point prints.
#
# Usage: scripts/poc-gate.sh ARTIFACT [--maxlsb N]
#        scripts/poc-gate.sh --table CSV [--maxlsb N]
#   ARTIFACT   judge a built file (a kept .part included): whole-file
#              trace_headers extraction + ffprobe PTS — the direct arm, the
#              only one possible standalone (no census in scope here)
#   --table    judge a prepared idr,poc,pts CSV instead (decode order — the
#              unit lane's entry point; test 76's tables drive it as-is)
#   --maxlsb   explicit MaxPicOrderCntLsb for the unwrap (else the artifact's
#              SPS capture; else per-sequence inference)
#
# EXIT CONTRACT — the same verdict honestly carries different exits in
# different contexts (the 1.15.2 Phase-5 5.1 principle, applied locally):
#   0   every picture on its lattice slot
#   1   off-lattice picture(s) — the written timeline is not the derived one
#   10  UNPROVEN: the gate cannot evaluate this input (pic_order_cnt_type != 0
#       — zero lsb rows; picture/packet count mismatch; or the extraction
#       itself failed, rc reported — EMPTY != ABSENT). Standalone there is NO
#       bless decision at stake: this script only reports what it could judge,
#       and "could not evaluate" is REVIEW semantics (verify.sh is the house
#       reference for exactly this split). Inside pairfill-paff.sh the SAME
#       UNPROVEN verdict keeps exit 1 + .part retention — an unproven build
#       must never be blessed there.
#   2   usage / no such file
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
RTM_EXIT_OK="0 1 2 10"
ART=""; TABLE=""; MAXLSB=0
while [ $# -gt 0 ]; do case "$1" in
  --table)  TABLE="${2:?--table needs a CSV path}"; shift 2;;
  --maxlsb) MAXLSB="${2:?--maxlsb needs a value}"; shift 2;;
  -*) echo "unknown opt: $1" >&2; exit 2;;
  *) [ -z "$ART" ] || { echo "one ARTIFACT only (got: $ART, $1)" >&2; exit 2; }
     ART="$1"; shift;;
esac; done
[ -n "$ART" ] || [ -n "$TABLE" ] || { echo "usage: poc-gate.sh ARTIFACT [--maxlsb N]  |  poc-gate.sh --table CSV [--maxlsb N]" >&2; exit 2; }
case "$MAXLSB" in ''|*[!0-9]*) echo "--maxlsb must be a whole number (got: $MAXLSB)" >&2; exit 2;; esac
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-paff.sh"   # pf_poc_extract + pf_poc_lattice

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ -n "$TABLE" ]; then
  [ -f "$TABLE" ] || { echo "no such table: $TABLE" >&2; exit 2; }
  cp "$TABLE" "$TMP/table.csv"
  rows=$(grep -c . "$TMP/table.csv" || true)
  echo "== poc-gate: prepared table $TABLE ($rows rows) =="
  if [ "${rows:-0}" -eq 0 ]; then
    echo ">> POC-LATTICE UNPROVEN — the table is empty: nothing to judge."
    echo "PP_POC_LATTICE unproven=1 why=count rows=0 packets=0"
    exit 10
  fi
else
  [ -f "$ART" ] || { echo "no such file: $ART" >&2; exit 2; }
  echo "== poc-gate: $ART (direct-output extraction — whole-file header parse) =="
  # EMPTY != ABSENT (WO-1.15.4): the extraction's exit status travels with its
  # output — a failed parse is UNPROVEN-with-rc, never a silent zero-row table
  # and NEVER an off-lattice accusation.
  xrc=0; pf_poc_extract "$ART" "$TMP/poc.csv" "$TMP/sps" || xrc=$?
  prc=0
  ffp -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$ART" 2>/dev/null | \
    awk -F, 'NF && $1!="N/A"{ print $1+0 }' > "$TMP/pts.csv" || prc=$?
  pp_na=$(grep -c . "$TMP/poc.csv" || true); pp_nb=$(grep -c . "$TMP/pts.csv" || true)
  if [ "$xrc" -ne 0 ] || [ "$prc" -ne 0 ] || [ "${pp_na:-0}" -eq 0 ] || [ "${pp_na:-0}" -ne "${pp_nb:-1}" ]; then
    pp_why=count; [ "${pp_na:-0}" -eq 0 ] && pp_why=poc_type
    { [ "$xrc" -ne 0 ] || [ "$prc" -ne 0 ]; } && pp_why=probe_failed
    echo ">> POC-LATTICE UNPROVEN — POC not extractable or picture/packet counts differ"
    echo "   (POC rows=$pp_na, timestamped packets=$pp_nb, extract rc=$xrc, probe rc=$prc;"
    echo "    pic_order_cnt_type != 0 streams carry no pic_order_cnt_lsb and the lattice"
    echo "    cannot be evaluated. NOT a verdict on the artifact — could-not-judge is"
    echo "    REVIEW semantics here, exit 10.)"
    echo "PP_POC_LATTICE unproven=1 why=$pp_why rows=$pp_na packets=$pp_nb"
    exit 10
  fi
  if [ "$MAXLSB" -eq 0 ]; then
    l2=$(head -1 "$TMP/sps" 2>/dev/null || true)
    case "${l2:-}" in ''|*[!0-9]*) ;; *) [ "$l2" -le 12 ] && MAXLSB=$((1 << (l2 + 4)));; esac
  fi
  paste -d, "$TMP/poc.csv" "$TMP/pts.csv" > "$TMP/table.csv"
  echo "   rows=$pp_na (== timestamped packets)"
fi
if [ "$MAXLSB" -gt 0 ]; then
  echo "   MaxPicOrderCntLsb=$MAXLSB; lsb unwrapped per H.264 8.2.1.1"
else
  echo "   MaxPicOrderCntLsb: no SPS value — inferred per sequence (next power of two above the largest lsb)"
fi
eval "$(pf_poc_lattice "$TMP/table.csv" "$MAXLSB")"
echo "   on_slot=$PL_ON/$PL_TOTAL  off_lattice=$PL_OFF  (POC scopes=$PL_SEQS)"
echo "PP_POC_LATTICE on_slot=$PL_ON total=$PL_TOTAL off=$PL_OFF scopes=${PL_SEQS:-0} nofit=${PL_NOFIT:-0}"
# 1.16.2: a scope whose presentation interval cannot be FIT was never judged.
# Reporting it as off-lattice would be an accusation the gate did not earn —
# and this script's own contract already has the right word for it: UNPROVEN.
if [ "${PL_NOFIT:-0}" -ne 0 ] && [ "${PL_OFF:-0}" -eq "${PL_NOFIT_PICS:-0}" ]; then
  echo ">> POC-LATTICE UNPROVEN — ${PL_NOFIT} of ${PL_SEQS} scope(s) carry no fittable"
  echo "   presentation interval (scope index ${PL_NOFIT_AT:-?}; ${PL_NOFIT_PICS} picture(s))."
  echo "   Those pictures are not judged, and not accused; the rest are on-slot."
  echo "PP_POC_LATTICE unproven=1 why=nofit scopes=${PL_NOFIT} pictures=${PL_NOFIT_PICS}"
  exit 10
fi
if [ "${PL_OFF:-1}" -ne 0 ]; then
  echo ">> OFF-LATTICE: $PL_OFF picture(s) off their presentation slot — the written"
  echo "   timeline is not the derived lattice."
  exit 1
fi
echo ">> ON-LATTICE: every picture on its presentation slot."
exit 0
