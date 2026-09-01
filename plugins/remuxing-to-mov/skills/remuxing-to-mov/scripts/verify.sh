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
# ">> REVIEW" -> their own exit 10). BECAUSE CALLERS MATCH THOSE STRINGS
# ANYWHERE IN THE OUTPUT, no GATE may print the exact tokens ">> OK",
# ">> REVIEW" or ">> FAIL" — a gate that does silently re-grades the run
# (measured 2026-08-29: gate (l) printing ">> REVIEW:" returned REVIEW for a
# build whose gate (h) had FAILED). Gates say ">> gate (x) FAILS/FLAGS:".
# Coding a caller to this script's exit
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

# --- the UNPROVEN ledger (gate (n), 1.16.0) ---------------------------------
# Constitution: "a verifier states what it could not prove". Until now a gate
# that could not run left NO TRACE in the report — the reader saw the gates
# that spoke and had no way to know which ones had not. That is the quiet
# assumption this whole round exists to close: on 2026-08-28 two builds passed
# every check the plugin HAD, and the checks it did not have said nothing.
#
# Every gate files a row here, including the ones that could not run:
#   pass        ran, judged, clean
#   fail        ran, judged, defect
#   unproven    OWED on this input and could not be evaluated -> forces REVIEW
#   n/a         does not apply to this input (wrong codec/container) -> no effect
#   flagged     ran, judged, raised a concern short of FAIL (it set REVIEW itself)
#   superseded  a cheaper gate was inconclusive and a stronger one settled it
# The distinction between `unproven` and `n/a` is the whole design: without it
# every run reads REVIEW and the signal is worthless.
# Deliberately a VARIABLE, not a temp file: lib-exit.sh records that a plain
# cleanup EXIT trap makes an expansion death report 0 on bash 3.2, and this
# script's whole contract is its printed verdict. No trap, no hazard.
LEDGER=""
led () {   # gate, verdict, why
  LEDGER="${LEDGER}$1|$2|$3
"
}

# Does the output carry a video stream at all? The distinction matters to
# every video gate below and it is the difference between two honest words:
# "n/a" (there is nothing here to judge) and "unproven" (there is, and I could
# not read it). Collapsing them either cries wolf on an audio-only deliverable
# or lets an unreadable video track pass as clean.
set +e; o_vidx=$(ffp1 -v error -select_streams v:0 -show_entries stream=index -of default=nw=1:nk=1 "$OUT" 2>/dev/null); o_vidx_rc=$?; set -e
O_HAS_VIDEO=0
case "${o_vidx:-}" in ''|*[!0-9]*) ;; *) O_HAS_VIDEO=1;; esac

echo "== verify: $OUT vs $SRC =="

