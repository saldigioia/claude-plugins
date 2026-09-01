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
# Usage: scripts/dim-scan.sh INPUT [--headers]
# Exit: 0 CLEAN (one resolution end-to-end) | 10 CHANGE(S) FOUND | 1 cannot
#       measure | 2 usage.
# Machine lines (stable API — extend only):
#   DIMSCAN_SUMMARY changes= dims= first_change_pts= frames=      (decode mode)
#   DIMSCAN_HDR mode=headers codec= distinct_ps= verdict=         (--headers)
#
# --headers (1.19.0, REMUX-PIPELINE retrace §6.2): the decode sweep on a
# 3.9 GB capture cost ~16 min — 87% of that session's measured machine time —
# purely to prove the resolution never changes. Coded dimensions live in the
# parameter sets (H.264/HEVC SPS; MPEG-2 sequence header), so counting
# DISTINCT parameter-set payloads in the elementary stream answers the same
# question demux-only, at disk speed (~20x). Scope stated honestly: ONE
# distinct PS proves the dimensions static (they have nowhere else to live);
# MORE than one proves a mid-stream PS change but not that dimensions moved —
# a findings verdict routes to the decode mode to confirm. Full decode stays
# the sign-off form and the only form for other codecs.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap: no stray code escapes
IN="${1:?usage: dim-scan.sh INPUT [--headers]}"
MODE=decode
case "${2:-}" in '') : ;; --headers) MODE=headers;; *) echo "unknown opt: $2" >&2; exit 2;; esac
[ $# -le 2 ] || { echo "unknown opt: $3" >&2; exit 2; }
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # only our own scratch; never the source

if [ "$MODE" = headers ]; then
  command -v python3 >/dev/null 2>&1 || { echo "--headers needs python3 (decode mode does not)" >&2; exit 2; }
  VC=$(ffp1 -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null || true)
  case "$VC" in
    h264)       BSF=(-bsf:v h264_mp4toannexb); RAWF=h264;  PSNAME=SPS;;
    hevc)       BSF=(-bsf:v hevc_mp4toannexb); RAWF=hevc;  PSNAME=SPS;;
    mpeg2video) BSF=();                        RAWF=mpeg2video; PSNAME="sequence header";;
    *) echo "--headers reads H.264/HEVC SPS and MPEG-2 sequence headers; this is ${VC:-unreadable}." >&2
       echo "Use the decode mode (no flag) — it is codec-agnostic." >&2; exit 2;;
  esac
  echo "== dim-scan --headers: $IN (demux-only distinct-$PSNAME census; codec=$VC) =="
  set +e
  NPS=$(ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$IN" -map 0:v:0 -c copy \
          ${BSF[@]+"${BSF[@]}"} -f "$RAWF" - 2>/dev/null | \
    python3 -c "
import sys, hashlib
codec = '$VC'
SC = b'\x00\x00\x01'; BUF = 1 << 22; OV = 1 << 16
f = sys.stdin.buffer; ov = b''; seen = set()
def is_ps(b0):
    if codec == 'h264': return (b0 & 0x1f) == 7
    if codec == 'hevc': return ((b0 >> 1) & 0x3f) == 33
    return b0 == 0xB3                       # mpeg2: sequence_header_code
while True:
    b = f.read(BUF)
    if not b: break
    d = ov + b; i = d.find(SC)
    while i != -1 and i + 3 < len(d):
        if is_ps(d[i+3]):
            j = d.find(SC, i + 3)
            if j != -1:
                seen.add(hashlib.sha1(d[i+3:j]).hexdigest())
        i = d.find(SC, i + 1)
    ov = d[-OV:]                            # boundary overlap; set dedupes re-hashes
print(len(seen))"); ps_rc=$?
  set -e
  case "$NPS" in ''|*[!0-9]*) NPS=0;; esac
  if [ "$ps_rc" -ne 0 ] || [ "$NPS" -eq 0 ]; then
    echo "no $PSNAME parsed (rc=$ps_rc) — cannot measure; run the decode mode" >&2
    echo "DIMSCAN_HDR mode=headers codec=$VC distinct_ps=0 verdict=unmeasured"
    exit 1
  fi
  if [ "$NPS" -eq 1 ]; then
    echo "   one distinct $PSNAME end-to-end — coded dimensions cannot change (they live there)."
    echo ">> CLEAN: no mid-stream parameter-set change."
    echo "DIMSCAN_HDR mode=headers codec=$VC distinct_ps=1 verdict=clean"
    exit 0
  fi
  echo "   $NPS distinct ${PSNAME}s — the parameter sets CHANGE mid-stream."
  echo ">> FINDINGS: a mid-stream PS change is the splice signature, but distinct sets can"
  echo "   also differ in non-dimension fields. Confirm what changed and WHERE with the"
  echo "   decode mode: scripts/dim-scan.sh \"$IN\"   (names each splice PTS)"
  echo "DIMSCAN_HDR mode=headers codec=$VC distinct_ps=$NPS verdict=findings"
  exit 10
fi

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
