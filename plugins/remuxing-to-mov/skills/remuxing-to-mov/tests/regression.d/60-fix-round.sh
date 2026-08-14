#!/usr/bin/env bash
# 60-fix-round.sh — the 1.11 adversarial-review fix round (Phase 6), pinned.
# Each section is one confirmed finding + the fix that closed it; a fix without
# a test that would have caught the original bug is not done (ground rule 8).
#
#   1. qt-groups.sh proof (e) swallowed verify.sh's REVIEW: verify.sh prints
#      its verdict as TEXT and exits 0 for BOTH OK and REVIEW (accepted legacy,
#      now stated in its header), so switching on the exit code reported a
#      REVIEW build "green" and blessed it DONE (exit 0). Fixed: the text is
#      mapped (the mov.sh/auto.sh/resync.sh pattern) and REVIEW propagates as
#      exit 10 with the ">> REVIEW" note surfaced.
#   2. verify.sh --audio false-FAILed the preserved-original gate on ADTS-AAC
#      dual-tracks: the mux's automatic aac_adtstoasc reframes ADTS->ASC (the
#      known-limits.md verified non-issue), the raw streamhash differs while
#      the payload is bit-identical, and the gate called an intact original
#      "provenance track corrupted" — rc=1 on the flagship --always-dual
#      deliverable. Fixed: on a raw-hash mismatch of an AAC pair the source is
#      re-hashed through aac_adtstoasc before judging. Negative control: a
#      genuinely WRONG source still FAILs (the fallback is not a waiver).
#   3. unroutable-codec gate parity (the WO 5.2 scope cut): only mov.sh
#      refused VP9-class sources; a direct auto.sh run burned rungs 0->2->3
#      and died in the raw muxer stack trace, remux.sh littered a 0-byte
#      .part, and batch.sh recorded FAIL instead of REFUSED. Fixed: shared
#      classifiers + refusal voice in lib-paff.sh, dispatched at every entry
#      point (exit 11, MOV_REFUSED, nothing written).
#   4. batch.sh rung-extraction sed dropped UPPERCASE rungs ([a-z0-9] matches
#      neither P nor S), recording PROV_RUNG=none for exactly the two repair
#      rungs whose provenance matters most. Fixed: [A-Za-z0-9]; pinned
#      end-to-end (a gate-(f) short-audio source drives auto to Rung 3-SYNC).
#   5. non-audio streams dropped with no runtime WARN (house rule 5): a
#      subtitle/data stream or a second video stream vanished silently on
#      every route. Fixed at the remux.sh funnel: per-stream WARN + additive
#      RMX_PLAN unmapped=N. (PAFF builders/dual-track standalone stay silent —
#      the documented residual, known-limits.md.)
#   6. PCM access depth honesty: a >16-bit source (pcm_bluray s32 = 24-bit
#      HDMV LPCM) shipped a pcm_s16le access track silently as to depth.
#      Fixed: announced WARN on the access line (encoding unchanged —
#      depth-aware access PCM is a recorded 1.12 candidate).
#
# Standalone: bash tests/regression.d/60-fix-round.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
# Sections needing MP4Box (1) or the pcm_bluray encoder (6) skip out loud when
# the bench lacks them. Scratch goes to mktemp (auto-cleaned); the repo tree is
# never written to. Regenerates missing shared fixtures via make-fixtures.sh.
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
ff () { ffmpeg -nostdin -y -v error "$@"; }

# shared fixtures: regenerate when missing (media never ships in git)
for f in aac.ts vp9.webm; do
  if [ ! -f "$FIX/$f" ]; then
    echo "== regenerating missing fixture: $f =="
    bash "$TESTS/make-fixtures.sh" "$f" || { echo "fixture build failed: $f"; exit 2; }
  fi
done

