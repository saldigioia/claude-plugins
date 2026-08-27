#!/usr/bin/env bash
# dim-scan.sh — whole-file frame-dimension sweep: the detection half of the
# "mid-stream SPS / resolution change" named limitation (known-limits.md,
# measured 2026-08-14: a broadcast splice that changes the coded resolution
# copy-muxes into MOV with NO warning, the stsd declares the FIRST resolution
# for the whole track, and no gate catches it — probe, mux, verify and
# playable-check all pass).
#
# This scan decodes the video once, whole-file (frame-level width/height only
# exist after decode — that is why ts-health, demux-only by charter, cannot
# own this class). CPU-bound and background-able; run it when a capture is
# suspected of spanning a junction, or from clean.sh.
#
# A found change names the splice PTS and the routes — all source-domain:
#   * cut at the splice (scripts/surgical-cut.sh on mpegts — each side then
#     remuxes with an honest, uniform stsd), or
#   * keep the source as-is and do NOT remux across the junction (the .mov
#     would declare the first resolution for the whole track).
#
# Usage: scripts/dim-scan.sh INPUT
# Exit: 0 CLEAN (one resolution end-to-end) | 10 CHANGE(S) FOUND | 1 cannot
#       measure | 2 usage.
# Machine line (stable API — extend only):
#   DIMSCAN_SUMMARY changes= dims= first_change_pts= frames=
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap: no stray code escapes
IN="${1:?usage: dim-scan.sh INPUT}"
[ $# -le 1 ] || { echo "unknown opt: $2" >&2; exit 2; }
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # only our own scratch; never the source

echo "== dim-scan: $IN (whole-file decode — frame dimensions only exist after decode) =="

# one pass; consecutive same-dimension frames collapse to segments
ffp -v error -select_streams v:0 -show_entries frame=pts_time,width,height \
    -of csv=p=0 "$IN" 2>/dev/null | \
  awk -F, 'NF>=3 && $2!="" && $3!="" {
      n++
      d=$2 "x" $3
      if(d!=cur){ seg++; if(cur!="") printf "CHANGE %s %s %s\n", $1, cur, d
                  else first=d
                  cur=d; dims=dims (dims==""?"":",") d }
    }
    END{ printf "FRAMES %d\nDIMS %s\nSEGS %d\n", n+0, dims, seg+0 }' > "$TMP/scan"
NFR=$(sed -n 's/^FRAMES //p' "$TMP/scan")
DIMS=$(sed -n 's/^DIMS //p' "$TMP/scan")
SEGS=$(sed -n 's/^SEGS //p' "$TMP/scan")
[ "${NFR:-0}" -gt 0 ] || { echo "no frames decoded — cannot measure" >&2; exit 1; }
NCH=$((SEGS > 0 ? SEGS - 1 : 0))
FIRST_CH=na

if [ "$NCH" -eq 0 ]; then
  echo "   $NFR frames, one resolution end-to-end: $DIMS"
  echo ">> CLEAN: no mid-stream dimension change."
else
  echo "   $NFR frames, $((NCH)) dimension change(s): $DIMS"
  grep '^CHANGE ' "$TMP/scan" | while read -r _ pts from to; do
    echo "   CHANGE at pts ${pts}s: $from -> $to"
  done
  # awk reads the file directly and exits on the first hit — the old
  # grep|head|awk shape was the D1 SIGPIPE class in ASSIGNMENT position
  # (a ~1900-CHANGE scan could kill the run under pipefail; WO-1.15.9)
  FIRST_CH=$(awk '/^CHANGE /{print $2; exit}' "$TMP/scan")
  echo ">> MID-STREAM RESOLUTION CHANGE — the class no downstream gate catches:"
  echo "   a -c copy .mov of this file would declare the FIRST resolution in stsd while"
  echo "   half its samples decode at another (known-limits.md, measured 2026-08-14)."
  echo "   Routes (source-domain):"
  echo "     cut   split at the splice first — on mpegts: scripts/lead-check.sh-style"
  echo "           census around ${FIRST_CH}s, then scripts/surgical-cut.sh (each side"
  echo "           then remuxes with an honest stsd)"
  echo "     keep  the source as-is; do NOT remux across the junction"
fi
echo "DIMSCAN_SUMMARY changes=$NCH dims=$DIMS first_change_pts=$FIRST_CH frames=$NFR"
[ "$NCH" -eq 0 ] && exit 0
exit 10
