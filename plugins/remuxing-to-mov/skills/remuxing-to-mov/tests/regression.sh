#!/usr/bin/env bash
# regression.sh — exercise the field-coded (PAFF) safeguards on synthesized
# fixtures. Born from a real incident: a genpts'd field-coded remux passed the
# mux tests, shipped, and tore on scrub. Each assertion below pins one safeguard
# so that regression cannot recur silently.
#
# Run:  bash tests/regression.sh        (needs ffmpeg+ffprobe with libx264)
# Exit: 0 if every assertion passes, 1 otherwise.
#
# SYNTHESIS LIMIT (read this): true broadcast PAFF — separate field pictures with
# a corrupted MOV seek index — cannot be minted by libx264 in a sandbox, and the
# specific "decodes clean but tears on an off-keyframe scrub" decode error cannot
# be reproduced synthetically (ffmpeg discards pre-seek frames before they reach a
# decoder/muxer, so a fake non-monotonic timeline does not error on seek). These
# fixtures therefore exercise the MECHANISMS the safeguards rely on, which ARE
# synthesizable:
#   * a seekability defect the mux/lossless/DTS checks all pass (single-GOP) and
#     which a keyframe-accurate seek is provably BLIND to — the scrub gate's
#     keyframe-sanity is what catches it;
#   * the scrub gate actually running accurate off-keyframe (-ss after -i) seeks;
#   * VCL-payload invariance across TS->MOV and a re-time (where decoded framemd5
#     false-FAILs) vs a real re-encode (which must still FAIL);
#   * the coded-picture-rate PAFF detector math.
# A real capture + a real player remain the final proof; this guards the plumbing.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SC="$HERE/../scripts"
. "$SC/lib-paff.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
# assert that "$1" (haystack) contains "$2" (needle); $3 = description
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }

echo "== building fixtures in $WORK =="
S="$WORK/src.ts"; CP="$WORK/copy.mov"; RB="$WORK/rebuild.mov"
RE="$WORK/reenc.mov"; OG="$WORK/onegop.mov"; BK="$WORK/brk_ts8.mov"; EH="$WORK/e.h264"
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }
# H.264 + tics, TS (Annex-B) source
ff -f lavfi -i testsrc2=size=320x240:rate=30000/1001 -t 6 -c:v libx264 -g 30 -bf 2 \
   -pix_fmt yuv420p -mpegts_flags +resend_headers "$S"
ff -i "$S" -map 0:v:0 -c:v copy -movflags +faststart -f mov "$CP"          # plain copy
ff -i "$S" -map 0:v:0 -c:v copy -f h264 "$EH"                              # elementary
ff -fflags +genpts -r 30000/1001 -i "$EH" -map 0:0 -c:v copy \
   -video_track_timescale 30000 -movflags +faststart -f mov "$RB"          # Rung-3 rebuild
ff -i "$S" -map 0:v:0 -c:v libx264 -crf 30 -pix_fmt yuv420p "$RE"          # NOT lossless
ff -f lavfi -i testsrc2=s=320x240:r=25 -t 35 -c:v libx264 -g 100000 \
   -keyint_min 100000 -sc_threshold 0 -pix_fmt yuv420p "$OG"               # single GOP, 35s
ff -fflags +genpts -r 30000/1001 -i "$EH" -map 0:0 -c:v copy \
   -video_track_timescale 8 -movflags +faststart -f mov "$BK"             # lossless, broken timeline

echo
echo "== 1. no false positive: a clean copy verifies OK =="
out=$(bash "$SC/verify.sh" "$S" "$CP" 2>&1); rc=$?
has "$out" ">> OK" "clean H.264 copy -> OK"
[ "$rc" -eq 0 ] && ok "clean copy exit 0" || no "clean copy exit 0 (got $rc)"