echo "-- (a) packet-hash identity (demux only, no decode) --"
phash () { ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$1" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null || true; }
# VCL-payload hash: strip SPS(7)/PPS(8)/AUD(9)/SEI(6) so parameter-set placement
# (TS in-band vs MOV avcC) and a Rung-3 repacketization cannot false-mismatch.
# What remains is the coded picture data — the correct lossless arbiter for H.264,
# and the reason decoded framemd5 is NOT used here: it FALSE-FAILs field-coded
# (PAFF) streams (field-vs-frame packaging) and any re-timed rebuild.
vcl_hash () { local b=""; \
  [ "$(ffp1 -v error -select_streams v:0 -show_entries stream=is_avc -of default=nw=1:nk=1 "$1" 2>/dev/null)" = true ] && b="h264_mp4toannexb,"; \
  ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$1" -map 0:v:0 -c:v copy -bsf:v "${b}filter_units=remove_types=6|7|8|9" -f streamhash -hash md5 - 2>/dev/null || true; }
sp=$(phash "$SRC"); op=$(phash "$OUT")
if [ -n "$sp" ] && [ "$sp" = "$op" ]; then
  echo "   PASS: video packets bit-identical — lossless proven, no decode needed."
  bitproven=1
  led a pass "video packet streamhash identical"
else
  echo "   inconclusive (expected for TS sources / Rung-3 rebuilds: packets get"
  echo "   re-framed even when the video is identical) — checking the essence."
  bitproven=0
  led a superseded "packet hash inconclusive by design on a re-framed copy — (b) settles it"
fi

if [ "$bitproven" -eq 0 ]; then
  if [ "$SRC_IS_H264" -eq 1 ] && [ "$HAVE_VCL" -eq 1 ]; then
    echo "-- (b) VCL-payload identity (demux only; lossless arbiter for H.264) --"
    sv=$(vcl_hash "$SRC"); ov=$(vcl_hash "$OUT")
    # EMPTY ≠ ABSENT (CHECKUP-2026-08-27 C3 / WO-1.15.4): an empty hash is a
    # TOOL failure (vcl_hash ends || true), not slice data — the accusation
    # arm is reachable only on two NON-EMPTY differing hashes. Empty-side
    # verdict mirrors the degraded-env arm: cannot cheaply prove, REVIEW.
    if [ -z "$sv" ] || [ -z "$ov" ]; then
      echo "   VCL hash could not be computed (src=$([ -n "$sv" ] && echo ok || echo EMPTY) out=$([ -n "$ov" ] && echo ok || echo EMPTY))"
      echo "   — no evidence either way: INCONCLUSIVE, not a mismatch. Settle with --full."
      [ "$verdict" = FAIL ] || verdict=REVIEW
      note="${note:+$note }VCL hash pass produced no output on one side (tool/decode failure) — losslessness UNPROVEN, not disproven; settle with --full."
      led b unproven "the VCL hash pass produced no output on one side (tool failure, not slice data)"
    elif [ "$sv" = "$ov" ]; then
      echo "   VCL MATCH: coded picture data bit-identical — lossless proven"
      echo "   (survives TS->MOV and field-rate rebuilds; framemd5 would false-FAIL here)."
      bitproven=1
      led b pass "VCL payload hash identical"
    else
      echo "   VCL MISMATCH — slice data differs; output is NOT a lossless copy."
      echo "     src=$sv"
      echo "     out=$ov"
      verdict=FAIL; other_failed=1
      led b fail "VCL payload hashes differ (src=$sv out=$ov)"
      VCL_MISMATCH=1
    fi
  elif [ "$SRC_IS_H264" -eq 1 ] && [ "$PF_PAFF" = yes ]; then
    # Degraded env (no filter_units) + field-coded: VCL is unavailable and decoded
    # framemd5 FALSE-FAILs PAFF — so we must NOT FAIL. Flag for a definitive check.
    echo "-- (b) lossless essence: VCL hash unavailable for a field-coded source --"
    echo "   filter_units/h264_mp4toannexb missing in this ffmpeg, and decoded"
    echo "   framemd5 false-FAILs field-coded streams — cannot cheaply prove lossless."
    [ "$verdict" = FAIL ] || verdict=REVIEW
    note="${note:+$note }VCL check unavailable (upgrade ffmpeg, or run --full); field-coded source can't be cheaply proven lossless."
    led b unproven "this ffmpeg has no filter_units/h264_mp4toannexb and framemd5 false-FAILs field-coded streams"
  else
    echo "-- (b) decoded spot-identity: first $N frames + packet-count parity --"
    fhead () { ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$1" -map 0:v:0 -frames:v "$N" -f framemd5 - 2>/dev/null \
                 | grep -v '^#' | awk -F', *' '{print $NF}' || true; }
    sh=$(fhead "$SRC"); oh=$(fhead "$OUT")
    # EMPTY ≠ ABSENT (CHECKUP-2026-08-27 C3 / WO-1.15.4): fhead ends || true,
    # so an empty hash list is a DECODE failure, not differing frames — the
    # measured pre-fix arm read empty==empty as "frames differ; NOT a
    # lossless copy". Accuse only on two NON-EMPTY differing hash lists.
    if [ -z "$sh" ] || [ -z "$oh" ]; then
      echo "   head sample: could not decode (src=$([ -n "$sh" ] && echo ok || echo EMPTY) out=$([ -n "$oh" ] && echo ok || echo EMPTY))"
      echo "   — no evidence either way: INCONCLUSIVE, not a mismatch. Settle with --full."
      [ "$verdict" = FAIL ] || verdict=REVIEW
      note="${note:+$note }Head-sample decode produced no frames on one side (tool/decode failure) — losslessness UNPROVEN, not disproven; settle with --full."
    elif [ "$sh" = "$oh" ]; then
      echo "   head sample: MATCH ($N decoded frames identical)"
    else
      echo "   head sample: FAIL — decoded frames differ; output is NOT a lossless copy."
      verdict=FAIL; other_failed=1
    fi
    # TS sources list the stream under its program AND top-level -> dedupe to one line
    pkts () { ffp1 -v error -select_streams v:0 -count_packets \
                -show_entries stream=nb_read_packets -of default=nw=1:nk=1 "$1" 2>/dev/null; }
    spk=$(pkts "$SRC"); opk=$(pkts "$OUT")
    echo "   video packets: source=$spk output=$opk"
    if [ "$spk" != "$opk" ] && [ "$verdict" = PASS ]; then
      verdict=REVIEW
      note="packet counts differ — fine after a Rung-3 rebuild (repacketization), otherwise possible truncation. Settle with --full."
    fi
  fi
fi

if [ "$O_HAS_VIDEO" -eq 0 ]; then led c "n/a" "the output carries no video stream to spot-decode"; fi
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
if [ "${errs:-0}" -eq 0 ] && [ "$O_HAS_VIDEO" -eq 1 ]; then
  led c pass "spot-window decode produced no error line"
fi
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
# ONE PASS, three gates (Constitution IV.2 — never re-derive what is already
# read). (d) takes the N/A counts, the DTS monotonicity and the duration
# histogram; (j) takes PTS UNIQUENESS and DTS<=PTS from the same rows; (l)
# takes the minimum PTS for the first-displayed-frame anchor.
eval "$(ffp -v error -select_streams v:0 -show_entries packet=pts,dts,duration -of csv=p=0 "$OUT" 2>/dev/null | \
  awk -F, 'NF{
      n++
      p=""; if($1!="N/A" && $1!=""){ p=$1+0
        if(pc[$1]++ == 1) dupp++          # a SECOND holder of this rung
        if(!hp || p<minp){ minp=p; hp=1 }
        if(!hx || p>maxp){ maxp=p; hx=1 }
      } else nap++
      if($2=="N/A"||$2==""){ nad++ } else { d=$2+0
        if(hav){ if(d<pd) back++; else if(d==pd) dup++ } pd=d; hav=1
        if(p!="" && d>p) dgtp++
      }
      if($3!="N/A" && $3!=""){ du=$3+0; h[du]++; if(h[du]>hm){hm=h[du]; modal=du} }
    }
    END{
      tiny=0; top=""; dv=0
      for(k in pc) if(pc[k]>1) dv++        # distinct COLLIDING pts values
      for(k in h){ if(modal>0 && (k+0)*10<modal) tiny+=h[k] }
      for(i=1;i<=3;i++){ bk=-1; bc=-1; for(k in h) if(h[k]>bc && !(k in used)){bc=h[k]; bk=k}
        if(bk<0) break; used[bk]=1; top=top sprintf("%sx%d ", h[bk], bk) }
      printf "TL_N=%d TL_NAPTS=%d TL_NADTS=%d TL_BACK=%d TL_DUP=%d TL_TINY=%d TL_MODAL=%d TL_TOP=%c%s%c TL_DUPPTS=%d TL_DUPVALS=%d TL_DTSGTPTS=%d TL_MINPTS=%d TL_MAXPTS=%d\n",
        n+0, nap+0, nad+0, back+0, dup+0, tiny+0, modal+0, 39, top, 39, dupp+0, dv+0, dgtp+0, minp+0, maxp+0
    }')"
echo "   packets=$TL_N  N/A-PTS=$TL_NAPTS  N/A-DTS=$TL_NADTS  backward-DTS=$TL_BACK  duplicate-DTS=$TL_DUP"
echo "   sample-duration histogram (top): ${TL_TOP:-'?'}  near-zero durations: $TL_TINY (want 0)"
DCLEAN=1   # (d) verdict feeds the (c)/(e) baseline classification (QTFF audit 5-4a/b)
if [ "${TL_N:-0}" -eq 0 ] && [ "$O_HAS_VIDEO" -eq 0 ]; then
  echo "   the output carries no video stream — these timeline gates have nothing to judge."
  led d "n/a" "the output carries no video stream"
  led j "n/a" "the output carries no video stream"
  led l "n/a" "the output carries no video stream"
elif [ "${TL_N:-0}" -eq 0 ]; then
  # EMPTY is not ABSENT: a video track whose packet list will not read is not a
  # clean timeline. DCLEAN=0 is load-bearing — gate (c) may only call decode
  # noise "inherited" against a timeline PROVEN clean, never an unread one.
  [ "$verdict" = FAIL ] || verdict=REVIEW; DCLEAN=0
  echo "   >> the output HAS a video stream and no packet could be read from it — the"
  echo "      timeline is UNPROVEN, not clean. Nothing below rests on this measurement."
  note="${note:+$note }The output's video packet list could not be read, so gates (d)/(j)/(l) are UNPROVEN — not passed."
  led d unproven "the output has a video stream but no packet could be read from it"
  led j unproven "the output has a video stream but no packet could be read from it"
  led l unproven "the output has a video stream but no packet could be read from it"
fi
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
    [ "$O_HAS_VIDEO" -eq 1 ] && led c pass "decode errors reproduce identically on the source (source: $c_src / output: $errs) with a clean (d)"
    note="${note:+$note }Spot-window decode errors reproduce on the source under identical windows (source: $c_src / output: $errs / delta: $c_delta) with a clean (d) timeline — capture-inherited noise, not remux damage. Settle for archival sign-off with --full + MKV strict-mux."
  else
    [ "$O_HAS_VIDEO" -eq 1 ] && led c fail "output decode errors not matched on the source (source: $c_src / output: $errs / delta: $c_delta; (d) clean=$DCLEAN)"
    note="${note:+$note }Output decode errors in spot windows (source: $c_src / output: $errs / delta: $c_delta; (d) clean=$DCLEAN). Claiming these are inherent to the source requires MATCHING counts on a linear decode of the same source window AND clean timeline gates (d)/(e) — the same error class can mask a second, container-level defect (post-mortem 2026-07-25)."
  fi
fi

if [ "${TL_N:-0}" -gt 0 ]; then
  if [ "$DCLEAN" -eq 1 ]; then led d pass "$TL_N packets: no N/A stamps, DTS strictly monotonic, duration histogram sane"
  elif [ "$d_failed" -eq 1 ]; then led d fail "N/A=$TL_NAPTS/$TL_NADTS backward-DTS=$TL_BACK duplicate-DTS=$TL_DUP near-zero-durations=$TL_TINY"
  else led d unproven "the near-zero duration profile could not be classified against the source"; fi
fi

# --- (j) output PTS uniqueness + DTS <= PTS (1.16.0) ------------------------
# WHY (measured 2026-08-29, feed.ts). Gate (d) has always checked N/A stamps,
# DTS monotonicity and the duration histogram. It never checked that two
# packets do not claim the SAME display slot. That is exactly what a plain
# copy of a stream with unstamped packets produces: the MOV muxer gives an
# unstamped packet pts=dts, which is both the wrong display slot AND a
# collision with a rung another packet already holds. Ten of them survived
# every gate this plugin had, because the essence was bit-identical.
#
# DTS <= PTS rides along: a picture decoded after it was displayed is not a
# timeline, and the same single pass already has both columns.
if [ "${TL_N:-0}" -gt 0 ]; then
  echo "-- (j) output PTS uniqueness + DTS <= PTS (whole file, demux only) --"
  echo "   packets=$TL_N  duplicate-PTS packets=$TL_DUPPTS across $TL_DUPVALS value(s)  DTS>PTS=$TL_DTSGTPTS"
  if [ "${TL_DUPPTS:-0}" -ne 0 ] || [ "${TL_DTSGTPTS:-0}" -ne 0 ]; then
    verdict=FAIL; d_failed=1; DCLEAN=0
    j_why=""
    [ "${TL_DUPPTS:-0}" -ne 0 ] && j_why="$TL_DUPPTS packet(s) share $TL_DUPVALS PTS value(s) — two pictures claiming one display slot"
    [ "${TL_DTSGTPTS:-0}" -ne 0 ] && j_why="${j_why:+$j_why; }$TL_DTSGTPTS packet(s) carry DTS > PTS — decoded after they are displayed"
    echo "   >> gate (j) FAILS: $j_why."
    echo "      An essence hash cannot see this: the coded pictures can be bit-identical"
    echo "      to the source while the container files two of them on one rung. Route by"
    echo "      MEASURED profile — scripts/diagnose.sh names the rung (the POC rung"
    echo "      adjudicates duplicates from the bitstream's own display positions)."
    note="${note:+$note }Output timeline: $j_why (gate (j)) — the essence may be lossless and the display order is still wrong."
    led j fail "$j_why"
  else
    echo "   PASS: every packet holds its own display slot, and nothing decodes after it displays."
    led j pass "$TL_N packets, no duplicate PTS, DTS <= PTS everywhere"
  fi
fi

# --- (l) first-displayed-frame anchor (1.16.0) ------------------------------
# WHY. A MOV edit list starts at the first CODED packet. On a reordered stream
# the earliest DISPLAYED frame is not the first coded one, so an output whose
# minimum PTS is above the stream's declared start silently trims the opening
# frame — invisible to every essence check, and visible to a viewer as a
# clipped first moment.
if [ "${TL_N:-0}" -gt 0 ]; then
  echo "-- (l) edit-list / first-frame anchor --"
  set +e; l_start=$(ffp1 -v error -select_streams v:0 -show_entries stream=start_pts -of default=nw=1:nk=1 "$OUT" 2>/dev/null); set -e
  case "${l_start:-}" in ''|N/A|*[!0-9-]*) l_start=""; esac
  echo "   min output PTS=$TL_MINPTS   stream start_pts=${l_start:-unreadable}"
  if [ -z "$l_start" ]; then
    [ "$verdict" = FAIL ] || verdict=REVIEW
    echo "   >> the declared start_pts could not be read — the anchor is UNPROVEN, not clean."
    note="${note:+$note }Gate (l): the output's declared start_pts could not be read, so it is unproven whether the edit list trims the first displayed frame."
    led l unproven "the output's declared start_pts could not be read"
  elif [ "$l_start" -gt "$TL_MINPTS" ]; then
    # REVIEW, not FAIL, and the distinction is Constitution II.1/II.3. What is
    # MEASURED is that the container declares presentation starting after its
    # own earliest composition time — so those samples sit OUTSIDE the declared
    # presentation. What is NOT measured is that any player drops them: the
    # samples are in the file, and a player that ignores the edit list shows
    # them. Calling that "trimmed" would be an accusation of loss this gate has
    # not proven, which is the exact habit this round exists to break.
    set +e
    l_before=$(ffp -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$OUT" 2>/dev/null | \
      awk -F, -v s="$l_start" 'NF && $1!="N/A" && $1+0 < s+0 {n++} END{print n+0}')
    set -e
    case "${l_before:-}" in ''|*[!0-9]*) l_before="an unread number of";; esac
    [ "$verdict" = FAIL ] || verdict=REVIEW
    echo "   >> gate (l) FLAGS: the declared start is $l_start but the earliest DISPLAYED frame sits"
    echo "      at $TL_MINPTS — $l_before sample(s) are present in the file yet fall outside"
    echo "      the declared presentation. On a reordered stream the first CODED picture is"
    echo "      not the first displayed one, so a container anchored on the coded head can"
    echo "      declare a start above its own earliest composition time. Whether a given"
    echo "      player honours that is not measured here; that it is inconsistent, is."
    echo "      The remedy is to anchor on the earliest displayed frame (min PTS)."
    note="${note:+$note }Gate (l): the output declares presentation starting at $l_start while its earliest displayed frame sits at $TL_MINPTS — $l_before sample(s) are outside the declared presentation (present in the file). Anchor on the earliest displayed frame."
    led l flagged "declared start $l_start is above the earliest displayed frame $TL_MINPTS ($l_before sample(s) outside the declared presentation)"
  else
    echo "   PASS: the earliest displayed frame is inside the declared presentation."
    led l pass "start_pts=$l_start <= earliest displayed frame $TL_MINPTS"
  fi
fi

if [ "$O_HAS_VIDEO" -eq 0 ]; then led e "n/a" "the output carries no video stream to scrub"; fi
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
  if [ "$O_HAS_VIDEO" -eq 0 ]; then
    : # already filed n/a above
  elif awk "BEGIN{exit !(${dur:-0} > 30)}"; then
    [ "$verdict" = FAIL ] || verdict=REVIEW
    note="${note:+$note }Single-GOP/unseekable output (${nkf:-0} keyframe over ${dur}s)."
    led e flagged "only ${nkf:-0} keyframe over ${dur}s — no interior scrub target"
  else
    led e pass "only ${nkf:-0} keyframe, but the output is ${dur}s — keyframe spacing is not a scrub concern here"
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
  if [ "${ntests:-0}" -eq 0 ]; then
    led e unproven "no off-keyframe scrub target could be placed in this output"
    [ "$verdict" = FAIL ] || verdict=REVIEW
    note="${note:+$note }Gate (e): no scrub target could be placed, so seek behaviour is UNPROVEN."
  elif [ "${serr:-0}" -eq 0 ]; then
    led e pass "$ntests off-keyframe accurate seeks, 0 decode errors"
  fi
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
      led e pass "deterministic recount at -threads 1 found 0 errors ($ntests seek points)"
    elif [ "${DCLEAN:-0}" -eq 1 ] && [ "$d_dec" -le 0 ] && [ "$d_mux" -le 0 ]; then
      [ "$verdict" = FAIL ] || verdict=REVIEW
      echo "   scrub classification: all lines reproduce on the source and (d) is clean — inherited/harness noise (REVIEW)."
      led e flagged "scrub lines reproduce on the untouched source (decoder $b_dec/$o_dec, muxer-stage $b_mux/$o_mux) with a clean (d)"
      note="${note:+$note }Scrub-gate lines reproduce on the untouched source under identical accurate seeks (decoder source: $b_dec / output: $o_dec; muxer-stage source: $b_mux / output: $o_mux; deterministic -threads 1 counts) with a clean (d) timeline — capture-inherited decode noise / harness-stage artifacts, not a torn timeline. The timeline is independently proven by (d); complete the proof set (MKV strict-mux + --full presentation order) for archival sign-off."
    else
      verdict=FAIL; e_failed=1
      led e fail "$o_tot deterministic decode error(s) on off-keyframe seeks (decoder delta $d_dec, muxer-stage delta $d_mux; (d) clean=${DCLEAN:-0})"
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
sdur () { ffp1 -v error -select_streams "$1" -show_entries stream=duration -of default=nw=1:nk=1 "$OUT" 2>/dev/null; }
# EMPTY ≠ ABSENT (CHECKUP-2026-08-27 A1 / WO-1.15.4): the audio census is
# captured WITH its exit status — the old `| grep -c . || true` read a FAILED
# probe as "no audio tracks", silently disarming this gate. A failed census is
# UNPROVEN: announced, REVIEW, never a quiet N/A and never a FAIL (the
# artifact is not indicted by a broken ruler). Counting rides awk (NF), not
# grep -c, whose rc-1-on-zero-matches is what bred the || true.
# EMPTY ≠ ABSENT (WO-1.15.4 leftover ledger, closed 1.15.19): vdur in
# ASSIGNMENT position under pipefail was the C4 shape inside verify itself.
# The ledger recorded this as "reads an empty probe as N/A"; MEASURED, it is
# worse — a failed video-duration probe is a SILENT ERR-trap abort right here,
# the report stops dead at this gate's header with NO verdict line, and the
# script exits 1, which is verify's FAIL. "I could not measure the video
# duration" shipped as "this file FAILED verification". A ruler that will not
# read is UNPROVEN; the artifact is never indicted by a broken ruler.
set +e; vdur=$(sdur v:0); vdur_rc=$?; set -e
set +e
f_cen=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$OUT" 2>/dev/null); f_cen_rc=$?
set -e
naud=0
if [ "$f_cen_rc" -eq 0 ]; then
  naud=$(printf '%s\n' "$f_cen" | LC_ALL=C sort -u | awk 'NF{n++} END{print n+0}')   # distinct indices: a program-bearing OUT lists each stream twice
fi
SYNC_TOL="${RTM_SYNC_TOL:-0.25}"
if [ "$f_cen_rc" -ne 0 ]; then
  echo "   audio census probe FAILED (ffprobe rc=$f_cen_rc) — sync parity UNPROVEN, not N/A."
  [ "$verdict" = FAIL ] || verdict=REVIEW
  note="${note:+$note }Gate (f) could not census the output audio (ffprobe rc=$f_cen_rc) — A/V duration parity is UNPROVEN (not disproven); re-run verify when the probe succeeds."
elif [ "${vdur_rc:-0}" -ne 0 ]; then
  echo "   video duration probe FAILED (ffprobe rc=$vdur_rc) — sync parity UNPROVEN, not N/A."
  [ "$verdict" = FAIL ] || verdict=REVIEW
  note="${note:+$note }Gate (f) could not read the output video duration (ffprobe rc=$vdur_rc) — A/V duration parity is UNPROVEN (not disproven); re-run verify when the probe succeeds."
  led f unproven "the output video duration probe failed (ffprobe rc=$vdur_rc)"
elif [ "${naud:-0}" -eq 0 ] || [ -z "$vdur" ] || [ "$vdur" = N/A ]; then
  echo "   no audio or no stream durations — sync parity N/A."
  led f "n/a" "the output carries no audio track, or no stream durations, to compare against"
else
  worst=0; worst_dir=short; ai=0; trk_unproven=0
  while [ "$ai" -lt "$naud" ]; do
    # same assignment-position trap as vdur above, per track (1.15.19): a
    # failed per-track duration probe used to abort the whole report silently.
    # A track whose ruler failed is announced and excluded from `worst` —
    # never folded in as a zero delta, which would read as perfect sync.
    set +e; ad=$(sdur "a:$ai"); ad_rc=$?; set -e
    if [ "$ad_rc" -ne 0 ]; then
      echo "   a:$ai duration probe FAILED (ffprobe rc=$ad_rc) — this track's parity UNPROVEN."
      trk_unproven=$((trk_unproven+1))
    elif [ -n "$ad" ] && [ "$ad" != N/A ]; then
      delta=$(awk "BEGIN{d=($vdur)-($ad); if(d<0)d=-d; printf \"%.3f\", d}")
      echo "   a:$ai=${ad}s vs video ${vdur}s (Δ ${delta}s)"
      if awk "BEGIN{exit !(($delta) > ($worst))}"; then
        worst=$delta
        worst_dir=$(awk "BEGIN{print (($ad) > ($vdur)) ? \"long\" : \"short\"}")
      fi
    fi
    ai=$((ai+1))
  done
  if [ "$trk_unproven" -gt 0 ]; then
    [ "$verdict" = FAIL ] || verdict=REVIEW
    note="${note:+$note }Gate (f) could not read the duration of $trk_unproven output audio track(s) — their A/V parity is UNPROVEN (not disproven); re-run verify when the probe succeeds."
    led f unproven "$trk_unproven audio track(s) had no readable duration"
  fi
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
      led f pass "max delta ${worst}s within tolerance ${SYNC_TOL}s + measured source gap budget ${gap_budget}s"
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
        led f flagged "A/V delta ${worst}s beyond tolerance ${SYNC_TOL}s + measured gap budget ${gap_budget}s"
      else
        note="${note:+$note }A/V duration mismatch up to ${worst}s (> ${SYNC_TOL}s tol; no measured source loss to explain it) — gap-collapse desync signature; diagnose.sh to confirm, resync.sh to fix."
        echo "   >> mismatch ${worst}s exceeds tolerance ${SYNC_TOL}s (no measured source loss) — sync REVIEW."
        led f flagged "A/V delta ${worst}s beyond tolerance ${SYNC_TOL}s with no measured source loss to explain it"
      fi
    fi
  else
    echo "   max Δ ${worst}s within ${SYNC_TOL}s tolerance — A/V durations consistent."
    led f pass "max A/V delta ${worst}s within the ${SYNC_TOL}s tolerance"
  fi
fi

g_gate_failed=0; g_gate_flagged=0
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
# EMPTY ≠ ABSENT (CHECKUP-2026-08-27 A1 / WO-1.15.4): one captured census
# feeds both counts — the old `| grep -c . || true` pair read a FAILED probe
# as "no audio tracks in the output — gate N/A" and disarmed the whole
# playability gate. A failed census is UNPROVEN: announced, REVIEW, never a
# quiet N/A. awk (NF) counts; grep -c's rc-1-on-zero is what bred || true.
set +e
g_cen=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$OUT" 2>/dev/null); g_cen_rc=$?
set -e
g_naud=0; g_naud_raw=0
if [ "$g_cen_rc" -eq 0 ]; then
  g_naud=$(printf '%s\n' "$g_cen" | LC_ALL=C sort -u | awk 'NF{n++} END{print n+0}')   # distinct indices: a program-bearing OUT lists each stream twice
  # the pre-correction figure, kept ONLY so the correction can announce itself
  # (P1c): the census fix silently moved a program-bearing OUT from FAIL to OK by
  # retiring a phantom track, and a FAIL->OK move may never be silent.
  g_naud_raw=$(printf '%s\n' "$g_cen" | awk 'NF{n++} END{print n+0}')
fi
g_ofmt=$(ffp1 -v error -show_entries format=format_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null)
g_qtff=0; case ",$g_ofmt," in *,mov,*|*,mp4,*) g_qtff=1;; esac
if [ "$g_cen_rc" -ne 0 ]; then
  echo "   audio census probe FAILED (ffprobe rc=$g_cen_rc) — audio playability UNPROVEN, not N/A."
  [ "$verdict" = FAIL ] || verdict=REVIEW
  note="${note:+$note }Gate (g) could not census the output audio (ffprobe rc=$g_cen_rc) — the playability gate is UNPROVEN (not disproven); re-run verify when the probe succeeds."