echo "== 1. qt-groups.sh maps verify.sh's TEXT verdict — a REVIEW is exit 10, never 'green' =="
if command -v MP4Box >/dev/null 2>&1; then
  # the reviewer's construction: a 2-audio .mov whose second track runs 3s
  # short, group-scrubbed so qt-groups has real patching to do. verify.sh on
  # the pair prints '>> REVIEW: A/V duration mismatch ...' yet exits 0 — the
  # exact shape the exit-code switch mis-read as green.
  ff -f lavfi -i testsrc2=duration=12 -f lavfi -i sine=duration=12 -f lavfi -i sine=duration=9 \
     -map 0:v -map 1:a -map 2:a -c:v libx264 -pix_fmt yuv420p -c:a aac "$WORK/qtg-src.mov" \
    || { echo "qtg fixture build failed"; exit 2; }
  MP4Box -noprog -group-clean "$WORK/qtg-src.mov" -out "$WORK/qtg-clean.mov" >/dev/null 2>&1 \
    || { echo "group-clean mint failed"; exit 2; }
  # premise check: verify.sh really does print REVIEW and exit 0 on this pair
  vo=$(bash "$SC/verify.sh" "$WORK/qtg-clean.mov" "$WORK/qtg-clean.mov" 2>&1); vrc=$?
  { [ "$vrc" -eq 0 ] && case "$vo" in *">> REVIEW"*) true;; *) false;; esac; } \
    && ok "premise: verify.sh prints '>> REVIEW' yet exits 0 (the accepted legacy contract)" \
    || no "premise shifted: verify.sh rc=$vrc on a REVIEW pair — re-read its header contract"
  o=$(bash "$SC/qt-groups.sh" "$WORK/qtg-clean.mov" "$WORK/qtg-grouped.mov" 2>&1); rc=$?
  [ "$rc" -eq 10 ] && ok "qt-groups on a REVIEW-verifying pair -> exit 10 (was: 0 'green')" \
    || { no "qt-groups rc=$rc, want 10"; printf '%s\n' "$o" | tail -6 | sed 's/^/   /'; }
  has   "$o" "proof (e) verify.sh: REVIEW" "proof (e) names the REVIEW instead of 'green'"
  has   "$o" ">> REVIEW: A/V duration mismatch" "the verify note itself is surfaced to the operator"
  hasnt "$o" "proof (e) verify.sh: green" "the dead 'green' verdict is gone for this pair"
  [ -f "$WORK/qtg-grouped.mov" ] && ok "REVIEW output still written (REVIEW blesses with a flag, not a refusal)" \
    || no "REVIEW output missing"
else
  echo "  (skip: MP4Box absent — the qt-groups proof-(e) pin is untestable on this bench)"
fi

echo
echo "== 2. verify.sh --audio: ADTS->ASC reframing is not corruption; a wrong source still FAILs =="
o=$(bash "$SC/mov.sh" "$FIX/aac.ts" "$WORK/adual.mov" --always-dual 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "mov.sh --always-dual on a TS/ADTS AAC source -> DONE (was: rc=1 FAIL)" \
  || { no "mov.sh --always-dual rc=$rc, want 0"; printf '%s\n' "$o" | tail -6 | sed 's/^/   /'; }
has "$o" "bit-exact vs source after ADTS->ASC reframing" "the gate names the reframing instead of crying corruption"
hasnt "$o" "provenance track corrupted" "no false corruption verdict on the intact original"
# decoded-payload identity — the reviewer's own proof that the original is intact
am5 () { ffmpeg -nostdin -v error -i "$1" -map "$2" -f s16le - 2>/dev/null | md5sum | awk '{print $1}'; }
{ [ -n "$(am5 "$FIX/aac.ts" 0:a:0)" ] && [ "$(am5 "$FIX/aac.ts" 0:a:0)" = "$(am5 "$WORK/adual.mov" 0:a:1)" ]; } \
  && ok "decoded payloads bit-identical (source a:0 == output a:1)" \
  || no "decoded payloads differ — the preserved original really is wrong"
# negative control: a DIFFERENT AAC source must still FAIL — the reframing
# fallback tolerates framing, never content
ff -f lavfi -i testsrc2=duration=5 -f lavfi -i sine=frequency=500:duration=5 \
   -map 0:v -map 1:a -c:v libx264 -pix_fmt yuv420p -c:a aac -f mpegts "$WORK/other.ts"
o=$(bash "$SC/verify.sh" "$WORK/other.ts" "$WORK/adual.mov" --audio 2>&1); rc=$?
{ [ "$rc" -eq 1 ] && case "$o" in *"provenance track corrupted"*) true;; *) false;; esac; } \
  && ok "negative control: a mismatched AAC source still FAILs the gate (rc=1)" \
  || no "negative control broken (rc=$rc) — the fallback must not wave content differences through"

