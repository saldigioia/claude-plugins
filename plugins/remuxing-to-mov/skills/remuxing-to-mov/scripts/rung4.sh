#!/usr/bin/env bash
# rung4.sh — the ONLY sanctioned re-encode path (Rung 4). QTFF audit 5-3a/b.
#
# Every other writer in this skill hard-guarantees `-c:v copy`. This script is
# the single place video re-encoding is allowed, and it refuses to run without
# the operator's verbatim attestation — because the output of a re-encode is no
# longer true source material, and that consent must come from a human, exactly,
# every time. No fuzzy accept; near-misses are refused, not corrected.
#
# Usage:
#   scripts/rung4.sh INPUT [OUTPUT] --profile h264|hevc|prores \
#     --attest "<exact operator attestation string>"
#   (or REMUX_ATTEST="<exact string>" in the environment)
#
# Profiles wrap references/delivery-encode.md verbatim:
#   h264   H.264 delivery (libx264 high@4.2, crf 18 slow, AAC 160k)  -> .mp4
#   hevc   HEVC Apple delivery (libx265 hvc1 main10, AAC 160k)       -> .mp4
#   prores Apple ProRes 422 HQ master (prores_ks p3, BT.709, ALAC)   -> .mov
#
# Hard rules:
#   - The attestation must match lib-attest.sh's RTM_RUNG4_ATTEST verbatim. It
#     originates from the operator; this script never supplies or prints it.
#   - Output defaults to <base>.rung4-<profile>.<ext> beside the input; an
#     explicit OUTPUT is allowed but an EXISTING file is never overwritten —
#     rung4 output can never collide with a master (or anything else).
#   - Never targets the source; atomic write (.part -> mv).
#   - Provenance is stamped in proper QuickTime mdta keys (metadata.sh
#     conventions): source filename, date, profile, reencoded-with-attestation.
#     A derivative must never masquerade as a master in a later audit —
#     verify.sh's master-purity check reads these signatures.
#   - HONEST LIMIT (5-3g): this gate is a tripwire, not a wall — raw ffmpeg
#     bypasses it. Depth comes from the SKILL.md evidence-block doctrine and
#     verify.sh's after-the-fact purity scan, not from this refusal alone.
# Exit: 0 encoded + provenance round-tripped; 1 encode/round-trip failure;
#       2 usage / attestation / refusal.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
IN="${1:?usage: rung4.sh INPUT [OUTPUT] --profile h264|hevc|prores --attest \"...\"}"
shift
OUT=""
case "${1:-}" in --*|"") : ;; *) OUT="$1"; shift;; esac
PROFILE=""; ATT="${REMUX_ATTEST:-}"
while [ $# -gt 0 ]; do case "$1" in
  --profile) PROFILE="${2:?--profile needs h264|hevc|prores}"; shift 2;;
  --profile=*) PROFILE="${1#*=}"; shift;;
  --attest)  ATT="${2:?--attest needs the exact operator string}"; shift 2;;
  --attest=*) ATT="${1#*=}"; shift;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
case "$PROFILE" in h264|hevc|prores) : ;; *) echo "rung4.sh: --profile must be h264, hevc, or prores (see references/delivery-encode.md)" >&2; exit 2;; esac

. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-mux.sh"    # rtm_part (extension-keeping atomics), mux_census (D5)
. "$SELF_DIR/lib-attest.sh"
if [ "$ATT" != "$RTM_RUNG4_ATTEST" ]; then
  echo "rung4.sh: REFUSED — no valid attestation." >&2
  echo "  A re-encode discards true source material. The exact consent phrase is" >&2
  echo "  defined once in scripts/lib-attest.sh (RTM_RUNG4_ATTEST) and must be" >&2
  echo "  typed by the operator via --attest or REMUX_ATTEST — verbatim, no" >&2
  echo "  paraphrase, and never supplied on the operator's behalf." >&2
  exit 2
fi

case "$PROFILE" in prores) DEXT=mov;; *) DEXT=mp4;; esac
if [ -z "$OUT" ]; then
  b="$(basename "$IN")"; OUT="$(dirname "$IN")/${b%.*}.rung4-${PROFILE}.${DEXT}"
fi
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "rung4.sh: refusing to target the source" >&2; exit 2; }
[ ! -e "$OUT" ] || { echo "rung4.sh: $OUT already exists — a rung4 derivative never overwrites anything (masters included). Pick another name." >&2; exit 2; }

