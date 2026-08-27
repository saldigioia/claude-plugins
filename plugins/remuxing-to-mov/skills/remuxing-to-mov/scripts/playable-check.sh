#!/usr/bin/env bash
# playable-check.sh — OPTIONAL macOS-only probe of the "playable" half of
# "playable != valid": can QuickTime/AVFoundation actually open and DECODE this
# file? ffmpeg can't answer that. No-op on non-macOS so it's safe in any pipeline.
#
# Usage: scripts/playable-check.sh [--fidelity] OUTPUT.mov
#        (the flag is accepted before or after the file)
# Exit:  0 = AVFoundation rendered a frame (and, with --fidelity, rendered it
#            CORRECTLY — SSIM vs the ffmpeg reference decode >= threshold)
#        1 = it could not (no frame, or --fidelity found a destroyed render)
#        2 = usage (unknown option, extra positional, or no such file)
#        3 = skipped (not macOS / no qlmanage; --fidelity additionally skips
#            without avconvert/ffmpeg) — confirm on the target Mac
#        (bare no-args stays the historic ${1:?} death, exit 1 — suite-pinned)
#
# METHOD: ask QuickLook (which uses AVFoundation, the same stack QuickTime Player
# uses) to render a thumbnail. A produced image means the system decoded a real
# frame. NOTE: this proves VIDEO decode/open only; audio playability (AC-3/E-AC-3/
# DTS) is not covered — listen once if it matters.
#
# FLOOR, NOT SIGN-OFF (post-mortem 2026-07-25): a thumbnail proves ONE frame
# decodes; it says NOTHING about the presentation timeline. A file with a
# muxer-invented timeline renders a thumbnail and is unwatchable in real
# playback. Sign-off for a suspect timeline = verify.sh's full gate set
# (timeline scan, scrub gate, A/V parity) — this check is only the last-mile
# "QuickTime can open it" floor on top of that.
#
# THE FLOOR HAS A FIDELITY STOREY (WO-B, 2026-08-15): a frame RENDERING proves
# neither the timeline nor the PIXELS. On 2026-08-15 two real broadcast MPEG-2
# 4:2:2 masters (m2v1, 1080i59.94) returned "playable-check: OK … verdict=ok"
# on macOS 26.6.1 while QuickTime rendered them as macroblock garbage — the
# thumbnail probe only proves qlmanage produced A file within the deadline; a
# corrupted render passes it. `--fidelity` closes that hole empirically: render
# the same moments through AVFoundation (bounded avconvert ProRes trims) and
# through ffmpeg (the trusted reference decoder), then compare with SSIM after
# both sides are normalized to a common full-resolution pixel format
# (yuv444p — so 4:2:2-vs-4:2:0 chroma siting never depresses a healthy score).
# Renders != renders correctly; only the comparison proves the pixels.
# The default (no flag) invocation keeps its exits and its verdict lines; 1.13
# changed only the ROUTES a FAIL prints (D2 — the container swap now precedes
# Rung 4) and added the extension NOTE when the argument is not .mov/.mp4 (D6).
#
# THE STOREY IS SCAN-AWARE (D1, 1.13, 2026-08-15): the 0.90 default was tuned on
# PROGRESSIVE material and false-FAILs healthy INTERLACED sources. Measured both
# ways: the field report's real 1080i59.94 capture scored 0.8866–0.9684 on
# healthy windows against 0.8146–0.8471 on corrupt ones (the bands nearly touch,
# and 0.8866 already failed 0.90), and on this bench (macOS 26.6.1 / ffmpeg
# 9.0.1) a synthetic healthy interlaced 4:2:2 MPEG-2 clip scored All 0.8669 —
# a false FAIL. So an interlaced source is judged against
# RTM_FIDELITY_SSIM_INTERLACED (default 0.86, sitting in the measured gap),
# progressive against RTM_FIDELITY_SSIM (0.90), and the scan is announced.
# FIELD NORMALIZATION WAS TRIED AND REJECTED, measured not assumed (same bench,
# same clip, best-frame All): bwdif on the reference 0.8669 (a no-op), yadif
# 0.8718, bwdif on both sides 0.8661, setfield=prog on either/both 0.8669,
# scale interl=0 on both 0.8669, an 8-bit-chroma path 0.8669, nearest-neighbour
# scaling 0.8612 — every candidate moved the number by <=0.005. The deficit is
# not field STRUCTURE: the plane split names it (Y 0.8892 vs U 0.8527 / V
# 0.8588 on the best-matched frame; Y 0.9678 vs U 0.8441 / V 0.8461 on the best
# temporally-aligned one), i.e. healthy interlaced 4:2:2 pays its SSIM in the
# CHROMA planes. That split is now reported per sample and on the machine line
# (y=/u=/v=), so a FAIL can NAME chroma-geometry corruption instead of handing
# back one opaque scalar.
#
# A FIDELITY FAIL IS NOT A ONE-ROUTE VERDICT (D2, 1.13): the lossless CONTAINER
# SWAP (same bitstream, MP4, `-tag:v mp4v` + esds) sits between the retag and
# Rung 4 — measured 2026-08-15 on the 21 GB capture at SSIM 0.9175+ on the very
# timestamps that failed in MOV. scripts/mp4-swap.sh performs it; the machine
# line carries mp4_swap=untried here because this script sees only the OUTPUT,
# never the source it was built from.
#
# NOTE: the macOS path cannot be exercised on Linux/CI; validate on a real Mac.
set -euo pipefail
export LC_ALL=C   # comma-decimal locales disarm awk float parsing (CHECKUP-2026-08-27 A3; rationale in lib-probe.sh, which this script does not source)
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
RTM_EXIT_OK="0 1 2 3 10 11" # + this script's documented 3 (SKIP: not macOS / no qlmanage; suite-pinned)
# arg surface (WO-B): the bare-${1:?} usage death (exit 1 — measured 1.11.0
# baseline, suite-pinned; NOT a usage exit 2) is preserved by expanding $1
# before any parsing. The flag may sit on either side of the file.
: "${1:?usage: playable-check.sh [--fidelity] OUTPUT.mov}"
FIDELITY=0; OUT=""
for a in "$@"; do case "$a" in
  --fidelity) FIDELITY=1;;
  -*) echo "playable-check: unknown option $a (usage: playable-check.sh [--fidelity] OUTPUT.mov)" >&2; exit 2;;
  *)  if [ -n "$OUT" ]; then echo "playable-check: one OUTPUT only (usage: playable-check.sh [--fidelity] OUTPUT.mov)" >&2; exit 2; fi
      OUT="$a";;
