#!/usr/bin/env bash
# 52-unroutable-codecs.sh — work-order 5.2: explicit messages for the
# never-mentioned codecs. VC-1 (Blu-ray), VP9/AV1 and Dolby E used to hit raw
# ffmpeg errors mid-build (VP9 verified un-muxable into MOV on the bench:
# "vp9 only supported in MP4" -> header-write failure) or misroute silently.
# Since 1.11 mov.sh refuses them PRE-FLIGHT — exit 11, one honest message with
# the routes out, the additive MOV_REFUSED machine line, nothing written —
# because unlike every other gate the failure is not a playability question:
# the MOV cannot exist.
#
# Asserted:
#   1. vp9.webm end-to-end through mov.sh: exit 11, routed message (keep /
#      lossless MP4 copy / rung4), MOV_REFUSED profile=unroutable-vcodec, NO
#      raw muxer error in the output (no mux is ever attempted), no artifact
#      written, source untouched.
#   2. sourced-classifier units (the RTM_TEST guard, same harness as
#      31-pcm-bluray.sh): unroutable_v vc1/vp9/av1 -> refuse; the boundary
#      HOLDS — h264/hevc/mpeg2video/ffv1 are NOT refused (ffv1 is the
#      PR_VNATIVE=no "build + prove post-build" class, a different arm);
#      unroutable_a dolby_e -> refuse; aac/ac3/pcm_bluray pass.
#   3. probe.sh honesty on the class: --kv reports vp9 outside the measured
#      matrix; human mode prints the REFUSED-class advisory instead of the
#      pre-1.11 "MOV may carry it" overclaim.
#
# BENCH LIMIT (say it honestly): this ffmpeg has NO VC-1, AV1 or Dolby E
# encoder (GROUND-verified encoder roster), so those classes cannot be minted
# as fixtures — VP9 is the end-to-end proof of the shared gate path, and
# VC-1/AV1/Dolby E are pinned at the classifier arms the gate dispatches on
# (the same injection-level doctrine as the PAFF/discontinuity synthesis
# limits in regression.sh). The Dolby E PCM-wrapped AES3 (SMPTE 337M) form is
# a DOCUMENTED limitation (SKILL.md troubleshooting), deliberately not
# detected — no assertion pretends otherwise.
#
# Standalone: bash tests/regression.d/52-unroutable-codecs.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
# Regenerates its fixture via make-fixtures.sh when missing. Scratch goes to
# mktemp (auto-cleaned); the repo tree is never written to.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }

# fixture: regenerate when missing (media never ships in git). make-fixtures
# self-checks BOTH stated properties (stream is vp9 AND the MOV mux still
# fails on this ffmpeg) — if it errors here, the premise itself needs a look.
if [ ! -f "$FIX/vp9.webm" ]; then
  echo "== regenerating missing fixture: vp9.webm =="
  bash "$TESTS/make-fixtures.sh" vp9.webm || { echo "fixture build failed (no libvpx-vp9, or VP9-in-MOV now muxes — re-bench WO 5.2)"; exit 2; }
fi
SRC="$FIX/vp9.webm"
srcsize=$(wc -c < "$SRC" | tr -d ' ')

# sourced-classifier unit harness (the 31-pcm-bluray.sh pattern): mov.sh's
# RTM_TEST guard stops the sourced file right after the classifier
# definitions, so each probe runs in a throwaway shell.
uv () { RTM_TEST=1 bash -c '. "$1/mov.sh"; set +e; unroutable_v "$2"; echo $?' _ "$SC" "$1" 2>/dev/null; }
ua () { RTM_TEST=1 bash -c '. "$1/mov.sh"; set +e; unroutable_a "$2"; echo $?' _ "$SC" "$1" 2>/dev/null; }

echo "== 1. vp9.webm through mov.sh: routed refusal, never a raw muxer error =="
o=$(bash "$SC/mov.sh" "$SRC" "$WORK/vp9.mov" 2>&1); rc=$?
[ "$rc" -eq 11 ] && ok "mov.sh refuses VP9 (exit 11, the REFUSED contract code)" \
  || { no "mov.sh rc=$rc, want 11"; printf '%s\n' "$o" | tail -6 | sed 's/^/   /'; }