echo "== rung4 ($PROFILE): $IN -> $OUT =="
echo "** THIS IS A RE-ENCODE. The output is a DERIVATIVE, not source material."
echo "** The master stays: $IN (never touched)."

# Profile args verbatim from references/delivery-encode.md.
VARGS=(); AARGS=()
case "$PROFILE" in
  h264)   VARGS=(-c:v libx264 -profile:v high -level 4.2 -pix_fmt yuv420p -crf 18 -preset slow)
          AARGS=(-c:a aac -b:a 160k);;
  hevc)   VARGS=(-c:v libx265 -tag:v hvc1 -profile:v main10 -pix_fmt yuv420p10le)
          AARGS=(-c:a aac -b:a 160k);;
  prores) VARGS=(-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le
                 -color_primaries bt709 -color_trc bt709 -colorspace bt709)
          AARGS=(-c:a alac);;
esac

# Provenance (5-3b): proper QuickTime mdta keys per metadata.sh conventions.
TODAY=$(date +%F)
PROV=(-metadata "com.apple.quicktime.rung4.source=$(basename "$IN")"
      -metadata "com.apple.quicktime.rung4.date=$TODAY"
      -metadata "com.apple.quicktime.rung4.profile=$PROFILE"
      -metadata "com.apple.quicktime.rung4.reencoded-with-attestation=yes")

# .part hides the extension from ffmpeg — pick the muxer from OUT explicitly
case "$OUT" in *.mov|*.MOV) FMT=mov;; *.mp4|*.m4v|*.MP4) FMT=mp4;; *) FMT=$([ "$DEXT" = mov ] && echo mov || echo mp4);; esac
trap 'rtm_unlock' EXIT   # writer-lock release however this run ends (WO-1.15.6 A2)
rtm_writer_preflight "$OUT" "$IN" || exit 2
PART="$(rtm_part "$OUT")"   # extension-keeping (D6) + unique per process (A2)
if ! ffmpeg -nostdin -y -v error "${FF_INPUT_OPTS[@]}" -i "$IN" \
    "${VARGS[@]}" ${AARGS[@]+"${AARGS[@]}"} \
    "${PROV[@]}" -movflags use_metadata_tags+faststart -f "$FMT" "$PART"; then
  echo ">> encode FAILED; partial output kept at $PART for inspection." >&2
  exit 1
fi
# POST-MUX CENSUS (D5, 1.13): COUNT ONLY here — this rung re-encodes, so the
# written codec_names are deliberately not the source's; what must not change
# silently is how many streams came out. ffmpeg's default selection is best
# video + best audio, so the plan is 1 + (1 if the source has audio).
R4_NA=$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "$IN" 2>/dev/null | sort -u | grep -c . || true)
R4_N=1; [ "${R4_NA:-0}" -gt 0 ] && R4_N=2
census_rc=0
mux_census "$PART" "$R4_N" "" rung4 "$IN" || census_rc=$?
if rtm_census_failed "$census_rc"; then
  echo ">> NOT blessing the re-encode; kept at $PART for inspection." >&2
  exit 1
fi
mv -f "$PART" "$OUT"
echo "wrote: $OUT"

# Provenance round-trip (proves the mdta write took — a derivative that cannot
# be identified as one later is the failure mode this exists to prevent).
echo "-- provenance round-trip --"
tags=$(ffp -v error -show_entries format_tags -of default=noprint_wrappers=1 "$OUT" 2>/dev/null)
miss=0
for k in "rung4.source=$(basename "$IN")" "rung4.date=$TODAY" "rung4.profile=$PROFILE" "rung4.reencoded-with-attestation=yes"; do
  key="com.apple.quicktime.${k%%=*}"; want="${k#*=}"
  got=$(printf '%s\n' "$tags" | sed -n "s/^TAG:${key}=//p" | head -1)
  if [ "$got" = "$want" ]; then echo "   ok  $key = $got"
  else echo "   !!  $key did not round-trip (got '${got:-<none>}', want '$want')"; miss=1; fi
done
[ "$miss" -eq 0 ] || { echo ">> FAIL: provenance did not round-trip — the derivative is unmarked. Do not keep it beside masters."; exit 1; }
echo ">> DONE: derivative written + provenance stamped. This file must never be"
echo "   presented as a master; the lossless original remains the archival copy."
# REVIEW propagation (1.14): an unexpected-surplus census still blesses the
# complete derivative and exits 10 ("look"), never 1. ASKED of the one writer,
# then mapped (1.15.18) — never the raw rc as the exit.
if rtm_census_review "${census_rc:-0}"; then exit 10; fi
exit 0