elif [ "${g_naud:-0}" -eq 0 ]; then
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
  # EMPTY ≠ ABSENT (1.15.19): A1 captured this gate's OUTPUT census and left
  # its SOURCE census on `grep -c . || true` — a failed probe read as 0 source
  # tracks, and g_baseline then reported "the source has NO audio track to
  # compare against" for EVERY output track, silently discarding the
  # inherited-vs-introduced attribution this gate exists to make. Counting
  # rides awk (NF), not grep -c, whose rc-1-on-zero-matches is what bred the
  # `|| true` in the first place.
  set +e
  g_srccen=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$SRC" 2>/dev/null); g_srccen_rc=$?
  set -e
  g_srcaud=0
  if [ "$g_srccen_rc" -eq 0 ]; then
    g_srcaud=$(printf '%s\n' "$g_srccen" | LC_ALL=C sort -u | awk 'NF{n++} END{print n+0}')
  else
    echo "   source audio census probe FAILED (ffprobe rc=$g_srccen_rc) — per-track baselines UNPROVEN, not absent."
    [ "$verdict" = FAIL ] || verdict=REVIEW
    g_gate_flagged=1
    note="${note:+$note }Gate (g) could not census the SOURCE audio (ffprobe rc=$g_srccen_rc) — inherited-vs-introduced attribution is UNPROVEN (not disproven); re-run verify when the probe succeeds."
  fi
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
    if [ "${g_srccen_rc:-0}" -ne 0 ]; then
      # EMPTY ≠ ABSENT (1.15.19): "the census FAILED" is not "there is nothing
      # to compare against" — the gate above already announced it and landed
      # REVIEW; this arm must not restate a failed probe as a measured absence.
      printf 'none\nthe SOURCE audio census FAILED (ffprobe rc=%s) — no baseline could be enumerated (UNPROVEN, not absent)\n\n' "$g_srccen_rc"; return 0
    fi
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
  # measured SILENT on the D3 bench (2026-08-15) and PLAYING on this machine
  # (2026-08-29) — a per-OS empirical split, not a categorical (1.16.7; the
  # C56/C72 4:2:2 demotion is the in-house precedent). What the old gate got
  # wrong is unaffected by the reversal: it PASSED this configuration
  # (allowlisted on the rationale that a PCM access track guarantees playback —
  # true only when one EXISTS) while failing configurations that work. ffmpeg declares MP2 at
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
  # EMPTY ≠ ABSENT (1.15.19): both censuses feed the naked-MP2 verdict and
  # both used to fail open on `|| true` — and they fail in OPPOSITE
  # directions, which is why they are captured together. A failed SOURCE
  # census reads 0 MP2 tracks and DISARMS the finding (the mp4a/mp3 arm never
  # fires); a failed OUTPUT census reads 0 PCM tracks and ARMS it, accusing a
  # legitimate dual-track deliverable of shipping "MP2 with NO PCM access
  # track" from a probe that never ran. Neither direction is allowed: the
  # accusation requires BOTH censuses to have succeeded. Counting rides awk.
  set +e
  g_mp2cen=$(ffp -v error -select_streams a -show_entries stream=index,codec_name -of csv=p=0 "$SRC" 2>/dev/null); g_mp2cen_rc=$?
  g_pcmcen=$(ffp -v error -select_streams a -show_entries stream=index,codec_name -of csv=p=0 "$OUT" 2>/dev/null); g_pcmcen_rc=$?
  set -e
  g_src_mp2=0; g_has_pcm=0; g_cls_rc=0
  if [ "$g_mp2cen_rc" -eq 0 ] && [ "$g_pcmcen_rc" -eq 0 ]; then
    # ,mp2,?$ not ,mp2$ — the F8 side-data trailing comma, preserved verbatim
    g_src_mp2=$(printf '%s\n' "$g_mp2cen" | LC_ALL=C sort -u | awk '/,mp2,?$/{n++} END{print n+0}')
    g_has_pcm=$(printf '%s\n' "$g_pcmcen" | LC_ALL=C sort -u | awk '/,pcm_/{n++} END{print n+0}')
  else
    g_cls_rc=1
    echo "   MP2/PCM classification census FAILED (src rc=$g_mp2cen_rc, out rc=$g_pcmcen_rc) —"
    echo "   the naked-MP2 finding is UNPROVEN: not withheld as 'clean', not asserted."
    [ "$verdict" = FAIL ] || verdict=REVIEW
    g_gate_flagged=1
    note="${note:+$note }Gate (g) could not census the MP2/PCM layout (src rc=$g_mp2cen_rc, out rc=$g_pcmcen_rc) — the naked-MP2 finding is UNPROVEN (neither cleared nor asserted); re-run verify when the probe succeeds."
  fi
  g_mp2_naked=0
  gi=0
  while [ "$gi" -lt "$g_naud" ]; do
    g_tag=$(ffp1 -v error -select_streams "a:$gi" -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$OUT" 2>/dev/null)
    g_cod=$(ffp1 -v error -select_streams "a:$gi" -show_entries stream=codec_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null)
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
        g_gate_flagged=1
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
        g_gate_flagged=1
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
        g_gate_flagged=1
        echo "   a:$gi tag='${g_tag:-none}' (codec ${g_cod:-unknown}): NOT on the QTFF audio"
        echo "        allowlist, but the bounded head decode is CLEAN — so it is not the"
        echo "        dead-sample-entry class. Advisory, not a FAIL (D3, 1.13): unbenched"
        echo "        here means unproven in QuickTime, not unclaimed by every decoder."
        echo "        Prove the render before shipping: scripts/playable-check.sh OUT"
        note="${note:+$note }Audio track a:$gi carries the unbenched sample-entry tag '${g_tag:-none}' (codec ${g_cod:-unknown}); it decodes cleanly, so this is an advisory, not the dead-track class — prove QuickTime playback before shipping."
      else
        verdict=FAIL; other_failed=1
        g_gate_failed=1
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
        g_gate_flagged=1
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
        g_gate_flagged=1
        echo "   a:$gi tag='${g_tag:-n/a}' (codec $g_cod): $g_tagword; $g_err decode line(s) in the"
        echo "        first ${WIN}s, but the IDENTICAL decode of the source reproduces them (delta"
        echo "        $g_net) — inherited/open-time noise, not a remux defect. REVIEW, not FAIL."
        note="${note:+$note }Audio track a:$gi shows $g_err decode line(s) in the first ${WIN}s that the source reproduces under the identical bounded decode (source: $g_base / output: $g_err / delta: $g_net) — capture-inherited damage or open-time parse noise, not remux damage; a remux cannot fix source damage. Listen before archiving."
      else
        verdict=FAIL; other_failed=1
        g_gate_failed=1
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
  if [ "$g_mp2_naked" -eq 1 ] && [ "${g_has_pcm:-0}" -eq 0 ] && [ "${g_cls_rc:-0}" -eq 0 ]; then
    [ "$verdict" = FAIL ] || verdict=REVIEW
    g_gate_flagged=1
    echo "   >> MP2 audio with NO PCM access track — the configuration this gate used to"
    echo "      PASS while failing the ones that work (D3, 1.13). Whether .mp2 PLAYS is"
    echo "      a PER-OS EMPIRICAL question, and this gate no longer asserts an answer:"
    echo "        measured PLAYING in QuickTime on this machine 2026-08-29"
    echo "          (plugin-doctor/README.md; that day's bench line records macOS 26.6.1)"
    echo "        measured SILENT on the D3 bench 2026-08-15 (1.13, macOS 26.6.1)"
    echo "      Both measurements stand; decode support drifts by OS in BOTH directions"
    echo "      (C63), so PROVE IT ON YOUR TARGET MACHINE before shipping this file."
    echo "      Note also that .mp2 is ffmpeg's convention, not an Apple-documented"
    echo "      sample entry — the spec lists no framed Layer II format — which is"
    echo "      worth a line in any sidecar. The works-everywhere option (not a"
    echo "      mandatory rebuild) stays dual-track: scripts/mov.sh routes MP2 there"
    echo "      automatically, or scripts/remux.sh --audio pcm."
    note="${note:+$note }Output carries MP2 audio with no PCM access track. Playability is per-OS empirical, not categorical: measured playing in QuickTime on this machine 2026-08-29, measured silent on the D3 bench 2026-08-15 (1.13) — prove it on your target machine. .mp2 is not an Apple-documented sample entry (worth a sidecar line). Works-everywhere option: mov.sh (dual-track) or remux.sh --audio pcm."
  fi
fi


# gate (g)'s ledger row, filed from the gate's own evidence rather than from a
# second reading of it (IV.1): the two counters above are set at the branches
# that move the verdict, so the row cannot drift from what the gate decided.
if [ "${g_cen_rc:-0}" -ne 0 ]; then
  led g unproven "the output audio census probe failed (ffprobe rc=$g_cen_rc)"
elif [ "${g_naud:-0}" -eq 0 ]; then
  led g "n/a" "the output carries no audio track to judge"
elif [ "$g_gate_failed" -eq 1 ]; then
  led g fail "an output audio track is not playable (see the gate's own lines above)"
elif [ "$g_gate_flagged" -eq 1 ]; then
  led g flagged "an output audio track raised a playability question short of FAIL"
else
  led g pass "${g_naud} output audio track(s): sample entry on the allowlist and head-decode clean"
fi

# ============================================================================
# Gates (h), (i), (k), (m) — 1.16.0. THE CONTAINER-LEVEL TIER.
#
# WHY THIS BLOCK EXISTS, measured 2026-08-29. Two builds of the same source
# were bit-identical to it and unusable: one carried a MOV sample per coded
# FIELD (the container claiming ~50/s over a ~25/s decode — stutter in
# QuickTime and IINA), the other a '.mp3' sample entry over MPEG-1 Layer II
# payload. Gates (a)/(b) proved both lossless, gate (c) decoded both without
# an error, gate (g) passed the audio. Every check the plugin had was blind,
# because the defect is in what the container DECLARES, not what it stores.
#
# An essence hash is necessary and it is nowhere near sufficient.
# ============================================================================

# --- (h) declared-vs-stored structure + (k) presentation order vs POC -------
# Both read the SAME whole-file header pass (Constitution IV.2: never
# re-derive). It is the expensive one — a trace_headers parse of the output —
# so it is BUDGETED: under RTM_STRUCT_MAX_BYTES it runs, above it the gates
# report UNPROVEN and name the standalone command. Unproven is a REVIEW, never
# a silent pass (II.1).
# RTM_STRUCT_MAX_BYTES=0 means NO BUDGET (always run), which is what
# references/knobs.md promises — an earlier draft compared against it as a
# plain threshold, so 0 declined every output instead of admitting it.
H_MAXB="${RTM_STRUCT_MAX_BYTES:-4294967296}"
case "$H_MAXB" in ''|*[!0-9]*) H_MAXB=4294967296;; esac
# ASSIGNMENT POSITION under `set -e` is this file's own documented trap (the
# C4 / WO-1.15.4 shape): a failing probe on the right of `VAR=$(...)` kills the
# script mid-report, and "I could not measure" then ships as "this file FAILED
# verification". Every probe below captures its status instead, and an
# unreadable answer becomes UNPROVEN — never n/a, which would read as "there
# was nothing here to check".
set +e
o_bytes=$(wc -c < "$OUT" 2>/dev/null | tr -d ' ')
o_vcodec=$(ffp1 -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null); o_vcodec_rc=$?
o_fmt=$(ffp1 -v error -show_entries format=format_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null); o_fmt_rc=$?
set -e
case "$o_bytes" in ''|*[!0-9]*) o_bytes=0;; esac
H_RUN=0
H_ISO=0
case "$o_fmt" in *mov*|*mp4*|*m4a*) H_ISO=1;; esac
if [ "$o_fmt_rc" -ne 0 ] || [ -z "${o_fmt:-}" ]; then
  [ "$verdict" = FAIL ] || verdict=REVIEW
  note="${note:+$note }Gates (h)/(k): the output's container format could not be read (ffprobe rc=$o_fmt_rc), so the sample structure and presentation order are UNPROVEN."
  led h unproven "the output container format could not be read (ffprobe rc=$o_fmt_rc)"
  led k unproven "the output container format could not be read (ffprobe rc=$o_fmt_rc)"
