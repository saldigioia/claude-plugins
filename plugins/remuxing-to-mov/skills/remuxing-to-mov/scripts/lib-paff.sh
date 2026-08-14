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
# COUNT EVERY PACKET, not just timestamped ones (post-mortem 2026-07-25): real
# broadcast PAFF often carries PES timestamps only on the FIRST field of each
# pair — the second field of every pair has no PTS and no DTS at all. A rate
# computed from timestamped packets alone reads ~1x on exactly those captures
# and reports paff=no: the false negative that routed a broken timeline to the
# wrong repair rung. So the numerator counts ALL packets in the window; only the
# time SPAN comes from the timestamped ones. The untimestamped fraction itself
# is exported (PF_NOPTS_FRAC / PF_HALF_TS) — ~50% missing IS the pair signature.
#
# Usage:
#   . "$(dirname "$0")/lib-paff.sh"
#   eval "$(pf_detect INPUT)"
#   # -> PF_CODEC PF_FIELD PF_CODED_RATE PF_NOMINAL_FPS PF_RATIO PF_PAFF
#   #    PF_FIELD_RATE PF_TIMESCALE PF_NOPTS PF_NOPTS_FRAC PF_HALF_TS
#   #    (PF_PAFF / PF_HALF_TS are yes|no)
#
# Every function is a read-only probe; none touch the source.

# every probe here opens broadcast inputs -> the raised probe window applies
# (ffp wrapper + FF_INPUT_OPTS; see lib-probe.sh for the misprobe post-mortem)
PF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$PF_LIB_DIR/lib-probe.sh"

# evaluate an ffprobe rate fraction ("60000/1001") to a decimal; "0" if unusable
pf_eval_fps () {
  awk "BEGIN{n=split(\"${1:-0}\",a,\"/\"); if(n<2||a[2]+0==0) printf \"%.4f\",a[1]+0; else printf \"%.4f\",a[1]/a[2]}"
}

# coded-picture rate over a bounded packet window (demux only, NO decode).
# min/max timestamp span is robust to B-frame reordering; dts fills in for N/A pts.
# EVERY packet counts toward the rate — untimestamped ones included (they are still
# coded pictures); only the span comes from timestamped packets. Skipping the
# untimestamped ones halves the measured rate on pair-timestamped PAFF captures
# and produces the paff=no false negative (post-mortem 2026-07-25).
# Emits: "RATE TOTAL_PKTS UNTIMESTAMPED_PKTS".
# Test hook: PF_PKT_FILE=<csv of pts_time,dts_time lines> bypasses ffprobe.
pf_coded_rate () {
  { if [ -n "${PF_PKT_FILE:-}" ]; then cat "$PF_PKT_FILE"; else
      ffp -v error -select_streams v:0 -read_intervals "%+#240" \
        -show_entries packet=pts_time,dts_time -of csv=p=0 "$1" 2>/dev/null; fi; } | \
  awk -F, 'NF{t=$1; if(t=="N/A"||t==""){t=$2}; n++;
            if(t=="N/A"||t==""){miss++; next}
            if(!seen){mn=mx=t;seen=1} else {if(t<mn)mn=t; if(t>mx)mx=t}}
           END{span=mx-mn; if(seen && span>0 && n>1) printf "%.4f %d %d",(n-1)/span,n,miss+0;
               else printf "0 %d %d",n+0,miss+0}'
}

# reorder profile over a bounded head window (demux only, NO decode): does the
# stream carry a presentation-reorder pyramid (B-frames / B-fields)? Measured
# from packets where BOTH pts and dts are present: pts!=dts occurrences, backward
# pts steps, and the max pts-dts offset in stream ticks. Decides which repair is
# legitimate: a constant-rate restamp (rebuild-paff.sh) sets PTS=DTS and plays a
# reordered stream in DECODE order — motion shuffled, a different way of being
# broken (post-mortem 2026-07-25). Reordered streams need their real PTS kept
# (pairfill-paff.sh) instead.
# Test hook: PF_PKT_TICKS_FILE=<csv of pts,dts integer-tick lines> bypasses ffprobe.
pf_reorder_scan () {
  { if [ -n "${PF_PKT_TICKS_FILE:-}" ]; then cat "$PF_PKT_TICKS_FILE"; else
      ffp -v error -select_streams v:0 -read_intervals "%+#3000" \
        -show_entries packet=pts,dts -of csv=p=0 "$1" 2>/dev/null; fi; } | \
  awk -F, 'NF{
      p=$1; d=$2; tot++
      if(p!="N/A" && p!=""){ if(havep && p+0<pp) back++; pp=p+0; havep=1 }
      if(p=="N/A"||p==""||d=="N/A"||d=="") next
      both++; off=p-d; if(off!=0) ne++; if(off>mx) mx=off
    }
    END{
      r="no"; if(ne>0 || back>0) r="yes"
      printf "PF_REORDER=%s\nPF_PTSNEDTS=%d\nPF_BACKPTS=%d\nPF_MAXOFF_TICKS=%d\nPF_TS_BOTH=%d\n", r, ne+0, back+0, mx+0, both+0
    }'
}

