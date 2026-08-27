#!/usr/bin/env bash
# verify.sh — prove a remux was lossless and the output timeline is clean,
# at the lowest cost that is actually conclusive.
# Usage: scripts/verify.sh SOURCE OUTPUT [--full] [--signaling] [--audio] [--silence]
#
# Default tier (NO full decode — I/O-bound, runs at many× realtime):
#   (a) packet-hash identity: -c copy -f streamhash on both files (demux only,
#       zero decode). A match PROVES the copied bitstream is identical — done.
#       A mismatch is INCONCLUSIVE, not a failure: TS sources get SPS/PPS
#       re-placed and Rung-3 rebuilds repacketize, so identical video can hash
#       differently at the packet level. Fall through to (b).
#   (b) lossless essence check (demux only):
#       - H.264: VCL-payload hash with SPS/PPS/AUD/SEI stripped — placement- and
#         re-timing-invariant, so it survives TS->MOV and field-rate rebuilds.
#         REPLACES decoded framemd5 for H.264, which FALSE-FAILs field-coded
#         (PAFF) streams (field-vs-frame packaging) and any rebuild.
#       - other codecs: framemd5 of the first 300 frames (hash column only) +
#         packet-count parity. Catches wrong-stream, corruption-at-head, truncation.
#       - degraded env (no filter_units/h264_mp4toannexb): non-field-coded H.264
#         falls back to framemd5; field-coded -> REVIEW, never a false FAIL.
#         scripts/doctor.sh reports whether the VCL path is available.
#   (c) decode spot-checks of the OUTPUT at middle + tail (10 s windows).
#   (d) whole-file output TIMELINE integrity (demux only): 0 N/A PTS/DTS, DTS
#       strictly monotonic, sane sample-duration histogram. Catches a
#       muxer-invented timeline (half-timestamped PAFF straight-copied) that the
#       essence checks are blind to — the shipped-broken-file class.
#   (e) SCRUB GATE: accurate seeks (-ss AFTER -i) to deliberately off-keyframe
#       targets + keyframe-spacing / single-GOP sanity. Reproduces a GUI scrub
#       (which a keyframe-snap -ss-before-i seek does not), so a glitchy PAFF
#       timeline FAILs here — before the source is deleted.
#   (g) AUDIO-PLAYABILITY GATE (WO 3.6): every OUTPUT audio track must carry a
#       QTFF sample-entry tag on a positive allowlist (the tags this plugin's
#       own routes can legitimately write, each minted and probed on this
#       bench 2026-08-14) AND head-decode with zero errors. Catches the
#       dead-HDMV-track class (entry 1, 18.5 GB Blu-ray, 2026-08-13:
#       pcm_bluray copy-muxed into a [128][0][0][0] sample entry NO decoder
#       claims — a "verified" deliverable with unplayable audio). Non-QTFF
#       outputs (an MKV cross-check) have no sample entries: decode half only.
#
# --full adds a whole-file decoded check: an order/count-tolerant multiset for
# H.264 (corroboration only — a positional compare false-fails field-coded), or
# a bit-exact rawvideo md5 for other codecs. Reserve it for archival sign-off,
# or to settle a REVIEW verdict from the default tier.
#
# Optional preservation checks (off by default; they don't affect the lossless
# verdict unless they find real loss):
#   --signaling : color/HDR tags + HEVC hvc1 + HDR side data + closed-caption
#                 presence, source vs output. Drift -> REVIEW.
#   --audio     : dual-track fidelity — the preserved original track must be
#                 bit-exact vs source (else FAIL) and the PCM access track must
#                 equal the decoded original, aligned (else REVIEW).
#   --silence   : silence content-parity for RE-TIMED audio (the resync path).
#                 Duration parity cannot see injected silence — the 2008 backhaul
#                 build shipped ~17 min of inserted silence (a filter-graph
#                 rebuild on a mid-stream layout change re-padded from t=0) with
#                 durations matching. This gate compares long-window silence
#                 (>= RTM_SIL_MIN s at RTM_SIL_DB, defaults 5s / -50dB) source vs
#                 output; output silence beyond the source total + the source's
#                 legitimate gap-fill budget (disc_scan DISC_P_MISSING, the
#                 presentation-order census — P1.4) + RTM_SIL_TOL
#                 FAILs the file. Costs a full audio decode of both files —
#                 opt-in, wired into resync.sh. Never waivable (content gate).
#
# Waiver sidecar (QTFF audit 5-4c): a FAIL from the count-signature gates
# (d)/(e) whose named independent proofs all pass can be covered by an
# operator-attested OUTPUT.waiver.json (written by scripts/waiver.sh). On an
# EXACT signature + file match this exits 0 with a loud WAIVED(<gate>) line and
# a machine-readable VERIFY_SUMMARY field; ANY drift voids the waiver (FAIL
# stands). Essence/identity failures ((b)/--full/--audio) are never waivable.
#
# Exit (ACCEPTED LEGACY — the printed verdict is the API, byte-identical since
# 1.10.0): ">> OK" and ">> REVIEW" BOTH exit 0 — this script NEVER emits the
# house code 10 itself; ">> FAIL" exits 1; usage/env exits 2; an exact-match
# waiver exits 0 with the WAIVED line. Callers MUST map the text verdict to
# the house contract (mov.sh/auto.sh/resync.sh/qt-groups.sh all map
# ">> REVIEW" -> their own exit 10). Coding a caller to this script's exit
# code alone reads REVIEW as green — the qt-groups.sh defect the 1.11 fix
# round repaired; the contract is documented here so the next in-repo caller
# cannot be misled again (references/verification-safety.md carries the same
# statement).
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
SRC="${1:?usage: verify.sh SOURCE OUTPUT [--full] [--signaling] [--audio] [--silence]}"; OUT="${2:?need OUTPUT}"; shift 2
FULL=0; SIG=0; AUD=0; SILP=0
while [ $# -gt 0 ]; do case "$1" in
  --full) FULL=1; shift;;
  --signaling) SIG=1; shift;;          # color/HDR/caption preservation (source vs output)
  --audio) AUD=1; shift;;              # dual-track audio fidelity (PCM access + original)
  --silence) SILP=1; shift;;           # silence content-parity (re-timed audio / resync path)
  "") shift;;                          # tolerate an empty arg from `verify.sh A B $FULL`
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
for f in "$SRC" "$OUT"; do [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }; done
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-paff.sh"
. "$SELF_DIR/lib-attest.sh"
eval "$(pf_detect "$SRC")"            # PF_CODEC / PF_PAFF describe the SOURCE
SRC_IS_H264=0; [ "$PF_CODEC" = h264 ] && SRC_IS_H264=1
# The H.264 VCL lossless arbiter needs filter_units + h264_mp4toannexb. On an
# ffmpeg that lacks them, DON'T false-FAIL — degrade (see step b). Herestring
# match avoids a pipefail SIGPIPE false-negative. RTM_FORCE_NO_VCL=1 forces the
# degraded path for testing. (scripts/doctor.sh reports this capability.)
BSFS_AVAIL=$(ffmpeg -hide_banner -bsfs 2>/dev/null || true)
HAVE_VCL=0
{ grep -qw filter_units <<<"$BSFS_AVAIL" && grep -qw h264_mp4toannexb <<<"$BSFS_AVAIL"; } && HAVE_VCL=1
[ "${RTM_FORCE_NO_VCL:-0}" = 1 ] && HAVE_VCL=0

N=300            # frames in the decoded head sample (~10-12 s of video)
WIN=10           # seconds per output decode spot-check window
verdict=PASS     # PASS | REVIEW | FAIL — only ever downgraded
note=""
# QTFF audit 5-4c (waiver sidecar): a FAIL from the COUNT-signature gates (d)/(e)
# can be covered by an operator-attested OUTPUT.waiver.json whose recorded
# signature matches this run EXACTLY — one file, one signature, never a class.
# Essence/identity failures ((b), --full, --audio) are never waivable: there the
# failing gate IS the lossless proof, so "independent proofs pass" cannot hold.
d_failed=0; e_failed=0; other_failed=0

echo "== verify: $OUT vs $SRC =="