esac; done
[ -n "$OUT" ] || { echo "playable-check: OUTPUT.mov required (usage: playable-check.sh [--fidelity] OUTPUT.mov)" >&2; exit 2; }
[ -f "$OUT" ] || { echo "no such file: $OUT" >&2; exit 2; }

# fid_note REASON WHY — every fidelity skip is ANNOUNCED (house rule: announced,
# never silent) and carries the machine token the wrapper parses. Emitted only
# when the mode was requested; a default invocation prints NOTHING new.
fid_note () {
  echo "playable-check: fidelity SKIP — $2"
  echo "PLAYCHECK_FIDELITY verdict=skip reason=$1 ssim=na os=${OSV:-na} y=na u=na v=na scan=${SCAN:-unknown} thresh=na mp4_swap=untried"
}
# mp4_swap_route WHY — the container-swap rung, named wherever a fidelity/decode
# FAIL is routed (D2). Rung 4 is no longer the FIRST named route out of a bad
# render; it is the LAST. This script only ever sees the finished OUTPUT, so it
# names the command and records mp4_swap=untried — the drivers (mov.sh/auto.sh
# --mp4-swap), which still hold the source, are what can actually run it.
mp4_swap_route () {
  echo "   Routes out, cheapest first (Rung 4 is the LAST one, not the first):"
  echo "     retag        MPEG-2 4:2:2 tagged 'm2v1' -> the XDCAM HD422 entry, a 4-byte"
  echo "                  stream-copy change: ffmpeg -i IN -map 0 -c copy -tag:v xd5b"
  echo "                  -movflags +faststart OUT.mov  (works when the stream matches"
  echo "                  the fourcc's profile contract — the 2026-08-15 VMA pair; it"
  echo "                  did NOT save the 2026-08-15 21 GB capture, where all five"
  echo "                  retags corrupted identically)"
  echo "     mp4swap      LOSSLESS CONTAINER SWAP — same bitstream, MP4 container,"
  echo "                  'mp4v'+esds instead of 'm2v1'+glbl: scripts/mp4-swap.sh SOURCE"
  echo "                  (measured 2026-08-15: SSIM 0.9175+ on the same timestamps that"
  echo "                   failed as .mov. ffmpeg's MOV tag table refuses to write that"
  echo "                   entry into a .mov — the deliverable is a .mp4, losslessly)"
  echo "     rung4        scripts/rung4.sh — operator-attested RE-ENCODE, last resort"
  echo "                  (recipes in references/delivery-encode.md)"
}