# mux_confessions LOGFILE — count the muxer's own admissions that it INVENTED
# timing: "pts has no value", "Timestamps are unset in a packet", non-monotonic
# DTS nudges. Any nonzero count on a MOV mux is a HARD STOP: the video bits may
# be perfect while the written timeline is garbage (post-mortem 2026-07-25 —
# these lines were treated as cosmetic and the shipped files were unwatchable).
mux_confessions () {
  [ -f "${1:-}" ] || { echo 0; return; }
  grep -ciE 'pts has no value|timestamps are unset|non-?monotonic dts' "$1" || true
}

# --- probe-shaped mux failure -> ONE honest retry at a 1G window (WO 1.2) ----
# Some source will exceed ANY fixed window — the raised 200M default included,
# and the operator may have LOWERED it via RTM_PROBESIZE. When avformat opens an
# input without ever learning a stream's parameters, the mux fails with one of
# exactly two probe-shaped tells: "dimensions not set" (the MOV muxer refusing
# to write a header for a video stream whose size it never saw) or "Could not
# find codec parameters". That class is a WINDOW problem, not a source defect,
# so the mux paths (remux.sh, dual-track.sh, pairfill-paff.sh) retry exactly
# once at 1G on both axes — announcing it first — instead of hard-failing with
# no self-help. Any OTHER failure is never retried (a retry must not mask a
# genuinely different error), and a second miss keeps the exit-code contract
# (1 FAIL). One retry, no loops; the output gates downstream of the mux are
# untouched — a retry only widens how much of the source is READ during
# probing, never what is written or blessed.
FF_RETRY_OPTS=(-probesize 1G -analyzeduration 1G)

# probe_shaped_failure LOGFILE — 0 iff the mux log carries the probe-window tell.
probe_shaped_failure () {
  [ -f "${1:-}" ] || return 1
  grep -qiE 'dimensions not set|could not find codec parameters' "$1"
}