echo "-- (a) packet-hash identity (demux only, no decode) --"
phash () { ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$1" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null || true; }
# VCL-payload hash: strip SPS(7)/PPS(8)/AUD(9)/SEI(6) so parameter-set placement
# (TS in-band vs MOV avcC) and a Rung-3 repacketization cannot false-mismatch.
# What remains is the coded picture data — the correct lossless arbiter for H.264,
# and the reason decoded framemd5 is NOT used here: it FALSE-FAILs field-coded
# (PAFF) streams (field-vs-frame packaging) and any re-timed rebuild.
vcl_hash () { local b=""; \
  [ "$(ffp -v error -select_streams v:0 -show_entries stream=is_avc -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1)" = true ] && b="h264_mp4toannexb,"; \
  ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$1" -map 0:v:0 -c:v copy -bsf:v "${b}filter_units=remove_types=6|7|8|9" -f streamhash -hash md5 - 2>/dev/null || true; }
sp=$(phash "$SRC"); op=$(phash "$OUT")
if [ -n "$sp" ] && [ "$sp" = "$op" ]; then
  echo "   PASS: video packets bit-identical — lossless proven, no decode needed."
  bitproven=1
else
  echo "   inconclusive (expected for TS sources / Rung-3 rebuilds: packets get"
  echo "   re-framed even when the video is identical) — checking the essence."
  bitproven=0
fi

if [ "$bitproven" -eq 0 ]; then
  if [ "$SRC_IS_H264" -eq 1 ] && [ "$HAVE_VCL" -eq 1 ]; then
    echo "-- (b) VCL-payload identity (demux only; lossless arbiter for H.264) --"
    sv=$(vcl_hash "$SRC"); ov=$(vcl_hash "$OUT")
    if [ -n "$sv" ] && [ "$sv" = "$ov" ]; then
      echo "   VCL MATCH: coded picture data bit-identical — lossless proven"
      echo "   (survives TS->MOV and field-rate rebuilds; framemd5 would false-FAIL here)."
      bitproven=1
    else
      echo "   VCL MISMATCH — slice data differs; output is NOT a lossless copy."
      echo "     src=$sv"
      echo "     out=$ov"
      verdict=FAIL; other_failed=1
    fi
  elif [ "$SRC_IS_H264" -eq 1 ] && [ "$PF_PAFF" = yes ]; then
    # Degraded env (no filter_units) + field-coded: VCL is unavailable and decoded
    # framemd5 FALSE-FAILs PAFF — so we must NOT FAIL. Flag for a definitive check.
    echo "-- (b) lossless essence: VCL hash unavailable for a field-coded source --"
    echo "   filter_units/h264_mp4toannexb missing in this ffmpeg, and decoded"
    echo "   framemd5 false-FAILs field-coded streams — cannot cheaply prove lossless."
    [ "$verdict" = FAIL ] || verdict=REVIEW
    note="${note:+$note }VCL check unavailable (upgrade ffmpeg, or run --full); field-coded source can't be cheaply proven lossless."
  else
    echo "-- (b) decoded spot-identity: first $N frames + packet-count parity --"
    fhead () { ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$1" -map 0:v:0 -frames:v "$N" -f framemd5 - 2>/dev/null \
                 | grep -v '^#' | awk -F', *' '{print $NF}' || true; }
    sh=$(fhead "$SRC"); oh=$(fhead "$OUT")
    if [ -n "$sh" ] && [ "$sh" = "$oh" ]; then
      echo "   head sample: MATCH ($N decoded frames identical)"
    else
      echo "   head sample: FAIL — decoded frames differ; output is NOT a lossless copy."
      verdict=FAIL; other_failed=1
    fi
    # TS sources list the stream under its program AND top-level -> dedupe to one line
    pkts () { ffp -v error -select_streams v:0 -count_packets \
                -show_entries stream=nb_read_packets -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1; }
    spk=$(pkts "$SRC"); opk=$(pkts "$OUT")
    echo "   video packets: source=$spk output=$opk"
    if [ "$spk" != "$opk" ] && [ "$verdict" = PASS ]; then
      verdict=REVIEW
      note="packet counts differ — fine after a Rung-3 rebuild (repacketization), otherwise possible truncation. Settle with --full."
    fi
  fi
fi

echo "-- (c) output decode spot-checks (${WIN}s windows) --"
dur=$(ffp -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" 2>/dev/null) || dur=0
case "$dur" in ''|N/A) dur=0;; esac
# Decode the output and count ffmpeg error-level lines. A REAL decode error
# (bitstream corruption) is deterministic and recurs on every pass; a stray line
# emitted under heavy host load is not. So `confirm` re-decodes a nonzero result
# (up to twice more) and keeps the MINIMUM — this drops load-induced false
# positives without ever masking a reproducible error (which stays nonzero).
decode_win () {  # $1 file; $2 optional start time; empty -> whole file
  if [ -n "${2:-}" ]; then
    ffmpeg -nostdin -v error -ss "$2" -t "$WIN" "${FF_INPUT_OPTS[@]}" -i "$1" -map 0:v:0 -map '0:a?' -f null - 2>&1 | grep -c . || true
  else
    ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$1" -map 0:v:0 -map '0:a?' -f null - 2>&1 | grep -c . || true
  fi
}
confirm () {  # re-confirm a nonzero count; keep the min, bail early on a clean pass
  local f n m i; f="$1"; n=$(decode_win "$f" "${2:-}"); i=0
  while [ "$n" -ne 0 ] && [ "$i" -lt 4 ]; do m=$(decode_win "$f" "${2:-}"); [ "$m" -lt "$n" ] && n=$m; i=$((i+1)); done
  printf '%s' "$n"
}
c_short=1; mid=""; tailp=""
if awk "BEGIN{exit !($dur < 4*$WIN)}"; then
  errs=$(confirm "$OUT")
  echo "   short file — full output decode: $errs errors (want 0)"
else
  c_short=0
  mid=$(awk "BEGIN{printf \"%.2f\", $dur/2}")
  tailp=$(awk "BEGIN{printf \"%.2f\", $dur-$WIN-2}")
  em=$(confirm "$OUT" "$mid"); et=$(confirm "$OUT" "$tailp")
  echo "   middle @${mid}s: $em errors; tail @${tailp}s: $et errors (want 0)"
  errs=$((em + et))
fi
# QTFF audit 5-4a: on a nonzero count, run the IDENTICAL stage against the
# SOURCE (same windows, same maps, same confirm-min). The DELTA — not the raw
# count — is what can indict the remux. Classification is deferred until after
# gate (d): an inherited-noise verdict requires the output timeline
# independently proven clean, or the noise can mask a container-level defect.
c_src=-1; c_delta=0
if [ "${errs:-0}" -gt 0 ]; then
  if [ "$c_short" -eq 1 ]; then c_src=$(confirm "$SRC")
  else c_src=$(( $(confirm "$SRC" "$mid") + $(confirm "$SRC" "$tailp") )); fi
  c_delta=$((errs - c_src))
  echo "   source-baseline (identical windows): source: $c_src / output: $errs / delta: $c_delta"
fi

echo "-- (d) output timeline integrity (whole file, demux only) --"
# The gate the shipped-broken files would have failed (post-mortem 2026-07-25):
# a MOV whose muxer was handed timestamp-less packets INVENTS timing — N/A PTS,
# decode-order PTS, 1-tick sample durations, a stts/ctts no player can follow —
# while the video essence stays bit-perfect, so (a)/(b) pass. Prove the OUTPUT's
# own timeline: zero N/A timestamps, strictly monotonic DTS, and a sane
# sample-duration histogram (CFR broadcast: one or two adjacent values; a spray
# of near-zero durations is the invented-timeline signature).
eval "$(ffp -v error -select_streams v:0 -show_entries packet=pts,dts,duration -of csv=p=0 "$OUT" 2>/dev/null | \
  awk -F, 'NF{
      n++
      if($1=="N/A"||$1=="") nap++
      if($2=="N/A"||$2==""){ nad++ } else { d=$2+0; if(hav){ if(d<pd) back++; else if(d==pd) dup++ } pd=d; hav=1 }
      if($3!="N/A" && $3!=""){ du=$3+0; h[du]++; if(h[du]>hm){hm=h[du]; modal=du} }
    }
    END{
      tiny=0; top=""
      for(k in h){ if(modal>0 && (k+0)*10<modal) tiny+=h[k] }
      for(i=1;i<=3;i++){ bk=-1; bc=-1; for(k in h) if(h[k]>bc && !(k in used)){bc=h[k]; bk=k}
        if(bk<0) break; used[bk]=1; top=top sprintf("%sx%d ", h[bk], bk) }
      printf "TL_N=%d TL_NAPTS=%d TL_NADTS=%d TL_BACK=%d TL_DUP=%d TL_TINY=%d TL_MODAL=%d TL_TOP=%c%s%c\n",
        n+0, nap+0, nad+0, back+0, dup+0, tiny+0, modal+0, 39, top, 39
    }')"
echo "   packets=$TL_N  N/A-PTS=$TL_NAPTS  N/A-DTS=$TL_NADTS  backward-DTS=$TL_BACK  duplicate-DTS=$TL_DUP"
echo "   sample-duration histogram (top): ${TL_TOP:-'?'}  near-zero durations: $TL_TINY (want 0)"
DCLEAN=1   # (d) verdict feeds the (c)/(e) baseline classification (QTFF audit 5-4a/b)
if [ "${TL_NAPTS:-0}" -ne 0 ] || [ "${TL_NADTS:-0}" -ne 0 ]; then
  verdict=FAIL; DCLEAN=0; d_failed=1
  note="${note:+$note }Output has ${TL_NAPTS}/${TL_NADTS} packets with N/A PTS/DTS — the muxer invented the timeline (hard stop; see timeline-repair.md)."
fi
if [ "${TL_BACK:-0}" -ne 0 ] || [ "${TL_DUP:-0}" -ne 0 ]; then
  verdict=FAIL; DCLEAN=0; d_failed=1
  note="${note:+$note }Output DTS not strictly monotonic (backward=$TL_BACK duplicate=$TL_DUP)."
fi
if [ "${TL_TINY:-0}" -gt 2 ]; then   # first/last sample may legitimately stray
  # Genuine VFR (web sources) legitimately has micro-durations — but then the
  # SOURCE shows the same profile. Per doctrine, "inherent" requires MATCHING
  # counts, so escalate lazily: scan the source the same way and FAIL only when
  # the output's near-zero count is not matched there (QTFF audit 5c).
  src_tiny=$(ffp -v error -select_streams v:0 -show_entries packet=duration -of csv=p=0 "$SRC" 2>/dev/null | \
    awk -F, 'NF && $1!="N/A"{ du=$1+0; h[du]++; n++; if(h[du]>hm){hm=h[du]; modal=du} }
      END{ t=0; if(n>0 && modal>0) for(k in h){ if((k+0)*10<modal) t+=h[k] }; if(n==0){print "na"} else print t+0 }')
  if [ "$src_tiny" = na ]; then
    [ "$verdict" = FAIL ] || verdict=REVIEW; DCLEAN=0
    note="${note:+$note }$TL_TINY near-zero sample durations in the output and the source's duration profile is unreadable — cannot prove inherent; inspect before shipping."
    echo "   >> $TL_TINY near-zero durations; source profile unreadable — REVIEW."
  elif [ "${TL_TINY:-0}" -le $((src_tiny + 2)) ]; then
    echo "   near-zero durations: output=$TL_TINY vs source=$src_tiny — matching profile (inherent VFR), not invented."
  else
    verdict=FAIL; DCLEAN=0; d_failed=1
    note="${note:+$note }$TL_TINY sample durations <1/10 of modal ($TL_MODAL) vs only $src_tiny in the source — invented-timeline signature."
  fi
fi

# QTFF audit 5-4a: classify gate (c)'s nonzero count now that (d) is known.
# Reproduced counts (delta <= 0) + a clean (d) timeline = capture-inherited
# noise -> REVIEW carrying the evidence (never a silent OK). Anything else
# keeps the full post-mortem warning: inherent noise can MASK a second,
# container-level defect, so the delta alone never clears a file.
if [ "${errs:-0}" -gt 0 ]; then
  [ "$verdict" = FAIL ] || verdict=REVIEW
  if [ "$c_src" -ge 0 ] && [ "$c_delta" -le 0 ] && [ "$DCLEAN" -eq 1 ]; then
    echo "   spot-check classification: source reproduces the counts and (d) is clean — inherited noise (REVIEW)."
    note="${note:+$note }Spot-window decode errors reproduce on the source under identical windows (source: $c_src / output: $errs / delta: $c_delta) with a clean (d) timeline — capture-inherited noise, not remux damage. Settle for archival sign-off with --full + MKV strict-mux."
  else
    note="${note:+$note }Output decode errors in spot windows (source: $c_src / output: $errs / delta: $c_delta; (d) clean=$DCLEAN). Claiming these are inherent to the source requires MATCHING counts on a linear decode of the same source window AND clean timeline gates (d)/(e) — the same error class can mask a second, container-level defect (post-mortem 2026-07-25)."
  fi
fi

echo "-- (e) scrub gate: player-style off-keyframe seeks + keyframe sanity --"
# WHY: the demux/keyframe-accurate checks above (and an -ss-before-i spot decode)
# snap to a keyframe and decode forward — they stayed clean on the corrupted PAFF
# file. A GUI scrub instead lands at arbitrary, often non-keyframe positions and
# follows the container seek index/edit list, which is what tore. This gate
# reproduces that: accurate seeks (-ss AFTER -i) to deliberately off-keyframe
# targets, plus a keyframe-spacing sanity check. Errors here FAIL the file so a
# glitchy timeline is caught BEFORE the source is deleted.
case "${dur:-0}" in ''|N/A) dur=0;; esac
kf=$(ffp -v error -select_streams v:0 -show_entries packet=pts_time,flags -of csv=p=0 "$OUT" 2>/dev/null \
      | awk -F, '$2 ~ /K/ && $1!="N/A" && $1!="" {print $1}' | sort -n | uniq)
nkf=$(printf '%s\n' "$kf" | grep -c . || true)
echo "   keyframes in output: $nkf"
if [ "${nkf:-0}" -lt 2 ]; then
  echo "   only ${nkf:-0} keyframe(s) — no interior scrub target; a scrub must decode"
  echo "   from the previous keyframe (potentially the file start)."
  if awk "BEGIN{exit !(${dur:-0} > 30)}"; then
    [ "$verdict" = FAIL ] || verdict=REVIEW
    note="${note:+$note }Single-GOP/unseekable output (${nkf:-0} keyframe over ${dur}s)."
  fi
else
  maxgap=$(printf '%s\n' "$kf" | awk 'NR>1{g=$1-p; if(g>m)m=g} {p=$1} END{printf "%.2f", m+0}')
  echo "   max keyframe gap: ${maxgap}s"
  samples=$(printf '%s\n' "$kf" | awk -v n=6 '{a[NR]=$1} END{
      if(NR<2) exit; step=(NR-1)/n; if(step<1)step=1;
      for(i=1; c<n; i+=step){ idx=int(i); if(idx<1)idx=1; if(idx+1>NR) break;
        kfb=a[idx]; nxt=a[idx+1]; if(nxt>kfb){c++; printf "%.3f %.3f\n", kfb, (nxt-kfb)/2} }}')
  # fast input-seek to the preceding keyframe, then ACCURATE output-seek to the
  # non-keyframe midpoint (-ss after -i): a player landing mid-GOP via the index.
  scrub_lines () {  # $1 file, $2 fast-seek keyframe, $3 accurate-seek offset, $4 threads ("" = default)
    ffmpeg -nostdin -v error ${4:+-threads "$4"} -ss "$2" "${FF_INPUT_OPTS[@]}" -i "$1" -ss "$3" -t 4 -map 0:v:0 -f null - 2>&1 || true
  }
  count_all () { printf '%s\n' "$1" | grep -c . || true; }
  count_mux () { printf '%s\n' "$1" | grep -c '^\[null @' || true; }
  serr=0; ntests=0
  while read -r kfb delta; do
    [ -n "$kfb" ] || continue
    ntests=$((ntests+1))
    serr=$((serr + $(count_all "$(scrub_lines "$OUT" "$kfb" "$delta" "")") ))
  done <<EOF
$samples
EOF
  echo "   off-keyframe accurate seeks: $ntests point(s), $serr decode error(s) (want 0)"
  if [ "${serr:-0}" -gt 0 ]; then
    # QTFF audit 5-4b: before scoring, (1) recount BOTH sides deterministically —
    # threaded decode jitters corruption-noise line counts (probe 2026-07-26:
    # 19 vs 17 on the SAME file), so the comparison is honest only at
    # -threads 1 (a zero recount = the fast-pass lines were load strays, the
    # same doctrine as gate (c)'s confirm-min); (2) classify lines — decoder-
    # class vs muxer-stage ('[null @' = the harness's own null muxer objecting
    # to what it is fed, e.g. duplicate DTS on ms-quantized sources — a
    # harness-artifact class, not a torn picture); (3) baseline-subtract the
    # IDENTICAL seeks run on the untouched source. Fully reproduced lines with
    # a clean (d) timeline -> REVIEW carrying the evidence. Any excess over
    # the source, or a dirty (d), keeps the FAIL: inherent noise can MASK a
    # broken container timeline (post-mortem 2026-07-25).
    o_tot=0; o_mux=0; b_tot=0; b_mux=0
    while read -r kfb delta; do
      [ -n "$kfb" ] || continue
      ol=$(scrub_lines "$OUT" "$kfb" "$delta" 1); bl=$(scrub_lines "$SRC" "$kfb" "$delta" 1)
      o_tot=$((o_tot + $(count_all "$ol") )); o_mux=$((o_mux + $(count_mux "$ol") ))
      b_tot=$((b_tot + $(count_all "$bl") )); b_mux=$((b_mux + $(count_mux "$bl") ))
    done <<EOF
$samples
EOF
    o_dec=$((o_tot - o_mux)); b_dec=$((b_tot - b_mux))
    d_dec=$((o_dec - b_dec)); d_mux=$((o_mux - b_mux))
    echo "   deterministic recount (-threads 1), identical seeks on both files:"
    echo "     decoder-class:     source: $b_dec / output: $o_dec / delta: $d_dec"
    echo "     muxer-stage(null): source: $b_mux / output: $o_mux / delta: $d_mux"
    if [ "$o_tot" -eq 0 ]; then
      echo "   scrub classification: deterministic recount clean — fast-pass lines were load strays."
    elif [ "${DCLEAN:-0}" -eq 1 ] && [ "$d_dec" -le 0 ] && [ "$d_mux" -le 0 ]; then
      [ "$verdict" = FAIL ] || verdict=REVIEW
      echo "   scrub classification: all lines reproduce on the source and (d) is clean — inherited/harness noise (REVIEW)."
      note="${note:+$note }Scrub-gate lines reproduce on the untouched source under identical accurate seeks (decoder source: $b_dec / output: $o_dec; muxer-stage source: $b_mux / output: $o_mux; deterministic -threads 1 counts) with a clean (d) timeline — capture-inherited decode noise / harness-stage artifacts, not a torn timeline. The timeline is independently proven by (d); complete the proof set (MKV strict-mux + --full presentation order) for archival sign-off."
    else
      verdict=FAIL; e_failed=1
      note="${note:+$note }Scrub gate: $o_tot deterministic decode error(s) on off-keyframe seeks (decoder delta $d_dec, muxer-stage delta $d_mux vs source; (d) clean=${DCLEAN:-0}) — the timeline tears on scrub (silent-corruption signature). Route via diagnose.sh by MEASURED profile (pairfill-paff.sh for half-timestamped H.264 PAFF; derive-dts.sh for a PTS-complete reordered stream, any codec; rebuild-paff.sh for H.264 with no surviving reorder — pairfill/rebuild are H.264-only). NEVER explain this away by replicating the errors on the source alone: two independent defects share this symptom, and inherent decode noise MASKS a broken container timeline (post-mortem 2026-07-25). The timeline must be independently proven — gate (d) above, MKV strict-mux, framemd5 presentation order (--full)."
    fi
  fi
fi

echo "-- (f) A/V duration parity (sync) --"
# The cheapest catch for the gap-collapse desync (remux-sync post-mortem): for one
# program every audio track should run the same length as the video. Raw PCM that
# had source discontinuities collapsed will read SHORT here. Demux-only (stream
# durations), so it costs nothing. A mismatch is a sync RISK -> REVIEW (the human
# settles it), never a silent OK. Base tolerance via RTM_SYNC_TOL (default 0.25s).
#
# SOURCE-AWARE TOLERANCE (WO 2.4, measured): a capture with real transport loss
# can never satisfy a fixed 0.25s — the collapsed audio legitimately differs by
# exactly the dropped time (a measured 4.18s-loss source re-flagged forever), so
# the fixed gate re-reported SOURCE damage as a remux defect. When the base
# tolerance is exceeded, the gate therefore widens by the source's MEASURED
# total forward-gap seconds: RTM_SOURCE_GAP_BUDGET (caller-supplied, e.g. from a
# ts-health scan of the original capture when SRC here is an intermediate) wins;
# otherwise disc_scan on SRC — the same forward-gap measurement the --silence
# budget and the backhaul gate already trust. Never widened without a measured
# budget: a clean source (budget 0) keeps the exact 0.25s, and a mismatch beyond
# budget+base still flags. The widened PASS prints both numbers plus the
# residual-explained line — an explained mismatch is stated, never silent.
# OPEN QUESTION surfaced, not papered over (dossier): the BBC resync run moved
# Δ from −2.2s to +1.9s — aresample overfill on multi-gap sources. An audio-LONG
# delta is called out by direction wherever it lands (inside or beyond budget).
sdur () { ffp -v error -select_streams "$1" -show_entries stream=duration -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1; }
vdur=$(sdur v:0); naud=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$OUT" 2>/dev/null | LC_ALL=C sort -u | grep -c . || true)   # distinct indices: a program-bearing OUT lists each stream twice
SYNC_TOL="${RTM_SYNC_TOL:-0.25}"
if [ "${naud:-0}" -eq 0 ] || [ -z "$vdur" ] || [ "$vdur" = N/A ]; then
  echo "   no audio or no stream durations — sync parity N/A."
else
  worst=0; worst_dir=short; ai=0
  while [ "$ai" -lt "$naud" ]; do
    ad=$(sdur "a:$ai")
    if [ -n "$ad" ] && [ "$ad" != N/A ]; then
      delta=$(awk "BEGIN{d=($vdur)-($ad); if(d<0)d=-d; printf \"%.3f\", d}")
      echo "   a:$ai=${ad}s vs video ${vdur}s (Δ ${delta}s)"
      if awk "BEGIN{exit !(($delta) > ($worst))}"; then
        worst=$delta
        worst_dir=$(awk "BEGIN{print (($ad) > ($vdur)) ? \"long\" : \"short\"}")
      fi
    fi
    ai=$((ai+1))
  done
  if awk "BEGIN{exit !(($worst) > ($SYNC_TOL))}"; then
    # over the base tolerance — resolve the measured budget LAZILY (the
    # whole-file source scan only runs when the fixed gate would flag; a clean
    # verify never pays for it), the gate-(d) src_tiny escalation pattern.
    gap_budget=""; gap_from=""
    case "${RTM_SOURCE_GAP_BUDGET:-}" in
      '') : ;;   # unset -> measure the source below
      *[!0-9.]*|*.*.*|.)
        # malformed is NOT a budget — say so and fall through to measuring;
        # widening on garbage would be the silent-widening trap
        echo "   RTM_SOURCE_GAP_BUDGET='${RTM_SOURCE_GAP_BUDGET}' is not a number — ignored (a budget must be MEASURED).";;
      *) gap_budget="$RTM_SOURCE_GAP_BUDGET"; gap_from="caller-supplied RTM_SOURCE_GAP_BUDGET";;
    esac
    if [ -z "$gap_budget" ]; then
      eval "$(disc_scan "$SRC")"
      # P1.4: a BUDGET must come from the presentation-order census. The
      # coded-order figure is an adjacent-dts_time delta sum, and on any
      # container whose DTS is reconstructed that is the artifact, not the
      # program. INCIDENT TESTIMONY, not a local measurement (the 54.6 GB 2023
      # VMA capture is not on this machine and cannot be re-measured here):
      # ~5,475 s of phantom "loss" reported on a 10,944 s program, against a
      # real loss of 4.58 s — see lib-paff.sh disc_scan for the mechanism, which
      # IS reproducible in the suite on constructed shapes. And this number does
      # not merely get printed, it WIDENS the gate. A phantom budget hides a real desync, so the tolerance now widens
      # only by presentation-order loss. Direction of travel: this NARROWS the
      # gate, which is the point. A genuinely gappy source still widens it by
      # its REAL measured loss (the gap.ts pin).
      # And a census taken across missing PTS buys nothing at all: disc_budget_secs
      # returns 0 there and disc_budget_note says why (the ts-health V_NADTS rule).
      gap_budget=$(disc_budget_secs "${DISC_P_NA:-0}" "${DISC_P_MISSING:-0}")
      gap_from="measured on the source: disc_scan found ${DISC_P_COUNT:-0} forward gap(s) in presentation order"
      # the evidence prints whenever the scan runs, pass or flag — a budget that
      # is spent silently is how the phantom one went unnoticed
      echo "   source gap census: ${DISC_P_COUNT:-0} gap(s) / ${DISC_P_MISSING:-0}s in presentation order;"
      echo "   coded-order census (dts column, comparison only): ${DISC_COUNT:-0} gap(s) / ${DISC_MISSING:-0}s. Budget spent: ${gap_budget}s."
      disc_budget_note "${DISC_P_NA:-0}" "${DISC_P_COUNT:-0}"
    fi
    eff_tol=$(awk "BEGIN{printf \"%.3f\", ($SYNC_TOL)+($gap_budget)}")
    if awk "BEGIN{exit !(($gap_budget) > 0 && ($worst) <= ($eff_tol))}"; then
      echo "   max Δ ${worst}s exceeds the base ${SYNC_TOL}s tolerance but is covered by the"
      echo "   source's gap budget: tolerance ${SYNC_TOL}s + gap budget ${gap_budget}s (${gap_from})."
      echo "   residual Δ${worst}s explained by measured source loss — the capture dropped"
      echo "   this much real time; audio runs ${worst_dir} of video by it, not a remux defect."
      if [ "$worst_dir" = long ]; then
        echo "   note: audio runs LONG — the overfill direction. Collapsed source gaps read"
        echo "   SHORT; a LONG delta on a resync build is the aresample-overfill open"
        echo "   question (BBC run: Δ −2.2s -> +1.9s). Within budget, but listen at the tail."
      fi
    else
      [ "$verdict" = FAIL ] || verdict=REVIEW
      if awk "BEGIN{exit !(($gap_budget) > 0)}"; then
        note="${note:+$note }A/V duration mismatch up to ${worst}s (audio ${worst_dir}) exceeds even the source-loss widened tolerance (${SYNC_TOL}s + measured gap budget ${gap_budget}s = ${eff_tol}s) — beyond what measured source loss explains. If audio runs long off a resync build this is the aresample-overfill open question (BBC run moved Δ −2.2s -> +1.9s) — do not ship on the budget's back; diagnose.sh to confirm."
        echo "   >> mismatch ${worst}s exceeds tolerance ${SYNC_TOL}s + gap budget ${gap_budget}s — sync REVIEW."
      else
        note="${note:+$note }A/V duration mismatch up to ${worst}s (> ${SYNC_TOL}s tol; no measured source loss to explain it) — gap-collapse desync signature; diagnose.sh to confirm, resync.sh to fix."
        echo "   >> mismatch ${worst}s exceeds tolerance ${SYNC_TOL}s (no measured source loss) — sync REVIEW."
      fi
    fi
  else
    echo "   max Δ ${worst}s within ${SYNC_TOL}s tolerance — A/V durations consistent."
  fi