elif [ "$H_ISO" -eq 0 ]; then
  led h "n/a" "the output is not an ISO/QuickTime container ($o_fmt) — it has no sample table to compare against"
  led k "n/a" "no ISO sample timeline to judge on this container ($o_fmt)"
elif [ "$O_HAS_VIDEO" -eq 1 ] && { [ "$o_vcodec_rc" -ne 0 ] || [ -z "${o_vcodec:-}" ]; }; then
  [ "$verdict" = FAIL ] || verdict=REVIEW
  note="${note:+$note }Gates (h)/(k): the output HAS a video stream whose codec could not be read (ffprobe rc=$o_vcodec_rc) — UNPROVEN, not inapplicable."
  led h unproven "the output has a video stream whose codec could not be read (ffprobe rc=$o_vcodec_rc)"
  led k unproven "the output has a video stream whose codec could not be read (ffprobe rc=$o_vcodec_rc)"
elif [ "$O_HAS_VIDEO" -eq 0 ]; then
  led h "n/a" "the output carries no video stream"
  led k "n/a" "the output carries no video stream"
elif [ "${o_vcodec:-}" != h264 ]; then
  # the census and the POC lattice are both H.264 slice-header facts
  led h "n/a" "output video is ${o_vcodec:-unreadable}, not H.264 — this census reads H.264 slice headers"
  led k "n/a" "output video is ${o_vcodec:-unreadable}, not H.264 — pic_order_cnt is an H.264 fact"
elif [ "${TL_N:-0}" -eq 0 ]; then
  led h unproven "the output's packet list could not be read, so there is no declared sample count to compare"
  led k unproven "the output's packet list could not be read"