# probe_retry_notice — the single honest line announcing the retry (printed at
# most once per mux; asserted verbatim by tests/regression.d/12-probe-retry.sh).
probe_retry_notice () {
  echo "** probe window exhausted at default; retrying with 1G — consider RTM_PROBESIZE"
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
# WO 1.2: when the input's video PARAMETERS are invisible at the current window
# (the probe-undershoot class), stdout also carries one deliberate
# FF_INPUT_OPTS=(...) array line so the eval'ing caller's own later opens ride
# the widened window too — see the comment at the check below.
pf_detect () {
  IN="$1"
  pf_codec=$(ffp -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  # --- probe-layer self-heal (WO 1.2): a video stream the container NAMES
  # (codec_name from the PMT/header) whose PARAMETERS never resolved (width
  # unreadable) is precisely the window-undershoot class from the lib-probe.sh
  # post-mortem — and it does not just threaten the mux: every parameter-needing
  # read downstream of this detect is equally blind (verify.sh's VCL lossless
  # arbiter hashed an EMPTY source at an undersized window and called it a
  # MISMATCH). So widen to the same 1G the mux retry uses — for the rest of THIS
  # probe pass, and, because every caller evals our stdout, for the CALLER's
  # process as well via the emitted array line (mov.sh's PR|PF whitelist drops
  # it by design; it keeps its own window). Read-only: a wider window changes
  # how much of the source is READ during probing, never what is written. The
  # note goes to stderr — stdout must stay eval-safe.
  pf_w=$(ffp -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  if [ -n "$pf_codec" ]; then
    case "${pf_w:-}" in ''|0|N/A)
      echo "   note: $pf_codec stream parameters invisible at the current probe window — re-probing wide (1G); consider RTM_PROBESIZE" >&2
      FF_INPUT_OPTS=("${FF_RETRY_OPTS[@]}")
      printf 'FF_INPUT_OPTS=(%s)\n' "${FF_RETRY_OPTS[*]}"
      ;;
    esac
  fi
  pf_field=$(ffp -v error -select_streams v:0 -show_entries stream=field_order -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  pf_af=$(ffp -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  pf_rf=$(ffp -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
  # shellcheck disable=SC2046  # word splitting is the point: "RATE TOTAL MISSING"
  set -- $(pf_coded_rate "$IN"); pf_cr="${1:-0}"; pf_tot="${2:-0}"; pf_miss="${3:-0}"
  pf_nf=$(pf_eval_fps "${pf_af:-0}")
  awk "BEGIN{exit !(${pf_nf:-0}>0)}" || pf_nf=$(pf_eval_fps "${pf_rf:-0}")
  pf_ratio=$(awk "BEGIN{if(${pf_nf:-0}>0)printf \"%.3f\",${pf_cr:-0}/$pf_nf; else print 0}")
  pf_frac=$(awk "BEGIN{if(${pf_tot:-0}>0)printf \"%.3f\",${pf_miss:-0}/$pf_tot; else print \"0.000\"}")
  # ~half the packets untimestamped = the PAFF pair signature (first field of each
  # pair timestamped, its mate not) — the class the timestamped-only rate misread.
  pf_half=no; awk "BEGIN{exit !(${pf_frac:-0}>=0.35 && ${pf_frac:-0}<=0.65)}" && pf_half=yes
  pf_paff=no; pf_fr=unknown; pf_ts=unknown
  if [ "$pf_codec" = h264 ] && awk "BEGIN{exit !(${pf_ratio:-0}>=1.7 && ${pf_ratio:-0}<=2.3)}"; then
    pf_paff=yes
    pf_sg=$(pf_suggest_field_rate "$pf_cr"); pf_fr=${pf_sg%% *}; pf_ts=${pf_sg##* }
  fi
  printf 'PF_CODEC=%s\nPF_FIELD=%s\nPF_CODED_RATE=%s\nPF_NOMINAL_FPS=%s\nPF_RATIO=%s\nPF_PAFF=%s\nPF_FIELD_RATE=%s\nPF_TIMESCALE=%s\nPF_NOPTS=%s\nPF_NOPTS_FRAC=%s\nPF_HALF_TS=%s\n' \
    "${pf_codec:-na}" "${pf_field:-na}" "${pf_cr:-0}" "${pf_nf:-0}" "${pf_ratio:-0}" "$pf_paff" "$pf_fr" "$pf_ts" "${pf_miss:-0}" "${pf_frac:-0}" "$pf_half"
}

# disc_scan — forward-timestamp-gap (discontinuity) scan of the video track.
# A discontinuity is a FORWARD DTS jump larger than a frame: the capture dropped
# frames and the broadcast clock skipped ahead. Stream-copy preserves these jumps
# in the video timeline but COLLAPSES them in raw PCM audio (ffmpeg's muxer
# writes no mid-stream empty edit per drop — QTFF has the mechanism, the writer
# doesn't use it), so a blind `-c copy` of a discontinuous source slides the
# audio progressively out of sync (see the remux-sync post-mortem). This is distinct from MISSING or BACKWARD timestamps:
# the timestamps here are present AND monotonic, so the mux tests pass — the gap
# is forward, and only a delta scan finds it. NO decode; whole stream (a gap can
# sit anywhere in a long capture, so this is deliberately not window-bounded).
#
# Usage:  eval "$(disc_scan INPUT)"
#   -> DISC_COUNT (forward gaps) DISC_MISSING (s of dropped time) DISC_FIRST (s|na)
#      DISC_FRAMEDUR (s) DISC_BACK (backward DTS steps) DISC_DUP (duplicate DTS)
# DISC_BACK/DISC_DUP are the WHOLE-FILE DTS-rot counters the backhaul gate needs:
# the windowed 5000-packet scan read 0 on the 2009 and 2012 feeds whose defects
# sat mid-file at splice points, and the decode-to-null nmono warnings come from
# exactly these demux-visible DTS relations — so one demux pass answers both the
# gap and the rot question without a decode.
# Tunables: DISC_MULT (gap threshold in frame durations, default 1.5).
# Test hook: DISC_DTS_FILE=<file of dts_time values> bypasses ffprobe;
#            DISC_FRAMEDUR_IN=<s> supplies the frame duration for that injected list.
disc_scan () {
  local IN="${1:-}" mult="${DISC_MULT:-1.5}" dts fdur rf
  if [ -n "${DISC_DTS_FILE:-}" ]; then
    dts=$(cat "$DISC_DTS_FILE"); fdur="${DISC_FRAMEDUR_IN:-0}"
  else
    rf=$(ffp -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
    fdur=$(pf_eval_fps "${rf:-0}")
    fdur=$(awk "BEGIN{f=${fdur:-0}+0; if(f>0) printf \"%.6f\",1/f; else print 0}")
    dts=$(ffp -v error -select_streams v:0 -show_entries packet=dts_time -of csv=p=0 "$IN" 2>/dev/null)
  fi
  printf '%s\n' "$dts" | awk -v fdur="${fdur:-0}" -v mult="$mult" '
    $1!="N/A" && $1!="" { t=$1+0
      if(seen){ d=t-p; if(d>0){ nd++; dl[nd]=d; pos[nd]=p; sd+=d } else if(d<0){ bk++ } else { du++ } }
      p=t; seen=1 }
    END{
      if(nd<1){ print "DISC_COUNT=0\nDISC_MISSING=0.000\nDISC_FIRST=na"; printf "DISC_FRAMEDUR=%.6f\nDISC_BACK=%d\nDISC_DUP=%d\n", fdur+0, bk+0, du+0; exit }
      fd=fdur+0; if(fd<=0) fd=sd/nd            # no fps -> mean delta is an excellent CFR proxy
      thr=mult*fd; cnt=0; miss=0; first="na"
      for(i=1;i<=nd;i++) if(dl[i]>thr){ cnt++; miss+=dl[i]-fd; if(first=="na") first=sprintf("%.3f",pos[i]) }
      printf "DISC_COUNT=%d\nDISC_MISSING=%.3f\nDISC_FIRST=%s\nDISC_FRAMEDUR=%.6f\nDISC_BACK=%d\nDISC_DUP=%d\n", cnt, miss, first, fd, bk+0, du+0
    }'
}

# --- WO 4.1: the 4:2:2 arm, demoted from refusal to empirical proof ----------
# The 1.8.0–1.10.0 gate refused mpeg2video/h264 + yuv422p outright (exit 11,
# nothing built), claiming "AVFoundation/QuickTime cannot decode 4:2:2".
# FALSIFIED on the bench 2026-08-13 (macOS 26.6.1, ffmpeg 8.1.2): every refused
# class fully decodes — qlmanage thumbnail AND avconvert whole-file (50/50
# frames) — MPEG-2 4:2:2, H.264 High 4:2:2, 10-bit 4:2:2, 10-bit 4:4:4, HEVC
# Rext 4:2:2. Worse, the exact 8-bit predicate [ pix = yuv422p ] let the
# ACTUAL 10-bit contribution profiles (yuv422p10le — the AVC-Intra class)
# bypass the gate entirely: over-broad and under-broad at once, and the cost
# of being wrong was the whole deliverable. The reform follows the plugin's
# own doctrine — prove, don't guess — and its own recorded fact that decode
# support DRIFTS by macOS version (C63: Tahoe 26.4 dropped MJPEG variants/
# AIC): a hardcoded codec verdict rots, a per-file post-build check
# self-corrects. Being wrong now costs an artifact plus an honest REVIEW,
# never "no artifact at all". Caveat carried from the bench: the falsifying
# clips were synthetic — they disprove the categorical "cannot decode", not
# every real broadcast master; that residual is exactly WHY the check is
# per-file (playability_verdict below, driven post-build by mov.sh/auto.sh).

# qt_contribution_profile PIX_FMT — 0 iff the pix_fmt is the 4:2:2
# contribution/backhaul class, ANY bit depth (yuv422p, yuv422p10le, ...).
# The single predicate mov.sh's front door and backhaul_gate both consult.
qt_contribution_profile () { case "${1:-}" in yuv422p*) return 0;; *) return 1;; esac; }

# contribution_advisory VCODEC PIX_FMT — the one announcement, shared by the
# mov.sh front door and backhaul_gate so the two can never diverge. The first
# line's phrase is pinned by tests/regression.d/41-422-empirical.sh.
contribution_advisory () {
  echo "** contribution profile ${1:-?}/${2:-?} — playability will be verified post-build"
  echo "   (the categorical 4:2:2 refusal was falsified on macOS 26.6.1, 2026-08-13;"
  echo "    decode support drifts by macOS version, so the driver PROVES this build"
  echo "    with playable-check.sh once it exists. On a standalone builder run,"
  echo "    prove it yourself: scripts/playable-check.sh OUT.mov)"
}

# playability_verdict OUTPUT.mov — the empirical half of the demoted gate: run
# playable-check.sh on a FINISHED build, print its output indented plus the
# additive machine line
#     MOV_PLAYABILITY os=<ver|na> verdict=<ok|fail|skip>
# and set PLAY_VERDICT for the caller's exit-code mapping (contribution-profile
# fail/skip -> 10 REVIEW at the driver; never 11, never 1 — the artifact exists
# and its essence verified). REUSES playable-check.sh (Ground Rule 6: the
# verdict self-dates the macOS it ran on) — never forks its logic. Returns 0
# always: the VERDICT is the result; the function itself must not trip set -e.
playability_verdict () {
  local out="${1:?playability_verdict needs OUTPUT}" prc=0 po osv
  po=$(bash "$PF_LIB_DIR/playable-check.sh" "$out" 2>&1) || prc=$?
  printf '%s\n' "$po" | sed 's/^/   /'
  osv=$(sw_vers -productVersion 2>/dev/null || echo na)
  case "$prc" in 0) PLAY_VERDICT=ok;; 3) PLAY_VERDICT=skip;; *) PLAY_VERDICT=fail;; esac
  echo "MOV_PLAYABILITY os=${osv:-na} verdict=$PLAY_VERDICT"   # machine-readable (additive, WO 4.1)
  return 0
}

# --- backhaul_gate — enforced at EVERY .mov entry point -----------------------
# backhaul_gate INPUT [VCODEC] [PIX_FMT] [CONTAINER]
# mov.sh runs the verbose front-door pass; this is the SAME verdict at the
# choke points that actually write a .mov (auto.sh, remux.sh, rebuild-paff.sh,
# pairfill-paff.sh), so no route — batch.sh and direct script calls included —
# can diverge from the criteria (the pre-gate 2017-feed build proved the
# bypass was real). Since WO 4.1/4.2 the gate refuses NOTHING — it announces:
#   * 4:2:2 contribution profile -> ADVISORY only (contribution_advisory);
#     the verdict is empirical and belongs AFTER the build. Nothing refuses
#     on pix_fmt anywhere anymore — the 1.10.0 "no side door" property
#     inverts for this arm: no side door REFUSES either.
#   * timeline rot (mpegts/mpeg2video gaps + non-monotonic DTS) -> WARNING
#     (WO 4.2, demoted from the 1.8.0-1.10.0 refusal): the old exit-11
#     claimed "no lossless MOV of this class survives verify" — a
#     PREDICTION, while the plugin already owns the measured judges: the
#     mux-confession hard stop (invented timing, KEPT — that one is
#     measured) and verify.sh's post-build timeline gates. On the
#     constructed rot fixture the prediction was wrong twice over (bench
#     2026-08-14): the demuxer's own discontinuity fixup muxed a monotonic
#     timeline (no confession fired), and verify caught the REAL defect
#     (dual-track access misalignment -> REVIEW) — an artifact plus
#     evidence instead of "no artifact at all". The warning keeps the
#     refusal's full voice: same three routes, same scan evidence, plus the
#     additive MOV_ROT_WARN machine line.
# Missing args are probed (instant single-field ffprobe; the rot scan only
# ever runs for mpegts/mpeg2video).
#
# Protocol: a caller that already passed the gate exports RTM_BACKHAUL_GATED=1
# so children skip the re-check; RTM_FORCE_BACKHAUL=1 (mov.sh --force-backhaul)
# skips the rot scan + warning (the build runs either way) — both are API and
# both are no-ops for the pix_fmt arm (there is no pix_fmt refusal to skip).
backhaul_gate_routes () {
  echo "   Honest routes out (the source stays TS/MKV — health-checked, never doomed):"
  echo "     keep     the source as-is — it is already the archival master; prove its"
  echo "              health: scripts/ts-health.sh SOURCE  (transport, timestamps, seek)"
  echo "     playback ffmpeg -i SOURCE -map 0:v:0 -map '0:a?' -c copy OUT.mkv  (lossless;"
  echo "              plays in IINA/VLC/mpv) — then scripts/ts-health.sh OUT.mkv to prove"
  echo "              the copy's timeline survived intact"
  echo "     rung4    scripts/rung4.sh — operator-attested re-encode, the ONLY sanctioned"
  echo "              path to a true QuickTime-native deliverable"
  echo "   Skip this scan+warning: mov.sh --force-backhaul (sets RTM_FORCE_BACKHAUL=1)"
}
# --- WO 5.2 unroutable codecs — shared classifiers + refusal voice ------------
# (moved here from mov.sh in the 1.11 fix round, 2026-08-14): the reviewer
# proved the gate-at-every-entry-point standard (1.10.0's own bar) was broken —
# a DIRECT auto.sh run burned rungs 0->2->3 and died in the raw muxer stack
# trace, remux.sh littered a 0-byte .part behind "vp9 only supported in MP4",
# and batch.sh recorded the class FAIL instead of REFUSED. One classifier +
# one refusal voice here; mov.sh, auto.sh and remux.sh all dispatch on it, so
# no entry point can diverge again. The regression suite unit-pins the
# classifiers through mov.sh's RTM_TEST sourcing guard (mov.sh sources this
# lib before the guard).
#
# unroutable_v: video codecs NO .mov can carry — the mux itself is impossible,
# so no lossless MOV of the class exists and the gate refuses with the routes
# instead of letting the muxer die raw (WO 5.2). VC-1 has no MOV sample entry
# (raw form: "Could not find tag for codec vc1"); VP9/AV1 the MOV muxer
# rejects outright (raw form: "vp9 only supported in MP4" — bench-verified
# ffmpeg 9.0.1, 2026-08-14; MP4 takes both -c copy). Distinct from the
# PR_VNATIVE=no class (ffv1 etc.): those MUX and get the WO 4.1 post-build
# playability proof — these never reach a mux at all.
unroutable_v () { case "$1" in vc1|vp9|av1) return 0;; *) return 1;; esac; }
# unroutable_a: audio whose "PCM treatment" is garbage, not a render — Dolby E
# is a broadcast mezzanine (up to 8 programs per AES3 pair); decoding it is a
# program/channel-assignment EDITORIAL decision, so the specialist decode is a
# named, operator-invoked step, never automatic (WO 5.2). Note the limit: this
# matches the codec-tagged form (codec_name dolby_e) only — Dolby E hiding
# inside a PCM track (SMPTE 337M / AES3 wrapping) is NOT sniffed (payload
# sync-word inspection is the deep-inspection rabbit hole); that named
# limitation is documented in SKILL.md troubleshooting.
unroutable_a () { case "$1" in dolby_e) return 0;; *) return 1;; esac; }