echo
echo "== 2. Fix 3: VCL hash is invariant across a re-timed lossless copy (framemd5 would false-FAIL) =="
# RB re-times the elementary stream (the operation that makes decoded framemd5
# diverge). Test 1 already showed the VCL path yields a clean PASS on a seekable
# copy; here we isolate the hash property: VCL equal, framemd5 not.
out=$(bash "$SC/verify.sh" "$S" "$RB" 2>&1)
has "$out" "VCL MATCH" "re-timed copy -> VCL match (lossless proven)"
vclh () { local b=""; \
  [ "$(ffprobe -v error -select_streams v:0 -show_entries stream=is_avc -of default=nw=1:nk=1 "$1"|head -1)" = true ] && b="h264_mp4toannexb,"; \
  ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -c:v copy -bsf:v "${b}filter_units=remove_types=6|7|8|9" -f streamhash -hash md5 - 2>/dev/null; }
[ "$(vclh "$S")" = "$(vclh "$RB")" ] && ok "VCL hash equal: SRC vs re-timed copy" || no "VCL hash should be equal across a lossless re-time"
fhead () { ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -frames:v 60 -f framemd5 - 2>/dev/null | grep -v '^#' | awk -F', *' '{print $NF}' | md5sum; }
if [ "$(fhead "$S")" != "$(fhead "$RB")" ]; then ok "decoded framemd5-head DIFFERS on the re-time (the false-FAIL VCL sidesteps)"
else no "expected framemd5-head to differ on the re-time (fixture too easy?)"; fi

echo
echo "== 3. real loss is still caught: a re-encode FAILs the lossless check =="
out=$(bash "$SC/verify.sh" "$S" "$RE" 2>&1); rc=$?
has "$out" "VCL MISMATCH" "re-encode -> VCL mismatch"
has "$out" ">> FAIL" "re-encode -> FAIL"
[ "$rc" -eq 1 ] && ok "re-encode exit 1" || no "re-encode exit 1 (got $rc)"

echo
echo "== 4. seekability: a single-GOP file the mux/lossless/DTS checks all pass is flagged =="
out=$(bash "$SC/verify.sh" "$OG" "$OG" 2>&1); rc=$?
has "$out" "Single-GOP" "single-GOP -> flagged unseekable"
has "$out" ">> REVIEW" "single-GOP -> REVIEW (not a clean OK)"
hasnt "$out" ">> OK" "single-GOP -> not silently OK"

echo
echo "== 5. the gate adds coverage the old keyframe-accurate check lacks =="
# The old QC seeked the way ffmpeg seeks: -ss BEFORE -i, which snaps to a keyframe
# and decodes forward. On the unseekable single-GOP file that stays clean — it is
# BLIND to the defect. (The error a real off-keyframe scrub throws can't be minted
# synthetically; see SYNTHESIS LIMIT above. We pin the blindness + that the gate
# runs the accurate seeks.)
oldsnap=$(ffmpeg -nostdin -v error -ss 17 -t 4 -i "$OG" -map 0:v:0 -f null - 2>&1 | grep -c .)
[ "$oldsnap" -eq 0 ] && ok "keyframe-accurate spot decode is BLIND to the single-GOP file (0 errors)" \
  || no "expected keyframe-snap clean on single-GOP (got $oldsnap)"
out=$(bash "$SC/verify.sh" "$S" "$CP" 2>&1)
has "$out" "off-keyframe accurate seeks:" "scrub gate runs accurate off-keyframe seeks (-ss after -i)"

echo
echo "== 6. the broken-timeline copy is never given a clean bill =="
out=$(bash "$SC/verify.sh" "$S" "$BK" 2>&1); rc=$?
hasnt "$out" ">> OK" "broken-timeline lossless copy -> not OK"
{ [ "$rc" -ne 0 ] || case "$out" in *REVIEW*) true;; *) false;; esac; } \
  && ok "broken-timeline -> REVIEW or FAIL (caught)" || no "broken-timeline slipped through (rc=$rc)"

echo
echo "== 7. PAFF detector: math fires at ~2x cadence, stays quiet at 1x =="
eval "$(pf_detect "$CP")"; [ "$PF_PAFF" = no ] && ok "progressive/frame-coded H.264 -> PF_PAFF=no" \
  || no "false-positive PAFF on frame-coded (ratio=$PF_RATIO)"
