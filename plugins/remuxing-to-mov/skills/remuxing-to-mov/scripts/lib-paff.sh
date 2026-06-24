#!/usr/bin/env bash
# lib-paff.sh — shared field-coded (PAFF) H.264 detection. SOURCE this, don't run it.
# Used by probe.sh, diagnose.sh, verify.sh so the three never disagree on what PAFF is.
#
# The programmatic PAFF tell (no decode required): in field-coded H.264 each FIELD
# picture is its own coded picture / access unit, so the coded-picture rate runs
# ~2x the container's frame rate (e.g. ~60 AU/s on 29.97p content — the exact
# signature behind the corrupted-file post-mortem). Progressive and frame-coded
# interlaced (MBAFF) both sit at ~1x and are NOT the fragile case. field_order
# tt/bb corroborates and is reported, but the rate ratio is the decisive test
# (some captures/builds report field_order=unknown even when field-coded).
#
# Usage:
#   . "$(dirname "$0")/lib-paff.sh"
#   eval "$(pf_detect INPUT)"
#   # -> PF_CODEC PF_FIELD PF_CODED_RATE PF_NOMINAL_FPS PF_RATIO PF_PAFF
#   #    PF_FIELD_RATE PF_TIMESCALE   (PF_PAFF is yes|no)
#
# Every function is a read-only probe; none touch the source.

# evaluate an ffprobe rate fraction ("60000/1001") to a decimal; "0" if unusable
pf_eval_fps () {
  awk "BEGIN{n=split(\"${1:-0}\",a,\"/\"); if(n<2||a[2]+0==0) printf \"%.4f\",a[1]+0; else printf \"%.4f\",a[1]/a[2]}"
}

# coded-picture rate over a bounded packet window (demux only, NO decode).
# min/max timestamp span is robust to B-frame reordering; dts fills in for N/A pts.
pf_coded_rate () {
  ffprobe -v error -select_streams v:0 -read_intervals "%+#240" \
    -show_entries packet=pts_time,dts_time -of csv=p=0 "$1" 2>/dev/null | \
  awk -F, '{t=$1; if(t=="N/A"||t==""){t=$2}; if(t=="N/A"||t=="")next;
            if(!seen){mn=mx=t;seen=1} else {if(t<mn)mn=t; if(t>mx)mx=t}; n++}
           END{span=mx-mn; if(seen && span>0 && n>1) printf "%.4f",(n-1)/span; else print "0"}'
}

# map a measured field/coded rate to a clean rebuild-paff FIELD_RATE + TIMESCALE.
# 58-62 defaults to 60000/1001 (NTSC PAFF is far more common than true 60).
pf_suggest_field_rate () {
  awk "BEGIN{r=${1:-0}+0;
    if(r>58&&r<62) print \"60000/1001 60000\";
    else if(r>=49&&r<=51) print \"50 50000\";
    else if(r>=29&&r<31.5) print \"30000/1001 30000\";
    else if(r>=24.5&&r<28) print \"25 25000\";
    else if(r>=23&&r<24.5) print \"24000/1001 24000\";
    else print \"unknown unknown\"}"
}