# unroutable_v_refuse CODEC — the one honest refusal, REFUSED-class outcome:
# the caller prints nothing else and exits 11. Nothing written, source
# untouched — because unlike every other gate the failure is not a playability
# question the post-build proof can answer: the MOV cannot exist.
unroutable_v_refuse () {
  case "$1" in
    vc1)
      echo "** REFUSED: VC-1 video (the Blu-ray/HD-DVD codec) cannot be carried in a"
      echo "   .mov — the MOV muxer has no VC-1 sample entry, so a lossless MOV of this"
      echo "   source does not exist. Nothing was built; the source is untouched." ;;
    *)
      echo "** REFUSED: $1 video cannot be muxed into a .mov — the MOV muxer"
      echo "   rejects it (MP4-only carriage; bench-verified ffmpeg 9.0.1, 2026-08-14),"
      echo "   so a lossless MOV of this source does not exist. Nothing was built; the"
      echo "   source is untouched." ;;
  esac
  echo "   Honest routes out:"
  echo "     keep   the source as-is — it is already the archival master"
  echo "     remux  lossless container change for playback (no re-encode):"
  echo "            VP9/AV1: ffmpeg -i IN -c copy OUT.mp4;  VC-1: ffmpeg -i IN -c copy"
  echo "            OUT.mkv  (plays in IINA/VLC/mpv either way)"
  echo "     rung4  scripts/rung4.sh — operator-attested re-encode, the ONLY sanctioned"
  echo "            path to a QuickTime-native .mov of this class"
  echo "MOV_REFUSED profile=unroutable-vcodec vcodec=$1"   # machine-readable (additive, WO 5.2)
}