fi

echo "-- (g) audio playability (QTFF sample-entry allowlist + bounded decode) --"
# WHY (WO 3.6): the dead-HDMV-track class was INVISIBLE to verification —
# mov.sh 1.10.0 copy-muxed Blu-ray LPCM (pcm_bluray) into a MOV audio track
# whose sample entry ([128][0][0][0], the BDAV stream type carried over as a
# fourcc) NO decoder claims — not even the ffmpeg that wrote it — and no gate
# here looked at audio playability: an 18.5 GB Blu-ray deliverable shipped
# "verified" with zero playable audio (entry 1, 2026-08-13). Two assertions
# per OUTPUT audio track, both required:
#   1. TAG: the sample entry is on a POSITIVE allowlist — exactly the tags
#      this plugin's own routes can legitimately land in a QTFF file, each
#      one minted and probed on this bench (macOS 26.6.1 / ffmpeg 9.0.1,
#      2026-08-14 — Ground Rule 6: empirical verdicts self-date):
#        sowt/twos/lpcm/in24/in32/fl32   PCM access tracks + raw-PCM copies
#        mp4a/alac/.mp3                  natively-playable copies
#        ec-3/EC-3                       E-AC-3 single-track copy (plays in QT)
#        ac-3/AC-3, dtsc, .mp2           dual-track's PRESERVED-ORIGINAL track
#          (AC-3/DTS/MP2): legal because the PCM ACCESS track is what
#          guarantees playback — TN2429: desktop QuickTime does NOT decode
#          AC-3, so this is a dead-track gate, not a per-track QT-playability
#          gate. Case is load-bearing: this bench's muxer writes ac-3/ec-3 on
#          fresh encodes but AC-3 on stream copies — both minted 2026-08-14.
#        ipcm                            the ISO PCM entry (D3, added 1.13):
#          ISO/IEC 23003-5 with the pcmC config box, MP4RA-registered, written
#          by ffmpeg since 6.1 and read by VLC/GPAC (which actively NORMALIZES
#          QTFF 'twos' to 'ipcm' on MP4 remux); Sony XAVC has shipped it in
#          broadcast delivery since 2021. It is what `-c:a pcm_s16le -f mp4`
#          produces — i.e. what the container-swap rung's access track IS
#          (minted + decoded on this bench 2026-08-15). Calling it "a sample
#          entry no decoder claims" was factually false.
#      Anything else in a QTFF container is UNRECOGNIZED, which since 1.13 is a
#      PRIOR, not a verdict (D3): the bounded decode probe runs anyway and a
#      clean decode downgrades the FAIL to an advisory REVIEW. Pre-1.13 the
#      probe was deliberately SKIPPED for off-list tags — the one measurement
#      that could falsify the claim was the one never taken, and `ipcm` was
#      condemned unwaivably (exit 1) on evidence that was never gathered.
#      Non-QTFF outputs (an MKV cross-check) carry no sample entries, so only
#      assertion 2 applies there — never a false FAIL.
#   2. DECODE: a bounded head decode (first ${WIN}s, this audio track only)
#      returns 0 error lines — gate (c)'s confirm-min doctrine: a nonzero
#      count re-runs and keeps the minimum, so load strays never FAIL.
# Never waivable (other_failed): a dead audio track is an essence defect,
# not a count signature — "independent proofs pass" cannot hold for it.
#
# --- P1.6: the decode half was not measuring audio decode --------------------
# It counted EVERY stderr line of the whole invocation (`grep -c .`, no -vn, no
# stream scoping, no source baseline, no inherited-noise path) and charged the
# total to each audio track in turn. Deterministic OPEN-TIME video notices land
# in that count: measured on this bench 2026-08-16 (macOS 26.6.1, ffmpeg 9.0.1),
# a bounded AUDIO-ONLY decode of tests/fixtures/late-sps.ts — `-map 0:a:0 -vn
# -t 10` — emits 306 `-v error` lines, every one of them the h264 parser
# complaining about a head no audio sample has anything to do with. So the
# number was not "audio decode errors" at all: a wrong MEASUREMENT, not a wrong
# inference — and it set an UNWAIVABLE other_failed.
# Three layers, none of which hide the raw count:
#   1. -vn on the decode. Belt and braces (the -map is already audio-only, so no
#      video is decoded at the OUTPUT stage) but it states the scope in the
#      command, and it costs nothing.
#   2. SOURCE-BASELINE SUBTRACTION, the same move gates (c)/(e) already make:
#      run the identical bounded decode against $SRC and difference it. Only
#      paid when the raw count is nonzero, exactly like gate (c).
#   3. An INHERITED-CLASSIFICATION path: delta <= 0 means the output reproduces
#      what the source already does, so it is inherited/open-time noise ->
#      REVIEW, never other_failed. A genuine audio-decode delta (net > 0) keeps
#      today's FAIL + other_failed.
# EXIT-CONTRACT NOTE: this moves one false-positive class from FAIL (1) to
# REVIEW (10 at the caller). A file whose SOURCE audio is as broken as the
# output's now reads inherited -> REVIEW. That is correct by this plugin's own
# inherited-damage doctrine — a remux cannot fix source damage, and claiming it
# caused it is the accusation gates (c)/(e) were rebuilt to stop making — and it
# is exactly how (c)/(e) already behave on the same evidence.
g_naud=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$OUT" 2>/dev/null | LC_ALL=C sort -u | grep -c . || true)   # distinct indices: a program-bearing OUT lists each stream twice
# the pre-correction figure, kept ONLY so the correction can announce itself
# (P1c): the census fix silently moved a program-bearing OUT from FAIL to OK by
# retiring a phantom track, and a FAIL->OK move may never be silent.
g_naud_raw=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$OUT" 2>/dev/null | grep -c . || true)
g_ofmt=$(ffp -v error -show_entries format=format_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1)
g_qtff=0; case ",$g_ofmt," in *,mov,*|*,mp4,*) g_qtff=1;; esac
if [ "${g_naud:-0}" -eq 0 ]; then
  echo "   no audio tracks in the output — gate N/A."