elif [ "$FULL" -ne 1 ] && [ "$H_MAXB" -gt 0 ] && [ "$o_bytes" -gt "$H_MAXB" ]; then
  # --- THE COPY-IDENTITY SETTLE (1.18.0) ------------------------------------
  # The whole-file trace_headers parse is over budget. Before declaring these
  # gates unproven, try the cheap proof that is SUFFICIENT for a copy-class
  # artifact: the remux's whole obligation there is FAITHFULNESS, so if
  #   (1) the payload is bit-identical      (gate (a)/(b): bitproven=1),
  #   (2) the video packet counts are equal (one sample per source packet),
  #   (3) the PTS column equals the source's (anchor-aligned, <=2 ms tolerance
  #       for timebase-conversion rounding),
  # then the output DECLARES what the source declared: any (h)/(k)-class
  # defect is inherited from the source — diagnosis territory, never remux
  # verification. That is a measurement, not a waiver (II.1): both rows state
  # exactly what was proven and that the parse was not run. Artifacts that
  # AUTHOR timing (pairfill/rebuild/poc/derive, genpts) fail check (3) by
  # construction and land in the UNPROVEN arm below unchanged — those writers
  # owe the absolute proof, and their own gates run it.
  # Cost: two demux-only PTS dumps (disk speed), no bitstream parse, no decode.
  # Why not trust a caller-declared rung class instead: never trust a claim
  # you can measure (the 2026-08-30 field lesson, inverted).
  echo "-- (h)/(k) structure + presentation order: whole-file parse over budget --"
  echo "   output is $o_bytes bytes > RTM_STRUCT_MAX_BYTES=$H_MAXB; attempting the"
  echo "   copy-identity settle: payload identity + packet count + PTS-column"
  echo "   equality vs the source (demux-only, no header parse, no decode)."
  id_ok=0; id_why=""; id_sn=0; id_on=0; id_max=""
  if [ "${bitproven:-0}" -ne 1 ]; then
    id_why="payload identity not proven by (a)/(b) on this artifact"
  else
    id_sd="$(mktemp)"; id_od="$(mktemp)"
    set +e
    ffp -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$SRC" 2>/dev/null > "$id_sd"; id_src_rc=$?
    ffp -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$OUT" 2>/dev/null > "$id_od"; id_out_rc=$?
    set -e
    id_sn=$(grep -c . "$id_sd" || true); id_on=$(grep -c . "$id_od" || true)
    if [ "$id_src_rc" -ne 0 ] || [ "$id_out_rc" -ne 0 ] || [ "${id_sn:-0}" -eq 0 ] || [ "${id_on:-0}" -eq 0 ]; then
      id_why="could not read a packet PTS column (src rc=$id_src_rc n=$id_sn, out rc=$id_out_rc n=$id_on)"
    elif [ "$id_sn" -ne "$id_on" ]; then
      id_why="video packet counts differ: src=$id_sn out=$id_on — not a 1:1 copy of the sample structure"
    elif grep -q "N/A" "$id_sd" "$id_od" 2>/dev/null; then
      id_why="a side carries N/A PTS — the column cannot anchor"
    else
      # max |(out - out_first) - (src - src_first)| over the paired columns.
      # Anchor subtraction tolerates a uniform muxer shift (-avoid_negative_ts);
      # 2 ms tolerance covers timebase-conversion rounding and sits an order of
      # magnitude below one field duration at 60 fields/s (~16.7 ms) — the
      # smallest displacement the (k) defect class produces.
      id_max=$(paste "$id_sd" "$id_od" | awk '
        NR==1 { s0=$1; o0=$2 }
        { d=($2-o0)-($1-s0); if (d<0) d=-d; if (d>m) m=d }
        END { printf "%.6f", m+0 }')
      if awk -v m="$id_max" 'BEGIN{ exit !((m+0) <= 0.002) }'; then id_ok=1
      else id_why="PTS columns diverge: max |delta| ${id_max}s > 0.002s after anchor alignment — this artifact's timing was authored, not copied; the authored classes owe the whole-file proof"
      fi
    fi
    rm -f "$id_sd" "$id_od"
  fi
  if [ "$id_ok" -eq 1 ]; then
    echo "   PASS (identity-proven): $id_on samples == $id_sn source packets, payload"
    echo "   bit-identical, PTS column equal (max |delta| ${id_max}s over $id_on packets)."
    echo "   The output declares what the source declared; the whole-file parse was NOT"
    echo "   run — an inherited source-side defect would be inherited faithfully, which"
    echo "   is diagnosis territory (diagnose.sh on the SOURCE), not remux verification."
    led h pass "identity-proven under budget: $id_on samples == $id_sn source packets, payload bit-identical (whole-file parse not run)"
    led k pass "identity-proven under budget: PTS column equals the source's (max |delta| ${id_max}s over $id_on packets; whole-file parse not run)"
  else
    echo "   the identity settle did not apply: $id_why"
    echo "   These two gates cost one whole-file header parse. They were NOT run, so"
    echo "   nothing below claims the sample structure or the display order is correct."
    echo "   Settle (k) alone:  scripts/poc-gate.sh \"$OUT\"        (header parse only)"
    echo "   Settle both:       scripts/verify.sh SRC OUT --full    (parse + whole-file"
    echo "                      decode — the sign-off tier; or RTM_STRUCT_MAX_BYTES=0)"
    echo "   A REVIEW whose ONLY cause is this budget decline is reportable as done —"
    echo "   settle it on the operator's ask, not by default (FAST PATH, SKILL.md)."
    [ "$verdict" = FAIL ] || verdict=REVIEW
    note="${note:+$note }Gates (h)/(k) declined on budget (output $o_bytes bytes > RTM_STRUCT_MAX_BYTES=$H_MAXB) and the copy-identity settle did not apply ($id_why) — the declared sample structure and the presentation order are UNPROVEN. Settle on the operator's ask: poc-gate.sh for (k) alone, or --full."
    led h unproven "declined on budget ($o_bytes > $H_MAXB bytes) and identity settle inapplicable: $id_why"
    led k unproven "declined on budget ($o_bytes > $H_MAXB bytes) and identity settle inapplicable: $id_why"
  fi
else
  H_RUN=1
fi

if [ "$H_RUN" -eq 1 ]; then
  HTD="$(mktemp -d)"    # only our own scratch (III.3)
  echo "-- (h) declared-vs-stored structure (ISO/IEC 14496-15 sample arithmetic) --"
  # ONE pass: the census AND the POC table gate (k) reads. The table is
  # copy-by-construction consistent here because both halves are measured from
  # the SAME file — the output itself (the reuse license test 78 pins).
  h_crc=0
  eval "$(pf_trace_census "$OUT" "$HTD/poc.csv" "$HTD/sps" "$HTD/str.csv" 2>/dev/null)" || h_crc=$?
  if [ "${PC_OK:-no}" != yes ]; then
    echo "   trace_headers parsed no coded picture from this output (rc=$h_crc) — the"
    echo "   structure is UNPROVEN, not clean. EMPTY is not ABSENT."
    [ "$verdict" = FAIL ] || verdict=REVIEW
    note="${note:+$note }Gate (h): the output's coded-picture census parsed nothing, so the declared sample count is unproven."
    led h unproven "trace_headers parsed no coded picture from the output (rc=$h_crc)"
    led k unproven "no coded picture parsed, so no POC column exists"
  else
    echo "   coded pictures=$PC_PICS  field=$PC_FIELDS frame=$PC_FRAMES"
    echo "   14496-15 sample arithmetic: complementary pairs=$PC_PAIRS + unpaired fields=$PC_SINGLES + frame pictures=$PC_FRAMES"
    echo "   samples the structure implies=$PC_EXPECT   samples the container declares=$TL_N"
    if [ "$PC_EXPECT" -ne "$TL_N" ]; then
      verdict=FAIL; other_failed=1
      h_ratio=$(awk -v a="$TL_N" -v b="$PC_EXPECT" 'BEGIN{ if(b>0) printf "%.3f", a/b; else printf "?" }')
      echo "   >> gate (h) FAILS: the container files $TL_N samples for a structure that is $PC_EXPECT"
      echo "      (ratio ${h_ratio}x). ISO/IEC 14496-15 requires BOTH fields of a"
      echo "      complementary field pair to live in ONE sample; players time playback"
      echo "      off samples, so one sample per FIELD makes the container claim roughly"
      echo "      twice the rate the decoder emits. The essence can be bit-perfect and"
      echo "      the file still stutters everywhere (measured 2026-08-29)."
      note="${note:+$note }Gate (h): the output declares $TL_N samples for a coded structure of $PC_EXPECT (pairs=$PC_PAIRS singles=$PC_SINGLES frames=$PC_FRAMES) — the container misdescribes what it stores; an essence hash cannot see this."
      led h fail "declared $TL_N samples vs $PC_EXPECT implied by the structure (pairs=$PC_PAIRS singles=$PC_SINGLES frames=$PC_FRAMES)"
    else
      echo "   PASS: the sample count the container declares is the one its coded structure implies."
      led h pass "$TL_N samples == $PC_EXPECT implied (pairs=$PC_PAIRS singles=$PC_SINGLES frames=$PC_FRAMES)"
    fi
    # the declared RATE, from the same numbers: samples / duration must agree
    # with avg_frame_rate. A right sample count with a wrong declared rate is
    # the same defect one storey up.
    set +e; h_afr=$(ffp1 -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 "$OUT" 2>/dev/null); set -e
    # the VIDEO stream's own duration, not the container's: format duration
    # includes the audio tail and any edit offset, which on a short output is a
    # few percent of nothing and would make this cry wolf.
    set +e
    h_dur=$(ffp1 -v error -select_streams v:0 -show_entries stream=duration -of default=nw=1:nk=1 "$OUT" 2>/dev/null)
    case "${h_dur:-}" in ''|N/A) h_dur=$(ffp1 -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" 2>/dev/null);; esac
    set -e
    case "${h_dur:-}" in ''|N/A) h_dur="";; esac
    if [ -n "${h_afr:-}" ] && [ -n "$h_dur" ] && [ "${h_afr}" != "0/0" ]; then
      # THE BAND IS A RELATIONSHIP, not a taste. The defect this catches is a
      # container declaring one sample per FIELD: a 2x error. Container rounding,
      # a trailing partial sample and capture jitter live within a few percent.
      # 1.10 is the empty middle — nothing legitimate reaches it and the defect
      # is nowhere near it (RTM_RATE_DEV_MAX overrides).
      h_devmax="${RTM_RATE_DEV_MAX:-1.10}"
      set +e; h_msg=$(awk -v afr="$h_afr" -v n="$TL_N" -v d="$h_dur" -v lim="$h_devmax" '
        BEGIN{ split(afr,p,"/"); r=(p[2]+0>0)? p[1]/p[2] : 0
               m=(d+0>0)? n/d : 0
               if(r<=0 || m<=0){ print "unreadable"; exit }
               dev=(r>m? r/m : m/r)
               printf "%s %.4f %.4f", (dev>lim+0 ? "MISMATCH" : "ok"), r, m }'); set -e
      case "$h_msg" in
        MISMATCH*)
          set -- $h_msg
          echo "   >> declared avg_frame_rate=$2/s but $TL_N samples over ${h_dur}s of video is $3/s —"
          echo "      the container's declared rate is not the rate it stores (band ${h_devmax}x)."
          [ "$verdict" = FAIL ] || verdict=REVIEW
          note="${note:+$note }Gate (h): declared avg_frame_rate ($2/s) disagrees with samples/duration ($3/s)."
          ;;
        ok*) : ;;
      esac
    fi

    # --- (k) presentation order vs the bitstream's own POC ------------------
    echo "-- (k) presentation order vs pic_order_cnt (H.264 §8.2.1.1) --"
    k_maxlsb=0
    k_l2=$(head -1 "$HTD/sps" 2>/dev/null || true)
    case "${k_l2:-}" in ''|*[!0-9]*) ;; *) [ "$k_l2" -le 12 ] && k_maxlsb=$((1 << (k_l2 + 4)));; esac
    k_prc=0
    ffp -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$OUT" 2>/dev/null | \
      awk -F, 'NF && $1!="N/A"{ print $1+0 }' > "$HTD/pts.csv" || k_prc=$?
    k_na=$(grep -c . "$HTD/poc.csv" 2>/dev/null || true); k_na=${k_na:-0}
    k_nb=$(grep -c . "$HTD/pts.csv" 2>/dev/null || true); k_nb=${k_nb:-0}
    # A CORRECTLY PAIRED OUTPUT HAS FEWER SAMPLES THAN CODED PICTURES, and that
    # is not a count mismatch — it is ISO/IEC 14496-15 working. One POC row per
    # PICTURE, one packet per SAMPLE: on a field-paired MOV the two differ by
    # exactly the pair count, and a gate that reads that as "cannot judge"
    # declines to judge precisely the artifact this plugin builds. So when the
    # census found pairs, keep the row that STARTS each sample (the top field)
    # and drop the continuation rows.
    if [ "$k_na" -ne "$k_nb" ] && [ "${PC_PAIRS:-0}" -gt 0 ] && [ -s "$HTD/str.csv" ]; then
      k_sn=$(grep -c . "$HTD/str.csv" 2>/dev/null || true); k_sn=${k_sn:-0}
      if [ "$k_sn" -eq "$k_na" ]; then
        paste -d, "$HTD/poc.csv" "$HTD/str.csv" | awk -F, '
          # drop a bottom field that continues the pair its predecessor opened
          { fld=$5+0; bot=$6+0; fn=$7+0
            cont = (prev_open && fld==1 && bot==1 && fn==prev_fn)
            if (!cont) printf "%s,%s,%s,%s\n", $1, $2, $3, $4
            prev_open = (fld==1 && bot==0); prev_fn = fn }' > "$HTD/poc_samples.csv"
        k_pa=$(grep -c . "$HTD/poc_samples.csv" 2>/dev/null || true); k_pa=${k_pa:-0}
        if [ "$k_pa" -eq "$k_nb" ]; then
          echo "   field-paired output: $k_na coded picture(s) -> $k_pa sample(s) (ISO/IEC"
          echo "   14496-15 pairing), which is what the container carries. Judging samples."
          mv -f "$HTD/poc_samples.csv" "$HTD/poc.csv"
          k_na=$k_pa
        fi
      fi
    fi
    # 1.16.2: a multi-SPS capture is EVALUATED, not declined. The POC table
    # carries the modulus active at each picture and pf_poc_lattice opens a new
    # scope when it changes, so no picture is unwrapped under another scope's
    # MaxPicOrderCntLsb. 1.16.1 reported UNPROVEN here — correct, and a refusal
    # to judge exactly the program-change captures this plugin exists for.
    if [ "${PC_SPS_L2_VARIES:-no}" = yes ]; then
      echo "   this stream carries more than one SPS modulus — judging per SPS-activation"
      echo "   scope (8.2.1.1 is modular; lsb state never crosses a scope boundary)."
    fi
    if [ "$k_prc" -ne 0 ] || [ "$k_na" -eq 0 ] || [ "$k_na" -ne "$k_nb" ]; then
      k_why=count
      [ "$k_na" -eq 0 ] && k_why="pic_order_cnt_type != 0 (the stream carries no pic_order_cnt_lsb)"
      [ "$k_prc" -ne 0 ] && k_why="the PTS probe failed (rc=$k_prc)"
      echo "   UNPROVEN: POC rows=$k_na, timestamped packets=$k_nb — $k_why."
      echo "   This is not a verdict on the artifact; it is this gate saying it could not judge."
      [ "$verdict" = FAIL ] || verdict=REVIEW
      note="${note:+$note }Gate (k): presentation order could not be checked against POC ($k_why) — UNPROVEN, not passed."
      led k unproven "$k_why (POC rows=$k_na, timestamped packets=$k_nb)"
    else
      paste -d, "$HTD/poc.csv" "$HTD/pts.csv" > "$HTD/table.csv"
      eval "$(pf_poc_lattice "$HTD/table.csv" "$k_maxlsb")"
      echo "   MaxPicOrderCntLsb=${k_maxlsb:-inferred}  on_slot=$PL_ON/$PL_TOTAL  off_lattice=$PL_OFF  (IDR sequences=$PL_SEQS)"
      echo "VERIFY_POC_LATTICE on_slot=$PL_ON total=$PL_TOTAL off=$PL_OFF seqs=$PL_SEQS"
      if [ "${PL_OFF:-1}" -ne 0 ] && [ "${PL_OFF:-0}" -eq "${PL_NOFIT_PICS:-0}" ]; then
        # every off-lattice picture is inside a scope whose interval could not
        # be FIT at all — that is "could not judge", not "torn". Naming the
        # scopes is the point (Constitution II.1/II.3).
        echo "   UNPROVEN: ${PL_NOFIT} POC scope(s) carry no fittable presentation interval"
        echo "   (scope index: ${PL_NOFIT_AT:-?}; ${PL_NOFIT_PICS} picture(s)). Those pictures are"
        if [ "${PL_NOFIT:-0}" -lt "${PL_SEQS:-0}" ]; then
          echo "   NOT judged here, and NOT accused. The remaining scopes reported on-slot."
        else
          echo "   NOT judged here, and NOT accused. NO scope in this output could be fitted,"
          echo "   so gate (k) has no opinion on it at all — (d)/(j) are the timeline verdict."
        fi
        [ "$verdict" = FAIL ] || verdict=REVIEW
        note="${note:+$note }Gate (k): ${PL_NOFIT} of ${PL_SEQS} POC scope(s) (index ${PL_NOFIT_AT:-?}) have no fittable presentation interval, so ${PL_NOFIT_PICS} picture(s) are UNPROVEN."
        led k unproven "${PL_NOFIT} of ${PL_SEQS} POC scope(s) unfittable (index ${PL_NOFIT_AT:-?}, ${PL_NOFIT_PICS} pictures)"
      elif [ "${PL_OFF:-1}" -ne 0 ]; then
        # SOURCE-BASELINE BEFORE INDICTING (the doctrine gates (c) and (e)
        # already run on). A remux is judged against its source: if the SOURCE's
        # own timeline already contradicts its bitstream — a synthetically
        # re-stamped file, a capture whose timestamps were rewritten downstream —
        # then an output that contradicts it by the same amount is FIDELITY, and
        # calling that damage re-reports a source property as a remux defect.
        # Paid LAZILY: this second whole-file pass only ever runs on a nonzero
        # count, so a clean verify never pays for it.
        echo "   $PL_OFF picture(s) off-lattice in the output — baselining against the source"
        echo "   before indicting the remux (identical extraction, same checker)."
        k_soff=-1
        if [ "$SRC_IS_H264" -eq 1 ]; then
          k_scrc=0
          eval "$(PC_PICS= pf_trace_census "$SRC" "$HTD/spoc.csv" "$HTD/ssps" 2>/dev/null)" || k_scrc=$?
          k_sna=$(grep -c . "$HTD/spoc.csv" 2>/dev/null || true); k_sna=${k_sna:-0}
          # KEEP THE N/A ROWS while pairing, then drop the pairs whose PTS is
          # absent. Filtering first mis-aligns POC row i against packet i+k the
          # moment the source has an unstamped packet — which is the whole class
          # of source this gate is most likely to be asked about.
          ffp -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$SRC" 2>/dev/null | \
            awk -F, 'NF{ print ($1=="N/A" || $1=="") ? "N/A" : $1+0 }' > "$HTD/spts_all.csv" || true
          k_snb=$(grep -c . "$HTD/spts_all.csv" 2>/dev/null || true); k_snb=${k_snb:-0}
          if [ "$k_sna" -gt 0 ] && [ "$k_sna" -eq "$k_snb" ]; then
            k_smax=0; k_sl2=$(head -1 "$HTD/ssps" 2>/dev/null || true)
            case "${k_sl2:-}" in ''|*[!0-9]*) ;; *) [ "$k_sl2" -le 12 ] && k_smax=$((1 << (k_sl2 + 4)));; esac
            paste -d, "$HTD/spoc.csv" "$HTD/spts_all.csv" | awk -F, '$3!="N/A"' > "$HTD/stable.csv"
            eval "$(pf_poc_lattice "$HTD/stable.csv" "$k_smax" | sed 's/^PL_/SPL_/')"
            k_soff=${SPL_OFF:-0}
          fi
        fi
        k_sshow="$k_soff"; [ "$k_soff" -lt 0 ] && k_sshow="unmeasurable"
        echo "   source-baseline (identical extraction): source: $k_sshow off of ${SPL_TOTAL:-0} / output: $PL_OFF off of $PL_TOTAL"
        # THE COMPARISON HAS TO BE LIKE FOR LIKE. The source table carries only
        # the pictures the source actually STAMPED; a repair rung that filled
        # holes hands the output more rows than the source ever had, and those
        # extra rows can only add to the output count. So the budget is the
        # source own off-lattice count PLUS the packets the source never placed
        # at all: the remux may not move a picture the source HAD placed, and a
        # reconstructed stamp answers to the rung evidence rules and gates
        # (d)/(j) rather than being indicted here a second time.
        k_extra=$((PL_TOTAL - ${SPL_TOTAL:-0})); [ "$k_extra" -lt 0 ] && k_extra=0
        k_budget=$((k_soff + k_extra))
        if [ "$k_extra" -gt 0 ]; then
          echo "   (the source stamped $k_extra fewer picture(s) than the output carries — those"
          echo "    reconstructed stamps are the repair rung own evidence to answer for)"
        fi
        if [ "$k_soff" -ge 0 ] && [ "$PL_OFF" -le "$k_budget" ]; then
          [ "$verdict" = FAIL ] || verdict=REVIEW
          echo "   >> INHERITED: the SOURCE own timeline contradicts its bitstream by at"
          echo "      least as much ($k_soff off-lattice; budget $k_budget with the $k_extra"
          echo "      reconstructed stamp(s)). The remux moved no picture the source had"
          echo "      placed; that is fidelity, not damage. The SOURCE is the review item."
          note="${note:+$note }Gate (k): $PL_OFF of $PL_TOTAL output pictures are off their POC lattice slot, within the budget $k_budget (the source own $k_soff plus $k_extra reconstructed stamp(s)) — inherited, not remux damage. The source timeline contradicts its own bitstream."
          led k flagged "off-lattice $PL_OFF within budget $k_budget (source $k_soff + $k_extra reconstructed stamps) — inherited"
        elif [ "$k_soff" -lt 0 ]; then
          # EMPTY is not ABSENT (III.1), applied to an accusation: a baseline
          # that could not be measured is not a baseline of zero, and an
          # unmeasured comparison may not convict the remux.
          [ "$verdict" = FAIL ] || verdict=REVIEW
          echo "   >> UNPROVEN: $PL_OFF picture(s) are off-lattice in the output, and the"
          echo "      source baseline could NOT be measured — so it is not established"
          echo "      whether this came from the remux or was already in the source."
          echo "      Settle it: scripts/poc-gate.sh \"$SRC\" and scripts/poc-gate.sh \"$OUT\""
          note="${note:+$note }Gate (k): $PL_OFF of $PL_TOTAL output pictures are off their POC lattice slot, and the source baseline could not be measured — UNPROVEN whether the remux caused it."
          led k unproven "$PL_OFF off-lattice in the output, source baseline unmeasurable"
        else
          verdict=FAIL; other_failed=1
          echo "   >> gate (k) FAILS: $PL_OFF picture(s) sit off their presentation slot, beyond the"
          echo "      $k_budget the source explains (its own $k_soff plus $k_extra reconstructed"
          echo "      stamp(s)) — a picture the source HAD placed was moved. The written timeline"
          echo "      CONTRADICTS the display order the bitstream itself states. A"
          echo "      constant-rate restamp of a reordered stream reads exactly like this."
          note="${note:+$note }Gate (k): $PL_OFF of $PL_TOTAL pictures are off the presentation lattice their own pic_order_cnt declares (source baseline: $k_soff) — the container's display order contradicts the bitstream."
          led k fail "$PL_OFF of $PL_TOTAL pictures off their POC lattice slot (source baseline $k_soff)"
        fi
      else
        echo "   PASS: every picture sits where its own pic_order_cnt says it should."
        led k pass "$PL_ON/$PL_TOTAL pictures on their POC lattice slot across $PL_SEQS scope(s)"
      fi
    fi
  fi
  rm -rf "$HTD"