echo
echo "== 3. unroutable gate parity: auto.sh / remux.sh / batch.sh refuse like mov.sh =="
srcsize=$(wc -c < "$FIX/vp9.webm" | tr -d ' ')
o=$(bash "$SC/auto.sh" "$FIX/vp9.webm" "$WORK/vp9a.mov" 2>&1); rc=$?
[ "$rc" -eq 11 ] && ok "auto.sh refuses VP9 pre-flight (exit 11; was: rc=1 after burning rungs 0->2->3)" \
  || { no "auto.sh rc=$rc, want 11"; printf '%s\n' "$o" | tail -4 | sed 's/^/   /'; }
has   "$o" "MOV_REFUSED profile=unroutable-vcodec vcodec=vp9" "auto.sh emits the machine line"
hasnt "$o" "attempting Rung" "no ladder rung is ever attempted on an unroutable codec"
hasnt "$o" "only supported in MP4" "no raw muxer error surfaces from auto.sh"
{ [ ! -f "$WORK/vp9a.mov" ] && [ ! -f "$WORK/vp9a.mov.part" ]; } \
  && ok "auto.sh refusal writes nothing (no artifact, no .part litter)" || no "auto.sh refusal left files behind"
o=$(bash "$SC/remux.sh" "$FIX/vp9.webm" "$WORK/vp9r.mov" 2>&1); rc=$?
[ "$rc" -eq 11 ] && ok "remux.sh refuses VP9 pre-flight (exit 11; was: rc=1 + raw muxer death)" \
  || { no "remux.sh rc=$rc, want 11"; printf '%s\n' "$o" | tail -4 | sed 's/^/   /'; }
has   "$o" "MOV_REFUSED profile=unroutable-vcodec vcodec=vp9" "remux.sh emits the machine line"
has   "$o" "rung4  scripts/rung4.sh" "remux.sh names the routes (shared voice, not a fork)"
{ [ ! -f "$WORK/vp9r.mov" ] && [ ! -f "$WORK/vp9r.mov.part" ]; } \
  && ok "remux.sh refusal writes nothing (the 0-byte .part litter is gone)" || no "remux.sh refusal left files behind"
