#!/usr/bin/env bash
# mp4-swap.sh — the CONTAINER-SWAP rung (D2, 1.13). Same bitstream, ISO
# container: build the lossless .mp4 sibling of a .mov that AVFoundation opens
# but renders WRONG, then prove it with the same gates the .mov had to pass.
#
# Usage: scripts/mp4-swap.sh SOURCE [OUTPUT.mp4] [--audio auto|copy|pcm]
#                            [--audio-keep all|first|layouts|IDX[,IDX...]]
#                            [--full] [--no-playcheck]
#   SOURCE        the ORIGINAL capture (not the failed .mov) — the swap is a
#                 fresh lossless remux of the same bitstream, never a re-wrap
#                 of a build already judged bad
#   OUTPUT        default: <source dir>/<stem>.mp4 (<stem>.swap.mp4 if the
#                 source is itself an .mp4, so the source is never the target)
#   --full        archival sign-off: pass --full to verify.sh
#   --no-playcheck  skip the AVFoundation fidelity proof (it is the POINT of
#                 this rung; only for a machine that cannot run it)
#
# WHY THIS RUNG EXISTS (measured 2026-08-15, macOS 26.6.1 / ffmpeg 9.0.1):
# a 21 GB MPEG-2 4:2:2 1080i29.97 capture built a verified-lossless .mov that
# QuickTime rendered as macroblock garbage. Five different sample-entry retags
# (m2v1/mp2v/hdv3/xd5b/xd5c) corrupted IDENTICALLY — because movenc has no
# XDCAM-specific sample-description writer: every MPEG-2 fourcc gets the same
# generic body (glbl(extradata) + fiel + optional colr), so the tag changes the
# FourCC and the compressor name and nothing else. The SAME bitstream in an
# .mp4 — sample entry 'mp4v' with an 'esds' descriptor — decoded correctly:
# SSIM 0.9175+ on the very timestamps that failed as .mov.
#
# WHY NOT JUST WRITE THAT ENTRY INTO THE .mov: ffmpeg refuses —
#   "Tag mp4v incompatible with output codec id '2' (m2v1)"
# — and that refusal is a TABLE ARTIFACT, not a spec rule: libavformat/mux.c
# does a linear lookup of the requested tag in the MOV muxer's table
# (ff_codec_movvideo_tags), which pairs 'mp4v' only with MPEG-4, while the MP4
# muxer's table pairs it with MPEG-2. Apple's QTFF "video sample description
# extensions" list includes `esds` as a first-class extension, so mp4v+esds is
# spec-legal INSIDE a .mov — ffmpeg simply has no path that writes it (stsd
# surgery via MP4Box/Bento4 would; unbenched, recorded in known-limits.md).
# So the honest deliverable for this class is a .mp4, losslessly.
#
# WHERE IT SITS IN THE LADDER: retag (free, works when the stream matches the
# fourcc's profile contract) -> THIS (lossless, measured, one bench) -> stsd
# surgery (spec-legal, unbenched) -> Rung 4 re-encode (last resort). Before
# 1.13 every fidelity FAIL named Rung 4 and nothing else.
#
# Video is ALWAYS stream-copied. The source is never touched. Exit contract:
#   0 = built + verified + fidelity-proven | 10 = REVIEW (written; verify or
#   the fidelity proof wants a closer look / could not run) | 1 = FAIL |
#   2 = usage | 11 = REFUSED (a codec no ISO container carries)
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4)

IN="${1:?usage: mp4-swap.sh SOURCE [OUTPUT.mp4] [--audio MODE] [--audio-keep POLICY] [--full] [--no-playcheck]}"; shift
OUT=""; FULL=""; AKEEP=all; AUDIO=""; NOPLAY=0
if [ "${1:-}" != "" ] && [ "${1#--}" = "${1:-}" ]; then OUT="$1"; shift; fi
while [ $# -gt 0 ]; do case "$1" in
  --full)          FULL="--full"; shift;;
  --no-playcheck)  NOPLAY=1; shift;;
  --audio)         AUDIO="${2:?--audio needs a value}"; shift 2;;
  --audio-keep)    AKEEP="${2:?--audio-keep needs a value}"; shift 2;;
  --audio-keep=*)  AKEEP="${1#*=}"; shift;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
if [ -z "$OUT" ]; then
  d="$(cd "$(dirname "$IN")" && pwd)"; b="$(basename "$IN")"; stem="${b%.*}"
  OUT="$d/$stem.mp4"
  [ "$OUT" = "$d/$b" ] && OUT="$d/$stem.swap.mp4"
fi

. "$SELF_DIR/lib-probe.sh"
. "$SELF_DIR/lib-paff.sh"   # playability_verdict (the shared empirical half)
. "$SELF_DIR/lib-mux.sh"    # rtm_lock: one writer per OUT (WO-1.15.6 A2)
# held across the remux child (which re-enters via RTM_LOCK_HELD and runs the
# disk pre-flight) and this driver's own verify/playability reads of OUT.
trap 'rtm_unlock' EXIT
rtm_lock "$OUT" || exit 2
rtm_claim_out "$OUT" || exit 2   # TIER 1 T1.10 final-OUT no-clobber