else
  [ "$g_qtff" -eq 1 ] || echo "   output container '$g_ofmt' has no QTFF sample entries — tag allowlist N/A; the decode half still applies."
  # NEVER SILENT (P1c): announce the census correction wherever it actually bites.
  # A program-bearing OUT used to be probed for a track that does not exist —
  # ffprobe reports `tag='n/a' (codec )` for it, the bounded decode of a
  # non-existent ordinal emits error lines, and gate (g) FAILed the file on them.
  # Retiring the phantom is a FAIL -> OK move, so it is announced with both
  # numbers rather than just quietly reading one track fewer.
  if [ "${g_naud_raw:-0}" -ne "${g_naud:-0}" ]; then
    echo "   audio census: $g_naud distinct track index(es); ffprobe listed ${g_naud_raw} stream"
    echo "        section(s) because this output carries PROGRAMS and every stream is emitted"
    echo "        twice (nested under the program and again at top level). The surplus is a"
    echo "        LISTING artifact, not a track: this gate probes $g_naud track(s). Before the"
    echo "        census fix it probed the phantom ordinal(s) too — tag='n/a' (codec ) — and"
    echo "        FAILed on their decode lines."
  fi
  # DISTINCT indices, not lines. On a container that carries PROGRAMS (every
  # mpegts source this plugin exists for), `-show_entries stream=` selects the
  # stream section in BOTH places ffprobe emits it — once nested under the
  # program and once at top level — so a plain line count reads DOUBLE: 2 for
  # tests/fixtures/m2v420.ts's single audio track, 4 for a two-track TS. This
  # count is the source-track census the baseline matcher enumerates over, so a
  # doubled count invents phantom tracks to compare against. (The identical
  # probe against $OUT elsewhere in this file is safe — a .mov has no programs
  # — which is why the defect only appeared once a SOURCE was probed this way.)
  g_srcaud=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$SRC" 2>/dev/null | LC_ALL=C sort -u | grep -c . || true)
  g_dec1 () {  # $1 file, $2 track index -> one bounded head decode's error-line count
    ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$1" -map "0:a:$2" -vn -t "$WIN" -f null - 2>&1 | grep -c . || true
  }
  g_dec () {  # $1 file, $2 track index -> error-line count (confirm-min)
    local f="$1" i="$2" n m t
    n=$(g_dec1 "$f" "$i"); t=0
    while [ "$n" -ne 0 ] && [ "$t" -lt 2 ]; do
      m=$(g_dec1 "$f" "$i"); [ "$m" -lt "$n" ] && n=$m; t=$((t+1))
    done
    printf '%s' "$n"
  }
  # --- F2: the baseline is chosen by EVIDENCE, never by ordinal ---------------
  # The previous g_srcmap mapped output audio ordinal -> source audio ordinal
  # POSITIONALLY (with a clamp at the source's last track for access-track
  # layouts). That is only correct when the output's audio tracks correspond
  # 1:1, in order, to the source's — and the plugin's own dual-track builder
  # violates it by construction: dual-track.sh maps `0:a:0` TWICE (a PCM access
  # copy plus the preserved original), so on a source with >=2 audio tracks the
  # second output track was baselined against source a:1, a completely
  # different stream. Reproduced: source with a damaged a:0 and a clean a:1,
  # output = two copies of source a:0 ->
  #     a:0  source: 2 / output: 2 / delta: 0   -> REVIEW
  #     a:1  source: 0 / output: 2 / delta: 2   -> FAIL + other_failed
  # Two byte-identical output tracks, opposite verdicts, and the FAIL is the
  # UNWAIVABLE kind. A false accusation manufactured entirely by the mapping.
  #
  # Correspondence is now established from observable stream properties, in
  # descending order of how hard they are to fake:
  #   1. channels + sample_rate — the pair that survives a format conversion.
  #      The dual-track ACCESS track is a DECODED copy, so its codec cannot
  #      match by construction; its channel count and rate still do.
  #   2. codec_name — separates the preserved original from the access copy.
  #   3. language tag, then 4. title tag — the remaining tie-breakers.
  # Each pass narrows the candidate set ONLY if at least one candidate matches
  # (a property the output simply does not carry must not empty the set), and
  # stops as soon as one candidate is left. A source with exactly ONE audio
  # track therefore always resolves to it, which is the pre-F2 behavior for
  # that case, unchanged.
  # NOTHING sits ahead of those four passes. A provenance SHORTCUT used to: any
  # output track titled "* (access)" / "* (original)" was hardcoded to source
  # a:0, on the reasoning that dual-track.sh and pairfill-paff.sh build their
  # pair from a:0 only. DELETED (P1c, 2026-08-16) — it reintroduced the exact
  # ordinal assumption the property matcher exists to replace, and it made the
  # answer WORSE than the evidence it preceded. Measured on this bench: a
  # dual-track MASTER (a:0 = PCM access, a:1 = MP2 original) copied byte-for-byte
  # with its titles intact had output a:1 baselined against source a:0 ->
  # delta 2 -> ">> FAIL" + other_failed, a false UNWAIVABLE accusation against a
  # `-c copy`. With the shortcut gone the codec pass resolves the same file to
  # It was NOT latent, either: a real dual-track.sh .mov carries the pair name in
  # the QTFF track-name atom, which ffprobe reports as TAG:name (measured
  # 2026-08-16: `TAG:name=PCM 24-bit (access)` / `TAG:name=MP2 (original)`), and
  # g_asig reads name as well as title precisely so that it is seen. The shortcut
  # fired on every dual-track/pairfill build this plugin makes.
  # WHAT ITS DELETION COSTS, measured not assumed: on a dual-track build from a
  # >=2-audio-track source the preserved original now resolves AMBIGUOUS instead
  # of to a:0 — and the verdict is unchanged, because the most-forgiving-candidate
  # rule scores the delta against the very track the shortcut would have named
  # (source a:0 carries the copied damage, so it IS the maximum). The pins in
  # tests/regression.d/61-reorder-depth.sh section 4 cover both halves.
  # What survives from that reasoning is the WARNING it carried: both builders
  # WRITE language=eng onto both output tracks regardless of what the source
  # said, so the language tag cannot separate two source tracks on that layout.
  # That is exactly why language sits third, behind channels/rate and codec.
  # >1 candidate left is not automatically a finding — see the ambiguity arm at
  # the call site, which FAILs only when the delta is positive against EVERY
  # candidate. NO source audio at all is a different thing entirely and is NOT
  # ambiguity (there was never a candidate set): see the `none` arm there.
  g_asig () {   # g_asig FILE ORD -> "codec|channels|rate|language|title", "-" for absent
    # `title` AND `name`: the same metadata key lands in a different tag per
    # container — Matroska keeps it as title, QTFF/MOV writes the track-name
    # atom and ffprobe reports it as name. Reading only one made the title
    # field read "-" on every .mov, which is where the provenance rule below
    # would have silently done nothing.
    ffp -v error -select_streams "a:$2" \
        -show_entries stream=codec_name,channels,sample_rate:stream_tags=language,title,name \
        -of default=nw=1 "$1" 2>/dev/null | \
    awk -F= '{ k=$1; v=$0; sub(/^[^=]*=/,"",v)
               if(k=="codec_name") c=v; else if(k=="channels") ch=v
               else if(k=="sample_rate") sr=v
               else if(tolower(k)=="tag:language") lg=v
               else if(tolower(k)=="tag:title" || tolower(k)=="tag:name") { if(ti=="") ti=v } }
             END{ printf "%s|%s|%s|%s|%s", (c==""?"-":c), (ch==""?"-":ch), \
                                           (sr==""?"-":sr), (lg==""?"-":lg), (ti==""?"-":ti) }'
  }
  g_sigfld () { printf '%s' "$1" | awk -F'|' -v k="$2" '{printf "%s", $k}'; }
  g_ssigs=""; g_ssigs_done=0
  g_ssig_init () {   # lazy, like the baseline decode itself: a clean gate pays nothing
    [ "$g_ssigs_done" -eq 1 ] && return 0
    local j=0
    while [ "$j" -lt "${g_srcaud:-0}" ]; do
      g_ssigs="${g_ssigs}$(g_asig "$SRC" "$j")|
"
      j=$((j+1))
    done
    g_ssigs_done=1
  }
  g_ssig_get () { printf '%s\n' "$g_ssigs" | awk -v n="$(( $1 + 1 ))" 'NR==n{printf "%s", $0}'; }
  g_srcmap () {  # g_srcmap OUT_TRACK -> three lines: MODE / WHY / CANDIDATE ORDINALS
    # THREE LINES, not one delimited record: WHY quotes the signature, which
    # contains the field separator. (It did, and the caller's split cut the
    # candidate list in half — caught before this shipped, but it is exactly
    # the class of bug that made an in-band delimiter a bad idea here.)
    local i="$1" osig cand keep n kn j s spec fields label m k
    if [ "${g_srcaud:-0}" -le 0 ]; then
      printf 'none\nthe source has NO audio track to compare against\n\n'; return 0
    fi
    g_ssig_init
    osig=$(g_asig "$OUT" "$i")
    cand=""; n=0; j=0
    while [ "$j" -lt "$g_srcaud" ]; do cand="$cand $j"; n=$((n+1)); j=$((j+1)); done
    label="nothing (the source has $n audio track(s) and no property separated them)"
    for spec in "2 3:channels+sample_rate" "1:codec" "4:language" "5:title"; do
      [ "$n" -eq 1 ] && break
      fields="${spec%%:*}"
      keep=""; kn=0
      for j in $cand; do
        s=$(g_ssig_get "$j"); m=1
        for k in $fields; do
          [ "$(g_sigfld "$s" "$k")" = "$(g_sigfld "$osig" "$k")" ] || { m=0; break; }
        done
        [ "$m" -eq 1 ] && { keep="$keep $j"; kn=$((kn+1)); }
      done
      # narrow only on a NON-EMPTY match (a property the output does not carry
      # must not empty the set), and only NAME the pass that actually reduced it
      if [ "$kn" -gt 0 ]; then
        [ "$kn" -lt "$n" ] && label="${spec#*:}"
        cand="$keep"; n=$kn
      fi
    done
    cand="${cand# }"
    if [ "$n" -eq 1 ]; then printf 'unique\n%s\n%s\n' "$label" "$cand"
    else printf 'ambiguous\n%s; output signature %s\n%s\n' "$label" "$osig" "$cand"; fi
  }
  # D3 (1.13) inverse-error inputs: an mp4a/.mp2 track carrying MPEG Layer II
  # is the configuration that produces NO AUDIO in AVFoundation, and the old
  # gate PASSED it (allowlisted on the rationale that a PCM access track
  # guarantees playback — true only when one EXISTS). ffmpeg declares MP2 at
  # >24 kHz with OTI 0x6B (MPEG-1 Part 3), the formally correct value, and the
  # demuxer maps 0x69/0x6B to AV_CODEC_ID_MP3 first-match — so ffprobe LABELS
  # 48 kHz Layer II as 'mp3'. The source is the discriminator this gate has and
  # the label does not: verify.sh holds both files.
  # DISTINCT index,codec_name PAIRS, not lines (P1c — the census sweep missed
  # these two). A program-bearing container emits every stream section TWICE
  # (nested under the program and again at top level), so a plain line count
  # reads 2 for m2v420.ts's single MP2 track. `sort -u` on codec_name ALONE is
  # not the fix either — a codec legitimately repeats across tracks, and
  # collapsing that would under-count a real two-MP2 source. Pairing the index
  # with the codec dedupes the listing artifact and keeps genuine repeats.
  # ,mp2,?$ not ,mp2$: a stream row carrying side data gains a trailing comma
  # ("0,mp2,") and a $-anchored grep goes blind on it (CHECKUP-2026-08-27 F8)
  g_src_mp2=$(ffp -v error -select_streams a -show_entries stream=index,codec_name -of csv=p=0 "$SRC" 2>/dev/null | LC_ALL=C sort -u | grep -cE ',mp2,?$' || true)
  g_has_pcm=$(ffp -v error -select_streams a -show_entries stream=index,codec_name -of csv=p=0 "$OUT" 2>/dev/null | LC_ALL=C sort -u | grep -c ',pcm_' || true)
  g_mp2_naked=0
  gi=0
  while [ "$gi" -lt "$g_naud" ]; do
    g_tag=$(ffp -v error -select_streams "a:$gi" -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1)
    g_cod=$(ffp -v error -select_streams "a:$gi" -show_entries stream=codec_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1)
    g_tag_ok=1
    if [ "$g_qtff" -eq 1 ]; then
      case "$g_tag" in
        sowt|twos|lpcm|in24|in32|fl32|mp4a|alac|.mp3|ec-3|EC-3|ac-3|AC-3|dtsc|.mp2|ipcm) : ;;
        *) g_tag_ok=0;;
      esac
    fi
    # ALWAYS probe (D3): the allowlist is a prior, and an off-list tag is
    # exactly the case where a measurement beats an opinion.
    g_err=$(g_dec "$OUT" "$gi")
    # P1.6 layers 2+3: only on a nonzero raw count (gate (c)'s lazy-baseline
    # discipline — a clean gate never pays for a source decode) run the
    # IDENTICAL bounded decode on the source and difference it. g_net is what
    # this gate is entitled to attribute to the remux; g_err stays printed.
    g_base=-1; g_net="${g_err:-0}"; g_bt=""; g_ambig=0
    # P1c: a positive delta can be JUSTIFIED three different ways, and the
    # sentence the operator reads — and the machine-consumed note the REVIEW
    # line carries — must say WHICH one applies. These three carry that wording,
    # reset per track; the defaults are the unique-baseline text, byte-for-byte
    # as before. (The unique arm re-assigns g_beyond_note because it is the one
    # arm that changes g_net AFTER this reset.)
    g_beyond="beyond the identical decode of the source"
    g_beyond_note="$g_net beyond the source baseline, deterministic after confirm-min"
    g_ambig_why="candidate set left ambiguous by channels/rate/codec/language/title"
    if [ "${g_err:-0}" -gt 0 ]; then
      g_mm=$(g_srcmap "$gi")
      g_mode=$(printf '%s\n' "$g_mm" | awk 'NR==1{printf "%s", $0}')
      g_why=$(printf '%s\n'  "$g_mm" | awk 'NR==2{printf "%s", $0}')
      g_cands=$(printf '%s\n' "$g_mm" | awk 'NR==3{printf "%s", $0}')
      case "$g_mode" in
        unique)
          g_bt="$g_cands"
          g_base=$(g_dec "$SRC" "$g_bt")
          g_net=$((g_err - g_base))
          g_beyond_note="$g_net beyond the source baseline, deterministic after confirm-min"
          echo "   a:$gi source-baseline (identical bounded decode, source a:$g_bt): source: $g_base / output: $g_err / delta: $g_net"
          echo "        baseline chosen on: $g_why"
          ;;
        ambiguous)
          # F2: no unwaivable accusation without an identified baseline. House
          # checklist test 3 — does divergence from prediction prove damage, or
          # just surprise? With two source tracks equally consistent with this
          # output track, a positive delta proves only that we guessed. Every
          # candidate's raw count is printed (nothing hidden) and the delta is
          # scored against the most forgiving of them.
          g_ambig=1
          echo "   a:$gi source-baseline AMBIGUOUS — matching on $g_why left source"
          echo "        track(s) [$g_cands] equally consistent with this output track, so this gate"
          echo "        cannot say which stream it is entitled to difference against."
          g_base=-1
          for g_c in $g_cands; do
            g_cb=$(g_dec "$SRC" "$g_c")
            echo "        candidate source a:$g_c -> $g_cb decode line(s) in the first ${WIN}s"
            [ "${g_cb:-0}" -gt "$g_base" ] && g_base="$g_cb"
          done
          g_net=$((g_err - g_base))
          echo "        output: $g_err / most forgiving candidate: $g_base / delta: $g_net"
          # P1c: the unresolved-baseline principle is right, and it simply does
          # not APPLY when the most forgiving candidate still leaves a positive
          # delta. The gate already computed that number and then threw it away.
          # delta > 0 against the BEST candidate means delta > 0 against every
          # candidate — damage is proven WITHOUT resolving the ambiguity — so the
          # ambiguity stops being decision-relevant here (g_ambig back to 0) and
          # the normal damage arms below judge it exactly as they judge a unique
          # baseline. This restores the pre-F2 exit code (1) for the ordinary
          # broadcast main+SAP shape: two property-identical source tracks, both
          # clean, one damaged output track. delta <= 0 keeps REVIEW.
          if [ "$g_net" -gt 0 ]; then
            g_ambig=0
            g_beyond="beyond the MOST FORGIVING candidate baseline — damage exceeds every candidate baseline, proven regardless of which source track corresponds"
            g_beyond_note="$g_net beyond the MOST FORGIVING of candidate source track(s) [$g_cands] (best candidate: $g_base) — damage exceeds every candidate baseline, proven regardless of which source track corresponds"
            echo "        Every candidate is BELOW the output count, so the delta is positive whichever"
            echo "        one corresponds: damage exceeds every candidate baseline — proven regardless"
            echo "        of which source track corresponds. This does NOT need the ambiguity resolved."
          else
            g_ambig_why="candidate set left ambiguous by channels/rate/codec/language/title, and the most forgiving of candidate source track(s) [$g_cands] still reproduces every line (delta $g_net)"
            echo "        An unidentified baseline cannot prove damage — REVIEW, never an unwaivable FAIL."
          fi
          ;;
        none)
          # P1c: NO source audio is maximal CERTAINTY, not maximal doubt. There
          # was never a candidate set to be ambiguous about: every audio line in
          # the output is new by construction, because there is no source audio
          # for it to have been inherited from. Routed to the normal damage path
          # (the HEAD verdict: FAIL + other_failed), with a baseline of 0 that is
          # measured by the container census, not guessed.
          g_base=0
          g_net="$g_err"
          g_beyond="new by construction — the source carries NO audio track to inherit them from"
          g_beyond_note="all $g_net of them new by construction — the source carries NO audio track at all, so no inherited-noise explanation exists"
          echo "   a:$gi source-baseline: $g_why, so the baseline is 0 BY CONSTRUCTION —"
          echo "        every audio line in this output is new ($g_err line(s), delta $g_net). Attribution"
          echo "        here is CERTAIN, not ambiguous: there was never a candidate set to choose from."
          ;;
        *)
          # defensive: an unforeseen mode word. Unattributed is not proven, so
          # REVIEW — but it must not borrow the ambiguity arm's sentence, which
          # names a candidate set this branch never had.
          g_ambig=1
          g_ambig_why="no source correspondence could be established at all, so there was nothing to subtract"
          echo "   a:$gi source-baseline: $g_why — the raw"
          echo "        count stands unattributed ($g_err line(s)); nothing to subtract."
          echo "        Unattributed is not proven — REVIEW, never an unwaivable FAIL."
          ;;
      esac
    fi
    if [ "$g_tag_ok" -eq 0 ]; then
      # F2 ORDERING: ambiguity is judged BEFORE the inherited arm. Both end at
      # REVIEW, but the inherited arm claims "the source reproduces them", and
      # that sentence is not available when the gate could not say WHICH source
      # track it was differencing against.
      if [ "${g_ambig:-0}" -eq 1 ] && [ "${g_err:-1}" -ne 0 ]; then
        [ "$verdict" = FAIL ] || verdict=REVIEW
        echo "   a:$gi tag='${g_tag:-none}' (codec ${g_cod:-unknown}): NOT on the QTFF audio"
        echo "        allowlist, and its $g_err decode line(s) could not be ATTRIBUTED — this gate"
        echo "        did not identify a source track to difference against (see above). Advisory,"
        echo "        not the dead-track class."
        echo "        Prove the render before shipping: scripts/playable-check.sh OUT"
        note="${note:+$note }Audio track a:$gi carries the unbenched sample-entry tag '${g_tag:-none}' (codec ${g_cod:-unknown}) and shows $g_err decode line(s) that could not be attributed to a source track (no unambiguous baseline) — an advisory, not the dead-track class; prove QuickTime playback before shipping."
      elif [ "${g_net:-1}" -le 0 ] && [ "${g_err:-1}" -ne 0 ]; then
        # off-list AND the lines all reproduce on the source: inherited/open-time
        # noise sitting on top of an unbenched tag. Not the dead-track class
        # (that class is defined by lines the SOURCE does not have), so it takes
        # the same advisory REVIEW the clean-decode arm takes — with the delta.
        [ "$verdict" = FAIL ] || verdict=REVIEW
        echo "   a:$gi tag='${g_tag:-none}' (codec ${g_cod:-unknown}): NOT on the QTFF audio"
        echo "        allowlist, and its $g_err decode line(s) are FULLY REPRODUCED on the source"
        echo "        (delta $g_net) — inherited/open-time noise, not a dead sample entry."
        echo "        Prove the render before shipping: scripts/playable-check.sh OUT"
        note="${note:+$note }Audio track a:$gi carries the unbenched sample-entry tag '${g_tag:-none}' (codec ${g_cod:-unknown}); its $g_err decode line(s) reproduce on the source under the identical bounded decode (delta $g_net), so this is inherited noise plus an unbenched tag — an advisory, not the dead-track class."
      elif [ "${g_err:-1}" -eq 0 ]; then
        # unrecognized BUT it decodes — the ipcm class before 1.13 knew about
        # it. Advisory REVIEW: an entry this plugin has not benched is a real
        # unknown for OTHER players, but it is not a dead track and it is not
        # an unwaivable essence FAIL.
        [ "$verdict" = FAIL ] || verdict=REVIEW
        echo "   a:$gi tag='${g_tag:-none}' (codec ${g_cod:-unknown}): NOT on the QTFF audio"
        echo "        allowlist, but the bounded head decode is CLEAN — so it is not the"
        echo "        dead-sample-entry class. Advisory, not a FAIL (D3, 1.13): unbenched"
        echo "        here means unproven in QuickTime, not unclaimed by every decoder."
        echo "        Prove the render before shipping: scripts/playable-check.sh OUT"
        note="${note:+$note }Audio track a:$gi carries the unbenched sample-entry tag '${g_tag:-none}' (codec ${g_cod:-unknown}); it decodes cleanly, so this is an advisory, not the dead-track class — prove QuickTime playback before shipping."
      else
        verdict=FAIL; other_failed=1
        echo "   a:$gi tag='${g_tag:-none}' (codec ${g_cod:-unknown}) — NOT on the QTFF audio allowlist"
        echo "        AND it does not decode ($g_err error line(s) in the first ${WIN}s, $g_net $g_beyond):"
        echo "        a sample entry no decoder claims (the dead-HDMV-track class, entry 1)."
        echo "        Do not ship; rebuild the audio via mov.sh's default routing (container-"
        echo "        framed LPCM decodes to a raw-PCM access track)."
        note="${note:+$note }Audio track a:$gi carries sample-entry tag '${g_tag:-none}' outside the QTFF allowlist AND fails to decode ($g_err error line(s), $g_beyond_note) — a dead track no decoder claims (entry 1: an 18.5 GB Blu-ray pcm_bluray copy-mux shipped 'verified' with unplayable audio, 2026-08-13); mov.sh's default routing rebuilds it as raw PCM."
      fi
    else
      g_tagword="allowlisted"; [ "$g_qtff" -eq 1 ] || g_tagword="tag N/A (non-QTFF)"
      if [ "${g_err:-1}" -eq 0 ]; then
        echo "   a:$gi tag='${g_tag:-n/a}' (codec $g_cod): $g_tagword; head decode clean."
      elif [ "${g_ambig:-0}" -eq 1 ]; then
        # F2: allowlisted tag, decode lines, no identified baseline. Ahead of
        # the inherited arm for the same reason as above — "the source
        # reproduces them" is a claim about a specific source track.
        [ "$verdict" = FAIL ] || verdict=REVIEW
        echo "   a:$gi tag='${g_tag:-n/a}' (codec $g_cod): $g_tagword; $g_err decode line(s) in the"
        echo "        first ${WIN}s that this gate could NOT attribute — no unambiguous source track to"
        echo "        difference against (see above). REVIEW on unproven attribution, not FAIL."
        note="${note:+$note }Audio track a:$gi shows $g_err decode line(s) in the first ${WIN}s, but gate (g) could not identify a single source track to baseline against ($g_ambig_why), so the lines are unattributed rather than proven to be remux damage — listen before archiving."
      elif [ "${g_net:-1}" -le 0 ]; then
        # P1.6 layer 3: the lines are all present on the SOURCE under the
        # identical bounded decode — inherited damage or open-time parse noise
        # (the late-sps class: 306 lines on the source and 306 on the output
        # under this gate's own bounded decode), never remux damage. REVIEW
        # carrying the evidence, and NOT other_failed: a remux cannot fix
        # source damage, and this is exactly how (c)/(e) classify the shape.
        [ "$verdict" = FAIL ] || verdict=REVIEW
        echo "   a:$gi tag='${g_tag:-n/a}' (codec $g_cod): $g_tagword; $g_err decode line(s) in the"
        echo "        first ${WIN}s, but the IDENTICAL decode of the source reproduces them (delta"
        echo "        $g_net) — inherited/open-time noise, not a remux defect. REVIEW, not FAIL."
        note="${note:+$note }Audio track a:$gi shows $g_err decode line(s) in the first ${WIN}s that the source reproduces under the identical bounded decode (source: $g_base / output: $g_err / delta: $g_net) — capture-inherited damage or open-time parse noise, not remux damage; a remux cannot fix source damage. Listen before archiving."
      else
        verdict=FAIL; other_failed=1
        echo "   a:$gi tag='${g_tag:-n/a}' (codec $g_cod): $g_err decode error line(s) in the first ${WIN}s (want 0); $g_net $g_beyond."
        note="${note:+$note }Audio track a:$gi does not decode cleanly ($g_err error line(s) in the first ${WIN}s, $g_beyond_note) — no playable-audio guarantee; do not ship."
      fi
    fi
    # the MP2-with-no-access-track signature, collected per track and judged once
    if [ "$g_qtff" -eq 1 ]; then
      case "$g_tag" in
        .mp2) g_mp2_naked=1;;
        mp4a) { [ "$g_cod" = mp2 ] || { [ "$g_cod" = mp3 ] && [ "${g_src_mp2:-0}" -gt 0 ]; }; } && g_mp2_naked=1;;
      esac
    fi
    gi=$((gi+1))
  done
  if [ "$g_mp2_naked" -eq 1 ] && [ "${g_has_pcm:-0}" -eq 0 ]; then
    [ "$verdict" = FAIL ] || verdict=REVIEW
    echo "   >> MP2 audio with NO PCM access track — the configuration this gate used to"
    echo "      PASS while failing the ones that work (D3, 1.13). AVFoundation has no"
    echo "      MPEG Layer II path for mp4a/.mp2 tracks: no positive report of Layer II"
    echo "      decode in QuickTime X/AVFoundation exists in any container, and this"
    echo "      bench measured silence. The allowlist entry for .mp2 is legal ONLY as"
    echo "      dual-track's preserved original, where the PCM access track is what"
    echo "      plays. Rebuild: scripts/mov.sh (routes MP2 to dual-track automatically)"
    echo "      or scripts/remux.sh --audio pcm."
    note="${note:+$note }Output carries MP2 audio with no PCM access track — AVFoundation has no Layer II path, so this file has no playable audio in QuickTime (D3, 1.13); rebuild via mov.sh (dual-track) or remux.sh --audio pcm."
  fi