fi

# --- (i) codec-tag-vs-payload identity --------------------------------------
# The sample entry must describe the payload underneath it. Two halves:
# tag<->codec (every stream, cheap) and tag<->payload frame headers (MPEG audio
# layer bits, AC-3 bsid). What cannot be proven from the payload is reported
# UNPROVEN by name, never passed quietly.
echo "-- (i) sample entry vs payload identity --"
# The condition is python3's availability, full stop. An earlier draft also
# tested the script's executable bit, which made the && false whenever the
# script WAS present — so a missing interpreter fell through to a generic
# "rc=127" row that never named the tool. A ledger row that cannot say what is
# missing is most of the way back to saying nothing.
if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$SELF_DIR/codec-id.py" ]; then
  [ "$verdict" = FAIL ] || verdict=REVIEW
  i_miss="python3"; [ -f "$SELF_DIR/codec-id.py" ] || i_miss="scripts/codec-id.py"
  echo "   $i_miss is not available — this gate could not run."
  note="${note:+$note }Gate (i): $i_miss absent, so sample-entry-vs-payload identity is UNPROVEN."
  led i unproven "$i_miss is not available on this host"
else
  i_rc=0
  set +e; i_out=$(python3 "$SELF_DIR/codec-id.py" "$OUT" 2>&1); i_rc=$?; set -e
  printf '%s\n' "$i_out" | sed -n 's/^CI_ROW /   /p'
  i_mis=$(printf '%s\n' "$i_out" | sed -n 's/^CI_MISMATCH=//p' | awk 'NR<=1')
  i_unp=$(printf '%s\n' "$i_out" | sed -n 's/^CI_UNPROVEN=//p' | awk 'NR<=1')
  i_read=$(printf '%s\n' "$i_out" | sed -n 's/^CI_READ=//p' | awk 'NR<=1')
  case "${i_mis:-}" in ''|*[!0-9]*) i_mis=-1;; esac
  case "${i_unp:-}" in ''|*[!0-9]*) i_unp=0;; esac
  if [ "${i_read:-no}" != yes ] || [ "$i_mis" -lt 0 ]; then
    [ "$verdict" = FAIL ] || verdict=REVIEW
    i_why=$(printf '%s\n' "$i_out" | sed -n 's/^CI_WHY=//p' | awk 'NR<=1')
    echo "   the identity pass could not read this output (${i_why:-rc=$i_rc}) — UNPROVEN."
    note="${note:+$note }Gate (i): sample-entry-vs-payload identity could not be evaluated (${i_why:-rc=$i_rc})."
    led i unproven "${i_why:-the identity pass failed, rc=$i_rc}"
  elif [ "$i_mis" -gt 0 ]; then
    verdict=FAIL; other_failed=1
    echo "   >> gate (i) FAILS: $i_mis stream(s) carry a sample entry that does not describe their"
    echo "      payload. A decoder that accepts both hides this completely — ffmpeg's"
    echo "      mp3float decodes Layer II happily under a '.mp3' entry, so the decode"
    echo "      probe and the essence hash both pass a mislabelled file (2026-08-29)."
    note="${note:+$note }Gate (i): $i_mis output stream(s) carry a sample entry that misdescribes their payload (see the CI_ROW lines) — lossless and still wrong."
    led i fail "$i_mis stream(s) declare a sample entry their payload contradicts"
  elif [ "$i_unp" -gt 0 ]; then
    echo "   PASS on what is provable; $i_unp stream(s) carry no readable frame header"
    echo "   (AAC in esds, raw PCM) — their tag agrees with the container's own codec name,"
    echo "   and the payload half is not provable from here."
    led i pass "tag<->codec agrees on every stream; payload half unprovable on $i_unp stream(s) (no readable frame header)"
  else
    echo "   PASS: every sample entry agrees with the payload underneath it."
    led i pass "every stream's sample entry agrees with its payload"
  fi