VC=$(ffp1 -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null)
PIX=$(ffp1 -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$IN" 2>/dev/null)
echo "== mp4-swap: $IN -> $OUT =="
echo "   container-swap rung: same bitstream (video stream-copied), ISO container."
case "$VC" in
  mpeg2video)
    echo "   MPEG-2 -> sample entry 'mp4v' + 'esds' (the entry AVFoundation decodes"
    echo "   correctly) instead of the .mov's 'm2v1' + 'glbl'. Measured 2026-08-15 on a"
    echo "   real 4:2:2 capture: SSIM 0.9175+ where every .mov retag scored 0.81-0.85." ;;
  *)
    echo "   $VC${PIX:+/$PIX}: the swap is codec-agnostic — it changes the CONTAINER and"
    echo "   therefore the sample entry the decoder dispatches on. The measured evidence"
    echo "   (2026-08-15) is MPEG-2 4:2:2; on any other codec this rung is a hypothesis"
    echo "   this run is about to TEST, not a promise." ;;
esac

echo "-- build (lossless remux, --container mp4) --"
set +e
bo=$(bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --container mp4 --audio-keep "$AKEEP" ${AUDIO:+--audio "$AUDIO"} 2>&1)
rc=$?
set -e
printf '%s\n' "$bo" | sed 's/^/   /'
if [ "$rc" -ne 0 ]; then
  # NAME the one version-dependent way this rung fails (announced, never a raw
  # stack trace): the PCM access track needs the ISO `ipcm` entry, which ffmpeg
  # only writes since 6.1 (commit d4ee177a). On an older muxer the VIDEO half of
  # the swap — the part this rung exists for — is still perfectly available.
  case "$bo" in
    *"Could not find tag for codec pcm_"*|*"pcm_s16le"*"only supported"*)
      echo ">> the PCM access track could not be written into MP4 by THIS ffmpeg."
      echo "   The ISO PCM sample entry ('ipcm', ISO/IEC 23003-5) arrived in ffmpeg 6.1;"
      echo "   $(ffmpeg -version 2>/dev/null | awk 'NR==1{print $2, $3}') cannot write it. The video half of the swap is"
      echo "   unaffected — rerun keeping the original audio bitstream:"
      echo "     scripts/mp4-swap.sh \"$IN\" \"$OUT\" --audio copy"
      echo "   (playable audio then depends on the codec: AAC/E-AC-3 play, MP2 does not —"
      echo "    references/ingest-compatibility.md) or upgrade ffmpeg." ;;
  esac
  echo "MP4_SWAP out=$OUT verdict=fail stage=build fidelity=na"   # machine-readable (additive, D2 1.13)
  case "$rc" in
    11) echo ">> REFUSED: this source cannot be carried in an ISO container either (above)."; exit 11;;   # TIER 3 T3.8 propagated cached deterministic attempt
    *)  echo ">> FAIL: the container swap did not build (above). Source untouched."; exit 1;;
  esac
fi

echo "-- verify (same gates the .mov had to pass) --"
set +e
o=$(bash "$SELF_DIR/verify.sh" "$IN" "$OUT" $FULL --signaling 2>&1); set -e
printf '%s\n' "$o" | sed 's/^/   /'
case "$o" in *">> OK"*) rc=0;; *">> REVIEW"*) rc=10;; *) rc=1;; esac

FID=na
if [ "$rc" -ne 1 ] && [ "$NOPLAY" -eq 0 ]; then
  echo "-- fidelity proof (the whole point of the rung: does THIS container decode right?) --"
  playability_verdict "$OUT" --fidelity
  FID=$(printf '%s\n' "$PLAY_VERDICT")
  case "$PLAY_VERDICT" in
    fail)
      [ "$rc" -eq 0 ] && rc=10
      echo "   -> the swap did NOT fix it on this macOS: the .mp4 renders wrong too."
      echo "      The container axis is exhausted for this file; next is stsd surgery"
      echo "      (mp4v+esds inside a .mov via MP4Box/Bento4 — spec-legal, unbenched)"
      echo "      or Rung 4 (scripts/rung4.sh, operator-attested re-encode)." ;;
    skip)
      [ "$rc" -eq 0 ] && rc=10
      echo "   -> fidelity unverified on this platform: REVIEW. The .mp4 is a verified"
      echo "      lossless artifact; prove the render on the target Mac"
      echo "      (scripts/playable-check.sh --fidelity \"$OUT\")." ;;
    ok)
      echo "   -> the container swap WORKS on this build: AVFoundation renders the same"
      echo "      pixels ffmpeg does. This .mp4 is the playable deliverable; the .mov of"
      echo "      the same bitstream is not (and no ffmpeg retag can make it one)." ;;
  esac
fi

echo
echo "MP4_SWAP out=$OUT verdict=$(case $rc in 0) echo ok;; 10) echo review;; *) echo fail;; esac) stage=verify fidelity=$FID"   # machine-readable (additive, D2 1.13)
case "$rc" in
  0)  echo ">> DONE: $OUT — lossless container swap, verified, and PROVEN to render correctly."
      echo "   Deliverable note: this is a .mp4 by necessity, not by preference — the same"
      echo "   sample entry cannot be written into a .mov by ffmpeg (mux.c tag table)."; exit 0;;
  10) echo ">> REVIEW: $OUT written; see above. Source untouched."; exit 10;;
  *)  echo ">> FAIL: see verify output above. Source untouched; $OUT is unverified."; exit 1;;
esac