if [ "$(uname -s)" != Darwin ]; then
  echo "playable-check: SKIP — not macOS; AVFoundation/QuickTime unavailable. Confirm on the target Mac."
  if [ "$FIDELITY" -eq 1 ]; then fid_note not-macos "the AVFoundation render half needs macOS too."; fi
  exit 3
fi
command -v qlmanage >/dev/null 2>&1 || {
  echo "playable-check: SKIP — qlmanage not found."
  if [ "$FIDELITY" -eq 1 ]; then fid_note no-qlmanage "qlmanage missing implies no usable AVFoundation toolchain here."; fi
  exit 3
}
# QTFF audit 5-1c (C63): the verdict is a property of the OS it ran on — decode
# support drifts across macOS versions (Tahoe 26.4 dropped MJPEG variants/AIC),
# so every recorded check self-dates its OS. Annotation only; no logic change.
OSV=$(sw_vers -productVersion 2>/dev/null || echo '?')

if [ "$FIDELITY" -eq 1 ]; then
  echo "playable-check: fidelity mode — after the thumbnail floor, the SAME moments will be"
  echo "  rendered through AVFoundation (bounded avconvert ProRes trims) and through ffmpeg"
  echo "  (the reference decoder), then compared with SSIM at yuv444p — threshold ${RTM_FIDELITY_SSIM:-0.90} progressive"
  echo "  (RTM_FIDELITY_SSIM) / ${RTM_FIDELITY_SSIM_INTERLACED:-0.86} interlaced (RTM_FIDELITY_SSIM_INTERLACED), keyed off the"
  echo "  output's field_order and announced below with the per-plane Y/U/V split."
  echo "  Motive (2026-08-15, macOS 26.6.1): two real broadcast MPEG-2 4:2:2"
  echo "  masters thumbnailed OK while QuickTime rendered macroblock garbage — renders != renders correctly."
fi

TMP="$(mktemp -d)"; SIBLINK=""
trap 'rm -rf "$TMP"; [ -n "$SIBLINK" ] && rm -f "$SIBLINK"' EXIT

