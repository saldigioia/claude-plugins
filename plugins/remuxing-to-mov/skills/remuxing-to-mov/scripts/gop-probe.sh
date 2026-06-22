#!/usr/bin/env bash
# gop-probe.sh — is a copy-cut point GOP-safe? Flags OPEN-GOP boundaries whose
# leading B-frames reference the PREVIOUS GOP. Cutting there drops those references
# and the decoder manufactures a garbage frame at the concat seam (see
# references/cutting-concat.md). Lossless cutting's real blind spot.
#
# QuickTime grounding: a CLOSED-GOP / IDR keyframe is a full SYNC SAMPLE ('stss') —
# the spec calls it "self-contained ... independent of preceding frames", safe to
# cut in front of. An OPEN-GOP I-frame is only a PARTIAL SYNC SAMPLE ('stps'): a
# random-access point, but frames around it display earlier and depend on what
# came before (the 'ctts' reordering + the 'sdtp' EarlierDisplayTimesAllowed flag).
#
# Usage: scripts/gop-probe.sh INPUT [CUT_TIME]
#   (no CUT_TIME) summarize the file: how many video keyframes are open vs closed.
#   CUT_TIME      analyze the keyframe an input-seek (-ss CUT_TIME) lands on, and
#                 recommend the nearest SAFE (closed) keyframe at or after it.
# Exit: 0 = safe (closed) / summary; 10 = the cut lands on an OPEN-GOP boundary.
set -euo pipefail
IN="${1:?usage: gop-probe.sh INPUT [CUT_TIME]}"; T="${2:-}"
[ -n "${GOP_PROBE_CSV:-}" ] || [ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }

# Per-keyframe open/closed table -> "ts open|closed", one line per video keyframe.
# A keyframe is OPEN if a frame decoded just after it DISPLAYS earlier AND is a
# B-frame (a leading B referencing across the boundary). Fields are identified by
# CONTENT (0/1=key_frame, I/P/B=pict_type, x.x=timestamp) so the parser is immune
# to ffprobe's column ordering across versions.
kf_table () {
  # GOP_PROBE_CSV lets tests feed a crafted ffprobe-format frame table
  # (key_frame,best_effort_timestamp_time,pict_type) without real open-GOP media,
  # which libx264/x265 won't synthesize on demand.
  { if [ -n "${GOP_PROBE_CSV:-}" ]; then cat "$GOP_PROBE_CSV"
    else ffprobe -v error -select_streams v:0 \
           -show_entries frame=key_frame,best_effort_timestamp_time,pict_type -of csv=p=0 "$1" 2>/dev/null
    fi; } \
  | awk -F, '{
      kf=""; pt=""; ts="";
      for(i=1;i<=NF;i++){
        if($i=="0"||$i=="1") kf=$i;
        else if($i ~ /^-?[0-9]+\.[0-9]+$/) ts=$i;
        else if($i ~ /^[A-Za-z?]+$/) pt=$i;
      }
      if(ts=="") next;
      K[NR]=kf; TS[NR]=ts; P[NR]=pt; n=NR
    }
    END{
      for(i=1;i<=n;i++) if(K[i]==1){
        lead=0; for(j=i+1;j<=i+6 && j<=n;j++) if(TS[j]+0 < TS[i]+0 && P[j]=="B") lead++;
        printf "%.6f %s\n", TS[i]+0, (lead>0?"open":"closed")
      }
    }'
}

TBL="$(kf_table "$IN")"
[ -n "$TBL" ] || { echo "no video keyframes found in $IN (not a coded video track?)" >&2; exit 2; }
nopen=$(printf '%s\n'  "$TBL" | awk '$2=="open"'   | grep -c . || true)
nclosed=$(printf '%s\n' "$TBL" | awk '$2=="closed"' | grep -c . || true)

if [ -z "$T" ]; then
  echo "== GOP summary: $IN =="
  echo "   video keyframes: open(partial-sync)=$nopen  closed(full-sync)=$nclosed"
  if [ "${nopen:-0}" -gt 0 ]; then
    echo "   This source has OPEN-GOP cut points. A copy-cut/concat that lands on one"
    echo "   can glitch at the seam. Pass a CUT_TIME to check a specific point, and"
    echo "   verify any join with scripts/seam-check.sh."
    echo "   first open keyframes (s): $(printf '%s\n' "$TBL" | awk '$2=="open"{print $1}' | head -5 | tr '\n' ' ')"
  else
    echo "   All keyframes are closed/full-sync — copy-cuts on keyframes are seam-safe."
  fi
  exit 0
fi

# --- analyze a specific cut time ---
# keyframe an input-seek lands on = last keyframe with ts <= T
land=$(printf '%s\n' "$TBL" | awk -v t="$T" '($1+0)<=(t+0){k=$0} END{print k}')
echo "== cut check: $IN @ ${T}s =="
if [ -z "$land" ]; then
  echo "   no keyframe at or before ${T}s — an input-seek would start at the file head."
  exit 0
fi
lk_ts=${land% *}; lk_state=${land#* }
echo "   input-seek lands on keyframe @ ${lk_ts}s -> $([ "$lk_state" = open ] && echo 'OPEN GOP (partial sync — RISKY)' || echo 'CLOSED GOP (full sync — safe)')"
if [ "$lk_state" = closed ]; then
  echo ">> SAFE: cut here; the segment is self-contained at the join."
  exit 0
fi
# recommend the nearest CLOSED keyframe at or after the landing keyframe
safe=$(printf '%s\n' "$TBL" | awk -v t="$lk_ts" '$2=="closed" && ($1+0)>=(t+0){print $1; exit}')
echo ">> RISKY: this is an OPEN-GOP boundary. Its leading B-frames reference the"
echo "   previous GOP; after a cut+concat they decode against the wrong frame and"
echo "   flash one garbage frame at the seam."
if [ -n "$safe" ]; then
  echo "   FIX: restart the segment on the next CLOSED-GOP keyframe @ ${safe}s"
  echo "        (input-seek so audio+video cut together):"
  echo "        ffmpeg -nostdin -ss ${safe} -i \"$IN\" -map 0:v:0 -map 0:a -c copy \\"
  echo "          -avoid_negative_ts make_zero -movflags +faststart -f mov OUT.mov"
  echo "        Confirm the skipped span carries no wanted content, then verify the join:"
  echo "        scripts/seam-check.sh JOINED.mov <seam_time>"
else
  echo "   No closed-GOP keyframe found ahead — this stream is all open-GOP. The exact"
  echo "   cut needs a SMART-CUT: re-encode just the boundary GOP to close it, copy the"
  echo "   rest (the one editing case that re-encodes; see references/cutting-concat.md)."
fi
exit 10