gate () { awk "BEGIN{r=$1/$2; print (r>=1.7&&r<=2.3)?\"yes\":\"no\"}"; }
[ "$(gate 59.94 29.97)" = yes ] && ok "59.94 AU/s over 29.97p -> PAFF" || no "missed 2x cadence"
[ "$(gate 50 25)" = yes ] && ok "50 AU/s over 25p -> PAFF" || no "missed 2x PAL cadence"
[ "$(gate 25 25)" = no ] && ok "25 AU/s over 25p -> not PAFF" || no "false-positive at 1x"
[ "$(pf_suggest_field_rate 59.94)" = "60000/1001 60000" ] && ok "field-rate map 59.94 -> 60000/1001 60000" \
  || no "bad field-rate mapping for 59.94"

echo
echo "== 8. Phase 0: doctor reports a usable env; verify degrades without false-FAIL =="
dout=$(bash "$SC/doctor.sh" --kv 2>&1); drc=$?
[ "$drc" -eq 0 ] && ok "doctor.sh exits 0 (required caps present)" || no "doctor.sh exit $drc"
has "$dout" "DOC_STATUS=" "doctor emits DOC_STATUS"
hasnt "$dout" "DOC_STATUS=BLOCKED" "doctor not BLOCKED in a working env"
# clean non-PAFF H.264 copy must NOT false-FAIL when the VCL path is forced off
out=$(RTM_FORCE_NO_VCL=1 bash "$SC/verify.sh" "$S" "$CP" 2>&1); rc=$?
{ [ "$rc" -ne 1 ]; } && ok "degraded verify of clean copy does not FAIL (rc=$rc)" || no "degraded verify false-FAILed a clean copy"
hasnt "$out" ">> FAIL" "degraded clean copy -> not FAIL"
# real loss must still FAIL in degraded mode (framemd5 fallback)
out=$(RTM_FORCE_NO_VCL=1 bash "$SC/verify.sh" "$S" "$RE" 2>&1); rc=$?
{ [ "$rc" -eq 1 ] && case "$out" in *">> FAIL"*) true;; *) false;; esac; } \
  && ok "degraded verify still FAILs a real re-encode" || no "degraded verify missed real loss (rc=$rc)"

echo
echo "== 9. Phase 1: probe --kv/--json structured output + recommended rung =="
kv=$(bash "$SC/probe.sh" "$S" --kv 2>&1)
has "$kv" "PR_REC_RUNG=0" "clean H.264 (no audio) -> recommended Rung 0"
has "$kv" "PR_VCODEC=h264" "kv reports vcodec"
has "$kv" "PF_PAFF=no" "kv carries the PAFF block"
MP2="$WORK/mp2.ts"; ff -f lavfi -i testsrc2=s=320x240:r=25 -f lavfi -i sine=1000 -t 3 -c:v libx264 -g 25 -c:a mp2 -pix_fmt yuv420p -f mpegts "$MP2"
kv2=$(bash "$SC/probe.sh" "$MP2" --kv 2>&1)
has "$kv2" "PR_AUDIO_ACTION=pcm" "MP2 audio -> PCM action"
has "$kv2" "PR_REC_RUNG=1" "MP2 audio -> recommended Rung 1"
js=$(bash "$SC/probe.sh" "$S" --json 2>&1)
case "$js" in '{'*'"rec_rung":0'*'}') ok "json emits a flat object with rec_rung";; *) no "json malformed: $js";; esac