# --- extension guard (D1.13/D6): qlmanage is EXTENSION-KEYED ------------------
# qlmanage picks its thumbnail extension from the FILENAME, so a build sitting
# under a non-QTFF name — every builder's atomic part file, mov.sh's
# `.premeta`, auto.sh's parked `.autobest`, a hand-renamed diagnostic copy —
# rendered no frame and drew "the decode stack cannot handle this input": a
# DECODE verdict for a FILENAME problem. The codebase already learned this in
# the builders (trim-to-idr.sh's "x.part.ts, not x.ts.part"; qt-groups.sh cites
# it) and never applied it here. So: announce, then probe through a link that
# carries a real extension. Announced, never silent — and never a refusal,
# because the operator's diagnostic copy deserves an answer, not a lecture.
#
# HARDLINK, not symlink — measured on this bench (macOS 26.6.1, 2026-08-15):
# qlmanage on a SYMLINK named .mov produced nothing and hit the deadline (Quick
# Look resolves to the real path and keys off THAT extension); the identical
# HARDLINK thumbnailed immediately. A hardlink needs the same filesystem, so:
# temp dir first, then a sibling of the output (same directory = same volume,
# removed on exit), then symlink as the announced last resort. The link is a
# second name for the SAME inode — nothing is copied, nothing is rewritten, and
# the source file this output was built from is never involved.
PROBE="$OUT"
case "$OUT" in
  *.mov|*.MOV|*.mp4|*.MP4|*.m4v|*.M4V|*.qt|*.QT) ;;
  *)
    OABS="$OUT"; case "$OUT" in /*) ;; *) OABS="$PWD/$OUT";; esac
    if ln "$OABS" "$TMP/probe.mov" 2>/dev/null; then
      PROBE="$TMP/probe.mov"; LKIND="hardlink in the temp dir"
    elif SIBLINK="$(dirname "$OABS")/.rtm-probe.$$.mov" && ln "$OABS" "$SIBLINK" 2>/dev/null; then
      PROBE="$SIBLINK"; LKIND="hardlink beside the output (different volume from the temp dir; removed on exit)"
    else
      SIBLINK=""; PROBE="$TMP/probe.mov"; ln -s "$OABS" "$PROBE" 2>/dev/null || PROBE="$OUT"
      LKIND="SYMLINK — the last resort: Quick Look does NOT follow symlinks (measured 2026-08-15), so a FAIL below may still be this filename, not the pixels"
    fi
    echo "playable-check: NOTE '$OUT' carries no QuickTime extension, and qlmanage/avconvert"
    echo "  are EXTENSION-KEYED — the file is probed through a $LKIND:"
    echo "  $PROBE"
    ;;
esac

# BOUNDED probe (WO 1.4, measured): qlmanage -t can hang FOREVER on input the
# thumbnail extension cannot parse (a garbage payload stalled it indefinitely —
# no verdict, no exit code, a wedged pipeline). A hung probe is not a verdict,
# so the render gets a deadline (RTM_QL_TIMEOUT seconds, default 60 — a healthy
# file thumbnails in single-digit seconds). macOS ships no `timeout` binary:
# background the render and poll with the deadline; on expiry the kill leaves
# no PNG, and the normal no-frame path below reports FAIL honestly.
qlmanage -t -s 480 -o "$TMP" "$PROBE" >/dev/null 2>&1 &
QLPID=$!
QLLIMIT="${RTM_QL_TIMEOUT:-60}"
QLDEADLINE=$(( $(date +%s) + QLLIMIT ))
while kill -0 "$QLPID" 2>/dev/null; do
  if [ "$(date +%s)" -ge "$QLDEADLINE" ]; then
    kill -9 "$QLPID" 2>/dev/null || true
    echo "playable-check: qlmanage produced nothing in ${QLLIMIT}s — killed (counted as no"
    echo "  frame rendered). USUALLY the decode stack cannot handle this input — but"
    echo "  qlmanage is extension-keyed, so first check the NAME: a file without a"
    echo "  QuickTime extension hangs/fails here for a filename reason, not a decode one"
    echo "  (this run probed '$PROBE')."
    break
  fi
  sleep 1
done
wait "$QLPID" 2>/dev/null || true
if ls "$TMP"/*.png >/dev/null 2>&1; then
  echo "playable-check: OK on macOS $OSV — AVFoundation rendered a frame; QuickTime can open the video."
  echo "  (audio playability for AC-3/E-AC-3/DTS is NOT proven by a thumbnail — listen if it matters.)"
  echo "  (FLOOR only: one frame decoding proves nothing about the timeline — a broken"
  echo "   timeline still thumbnails. Sign-off = verify.sh's gates, then a real scrub.)"
  THUMB=ok
else
  echo "playable-check: FAIL on macOS $OSV — AVFoundation produced no frame; QuickTime likely can't decode this"
  echo "  (e.g. 4:2:2 MPEG-2, an untagged codec, or a macOS-version codec drop — see"
  echo "  ingest-compatibility.md 'Decode support is a moving target')."
  mp4_swap_route
  THUMB=fail
fi
if [ "$FIDELITY" -eq 0 ]; then
  # default mode ends where 1.11.0 ended — same verdict lines, same exits (the
  # 1.13 additions are the FAIL routes above and the D6 extension NOTE)
  if [ "$THUMB" = ok ]; then exit 0; else exit 1; fi
fi

# --- fidelity storey (WO-B, 2026-08-15) --------------------------------------
if [ "$THUMB" = fail ]; then
  fid_note thumbnail-fail "the thumbnail floor already failed; there is no render to compare."
  exit 1
fi
command -v avconvert >/dev/null 2>&1 || { fid_note no-avconvert "avconvert not found — the AVFoundation render half cannot run. Prove on a Mac that has it."; exit 3; }
command -v ffmpeg    >/dev/null 2>&1 || { fid_note no-ffmpeg "ffmpeg not found — the reference-decode half cannot run."; exit 3; }
command -v ffprobe   >/dev/null 2>&1 || { fid_note no-ffprobe "ffprobe not found — cannot place the sample windows."; exit 3; }
RW=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of default=nw=1:nk=1 "$OUT" 2>/dev/null | awk 'NR==1')
RH=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=nw=1:nk=1 "$OUT" 2>/dev/null | awk 'NR==1')
if [ -z "$RW" ] || [ -z "$RH" ]; then fid_note probe-blind "ffprobe could not read the video geometry; nothing to compare against."; exit 3; fi
DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" 2>/dev/null | awk 'NR==1')
case "$DUR" in ''|N/A) DUR=0;; esac
# --- scan-aware threshold (D1, 1.13) -----------------------------------------
# The 0.90 default is PROGRESSIVE-TUNED and false-FAILs healthy interlaced
# material (header: measured both on the field report's real 1080i59.94 capture
# and on this bench). Field normalization was tried and rejected — the deficit
# lives in the CHROMA planes, not in field structure — so the honest correction
# is a scan-keyed threshold plus the plane split below, not a filter that
# changes nothing. Announced, self-dating, and overridable.
FO=$(ffprobe -v error -select_streams v:0 -show_entries stream=field_order -of default=nw=1:nk=1 "$OUT" 2>/dev/null | awk 'NR==1')
case "$FO" in tt|bb|tb|bt) SCAN=interlaced;; progressive) SCAN=progressive;; *) SCAN=unknown;; esac
# Sample placement: 3 windows across a long file (garbage rarely confines
# itself to one GOP, but one window is a single point of luck), 1 mid-file
# window when short, the whole head when tiny/unknown. Each window is a small
# bounded avconvert trim so the cost never scales with file length.
FWIN=2
if awk -v d="$DUR" 'BEGIN{exit !(d>=8)}'; then
  STARTS=$(awk -v d="$DUR" 'BEGIN{printf "%.3f %.3f %.3f", 0.15*d, 0.45*d, 0.75*d}')
elif awk -v d="$DUR" 'BEGIN{exit !(d>=3)}'; then
  STARTS=$(awk -v d="$DUR" 'BEGIN{printf "%.3f", d/2-1}')
else
  STARTS=0
  if awk -v d="$DUR" 'BEGIN{exit !(d>0.2)}'; then FWIN=$(awk -v d="$DUR" 'BEGIN{printf "%.3f", d}'); fi
fi
if [ "$SCAN" = interlaced ]; then
  THRESH="${RTM_FIDELITY_SSIM_INTERLACED:-0.86}"
  echo "  scan: INTERLACED (field_order=$FO) -> threshold $THRESH (RTM_FIDELITY_SSIM_INTERLACED)."
  echo "    The 0.90 default is progressive-tuned: healthy interlaced windows measured"
  echo "    0.8866-0.9684 against 0.8146-0.8471 corrupt (2026-08-15 field report), and a"
  echo "    healthy synthetic interlaced 4:2:2 clip scored 0.8669 on this bench — 0.90"
  echo "    false-FAILs them. RESIDUAL, said out loud: those bands are ~0.02 apart, so"
  echo "    this floor separates them with thin margin; the per-plane split below is the"
  echo "    corroborating evidence, and a FAIL here routes to the container swap first."
else
  THRESH="${RTM_FIDELITY_SSIM:-0.90}"
  [ "$SCAN" = unknown ] && echo "  scan: UNKNOWN (field_order='${FO:-none}') -> progressive threshold $THRESH (an interlaced source declaring nothing is judged strictly; RTM_FIDELITY_SSIM_INTERLACED applies only to a declared interlaced scan)."
fi
AVLIMIT="${RTM_AVC_TIMEOUT:-120}"   # per-window avconvert deadline (RTM_QL_TIMEOUT style): a hang is a verdict, never a wedge
N=0; MINSSIM=""; FIDFAIL=0; FAILREASON=""; MINY=""; MINU=""; MINV=""
for SSTART in $STARTS; do
  N=$((N+1))
  TREF=$(awk -v s="$SSTART" -v w="$FWIN" 'BEGIN{printf "%.3f", s+w/2}')
  REF="$TMP/ref$N.nut"; CLIP="$TMP/clip$N.mov"
  echo "  [sample $N] reference t=${TREF}s, AVFoundation window ${SSTART}s +${FWIN}s"
  # reference frame stays NATIVE YUV (FFV1 in NUT): a PNG detour goes through
  # RGB with a guessed matrix and measurably depresses chroma SSIM (bench
  # 2026-08-15: All 0.9268 via PNG vs 0.9541 native on the same healthy pair).
  if ! ffmpeg -nostdin -v error -ss "$TREF" -i "$OUT" -map 0:v:0 -frames:v 1 -c:v ffv1 -y -f nut "$REF" 2>/dev/null || [ ! -s "$REF" ]; then
    echo "    ffmpeg produced no reference frame at t=${TREF}s — this sample cannot be judged; moving on."
    continue
  fi
  # bounded AVFoundation render: near-lossless preset so the comparison measures
  # the DECODE, not a lossy re-encode; backgrounded + deadline-killed exactly
  # like the qlmanage probe (an avconvert hang on undecodable input IS the verdict)
  # --source is $PROBE, not $OUT: avconvert is extension-keyed like qlmanage
  # (D6) — on a QuickTime-extensioned output the two are the same path.
  avconvert --preset PresetAppleProRes422LPCM --source "$PROBE" --output "$CLIP" --start "$SSTART" --duration "$FWIN" --replace >/dev/null 2>&1 &
  AVPID=$!
  AVDEADLINE=$(( $(date +%s) + AVLIMIT ))
  AVHUNG=0
  while kill -0 "$AVPID" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$AVDEADLINE" ]; then
      kill -9 "$AVPID" 2>/dev/null || true; AVHUNG=1
      echo "    avconvert produced nothing in ${AVLIMIT}s — killed (RTM_AVC_TIMEOUT; AVFoundation"
      echo "    cannot handle this window — a hang is a fidelity verdict of its own)."
      break
    fi
    sleep 1
  done
  AVRC=0; wait "$AVPID" 2>/dev/null || AVRC=$?
  if [ "$AVHUNG" -eq 1 ]; then FIDFAIL=1; FAILREASON=convert-hang; break; fi
  if [ "$AVRC" -ne 0 ] || [ ! -s "$CLIP" ]; then
    echo "    avconvert could not render this window (rc=$AVRC) — AVFoundation failed on real content."
    FIDFAIL=1; FAILREASON=convert-fail; break
  fi
  # alignment-free compare: the single reference frame rides framesync's
  # repeatlast against EVERY frame of the AVFoundation render, and the BEST
  # match counts — a healthy render must contain (nearly) the reference frame
  # somewhere in the window, whatever avconvert's exact trim boundary was.
  # (Never `-loop 1` on the reference: an infinite secondary input hangs the
  # graph — measured 2026-08-15; the 1-frame input + repeatlast terminates.)
  SLOG="$TMP/ssim$N.log"
  ffmpeg -nostdin -v error -i "$CLIP" -i "$REF" \
    -lavfi "[0:v]scale=${RW}:${RH}:flags=bicubic,format=yuv444p[a];[1:v]format=yuv444p[b];[a][b]ssim=stats_file=$SLOG" \
    -an -f null - 2>/dev/null || true
  if [ ! -s "$SLOG" ]; then
    echo "    the SSIM comparison itself produced no per-frame stats — cannot bless what was not measured."
    FIDFAIL=1; FAILREASON=compare-fail; break
  fi
  # PLANE SPLIT (D1, 1.13): the ssim filter already writes Y/U/V/All per frame —
  # reading only "All" threw away the one number that NAMES the failure class.
  # Healthy interlaced 4:2:2 pays its deficit almost entirely in chroma
  # (measured, header); the hypothesised 4:2:0-geometry misread would collapse
  # chroma AND drag luma. Take the whole row of the BEST-All frame so the four
  # numbers describe the same picture, never a mix of frames.
  eval "$(awk 'BEGIN{m=-1}
      { y=u=v=a=""
        for(i=1;i<=NF;i++){
          c=index($i,":"); if(!c) continue
          k=substr($i,1,c-1); w=substr($i,c+1)
          if(k=="Y")y=w; else if(k=="U")u=w; else if(k=="V")v=w; else if(k=="All")a=w }
        if(a!="" && a+0>m){ m=a+0; by=y+0; bu=u+0; bv=v+0 } }
      END{ if(m<0) m=0
           printf "BEST=%.4f BESTY=%.4f BESTU=%.4f BESTV=%.4f\n", m, by+0, bu+0, bv+0 }' "$SLOG")"
  echo "    best frame-match SSIM vs reference: $BEST  (Y $BESTY  U $BESTU  V $BESTV)"
  if [ -z "$MINSSIM" ] || awk -v a="$BEST" -v b="$MINSSIM" 'BEGIN{exit !(a<b)}'; then
    MINSSIM=$BEST; MINY=$BESTY; MINU=$BESTU; MINV=$BESTV
  fi
done
# the additive plane/scan/threshold fields ride the END of the machine line
# (Ground Rule 4: append, never rename) — os= and verdict=/reason=/ssim= keep
# their byte-for-byte positions, so every existing parser is untouched.
FIDTAIL="y=${MINY:-na} u=${MINU:-na} v=${MINV:-na} scan=$SCAN thresh=$THRESH mp4_swap=untried"
if [ "$FIDFAIL" -eq 1 ]; then
  echo "playable-check: FIDELITY FAIL on macOS $OSV — the AVFoundation side could not be"
  echo "  rendered/compared ($FAILREASON). Treat as not proven QuickTime-playable."
  mp4_swap_route
  echo "PLAYCHECK_FIDELITY verdict=fail reason=$FAILREASON ssim=${MINSSIM:-na} os=$OSV $FIDTAIL"
  exit 1
fi
if [ -z "$MINSSIM" ]; then
  fid_note no-reference "no sample yielded a reference frame; nothing was compared."
  exit 3
fi
if awk -v s="$MINSSIM" -v t="$THRESH" 'BEGIN{exit !(s>=t)}'; then
  echo "playable-check: FIDELITY OK on macOS $OSV — worst sampled SSIM $MINSSIM >= $THRESH ($SCAN):"
  echo "  the AVFoundation render matches the ffmpeg reference; the pixels survive, not just the open."
  echo "  worst-sample planes: Y ${MINY:-na}  U ${MINU:-na}  V ${MINV:-na}"
  echo "PLAYCHECK_FIDELITY verdict=ok reason=none ssim=$MINSSIM os=$OSV $FIDTAIL"
  exit 0
else
  echo "playable-check: FIDELITY FAIL on macOS $OSV — worst sampled SSIM $MINSSIM < $THRESH ($SCAN):"
  echo "  AVFoundation produced a render but NOT the right pixels (the 2026-08-15"
  echo "  false-green class: renders != renders correctly — e.g. macroblock garbage)."
  echo "  worst-sample planes: Y ${MINY:-na}  U ${MINU:-na}  V ${MINV:-na}"
  # NAME the signature instead of handing back one opaque scalar (D1)
  if [ -n "$MINY" ] && awk -v y="$MINY" -v t="$THRESH" 'BEGIN{exit !(y>=t)}'; then
    echo "  SIGNATURE: LUMA SURVIVES ($MINY >= $THRESH), the CHROMA planes carry the whole"
    echo "  deficit — consistent with a chroma-geometry misread (the 4:2:0-geometry"
    echo "  hypothesis: the decoder configured from the fourcc/profile contract rather"
    echo "  than the sequence_extension). On an interlaced source it can ALSO be the"
    echo "  measured interlaced-chroma comparison artifact; the container swap below"
    echo "  discriminates — it costs one lossless remux and re-runs this same gate."
  else
    echo "  SIGNATURE: LUMA IS DAMAGED TOO (Y ${MINY:-na} < $THRESH) — not a chroma-siting"
    echo "  artifact of the comparison; the render itself is wrong."
  fi
  mp4_swap_route
  echo "PLAYCHECK_FIDELITY verdict=fail reason=fidelity ssim=$MINSSIM os=$OSV $FIDTAIL"
  exit 1
fi