# one probe pass -> KEY=VAL lines for eval. Decision logic lives ONLY here.
pf_detect () {
  IN="$1"
  pf_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  pf_field=$(ffprobe -v error -select_streams v:0 -show_entries stream=field_order -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  pf_af=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  pf_rf=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  pf_cr=$(pf_coded_rate "$IN")
  pf_nf=$(pf_eval_fps "${pf_af:-0}")
  awk "BEGIN{exit !(${pf_nf:-0}>0)}" || pf_nf=$(pf_eval_fps "${pf_rf:-0}")
  pf_ratio=$(awk "BEGIN{if(${pf_nf:-0}>0)printf \"%.3f\",${pf_cr:-0}/$pf_nf; else print 0}")
  pf_paff=no; pf_fr=unknown; pf_ts=unknown
  if [ "$pf_codec" = h264 ] && awk "BEGIN{exit !(${pf_ratio:-0}>=1.7 && ${pf_ratio:-0}<=2.3)}"; then
    pf_paff=yes
    pf_sg=$(pf_suggest_field_rate "$pf_cr"); pf_fr=${pf_sg%% *}; pf_ts=${pf_sg##* }
  fi
  printf 'PF_CODEC=%s\nPF_FIELD=%s\nPF_CODED_RATE=%s\nPF_NOMINAL_FPS=%s\nPF_RATIO=%s\nPF_PAFF=%s\nPF_FIELD_RATE=%s\nPF_TIMESCALE=%s\n' \
    "${pf_codec:-na}" "${pf_field:-na}" "${pf_cr:-0}" "${pf_nf:-0}" "${pf_ratio:-0}" "$pf_paff" "$pf_fr" "$pf_ts"
}

# disc_scan — forward-timestamp-gap (discontinuity) scan of the video track.
# A discontinuity is a FORWARD DTS jump larger than a frame: the capture dropped
# frames and the broadcast clock skipped ahead. Stream-copy preserves these jumps
# in the video timeline but COLLAPSES them in raw PCM audio (MOV/MP4 PCM is a
# contiguous sample array with no gap/edit mechanism), so a blind `-c copy` of a
# discontinuous source slides the audio progressively out of sync (see the
# remux-sync post-mortem). This is distinct from MISSING or BACKWARD timestamps:
# the timestamps here are present AND monotonic, so the mux tests pass — the gap
# is forward, and only a delta scan finds it. NO decode; whole stream (a gap can
# sit anywhere in a long capture, so this is deliberately not window-bounded).
#
# Usage:  eval "$(disc_scan INPUT)"
#   -> DISC_COUNT (forward gaps) DISC_MISSING (s of dropped time) DISC_FIRST (s|na)
#      DISC_FRAMEDUR (s)
# Tunables: DISC_MULT (gap threshold in frame durations, default 1.5).
# Test hook: DISC_DTS_FILE=<file of dts_time values> bypasses ffprobe;
#            DISC_FRAMEDUR_IN=<s> supplies the frame duration for that injected list.
disc_scan () {
  local IN="${1:-}" mult="${DISC_MULT:-1.5}" dts fdur rf
  if [ -n "${DISC_DTS_FILE:-}" ]; then
    dts=$(cat "$DISC_DTS_FILE"); fdur="${DISC_FRAMEDUR_IN:-0}"
  else
    rf=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
    fdur=$(pf_eval_fps "${rf:-0}")
    fdur=$(awk "BEGIN{f=${fdur:-0}+0; if(f>0) printf \"%.6f\",1/f; else print 0}")
    dts=$(ffprobe -v error -select_streams v:0 -show_entries packet=dts_time -of csv=p=0 "$IN" 2>/dev/null)
  fi
  printf '%s\n' "$dts" | awk -v fdur="${fdur:-0}" -v mult="$mult" '
    $1!="N/A" && $1!="" { t=$1+0
      if(seen){ d=t-p; if(d>0){ nd++; dl[nd]=d; pos[nd]=p; sd+=d } }
      p=t; seen=1 }
    END{
      if(nd<1){ print "DISC_COUNT=0\nDISC_MISSING=0.000\nDISC_FIRST=na"; printf "DISC_FRAMEDUR=%.6f\n", fdur+0; exit }
      fd=fdur+0; if(fd<=0) fd=sd/nd            # no fps -> mean delta is an excellent CFR proxy
      thr=mult*fd; cnt=0; miss=0; first="na"
      for(i=1;i<=nd;i++) if(dl[i]>thr){ cnt++; miss+=dl[i]-fd; if(first=="na") first=sprintf("%.3f",pos[i]) }
      printf "DISC_COUNT=%d\nDISC_MISSING=%.3f\nDISC_FIRST=%s\nDISC_FRAMEDUR=%.6f\n", cnt, miss, first, fd
    }'
}