echo
echo "== 10. Phase 2: auto.sh routes the ladder, verify-gated, never auto re-encodes =="
o=$(bash "$SC/auto.sh" "$S" "$WORK/a0.mov" 2>&1); rc=$?
has "$o" "attempting Rung 0" "clean H.264 -> Rung 0"
has "$o" ">> DONE" "clean H.264 -> DONE"
{ [ "$rc" -eq 0 ] && [ -f "$WORK/a0.mov" ]; } && ok "auto exit 0 + output written" || no "auto clean failed (rc=$rc)"
v=$(bash "$SC/verify.sh" "$S" "$WORK/a0.mov" 2>&1); has "$v" ">> OK" "auto output verifies lossless"
o=$(bash "$SC/auto.sh" "$MP2" "$WORK/a1.mov" 2>&1); rc=$?
has "$o" "attempting Rung 1" "MP2 audio -> Rung 1"
[ "$rc" -eq 0 ] && ok "auto MP2 exit 0" || no "auto MP2 exit $rc"
o=$(bash "$SC/auto.sh" "$S" "$WORK/dry.mov" --dry-run 2>&1)
[ -f "$WORK/dry.mov" ] && no "dry-run wrote a file" || ok "dry-run writes nothing"
has "$o" "never automatic" "dry-run states re-encode is never automatic"
hasnt "$o" "attempting" "dry-run executes no rung"
bash "$SC/auto.sh" "$S" "$S" >/dev/null 2>&1; rc=$?; [ "$rc" -eq 2 ] && ok "auto refuses source==output" || no "auto allowed source==output ($rc)"
# escalation machinery: nothing can make a single-GOP source seekable; auto must
# try and then honestly report REVIEW/FAIL, never a false DONE.
OGT="$WORK/og.ts"; ff -f lavfi -i testsrc2=s=160x120:r=25 -t 31 -c:v libx264 -preset ultrafast -g 100000 -keyint_min 100000 -sc_threshold 0 -pix_fmt yuv420p -f mpegts "$OGT"
o=$(bash "$SC/auto.sh" "$OGT" "$WORK/aog.mov" 2>&1); rc=$?
hasnt "$o" ">> DONE" "auto never falsely DONEs an unseekable source"
[ "$rc" -ne 0 ] && ok "auto exits non-zero (REVIEW/FAIL) + escalates on unfixable input (rc=$rc)" || no "auto returned success on unseekable input"

echo
echo "== 11. Phase 3: signaling + dual-track audio verification =="
AACS="$WORK/aac.mp4"; ff -f lavfi -i testsrc2=s=320x240:r=25 -f lavfi -i sine=1000:r=48000 -t 4 -c:v libx264 -g 25 -c:a aac -b:a 128k -pix_fmt yuv420p "$AACS"
DT="$WORK/dt.mov"; bash "$SC/dual-track.sh" "$AACS" "$DT" >/dev/null 2>&1
o=$(bash "$SC/verify.sh" "$AACS" "$DT" --audio 2>&1)
has "$o" "bit-exact vs source" "dual-track: original preserved bit-exact"
has "$o" "aligned" "dual-track: access track aligned to original"
DTB="$WORK/dtbad.mov"; ff -i "$DT" -map 0:v:0 -map 0:a:0 -map 0:a:1 -c:v copy -c:a:0 copy -c:a:1 aac -b:a:1 64k "$DTB"
o=$(bash "$SC/verify.sh" "$AACS" "$DTB" --audio 2>&1); rc=$?
{ [ "$rc" -eq 1 ] && case "$o" in *">> FAIL"*) true;; *) false;; esac; } && ok "dual-track: re-encoded original -> FAIL" || no "dual-track FAIL not detected (rc=$rc)"
o=$(bash "$SC/verify.sh" "$S" "$CP" --audio 2>&1); hasnt "$o" ">> FAIL" "--audio on single-track gracefully skips (no false FAIL)"
o=$(bash "$SC/verify.sh" "$S" "$CP" --signaling 2>&1); has "$o" "no drift" "signaling: clean copy -> no drift"
ENC=$(ffmpeg -hide_banner -encoders 2>/dev/null || true)   # capture once: piping into grep -q + pipefail SIGPIPEs ffmpeg
if grep -qw libx265 <<<"$ENC"; then
  HV="$WORK/hevc.mp4"; ff -f lavfi -i testsrc2=s=320x240:r=25 -t 3 -c:v libx265 -x265-params log-level=none -tag:v hvc1 -pix_fmt yuv420p "$HV"
  H1="$WORK/hev1.mov"; ff -i "$HV" -map 0:v:0 -c:v copy -tag:v hev1 -movflags +faststart -f mov "$H1"
  o=$(bash "$SC/verify.sh" "$HV" "$H1" --signaling 2>&1)
  has "$o" "NOT hvc1" "signaling: HEVC hev1 tag flagged as drift"
  has "$o" ">> REVIEW" "signaling: drift -> REVIEW"