fi

if [ "$SILP" -eq 1 ]; then
  echo "-- (--silence) silence content-parity (source vs output audio) --"
  # The injected-silence signature: a re-timed build re-padded silence from t=0
  # on a filter-graph rebuild (mid-stream layout change) — hundreds of seconds of
  # silence with A/V durations still matching, so gate (f) passes it. Legitimate
  # resync gap-fill silence is bounded by the source's forward gaps (DISC_P_MISSING).
  nao=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$OUT" 2>/dev/null | LC_ALL=C sort -u | grep -c . || true)   # distinct indices: a program-bearing OUT lists each stream twice
  if [ "${nao:-0}" -eq 0 ]; then
    echo "   no audio in output — silence parity N/A."
  else
    SIL_DB="${RTM_SIL_DB:--50dB}"; SIL_MIN="${RTM_SIL_MIN:-5}"; SIL_TOL="${RTM_SIL_TOL:-2.0}"
    sil_total () {  # $1 file -> summed seconds of long-window silence across all audio tracks
      { ffmpeg -nostdin -nostats -v info "${FF_INPUT_OPTS[@]}" -i "$1" -map '0:a?' -vn \
          -af "silencedetect=n=${SIL_DB}:d=${SIL_MIN}" -f null - 2>&1 || true; } | \
        awk '{for(i=1;i<NF;i++) if($i=="silence_duration:") s+=$(i+1)} END{printf "%.3f", s+0}'
    }
    ssil=$(sil_total "$SRC"); osil=$(sil_total "$OUT")
    eval "$(disc_scan "$SRC")"
    # P1.4: the gap-fill budget is presentation-order loss, for the same reason
    # gate (f)'s is — this is a tolerance, and a coded-order figure inflated by a
    # reconstructed dts column would license injected silence it cannot account for.
    sil_budget=$(disc_budget_secs "${DISC_P_NA:-0}" "${DISC_P_MISSING:-0}")
    excess=$(awk "BEGIN{printf \"%.3f\", ($osil) - ($ssil) - (${sil_budget:-0}) - ($SIL_TOL)}")
    echo "   long-window silence (>=${SIL_MIN}s @ ${SIL_DB}): source=${ssil}s  output=${osil}s"
    echo "   allowed: source silence + gap-fill budget ${sil_budget:-0}s (presentation order; coded-order census ${DISC_MISSING:-0}s) + tolerance ${SIL_TOL}s"
    disc_budget_note "${DISC_P_NA:-0}" "${DISC_P_COUNT:-0}"
    if awk "BEGIN{exit !(($excess) > 0)}"; then
      verdict=FAIL; other_failed=1
      echo "   >> ${excess}s of silence in the output has NO counterpart in the source —"
      echo "      the injected-silence signature (a re-timed build re-padded from t=0,"
      echo "      e.g. an aresample first_pts=0 graph rebuild on a mid-stream layout"
      echo "      change). All audio after the first injected block is out of sync."
      note="${note:+$note }Output carries ${excess}s of long-window silence absent from the source (beyond the ${sil_budget:-0}s gap-fill budget) — injected-silence signature; do not ship (resync.sh refuses layout-change sources; see timeline-repair.md)."
    else
      echo "   silence parity consistent (within the gap-fill budget)."
    fi
  fi