has "$o" "REFUSED: vp9 video cannot be muxed into a .mov" "the honest message names the codec and the impossibility"
has "$o" "MOV_REFUSED profile=unroutable-vcodec vcodec=vp9" "additive MOV_REFUSED machine line with the new profile value"
# the three routes out (keep / lossless container change / attested re-encode)
has "$o" "keep   the source as-is" "route: keep the source (archival master)"
has "$o" "-c copy OUT.mp4" "route: lossless MP4 copy named (VP9/AV1 carriage verified on the bench)"
has "$o" "rung4  scripts/rung4.sh" "route: operator-attested rung4 named"
# the acceptance bar: the refusal is PRE-FLIGHT — no mux is attempted, so no
# raw ffmpeg muxer error can be the primary output
hasnt "$o" "Could not find tag" "no raw 'Could not find tag' muxer error surfaces"
hasnt "$o" "only supported in MP4" "no raw 'only supported in MP4' muxer error surfaces"
hasnt "$o" "Could not write header" "no raw header-write failure surfaces"
# nothing half-built, source untouched
{ [ ! -f "$WORK/vp9.mov" ] && [ ! -f "$WORK/vp9.mov.part" ]; } \
  && ok "refusal writes nothing (no artifact, no .part)" || no "refusal left an output behind"
{ [ -f "$SRC" ] && [ "$(wc -c < "$SRC" | tr -d ' ')" = "$srcsize" ]; } \
  && ok "source untouched (exists, byte count unchanged)" || no "source was modified"

echo
echo "== 2. sourced units: the unroutable classifiers, boundary intact =="
# refused arms (VC-1/AV1 have no encoder on this bench — classifier-level pin)
[ "$(uv vc1)" = 0 ] && ok "unroutable_v vc1 -> refuse (no MOV sample entry)" || no "unroutable_v vc1 = $(uv vc1), want 0"
[ "$(uv vp9)" = 0 ] && ok "unroutable_v vp9 -> refuse" || no "unroutable_v vp9 = $(uv vp9), want 0"
[ "$(uv av1)" = 0 ] && ok "unroutable_v av1 -> refuse (MP4-only sibling)" || no "unroutable_v av1 = $(uv av1), want 0"
# the boundary: MOV-buildable classes must NEVER be swept into the refusal —
# ffv1 is the PR_VNATIVE=no arm (builds + post-build proof, WO 5.1), not this
[ "$(uv h264)" = 1 ] && ok "unroutable_v h264 -> pass (copy class untouched)" || no "unroutable_v h264 = $(uv h264), want 1"
[ "$(uv hevc)" = 1 ] && ok "unroutable_v hevc -> pass" || no "unroutable_v hevc = $(uv hevc), want 1"
[ "$(uv mpeg2video)" = 1 ] && ok "unroutable_v mpeg2video -> pass" || no "unroutable_v mpeg2video = $(uv mpeg2video), want 1"
[ "$(uv ffv1)" = 1 ] && ok "unroutable_v ffv1 -> pass (build + prove, a DIFFERENT arm)" || no "unroutable_v ffv1 = $(uv ffv1), want 1"
# audio arm (no Dolby E encoder exists in ffmpeg — classifier-level pin)
[ "$(ua dolby_e)" = 0 ] && ok "unroutable_a dolby_e -> refuse (mezzanine, PCM-treat = noise)" || no "unroutable_a dolby_e = $(ua dolby_e), want 0"
[ "$(ua aac)" = 1 ] && ok "unroutable_a aac -> pass" || no "unroutable_a aac = $(ua aac), want 1"
[ "$(ua ac3)" = 1 ] && ok "unroutable_a ac3 -> pass (TN2429 dual-track route untouched)" || no "unroutable_a ac3 = $(ua ac3), want 1"
[ "$(ua pcm_bluray)" = 1 ] && ok "unroutable_a pcm_bluray -> pass (WO 3.1 pcm route, not a refusal)" || no "unroutable_a pcm_bluray = $(ua pcm_bluray), want 1"

echo
echo "== 3. probe.sh honesty on the class =="
kv=$(bash "$SC/probe.sh" "$SRC" --kv 2>&1)
has "$kv" "PR_VCODEC=vp9" "kv reports the codec"
has "$kv" "PR_VNATIVE=no" "kv: vp9 stays outside the measured matrix (additive field intact)"
h=$(bash "$SC/probe.sh" "$SRC" 2>&1)
has "$h" "REFUSED-class: vp9 cannot be muxed into MOV" "human mode: the unroutable advisory replaces the overclaim"
has "$h" "rung4.sh" "human mode: the attested re-encode route is named"
hasnt "$h" "MOV may carry" "human mode: the pre-1.11 'MOV may carry it' overclaim is gone for vp9"

[ -f "$SRC" ] || no "fixture vanished during the run"

echo
echo "unroutable-codecs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