else
  echo "  (skip: libx265 unavailable for the HEVC signaling fixture)"
fi

echo
echo "== 12. Phase 4: batch.sh writes verified outputs + provenance, resumes idempotently =="
BD="$WORK/bin"; BO="$WORK/bout"; mkdir -p "$BD" "$BO"
ff -f lavfi -i testsrc2=s=160x120:r=25 -t 2 -c:v libx264 -g 25 -pix_fmt yuv420p -f mpegts "$BD/c1.ts"
ff -f lavfi -i testsrc2=s=160x120:r=25 -f lavfi -i sine=1000 -t 2 -c:v libx264 -g 25 -c:a mp2 -pix_fmt yuv420p -f mpegts "$BD/c2.ts"
o=$(bash "$SC/batch.sh" "$BD" --out "$BO" 2>&1); rc=$?
has "$o" "OK=2  REVIEW=0  FAIL=0" "batch processes both -> OK"
[ "$rc" -eq 0 ] && ok "batch exit 0 when nothing fails" || no "batch exit $rc"
{ [ -f "$BO/c1.mov" ] && [ -f "$BO/c2.mov" ]; } && ok "batch wrote both outputs" || no "missing batch outputs"
{ [ -f "$BO/c1.mov.provenance.kv" ] && grep -q 'PROV_VERDICT=OK' "$BO/c1.mov.provenance.kv"; } && ok "provenance sidecar written + verdict recorded" || no "sidecar missing/incomplete"
v=$(bash "$SC/verify.sh" "$BD/c1.ts" "$BO/c1.mov" 2>&1); has "$v" ">> OK" "batch output verifies lossless"
{ [ -f "$BD/c1.ts" ] && [ -f "$BD/c2.ts" ]; } && ok "batch never deletes sources" || no "batch deleted a source"
o=$(bash "$SC/batch.sh" "$BD" --out "$BO" 2>&1)
has "$o" "skipped=2" "re-run is idempotent (skips already-OK, unchanged)"

echo
echo "== 13. Phase 5: playable-check is macOS-gated (clean skip on Linux); auto --playable ignores SKIP =="
o=$(bash "$SC/playable-check.sh" "$CP" 2>&1); rc=$?
has "$o" "SKIP" "playable-check skips on non-macOS"
[ "$rc" -eq 3 ] && ok "playable-check exit 3 (skip) on Linux" || no "playable-check exit $rc (want 3)"
o=$(bash "$SC/auto.sh" "$S" "$WORK/pc.mov" --playable 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && case "$o" in *">> DONE"*) true;; *) false;; esac; } \
  && ok "auto --playable keeps OK when playability is unknown (SKIP)" || no "auto --playable mishandled SKIP (rc=$rc)"

echo
echo "== 14. Rung-3 rebuild preserves per-track audio language (review finding #4) =="
ML="$WORK/ml.ts"; MLO="$WORK/ml.mov"
ff -f lavfi -i testsrc2=s=160x120:r=25 -f lavfi -i sine=600 -f lavfi -i sine=900 -t 2 \
  -map 0:v -map 1:a -map 2:a -c:v libx264 -g 25 -c:a aac -pix_fmt yuv420p \
  -metadata:s:a:0 language=fra -metadata:s:a:1 language=spa -f mpegts "$ML"
bash "$SC/rebuild-paff.sh" "$ML" "$MLO" 30000/1001 30000 >/dev/null 2>&1
langs=$(ffprobe -v error -select_streams a -show_entries stream_tags=language -of csv=p=0 "$MLO" 2>/dev/null | tr '\n' ',')
case "$langs" in fra,spa,) ok "rebuild-paff preserves real languages (fra,spa), not eng,eng";; *) no "languages not preserved: $langs";; esac

echo
echo "===================================================================="
echo "  PASSED: $pass    FAILED: $fail"
echo "===================================================================="
[ "$fail" -eq 0 ]
