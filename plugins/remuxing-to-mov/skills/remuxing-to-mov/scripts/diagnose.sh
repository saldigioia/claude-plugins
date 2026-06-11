#!/usr/bin/env bash
# diagnose.sh — run the glitch-diagnosis ladder in order and print a verdict.
# Usage: scripts/diagnose.sh INPUT
# Ladder: (1) decode-to-null integrity + non-monotonic-DTS scan
#         (2) MKV strict-mux test (catches MISSING timestamps)
#         (3) packet DTS monotonicity scan (catches backward AND duplicate DTS)
# Executable form of references/timeline-repair.md. "Non-monotonic" includes
# DUPLICATE (equal) DTS — ffmpeg flags "X >= X" as invalid, and a field-coded
# stream on a non-integer timebase produces these throughout.
set -euo pipefail
IN="${1:?usage: diagnose.sh INPUT}"
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # only our own scratch; never the source

echo "== diagnosing: $IN =="

# (1) decode-to-null: separates real decode damage from timestamp defects.
echo "-- (1) decode-to-null integrity --"
ffmpeg -nostdin -v error -i "$IN" -map 0:v:0 -f null - 2>"$TMP/null.err" || true
ndecode=$(grep -ciE 'error while decoding|concealing|invalid data' "$TMP/null.err" || true)
nmono=$(grep -ciE 'non.?monotonical' "$TMP/null.err" || true)
sort "$TMP/null.err" | uniq -c | sort -rn | head -8 | sed 's/^/   /'
echo "   decode-damage lines: ${ndecode:-0} | non-monotonic-DTS warnings: ${nmono:-0}"
if [ "${ndecode:-0}" -ge 5 ]; then
  echo ">> VERDICT: SOURCE DAMAGED (dropped/corrupt packets). No remux repairs this. Re-capture."
  exit 0
fi
echo "   (a few mmco/ref-frame lines are benign and carry through losslessly)"

# (2) strict mux to MKV — Matroska refuses the absent timestamps MOV swallows.
echo "-- (2) MKV strict-mux test --"
if ffmpeg -nostdin -v error -i "$IN" -map 0:v:0 -map "0:a?" -c copy "$TMP/t.mkv" 2>"$TMP/mkv.err"; then
  echo "   MKV mux OK -> timestamps are present (not missing)."
  mkv_ok=1
else
  echo "   MKV mux FAILED:"; sed 's/^/     /' "$TMP/mkv.err" | tail -3
  if grep -qiE 'timestamp.*unset|unknown timestamp' "$TMP/mkv.err"; then
    echo ">> VERDICT: MISSING TIMESTAMPS. Try Rung-2 genpts (remux.sh --genpts);"
    echo "   if it still glitches, full rebuild: scripts/rebuild-paff.sh."
    exit 0
  fi
  mkv_ok=0
fi

# (3) packet DTS monotonicity (backward OR duplicate). <= catches equal DTS.
echo "-- (3) DTS monotonicity scan --"
read -r ndup nback < <(ffprobe -v error -select_streams v:0 -read_intervals "%+#5000" \
  -show_entries packet=dts -of csv=p=0 "$IN" 2>/dev/null | \
  awk -F, 'NR>1 && $1!="N/A" && p!="N/A"{ if($1<p)bk++; else if($1==p)du++ } {p=$1}
    END{print (du+0), (bk+0)}')
echo "   first 5000 packets: duplicate(equal) DTS=${ndup:-0}  backward DTS=${nback:-0}"

# --- verdict ---
if [ "${nmono:-0}" -ge 10 ] || [ "${ndup:-0}" -gt 0 ] || [ "${nback:-0}" -gt 0 ]; then
  echo ">> VERDICT: NON-MONOTONIC / DUPLICATE DTS (broken timeline, common on a"
  echo "   field-coded stream muxed on a non-integer timebase). Full rebuild at the"
  echo "   field rate: scripts/rebuild-paff.sh IN OUT.mov 60000/1001 60000"
elif [ "${mkv_ok:-1}" -eq 1 ]; then
  echo ">> VERDICT: timing looks sound -> plain copy (Rung 0): scripts/remux.sh."
  echo "   (If MOV still glitches despite this, rebuild anyway: rebuild-paff.sh.)"
else
  echo ">> VERDICT: timestamps problematic (MKV refused) -> rebuild: scripts/rebuild-paff.sh."
fi