fi

echo "-- master-purity (video-stream writing-library signatures) --"
# QTFF audit 5-3c: a file presented as copy-lineage whose VIDEO stream carries
# an encoder writing-library signature (x264/x265/Lavc) has a re-encode in its
# history. Scoped to the video stream ONLY — dual-track access audio
# legitimately carries Lavc tags, and a whole-file scan would false-alarm on
# every default deliverable. Informational WARN: it never changes the verdict
# (the essence gates above decide losslessness); it changes what the file may
# be CATALOGUED as. rung4.sh derivatives also carry mdta provenance keys.
vsig () {  # $1 file -> comma list of video writing-library signatures ("" = none)
  local f="$1" tag sei
  tag=$(ffp -v error -select_streams v:0 -show_entries stream_tags=encoder -of default=nw=1:nk=1 "$f" 2>/dev/null | head -1)
  case "$tag" in *x264*|*x265*|*Lavc*) : ;; *) tag="";; esac
  sei=$(ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$f" -map 0:v:0 -frames:v 60 -c copy -f mpegts - 2>/dev/null | \
        LC_ALL=C grep -aoE 'x264|x265|Lavc' | sort -u | paste -sd, - || true)
  printf '%s' "${tag:+$tag }${sei}"
}
osig=$(vsig "$OUT"); ssig=$(vsig "$SRC")
r4tag=$(ffp -v error -show_entries format_tags=com.apple.quicktime.rung4.reencoded-with-attestation -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1)
if [ -z "$osig" ]; then
  echo "   no writing-library signature in the output video — master-purity consistent."