o=$(bash "$SC/batch.sh" "$FIX/vp9.webm" --out "$WORK/vb" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "batch exits 0 (REFUSED is the gate working, never a batch failure)" || no "batch rc=$rc, want 0"
has   "$o" "REFUSED=1" "batch report counts the class REFUSED"
has   "$o" "FAIL=0"    "batch report counts no FAIL (was: FAIL=1 REFUSED=0)"
side=$(cat "$WORK/vb/vp9.mov.provenance.kv" 2>/dev/null || true)
has "$side" "PROV_VERDICT=REFUSED" "provenance sidecar records the REFUSED verdict"
[ "$(wc -c < "$FIX/vp9.webm" | tr -d ' ')" = "$srcsize" ] && ok "source untouched through all three refusals" \
  || no "source was modified"

echo
echo "== 4. batch.sh sidecar records UPPERCASE rungs (PROV_RUNG=S, the sed fix) =="
# gate-(f) short-audio shape (the 23-escalation recipe): auto verifies REVIEW
# on rung 0, escalates to Rung 3-SYNC (resync) -> AUTO_SUMMARY rung=S. The
# pre-fix sed ([a-z0-9]) matched neither P nor S and wrote PROV_RUNG=none.
ff -f lavfi -i testsrc2=s=320x240:r=30000/1001 -t 6 -c:v libx264 -g 30 -pix_fmt yuv420p -an "$WORK/dv6.mov"
ff -f lavfi -i sine=1000 -t 5.4 -c:a aac "$WORK/da54.m4a"
ff -i "$WORK/dv6.mov" -i "$WORK/da54.m4a" -map 0:v:0 -map 1:a:0 -c copy "$WORK/dshort.mov"
o=$(bash "$SC/batch.sh" "$WORK/dshort.mov" --out "$WORK/sb" 2>&1); rc=$?
has "$o" "rung=S" "auto really ended on an uppercase rung (premise intact)"
side=$(cat "$WORK/sb/dshort.mov.provenance.kv" 2>/dev/null || true)
has "$side" "PROV_RUNG=S" "sidecar records PROV_RUNG=S (was: PROV_RUNG=none)"
has "$side" "PROV_VERDICT=REVIEW" "sidecar verdict matches the exit code"

echo
echo "== 5. non-audio drops WARN at the remux funnel (house rule 5) =="
printf '1\n00:00:00,000 --> 00:00:03,000\nhello\n' > "$WORK/s.srt"
ff -f lavfi -i testsrc2=s=320x240:r=25:d=4 -f lavfi -i sine=1000:d=4 -i "$WORK/s.srt" \
   -map 0:v -map 1:a -map 2:s -c:v libx264 -pix_fmt yuv420p -c:a aac -c:s srt "$WORK/subbed.mkv"
o=$(bash "$SC/remux.sh" "$WORK/subbed.mkv" "$WORK/subbed.mov" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "subtitled source still builds (the WARN is an announcement, not a gate)" || no "remux rc=$rc"
has "$o" "WARN DROP stream #2 (subtitle subrip)" "the dropped subtitle stream is WARNed by index/type/codec"
has "$o" "unmapped=1" "RMX_PLAN carries the additive unmapped= count"
# a plain 1v+1a source stays quiet: unmapped=0, no census WARN
o=$(bash "$SC/remux.sh" "$FIX/aac.ts" "$WORK/plain.mov" 2>&1); rc=$?
has   "$o" "unmapped=0" "clean source: unmapped=0"
hasnt "$o" "WARN DROP stream #" "clean source: no spurious census WARN (TS double-listing deduped)"

echo
echo "== 6. PCM access depth honesty: a >16-bit source WARNs on the access line =="
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q pcm_bluray; then
  ff -f lavfi -i testsrc2=s=320x240:r=25:d=4 -f lavfi -i sine=1000:d=4 \
     -c:v libx264 -pix_fmt yuv420p -c:a pcm_bluray -sample_fmt s32 -f mpegts "$WORK/pcm24.m2ts"
  o=$(bash "$SC/mov.sh" "$WORK/pcm24.m2ts" "$WORK/pcm24.mov" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "24-bit pcm_bluray source still builds DONE (the WARN is honesty, not a refusal)" \
    || { no "mov.sh rc=$rc on pcm24"; printf '%s\n' "$o" | tail -4 | sed 's/^/   /'; }
  has "$o" "DEPTH IS REDUCED" "the depth reduction is announced (was: silent as to depth)"
  has "$o" "exceeds 16-bit" "the WARN names the decoder-native format evidence"
  # 16-bit-native sources must NOT draw the depth WARN (aac decodes fltp -> no s32 arm)
  o=$(bash "$SC/remux.sh" "$FIX/aac.ts" "$WORK/aacpcm.mov" --audio pcm 2>&1)
  hasnt "$o" "DEPTH IS REDUCED" "no depth WARN where no integer depth exceeds 16-bit"
else
  echo "  (skip: no pcm_bluray encoder on this bench — depth-WARN pin untestable)"
fi

echo
echo "fix-round: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