fi

# --- (m) the essence ARBITER: NAL-payload hash ------------------------------
# Only ever paid to adjudicate a (b) MISMATCH. Merging two field access units
# into one sample legitimately turns a 4-byte start code into a 3-byte one, so
# a byte hash false-mismatches a PROVABLY CORRECT build by exactly one byte per
# merged pair. This compares NAL payloads, which no framing choice can change.
if [ "${VCL_MISMATCH:-0}" -eq 1 ]; then
  echo "-- (m) essence arbiter: NAL-payload hash (start-code-length agnostic) --"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "   python3 is not available — the arbiter could not run, so gate (b)'s MISMATCH stands."
    led m unproven "python3 is not available, so (b)'s byte-level mismatch could not be arbitrated"
  else
    m_sb=""; m_ob=""
    [ "$(ffp1 -v error -select_streams v:0 -show_entries stream=is_avc -of default=nw=1:nk=1 "$SRC" 2>/dev/null || true)" = true ] && m_sb="h264_mp4toannexb,"
    [ "$(ffp1 -v error -select_streams v:0 -show_entries stream=is_avc -of default=nw=1:nk=1 "$OUT" 2>/dev/null || true)" = true ] && m_ob="h264_mp4toannexb,"
    set +e
    m_s=$(python3 "$SELF_DIR/nalhash.py" "$SRC" --bsf "${m_sb}filter_units=pass_types=1-5" --kv 2>/dev/null | sed -n 's/^NH_MD5=//p' | awk 'NR<=1')
    m_o=$(python3 "$SELF_DIR/nalhash.py" "$OUT" --bsf "${m_ob}filter_units=pass_types=1-5" --kv 2>/dev/null | sed -n 's/^NH_MD5=//p' | awk 'NR<=1')
    set -e
    echo "   src NAL payload md5=${m_s:-EMPTY}"
    echo "   out NAL payload md5=${m_o:-EMPTY}"
    if [ -z "$m_s" ] || [ -z "$m_o" ]; then
      echo "   the arbiter produced no hash on one side — (b)'s MISMATCH stands, unarbitrated."
      led m unproven "the NAL-payload pass produced no hash on one side"
    elif [ "$m_s" = "$m_o" ]; then
      # a genuine correction of gate (b): the coded pictures ARE identical and
      # only the Annex-B framing changed. This is the one place a FAIL is lifted,
      # and it is lifted by a STRONGER measurement, never by a tolerance.
      echo "   >> ARBITRATED: the coded picture data is IDENTICAL; only the Annex-B start-code"
      echo "      framing differs (merging a field pair into one sample costs exactly one byte"
      echo "      per pair). Gate (b)'s byte-level mismatch was a framing artefact, not loss."
      bitproven=1
      if [ "$other_failed" -eq 1 ] && [ "$verdict" = FAIL ]; then
        verdict=REVIEW; other_failed=0
        note="${note:+$note }Gate (b) mismatched at the byte level and gate (m) arbitrated it: the NAL payloads are identical, so the essence is lossless — the difference is Annex-B framing. Review the rest of the report."
      fi
      led m pass "NAL payloads identical (md5=$m_s) — (b)'s byte mismatch was start-code framing"
    else
      echo "   >> the NAL payloads differ too — gate (b)'s MISMATCH is real essence loss."
      led m fail "NAL payloads differ (src=$m_s out=$m_o) — real essence loss, not framing"
    fi
  fi
else
  led m "n/a" "gate (b) proved the essence at the byte level; the arbiter is only paid on a mismatch"
fi