elif [ -n "$r4tag" ]; then
  echo "   output video carries '$osig' and DECLARES itself a rung4 derivative (mdta"
  echo "   provenance present) — a derivative, correctly marked. Not a master."
elif [ -n "$ssig" ]; then
  echo "   ** PURITY NOTE: output video carries '$osig' — also present in the source"
  echo "      ('$ssig'), so it is inherited lineage, not remux damage. If this source is"
  echo "      catalogued as a broadcast master, that catalog entry deserves a second look."
else
  echo "   ** MASTER-PURITY WARN: output video carries writing-library signature"
  echo "      '$osig' that the source does NOT — a re-encode happened somewhere in this"
  echo "      pipeline. Do not catalog this file as a master; the only sanctioned"
  echo "      re-encode path is scripts/rung4.sh, which stamps mdta provenance."
fi

if [ "$FULL" -eq 1 ]; then
  if [ "$SRC_IS_H264" -eq 1 ]; then
    echo "-- (--full) whole-file decoded multiset + PRESENTATION ORDER (H.264) --"
    # For H.264 the VCL hash in (b) is the bit-exact lossless proof. A decoded
    # compare is corroboration only and must be ORDER/COUNT-tolerant: field-coded
    # rebuilds legitimately present a different frame count (field-vs-frame / edit
    # list), so a positional rawvideo md5 would FALSE-FAIL. Compare the sorted
    # multiset of frame hashes, and never FAIL on the multiset alone.
    # BUT: equal multiset + different SEQUENCE = the same frames presented in a
    # different ORDER — the decode-order/shuffled-motion defect a constant-rate
    # restamp inflicts on a reorder pyramid (post-mortem 2026-07-25). Every other
    # gate is blind to it (bits identical, decode clean, scrub clean). That IS
    # a FAIL: framemd5 presentation sequence of the output must equal the source.
    HLD="$(mktemp -d)"
    hlist () { ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$1" -map 0:v:0 -f framemd5 - 2>/dev/null \
                 | grep -v '^#' | awk -F', *' '{print $NF}'; }
    hlist "$SRC" > "$HLD/s"; hlist "$OUT" > "$HLD/o"
    s=$(sort "$HLD/s" | md5sum | awk '{print $1}'); d=$(sort "$HLD/o" | md5sum | awk '{print $1}')
    sq=$(md5sum < "$HLD/s" | awk '{print $1}'); dq=$(md5sum < "$HLD/o" | awk '{print $1}')
    echo "   source multiset=$s sequence=$sq"
    echo "   output multiset=$d sequence=$dq"
    if [ "$s" = "$d" ]; then
      if [ "$sq" = "$dq" ]; then
        echo "   PASS: decoded frames identical AND in the same presentation order."
        [ "$verdict" = REVIEW ] && { verdict=PASS; note=""; }
      else
        echo "   FAIL: same frames, DIFFERENT presentation order — the output plays"
        echo "   pictures in decode order (shuffled motion). A constant-rate restamp"
        echo "   of a reordered stream does exactly this; repair by MEASURED profile:"
        echo "   derive-dts.sh when every packet still carries PTS (PF_NOPTS_FRAC=0 —"
        echo "   any codec), pairfill-paff.sh for the half-timestamped H.264 PAFF class;"
        echo "   never rebuild-paff.sh."
        verdict=FAIL; other_failed=1
      fi
    else
      echo "   NOTE: decoded multiset differs — expected for a field-coded / edit-list"
      echo "   rebuild (different presented frame count). The VCL hash in (b) is the"
      echo "   authoritative lossless proof; not downgrading on this alone."
    fi
    rm -rf "$HLD"
  else
    echo "-- (--full) whole-file decoded-pixel identity (two full decodes) --"
    fmd5 () { ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$1" -map 0:v:0 -c:v rawvideo -f md5 - | sed 's/^MD5=//'; }
    s=$(fmd5 "$SRC"); d=$(fmd5 "$OUT")
    echo "   source=$s"
    echo "   output=$d"
    if [ "$s" = "$d" ]; then
      echo "   PASS: every decoded frame is bit-identical."
      [ "$verdict" = REVIEW ] && { verdict=PASS; note=""; }   # definitive check overrides sampled doubt
    else
      echo "   FAIL: decoded frames differ — output is NOT a lossless copy."
      verdict=FAIL; other_failed=1
    fi
  fi
fi

if [ "$SIG" -eq 1 ]; then
  echo "-- (--signaling) color / HDR / caption preservation (source vs output) --"
  sg () { ffp -v error -select_streams v:0 -show_entries stream="$2" -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1; }
  sdrift=0
  # sample_aspect_ratio rides the pasp atom — anamorphic broadcast (e.g. 40:33)
  # displays stretched/squeezed if it drops, and nothing else checks it (QTFF
  # audit 3d: pasp survives -c copy, but drift here used to ship silently)
  for k in color_primaries color_transfer color_space color_range sample_aspect_ratio; do
    a=$(sg "$SRC" "$k"); b=$(sg "$OUT" "$k")
    # undefined SAR (N/A / 0:1) in the source is not a signal; don't false-DRIFT
    # against a defaulted 1:1 in the output
    if [ "$k" = sample_aspect_ratio ]; then case "$a" in ''|N/A|0:1) echo "   $k: source undefined — skipped"; continue;; esac; fi
    if [ "$a" != "$b" ]; then echo "   $k: source=$a output=$b  (DRIFT)"; sdrift=1; else echo "   $k=$a (preserved)"; fi
  done
  if [ "$PF_CODEC" = hevc ]; then
    # container-gated (1.14 / DF-14): hvc1 is a QTFF SAMPLE-ENTRY tag; a non-QTFF
    # output (e.g. an MKV cross-check) has no such tag to assert, and calling its
    # absence DRIFT was a false verdict. Same container test gate (g) computes
    # (g_qtff): format_name contains mov/mp4. Non-QTFF -> announced skip.
    sg_ofmt=$(ffp -v error -show_entries format=format_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1)
    sg_qtff=0; case ",$sg_ofmt," in *,mov,*|*,mp4,*) sg_qtff=1;; esac
    if [ "$sg_qtff" -eq 1 ]; then
      t=$(ffp -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1)
      [ "$t" = hvc1 ] && echo "   HEVC tag=hvc1 (QuickTime-playable)" || { echo "   HEVC tag=$t — NOT hvc1; QuickTime won't play it (DRIFT)"; sdrift=1; }
    else
      echo "   HEVC tag: output container '$sg_ofmt' is not QTFF — hvc1 assertion skipped (tag N/A)"
    fi
  fi
  ccs=$(ffp -v error -select_streams v:0 -show_entries stream=closed_captions -of default=nw=1:nk=1 "$SRC" 2>/dev/null | head -1)
  cco=$(ffp -v error -select_streams v:0 -show_entries stream=closed_captions -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1)
  if [ "${ccs:-0}" = 1 ] && [ "${cco:-0}" != 1 ]; then echo "   closed captions: present in source, MISSING in output (DRIFT)"; sdrift=1
  else echo "   closed captions: source=${ccs:-0} output=${cco:-0}"; fi
  hs=$(ffp -v error -select_streams v:0 -read_intervals "%+#1" -show_entries frame=side_data_type -of csv=p=0 "$SRC" 2>/dev/null | tr '\n' ';')
  ho=$(ffp -v error -select_streams v:0 -read_intervals "%+#1" -show_entries frame=side_data_type -of csv=p=0 "$OUT" 2>/dev/null | tr '\n' ';')
  case "$hs" in *"Mastering display"*|*"Content light"*)
    case "$ho" in *"Mastering display"*|*"Content light"*) echo "   HDR mastering/CLL side data preserved";;
      *) echo "   HDR mastering/CLL side data in source, MISSING in output (DRIFT)"; sdrift=1;; esac;;
  esac
  [ "$sdrift" -eq 0 ] && echo "   signaling: no drift" || { [ "$verdict" = FAIL ] || verdict=REVIEW; note="${note:+$note }Signaling/caption drift (see --signaling)."; }
fi