# unroutable_a_refuse ORD — the Dolby E refusal; caller exits 11. The exclude
# route names the flag-bearing entry points (mov.sh/remux.sh --audio-keep);
# auto.sh has no keep flag, so its route out IS one of those two.
unroutable_a_refuse () {
  echo "** REFUSED: audio track a:$1 is Dolby E — a broadcast mezzanine carrying"
  echo "   up to 8 programs in one AES3 pair. MOV cannot carry the bitstream, and"
  echo "   treating it as PCM yields FULL-SCALE NOISE, not audio. Which program and"
  echo "   channel assignment to extract is an editorial decision, so the decode is a"
  echo "   named, operator-invoked step — never automatic. Nothing was built."
  echo "   Honest routes out:"
  echo "     decode   specialist decode via ffmpeg's dolby_e decoder (operator-invoked):"
  echo "              ffmpeg -i IN -map 0:a:$1 -c:a pcm_s24le program.wav"
  echo "              (first program by default) — then marry the WAV back in post,"
  echo "              or rerun mov.sh on a source carrying the decoded track"
  echo "     exclude  rerun with --audio-keep IDX[,IDX] (mov.sh / remux.sh) listing"
  echo "              only the non-Dolby-E track ordinals (the drop is announced,"
  echo "              never silent)"
  echo "     keep     the source as-is — it is already the archival master"
  echo "MOV_REFUSED profile=dolby-e-audio track=a:$1"   # machine-readable (additive, WO 5.2)
}