if [ "$SILP" -eq 1 ]; then
  echo "-- (--silence) silence content-parity (source vs output audio) --"
  # The injected-silence signature: a re-timed build re-padded silence from t=0
  # on a filter-graph rebuild (mid-stream layout change) — hundreds of seconds of
  # silence with A/V durations still matching, so gate (f) passes it. Legitimate
  # resync gap-fill silence is bounded by the source's forward gaps (DISC_P_MISSING).
  # EMPTY ≠ ABSENT (WO-1.15.4 leftover ledger, closed 1.15.19): the rule was
  # applied to the gates that run by DEFAULT — (f) and (g), which announce
  # this same probe's failure a few hundred lines above — and left here, at a
  # gate the operator had to ASK for. Measured pre-fix: (f) and (g) print
  # "audio census probe FAILED … UNPROVEN" and two lines later this gate read
  # the SAME failed probe as "no audio in output". The caller who typed
  # --silence is the one caller who has declared they want this evidence; a
  # silent N/A is the worst possible answer to give them.
  set +e
  sil_cen=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$OUT" 2>/dev/null); sil_cen_rc=$?
  set -e
  nao=0
  if [ "$sil_cen_rc" -eq 0 ]; then
    nao=$(printf '%s\n' "$sil_cen" | LC_ALL=C sort -u | awk 'NF{n++} END{print n+0}')   # distinct indices: a program-bearing OUT lists each stream twice
  fi
  if [ "$sil_cen_rc" -ne 0 ]; then
    echo "   audio census probe FAILED (ffprobe rc=$sil_cen_rc) — silence parity UNPROVEN, not N/A."
    [ "$verdict" = FAIL ] || verdict=REVIEW
    note="${note:+$note }--silence could not census the output audio (ffprobe rc=$sil_cen_rc) — silence parity is UNPROVEN (not disproven); re-run verify when the probe succeeds."
  elif [ "${nao:-0}" -eq 0 ]; then
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
  tag=$(ffp1 -v error -select_streams v:0 -show_entries stream_tags=encoder -of default=nw=1:nk=1 "$f" 2>/dev/null)
  case "$tag" in *x264*|*x265*|*Lavc*) : ;; *) tag="";; esac
  sei=$(ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$f" -map 0:v:0 -frames:v 60 -c copy -f mpegts - 2>/dev/null | \
        LC_ALL=C grep -aoE 'x264|x265|Lavc' | sort -u | paste -sd, - || true)
  printf '%s' "${tag:+$tag }${sei}"
}
osig=$(vsig "$OUT"); ssig=$(vsig "$SRC")
r4tag=$(ffp1 -v error -show_entries format_tags=com.apple.quicktime.rung4.reencoded-with-attestation -of default=nw=1:nk=1 "$OUT" 2>/dev/null)
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
    # EMPTY ≠ ABSENT (CHECKUP-2026-08-27 D2 / WO-1.15.4): the two whole-file
    # decodes used to run in statement position — a mid-decode failure (I/O
    # error at 90% of a 2 h broadcast; stderr already discarded) was a SILENT
    # ERR-trap exit 1 indistinguishable from a real FAIL, and the mktemp dir
    # (~40 MB of framemd5 lists) leaked. Capture each rc; a failed decode is
    # INCONCLUSIVE (UNPROVEN, not FAILED) and the scratch dir dies either way.
    hl_src_rc=0; hlist "$SRC" > "$HLD/s" || hl_src_rc=$?
    hl_out_rc=0; hlist "$OUT" > "$HLD/o" || hl_out_rc=$?
    if [ "$hl_src_rc" -ne 0 ] || [ "$hl_out_rc" -ne 0 ]; then
      echo "   --full decode FAILED mid-stream (src rc=$hl_src_rc, out rc=$hl_out_rc) — the"
      echo "   whole-file presentation-order check is INCONCLUSIVE: not proof of loss,"
      echo "   not proof of losslessness. Fix the read/decode problem and re-run --full."
      [ "$verdict" = FAIL ] || verdict=REVIEW
      note="${note:+$note }--full whole-file decode failed mid-stream (src rc=$hl_src_rc, out rc=$hl_out_rc) — presentation-order check UNPROVEN, not FAILED; re-run --full after fixing the read/decode problem."
      rm -rf "$HLD"
    else
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
    fi
  else
    echo "-- (--full) whole-file decoded-pixel identity (two full decodes) --"
    fmd5 () { ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$1" -map 0:v:0 -c:v rawvideo -f md5 - | sed 's/^MD5=//'; }
    # same D2 shape as the H.264 arm: statement-position decodes died silently
    # on a mid-stream failure; capture each rc and call the check inconclusive.
    fm_src_rc=0; s=$(fmd5 "$SRC") || fm_src_rc=$?
    fm_out_rc=0; d=$(fmd5 "$OUT") || fm_out_rc=$?
    if [ "$fm_src_rc" -ne 0 ] || [ "$fm_out_rc" -ne 0 ] || [ -z "$s" ] || [ -z "$d" ]; then
      echo "   --full decode FAILED mid-stream (src rc=$fm_src_rc, out rc=$fm_out_rc) — the"
      echo "   decoded-pixel identity check is INCONCLUSIVE: not proof of loss, not proof"
      echo "   of losslessness. Fix the read/decode problem and re-run --full."
      [ "$verdict" = FAIL ] || verdict=REVIEW
      note="${note:+$note }--full decoded-pixel identity failed mid-stream (src rc=$fm_src_rc, out rc=$fm_out_rc) — UNPROVEN, not FAILED; re-run --full after fixing the read/decode problem."
    else
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
fi

if [ "$SIG" -eq 1 ]; then
  echo "-- (--signaling) color / HDR / caption preservation (source vs output) --"
  sg () { ffp1 -v error -select_streams v:0 -show_entries stream="$2" -of default=nw=1:nk=1 "$1" 2>/dev/null; }
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
    sg_ofmt=$(ffp1 -v error -show_entries format=format_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null)
    sg_qtff=0; case ",$sg_ofmt," in *,mov,*|*,mp4,*) sg_qtff=1;; esac
    if [ "$sg_qtff" -eq 1 ]; then
      t=$(ffp1 -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$OUT" 2>/dev/null)
      [ "$t" = hvc1 ] && echo "   HEVC tag=hvc1 (QuickTime-playable)" || { echo "   HEVC tag=$t — NOT hvc1; QuickTime won't play it (DRIFT)"; sdrift=1; }
    else
      echo "   HEVC tag: output container '$sg_ofmt' is not QTFF — hvc1 assertion skipped (tag N/A)"
    fi
  fi
  ccs=$(ffp1 -v error -select_streams v:0 -show_entries stream=closed_captions -of default=nw=1:nk=1 "$SRC" 2>/dev/null)
  cco=$(ffp1 -v error -select_streams v:0 -show_entries stream=closed_captions -of default=nw=1:nk=1 "$OUT" 2>/dev/null)
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
  # EMPTY ≠ ABSENT (WO-1.15.4 leftover ledger, closed 1.15.19): same census,
  # same `|| true`, same trap as --silence above — a failed probe printed
  # "output has 0 audio track(s) … Skipping." and exited clean, reporting a
  # track COUNT that was never measured to a caller who explicitly asked this
  # gate to run. A failed census is UNPROVEN; a genuine 1-track layout is
  # still an ordinary skip (the discrimination pin in test 95 §L2b).
  set +e
  aud_cen=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$OUT" 2>/dev/null); aud_cen_rc=$?
  set -e
  na=0
  if [ "$aud_cen_rc" -eq 0 ]; then
    na=$(printf '%s\n' "$aud_cen" | LC_ALL=C sort -u | awk 'NF{n++} END{print n+0}')   # distinct indices: a program-bearing OUT lists each stream twice
  fi
  a0c=$(ffp1 -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null)
  if [ "$aud_cen_rc" -ne 0 ]; then
    echo "   audio census probe FAILED (ffprobe rc=$aud_cen_rc) — dual-track fidelity UNPROVEN, not skipped."
    [ "$verdict" = FAIL ] || verdict=REVIEW
    note="${note:+$note }--audio could not census the output audio (ffprobe rc=$aud_cen_rc) — dual-track fidelity is UNPROVEN (not disproven); re-run verify when the probe succeeds."
  elif [ "${na:-0}" -lt 2 ]; then
    echo "   output has ${na:-0} audio track(s); dual-track checks need PCM access + original. Skipping."
  elif case "$a0c" in pcm_*) false;; *) true;; esac; then
    echo "   a:0 is '$a0c', not PCM — not a dual-track-access layout. Skipping."
  else
    raw=${a0c#pcm_}
    a1c=$(ffp1 -v error -select_streams a:1 -show_entries stream=codec_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null)
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
      s0c=$(ffp1 -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$SRC" 2>/dev/null)
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
      ach=$(ffp1 -v error -select_streams a:0 -show_entries stream=channels    -of default=nw=1:nk=1 "$OUT" 2>/dev/null)
      asr=$(ffp1 -v error -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 "$OUT" 2>/dev/null)
      case "$a0c" in pcm_s16le) bps=2;; pcm_s24le) bps=3;; pcm_s32le|pcm_f32le) bps=4;; pcm_s8|pcm_u8) bps=1;; *) bps=0;; esac
      case "$ach" in ''|*[!0-9]*) ach=0;; esac
      case "$asr" in ''|*[!0-9]*) asr=0;; esac
      bpf=$((bps * ach))
      spo () {  # spo TRACK -> declared start offset in SAMPLES (0 if undeclared)
        # BY KEY, never by line number (CHECKUP-2026-08-27 C6 / WO-1.15.4):
        # ffprobe emits stream fields in ITS canonical order regardless of the
        # request order (the remux.sh OTHERS/metadata.sh house lesson) —
        # measured here: line 1 is time_base, line 2 is start_pts. The nk=1
        # form read them SWAPPED, split("0","/") gave an empty denominator,
        # and this function printed 0 unconditionally — which killed the D4
        # "delta == declared start_pts" branch below as dead code and printed
        # a false measurement into the report.
        ffp -v error -select_streams "a:$1" -show_entries stream=start_pts,time_base \
            -of default=nw=1 "$OUT" 2>/dev/null | \
          awk -F= -v r="$asr" '$1=="start_pts"{p=$2} $1=="time_base"{tb=$2}
            END{ split(tb,t,"/")
              if(p==""||p=="N/A"||t[2]+0==0||r+0==0){print 0; exit}
              printf "%.0f", p*t[1]/t[2]*r }'
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

# ============================================================================
# Gate (n) — THE UNPROVEN LEDGER. "A verifier states what it could not prove."
#
# Every gate above files a row, INCLUDING the ones that could not run. Before
# 1.16.0 a gate that did not run left no trace: the reader saw the gates that
# spoke and had no way to know which had stayed silent. That is the quiet
# assumption this whole round is about — on 2026-08-28 two broken builds passed
# every check the plugin HAD, and the checks it lacked said nothing at all.
#
# Callers print this block verbatim. "Built; these checks could not run; here
# is what that leaves unproven" is a GOOD outcome and it reads REVIEW, which
# every caller maps to its own exit 10.
# ============================================================================
n_unproven=0
if [ -n "$LEDGER" ]; then
  n_unproven=$(printf '%s' "$LEDGER" | awk -F'|' '$2=="unproven"{n++} END{print n+0}')
fi
# An UNPROVEN gate that was OWED downgrades a clean run to REVIEW. It never
# upgrades a FAIL, and `n/a` (the gate does not apply to this input) and
# `superseded` (a stronger gate settled it) never move the verdict at all —
# without that split every run would read REVIEW and the signal would be worth
# nothing.
if [ "$n_unproven" -gt 0 ] && [ "$verdict" = PASS ]; then
  verdict=REVIEW
  note="${note:+$note }$n_unproven gate(s) could not be evaluated on this input — see the VERIFY_LEDGER block for which, and what each leaves unproven."
fi

echo
echo "-- (n) ledger: every gate, including the ones that could not run --"
printf '%s' "$LEDGER" | awk -F'|' 'NF>=2{ printf "VERIFY_LEDGER gate=%s verdict=%s why=%s\n", $1, $2, $3 }'
printf '%s' "$LEDGER" | awk -F'|' '$2=="unproven"{ printf "   UNPROVEN (%s): %s — nothing in this report claims otherwise.\n", $1, $3 }'
[ "$n_unproven" -eq 0 ] && echo "   every gate above reached a verdict; nothing is left unproven."
echo "VERIFY_LEDGER_SUMMARY gates=$(printf '%s' "$LEDGER" | grep -c . || true) unproven=$n_unproven verdict=$verdict"

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
    # A WAIVER NEVER COVERS WHAT WAS NOT CHECKED (1.16.0). Eligibility already
    # required that no gate outside the (d)/(e) count signature FAILED; it now
    # also requires that none was left UNPROVEN. Waiving a count signature while
    # a gate that could contradict it has not run is exactly the quiet
    # assumption this round exists to close — and on a large output the two
    # container gates decline on budget by default, so this is the common case,
    # not a corner. `--full` runs them and the waiver becomes available again.
    if [ "$other_failed" -eq 0 ] && [ "${n_unproven:-0}" -gt 0 ]; then
      echo ">> NOT waiver-eligible: $n_unproven gate(s) could not be evaluated on this"
      echo "   run (see the ledger above). A waiver covers a signature that independent"
      echo "   proofs have CLEARED; it cannot cover one they were never asked about."
      echo "   Re-run with --full (or raise RTM_STRUCT_MAX_BYTES) and try again."
    elif [ "$other_failed" -eq 0 ]; then
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
        rsize=$(sed -n 's/^[[:space:]]*"file_size":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$WVR" | awk 'NR<=1')
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