if [ "$AUD" -eq 1 ]; then
  echo "-- (--audio) dual-track audio fidelity (PCM access + preserved original) --"
  na=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$OUT" 2>/dev/null | LC_ALL=C sort -u | grep -c . || true)   # distinct indices: a program-bearing OUT lists each stream twice
  a0c=$(ffp -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1)
  if [ "${na:-0}" -lt 2 ]; then
    echo "   output has ${na:-0} audio track(s); dual-track checks need PCM access + original. Skipping."
  elif case "$a0c" in pcm_*) false;; *) true;; esac; then
    echo "   a:0 is '$a0c', not PCM — not a dual-track-access layout. Skipping."
  else
    raw=${a0c#pcm_}
    a1c=$(ffp -v error -select_streams a:1 -show_entries stream=codec_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1)
    drc=""; case "$a1c" in ac3|eac3) drc="-drc_scale 0";; esac     # match dual-track.sh's default
    s1=$(ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$SRC" -map 0:a:0 -c copy -f streamhash -hash md5 - 2>/dev/null || true)
    o1=$(ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$OUT" -map 0:a:1 -c copy -f streamhash -hash md5 - 2>/dev/null || true)
    if [ -n "$s1" ] && [ "$s1" = "$o1" ]; then echo "   original track (a:1): bit-exact vs source — preserved."
    else
      # Repacketization tolerance (1.11 fix round) — gate (a)'s own doctrine
      # applied to the preserved track: TS/ADTS AAC is reframed to ASC by the
      # MOV mux (the automatic aac_adtstoasc, the verified non-issue in
      # references/known-limits.md), so the raw packet hash differs while the
      # AAC payload is bit-identical — the pre-fix gate called that "provenance
      # track corrupted" and FAILed the flagship --always-dual deliverable on
      # a genuinely intact original. Before crying corruption, re-hash the
      # SOURCE through the same reframing and compare again. AAC-only ON
      # PURPOSE: every other preserved-original codec (ac3/eac3/dts/mp2)
      # copies frame-for-frame, so a raw-hash mismatch there stays a FAIL.
      a1_ok=0
      s0c=$(ffp -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$SRC" 2>/dev/null | head -1)
      if [ "$s0c" = aac ] && [ "$a1c" = aac ]; then
        s1a=$(ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$SRC" -map 0:a:0 -c copy -bsf:a aac_adtstoasc -f streamhash -hash md5 - 2>/dev/null || true)
        if [ -n "$s1a" ] && [ "$s1a" = "$o1" ]; then
          echo "   original track (a:1): bit-exact vs source after ADTS->ASC reframing — preserved"
          echo "   (the mux's automatic aac_adtstoasc: payload identical, framing headers"
          echo "   differ by container rule — references/known-limits.md, verified non-issue)."
          a1_ok=1
        fi
      fi
      if [ "$a1_ok" -eq 0 ]; then
        echo "   original track (a:1): NOT bit-exact vs source — provenance track corrupted."
        verdict=FAIL; other_failed=1
      fi
    fi
    # --- D4 (1.13): "misaligned" must be a MEASUREMENT, not a hash inequality --
    # The pre-1.13 gate md5'd both tracks WHOLE and called any difference
    # "Dual-track audio misaligned" — a TIMING claim a whole-track hash cannot
    # support, since any length delta flips the hash. The field report hit
    # exactly that: a 1040-sample length delta equal to the tracks' declared
    # start_pts, cross-correlation 1.000000 at offset 0, zero differing samples
    # in the overlap — reported as "misaligned", inviting a "fix" that would
    # have introduced real desync. So: hash whole first (unchanged fast path);
    # on a mismatch, MEASURE — lengths, declared start_pts, and the content of
    # the common window (tail-trimmed, then head-trimmed by the delta) — and
    # keep the word "misaligned" for a mismatch that survives all of it.
    dec_md5 () {  # dec_md5 TRACK [FILTER] [DRC] -> md5 of the decoded track
      # shellcheck disable=SC2086
      ffmpeg -nostdin -v error ${3:-} "${FF_INPUT_OPTS[@]}" -i "$OUT" -map "0:a:$1" \
        ${2:+-af "$2"} -c:a "$a0c" -f "$raw" - 2>/dev/null | md5sum | awk '{print $1}'
    }
    dec_len () {  # dec_len TRACK [DRC] -> decoded byte count
      # shellcheck disable=SC2086
      ffmpeg -nostdin -v error ${2:-} "${FF_INPUT_OPTS[@]}" -i "$OUT" -map "0:a:$1" \
        -c:a "$a0c" -f "$raw" - 2>/dev/null | wc -c | tr -d ' '
    }
    d0=$(dec_md5 0); d1=$(dec_md5 1 "" "$drc")
    if [ "$d0" = "$d1" ]; then
      echo "   access track (a:0 PCM): == decoded original, aligned."
    else
      ach=$(ffp -v error -select_streams a:0 -show_entries stream=channels    -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1)
      asr=$(ffp -v error -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 "$OUT" 2>/dev/null | head -1)
      case "$a0c" in pcm_s16le) bps=2;; pcm_s24le) bps=3;; pcm_s32le|pcm_f32le) bps=4;; pcm_s8|pcm_u8) bps=1;; *) bps=0;; esac
      case "$ach" in ''|*[!0-9]*) ach=0;; esac
      case "$asr" in ''|*[!0-9]*) asr=0;; esac
      bpf=$((bps * ach))
      spo () {  # spo TRACK -> declared start offset in SAMPLES (0 if undeclared)
        ffp -v error -select_streams "a:$1" -show_entries stream=start_pts,time_base \
            -of default=nw=1:nk=1 "$OUT" 2>/dev/null | \
          awk -v r="$asr" 'NR==1{p=$0} NR==2{split($0,t,"/");
            if(p=="N/A"||p==""||t[2]+0==0||r+0==0){print 0; exit}
            printf "%.0f", p*t[1]/t[2]*r}'
      }
      n0=$(dec_len 0); n1=$(dec_len 1 "$drc")
      sp0=$(spo 0); sp1=$(spo 1)
      case "$sp0" in ''|*[!0-9]*) sp0=0;; esac
      case "$sp1" in ''|*[!0-9]*) sp1=0;; esac
      echo "   access track (a:0) whole-track hash differs from the decoded original — measuring:"
      if [ "$bpf" -le 0 ] || [ "${n0:-0}" -le 0 ] || [ "${n1:-0}" -le 0 ]; then
        echo "     decoded bytes a:0=$n0 a:1=$n1 (frame size unknown for '$a0c' — cannot"
        echo "     convert to samples). Not claiming a timing verdict on this evidence."
        [ "$verdict" = FAIL ] || verdict=REVIEW
        note="${note:+$note }Dual-track access/original decodes differ and the sample geometry could not be measured — inspect before shipping."
      else
        dbytes=$((n0 - n1)); [ "$dbytes" -lt 0 ] && dbytes=$((-dbytes))
        dsamp=$((dbytes / bpf)); nmin=$n0; [ "$n1" -lt "$n0" ] && nmin=$n1
        nsmin=$((nmin / bpf))
        spd=$((sp0 - sp1)); [ "$spd" -lt 0 ] && spd=$((-spd))
        echo "     decoded samples a:0=$((n0 / bpf)) a:1=$((n1 / bpf)) (delta $dsamp), declared start_pts a:0=$sp0 a:1=$sp1 samples"
        # (i) same content, one track longer at the TAIL
        t0=$(dec_md5 0 "atrim=end_sample=$nsmin"); t1=$(dec_md5 1 "atrim=end_sample=$nsmin" "$drc")
        if [ "$t0" = "$t1" ]; then
          expl=""
          if [ "$dsamp" -eq "$spd" ] && [ "$spd" -ne 0 ]; then expl="= the declared start_pts DELTA"
          elif [ "$dsamp" -eq "$sp0" ] && [ "$sp0" -ne 0 ]; then expl="= a:0's declared start_pts"
          elif [ "$dsamp" -eq "$sp1" ] && [ "$sp1" -ne 0 ]; then expl="= a:1's declared start_pts"; fi
          if [ -n "$expl" ]; then
            echo "     >> ALIGNED at offset 0: the $nsmin-sample common window is byte-identical;"
            echo "        the $dsamp-sample length delta $expl (container-declared start offset,"
            echo "        not drift). This is the field-report signature (2026-08-15) the"
            echo "        pre-1.13 whole-track hash reported as 'misaligned' — it is not."
          else
            echo "     >> content ALIGNED at offset 0 over the $nsmin-sample common window, but the"
            echo "        $dsamp-sample length delta is NOT explained by either track's declared"
            echo "        start_pts (a:0=$sp0 a:1=$sp1). Aligned where they overlap; the tail is the"
            echo "        review item — a truncated or over-long access track, not desync."
            [ "$verdict" = FAIL ] || verdict=REVIEW
            note="${note:+$note }Dual-track audio: content identical over the ${nsmin}-sample common window (offset 0), but an unexplained ${dsamp}-sample length delta remains (declared start_pts a:0=$sp0 a:1=$sp1) — a tail-length question, not a sync one."
          fi
        else
          # (ii) same content, one track longer at the HEAD (shift by the delta)
          h0=$t0; h1=$t1; shifted=no
          if [ "$dsamp" -gt 0 ]; then
            if [ "$n0" -gt "$n1" ]; then
              h0=$(dec_md5 0 "atrim=start_sample=$dsamp,atrim=end_sample=$nsmin")
              h1=$(dec_md5 1 "atrim=end_sample=$nsmin" "$drc")
            else
              h0=$(dec_md5 0 "atrim=end_sample=$nsmin")
              h1=$(dec_md5 1 "atrim=start_sample=$dsamp,atrim=end_sample=$nsmin" "$drc")
            fi
            [ "$h0" = "$h1" ] && shifted=yes
          fi
          if [ "$shifted" = yes ]; then
            echo "     >> OFFSET by exactly $dsamp samples ($(awk -v s="$dsamp" -v r="$asr" 'BEGIN{printf "%.3f", (r>0? s/r : 0)}')s): the tracks carry the SAME"
            echo "        samples with one leading the other. That IS a sync defect (the access"
            echo "        track and the preserved original do not start together)."
            [ "$verdict" = FAIL ] || verdict=REVIEW
            note="${note:+$note }Dual-track audio offset by ${dsamp} samples (same content, shifted head) — the access track and the preserved original do not start together."
          else
            echo "     >> MISALIGNED: the common window differs even after trimming to equal"
            echo "        length and after shifting by the measured delta — the decodes are"
            echo "        not the same audio, which no start_pts explains."
            [ "$verdict" = FAIL ] || verdict=REVIEW
            note="${note:+$note }Dual-track audio misaligned: the ${nsmin}-sample common window differs at offset 0 and at the measured ${dsamp}-sample shift."
          fi
        fi
      fi
    fi
  fi
fi

case "$verdict" in
  PASS)
    if [ "$bitproven" -eq 1 ] || [ "$FULL" -eq 1 ]; then echo ">> OK (lossless proven; timeline scrub-clean)"
    else echo ">> OK (sampled checks; scrub-clean; for archival sign-off run again with --full)"; fi ;;
  REVIEW) echo ">> REVIEW: $note" ;;
  FAIL)
    # QTFF audit 5-4c: emit the exact failure signature (class + count) when the
    # FAIL comes only from the count-signature gates (d)/(e), then consult an
    # operator-attested waiver sidecar. An EXACT match — same gate set, same
    # counts, same file bytes-identity, verbatim attestation — exits 0 with a
    # loud WAIVED line; any drift voids the waiver and the FAIL stands.
    WVR="$OUT.waiver.json"
    wgate=""; wsig=""
    if [ "$other_failed" -eq 0 ]; then
      if   [ "$d_failed" -eq 1 ] && [ "$e_failed" -eq 1 ]; then wgate="d+e"
      elif [ "$d_failed" -eq 1 ]; then wgate="d"
      elif [ "$e_failed" -eq 1 ]; then wgate="e"; fi
    fi
    if [ -n "$wgate" ]; then
      [ "$d_failed" -eq 1 ] && wsig="d:napts=${TL_NAPTS:-0},nadts=${TL_NADTS:-0},back=${TL_BACK:-0},dup=${TL_DUP:-0},tiny=${TL_TINY:-0}"
      [ "$e_failed" -eq 1 ] && wsig="${wsig:+$wsig;}e:dec_src=${b_dec:-0},dec_out=${o_dec:-0},mux_src=${b_mux:-0},mux_out=${o_mux:-0}"
      osize=$(wc -c < "$OUT" | tr -d ' ')
      case "$op" in *MD5=*) vh="${op##*MD5=}";; *) vh=none;; esac
      echo "VERIFY_SIGNATURE gate=$wgate sig='$wsig' size=$osize vhash=$vh"
      if [ -f "$WVR" ]; then
        wv () { awk -F'"' -v k="$1" '$2==k{print $4; exit}' "$WVR"; }
        rgate=$(wv gate); rsig=$(wv signature); ratt=$(wv attestation); rvh=$(wv video_streamhash)
        rsize=$(sed -n 's/^[[:space:]]*"file_size":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$WVR" | head -1)
        if [ "$rgate" = "$wgate" ] && [ "$rsig" = "$wsig" ] && [ "$rsize" = "$osize" ] && \
           [ "$rvh" = "$vh" ] && [ "$ratt" = "$RTM_WAIVER_ATTEST" ]; then
          echo ">> WAIVED($wgate): this exact gate failure is covered by the operator-attested"
          echo "   waiver sidecar $WVR"
          echo "   Scope: THIS file, THIS signature only — any new signature or changed count"
          echo "   voids it. The recorded proofs and coverage limits live in the sidecar."
          echo "VERIFY_SUMMARY verdict=WAIVED gate=$wgate sig='$wsig' sidecar='$WVR'"
          exit 0
        fi
        att_ok=NO; [ "$ratt" = "$RTM_WAIVER_ATTEST" ] && att_ok=yes
        echo ">> waiver sidecar present but VOID — it does not match this run:"
        echo "   recorded: gate=${rgate:-?} sig=${rsig:-?} size=${rsize:-?} vhash=${rvh:-?} attestation-ok=$att_ok"
        echo "   this run: gate=$wgate sig=$wsig size=$osize vhash=$vh"
        echo "   A changed signature or file is NEW evidence — a waiver never transfers; re-investigate."
      else
        echo "   (if independent proofs show this exact failure benign for this file,"
        echo "    scripts/waiver.sh can record an operator-attested waiver sidecar)"
      fi
    elif [ -f "$WVR" ]; then
      echo ">> waiver sidecar present but this FAIL is NOT waiver-eligible: an essence/identity"
      echo "   gate failed ((b)/--full/--audio) — a waiver never covers a lossless-proof failure."
    fi
    echo ">> FAIL (see above)"; exit 1 ;;
esac