backhaul_gate () {
  local in="${1:?backhaul_gate needs INPUT}" vc="${2:-}" pix="${3:-}" cont="${4:-}"
  [ "${RTM_BACKHAUL_GATED:-0}" = 1 ] && return 0
  [ "${RTM_FORCE_BACKHAUL:-0}" = 1 ] && return 0
  if [ -z "$vc" ]; then
    vc=$(ffp -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$in" 2>/dev/null | head -1)
  fi
  if [ -z "$pix" ]; then
    pix=$(ffp -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$in" 2>/dev/null | head -1)
  fi
  # 4:2:2 arm (WO 4.1): advisory only — matches yuv422p* at every bit depth
  # (the old exact 8-bit match let yuv422p10le sources slip through unannounced).
  # The playability verdict is empirical and runs post-build in the drivers.
  if qt_contribution_profile "$pix"; then
    contribution_advisory "$vc" "$pix"
  fi
  if [ "$vc" = mpeg2video ]; then
    if [ -z "$cont" ]; then
      cont=$(ffp -v error -show_entries format=format_name -of default=nw=1:nk=1 "$in" 2>/dev/null | head -1)
    fi
    case "$cont" in *mpegts*)
      eval "$(disc_scan "$in")"
      if [ "${DISC_COUNT:-0}" -ge 1 ] && [ $(( ${DISC_BACK:-0} + ${DISC_DUP:-0} )) -ge 1 ]; then
        # WO 4.2: warn, don't refuse — the demoted gate keeps its voice (same
        # three routes) but the verdict belongs to the build's own measured
        # gates: mux-confession hard stop + verify. Never MOV_REFUSED here —
        # nothing may print a refusal and then build anyway.
        echo "** WARN: BACKHAUL TIMELINE ROT — ${DISC_COUNT} forward gap(s) PLUS non-monotonic"
        echo "   DTS (whole-file: backward=${DISC_BACK:-0} duplicate=${DISC_DUP:-0}). Building anyway (WO 4.2):"
        echo "   the mux-confession gate hard-stops if the muxer invents timing, and verify"
        echo "   judges the finished timeline with evidence — expect REVIEW/FAIL on this"
        echo "   class. Full read: scripts/diagnose.sh SOURCE."
        backhaul_gate_routes
        echo "MOV_ROT_WARN profile=timeline-rot vcodec=$vc disc=${DISC_COUNT:-0} back=${DISC_BACK:-0} dup=${DISC_DUP:-0}"   # machine-readable (additive, WO 4.2)
      fi
      ;;
    esac
  fi
  return 0
}
