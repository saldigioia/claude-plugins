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
# The default (no flag) invocation is unchanged — same lines, same exits.
#
# NOTE: the macOS path cannot be exercised on Linux/CI; validate on a real Mac.
set -euo pipefail
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
  echo "PLAYCHECK_FIDELITY verdict=skip reason=$1 ssim=na os=${OSV:-na}"
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
  echo "  (the reference decoder), then compared with SSIM at yuv444p (threshold ${RTM_FIDELITY_SSIM:-0.90},"
  echo "  RTM_FIDELITY_SSIM). Motive (2026-08-15, macOS 26.6.1): two real broadcast MPEG-2 4:2:2"
  echo "  masters thumbnailed OK while QuickTime rendered macroblock garbage — renders != renders correctly."
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# BOUNDED probe (WO 1.4, measured): qlmanage -t can hang FOREVER on input the
# thumbnail extension cannot parse (a garbage payload stalled it indefinitely —
# no verdict, no exit code, a wedged pipeline). A hung probe is not a verdict,
# so the render gets a deadline (RTM_QL_TIMEOUT seconds, default 60 — a healthy
# file thumbnails in single-digit seconds). macOS ships no `timeout` binary:
# background the render and poll with the deadline; on expiry the kill leaves
# no PNG, and the normal no-frame path below reports FAIL honestly.
qlmanage -t -s 480 -o "$TMP" "$OUT" >/dev/null 2>&1 &
QLPID=$!
QLLIMIT="${RTM_QL_TIMEOUT:-60}"
QLDEADLINE=$(( $(date +%s) + QLLIMIT ))
while kill -0 "$QLPID" 2>/dev/null; do
  if [ "$(date +%s)" -ge "$QLDEADLINE" ]; then
    kill -9 "$QLPID" 2>/dev/null || true
    echo "playable-check: qlmanage produced nothing in ${QLLIMIT}s — killed (a hang here means"
    echo "  the decode stack cannot handle this input; counted as no frame rendered)."
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
  echo "  ingest-compatibility.md 'Decode support is a moving target'). A playable"
  echo "  deliverable needs Rung 4 (scripts/rung4.sh) — recipes in references/delivery-encode.md."
  THUMB=fail
fi
if [ "$FIDELITY" -eq 0 ]; then
  # default mode ends exactly where 1.11.0 ended — byte-identical lines + exits
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
THRESH="${RTM_FIDELITY_SSIM:-0.90}"
AVLIMIT="${RTM_AVC_TIMEOUT:-120}"   # per-window avconvert deadline (RTM_QL_TIMEOUT style): a hang is a verdict, never a wedge
N=0; MINSSIM=""; FIDFAIL=0; FAILREASON=""
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
  avconvert --preset PresetAppleProRes422LPCM --source "$OUT" --output "$CLIP" --start "$SSTART" --duration "$FWIN" --replace >/dev/null 2>&1 &
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
  BEST=$(awk -F'All:' 'NF>1{split($2,p," "); if (p[1]+0>m) m=p[1]+0} END{printf "%.4f", m+0}' "$SLOG")
  echo "    best frame-match SSIM vs reference: $BEST"
  if [ -z "$MINSSIM" ] || awk -v a="$BEST" -v b="$MINSSIM" 'BEGIN{exit !(a<b)}'; then MINSSIM=$BEST; fi
done
if [ "$FIDFAIL" -eq 1 ]; then
  echo "playable-check: FIDELITY FAIL on macOS $OSV — the AVFoundation side could not be"
  echo "  rendered/compared ($FAILREASON). Treat as not proven QuickTime-playable."
  echo "PLAYCHECK_FIDELITY verdict=fail reason=$FAILREASON ssim=${MINSSIM:-na} os=$OSV"
  exit 1
fi
if [ -z "$MINSSIM" ]; then
  fid_note no-reference "no sample yielded a reference frame; nothing was compared."
  exit 3
fi
if awk -v s="$MINSSIM" -v t="$THRESH" 'BEGIN{exit !(s>=t)}'; then
  echo "playable-check: FIDELITY OK on macOS $OSV — worst sampled SSIM $MINSSIM >= $THRESH:"
  echo "  the AVFoundation render matches the ffmpeg reference; the pixels survive, not just the open."
  echo "PLAYCHECK_FIDELITY verdict=ok reason=none ssim=$MINSSIM os=$OSV"
  exit 0
else
  echo "playable-check: FIDELITY FAIL on macOS $OSV — worst sampled SSIM $MINSSIM < $THRESH:"
  echo "  AVFoundation produced a render but NOT the right pixels (the 2026-08-15"
  echo "  false-green class: renders != renders correctly — e.g. macroblock garbage)."
  echo "  Treat as NOT QuickTime-playable; a native deliverable needs Rung 4"
  echo "  (scripts/rung4.sh — recipes in references/delivery-encode.md)."
  echo "PLAYCHECK_FIDELITY verdict=fail reason=fidelity ssim=$MINSSIM os=$OSV"
  exit 1
fi
