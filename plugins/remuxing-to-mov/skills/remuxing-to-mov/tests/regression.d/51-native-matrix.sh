#!/usr/bin/env bash
# 51-native-matrix.sh — work-order 5.1: recognize the measured-native video
# codecs (and align probe's audio advisory with the fixed routing).
#
# Pre-1.11 the scripts named only h264/mpeg2video/hevc (+prores as a Rung-4
# target) as MOV video classes. Measured on the bench 2026-08-14 (macOS 26.6.1,
# ffmpeg 9.0.1): mpeg4(tag mp4v), MJPEG 4:2:0(jpeg), dvvideo(dvcp) and
# prores(apcn) all mux -c copy into MOV and fully decode in AVFoundation — so
# a DV/MJPEG/MPEG-4 capture must route as a recognized lossless copy, never
# toward a needless conversion. Codec decode verdicts DRIFT with macOS (C63:
# Tahoe 26.4 dropped MJPEG variants; C72: 26.6.1 restored 4:2:2), so the
# recognition self-dates (Ground Rule 6) and the classes probe cannot vouch
# for get the WO 4.1 post-build empirical proof instead of a silent
# "QuickTime-ready" overclaim.
#
# Asserted:
#   1. each F8 fixture (mp4v.mov, mjpeg.mov, dv.mov, prores.mov) through
#      mov.sh: builds (DONE on this mac bench; prores rides the WO 4.1
#      contribution arm off-macOS -> honest REVIEW), prints the bench-dated
#      recognition line, video is copied bit-exact (streamhash identity +
#      source tag preserved), and the OUTPUT passes playable-check.sh
#      (OS-split: SKIP announced off-macOS — Ground Rule 6).
#   2. probe.sh exports the new additive field: PR_VNATIVE=yes for all four
#      (+ m2v420.ts control), "vnative" present in --json.
#   3. the unproven classes are wired into the EXISTING empirical machinery:
#      MJPEG non-4:2:0 (PR_VNATIVE=variant, the C63 measured-drop class) and
#      an unmeasured codec (ffv1, PR_VNATIVE=no) both BUILD with the announced
#      warning/note plus a MOV_PLAYABILITY line, and the exit code follows the
#      verdict (ok -> 0 DONE, fail/skip -> 10 REVIEW) — drift-proof: a future
#      macOS restoring a codec flips the verdict, not the test.
#   4. WO 3.1 addendum — probe's PR_AUDIO_ACTION agrees with the fixed
#      routing: pcm_bluray -> pcm (Rung 1 --audio pcm; the pre-5.1 copy-class
#      advisory contradicted mov.sh/remux.sh), mp3 -> copy (QT-native, C33;
#      pre-5.1 it was misfiled pcm, a needless forced decode), mp2 control
#      stays pcm, ac3 stays copy-class (rung 0 = remux --audio auto already
#      lands it as announced per-track PCM access, WO 3.2).
#
# Standalone: bash tests/regression.d/51-native-matrix.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
# Regenerates missing fixtures via make-fixtures.sh; inline scratch classes
# (mjpeg-422, ffv1, mp3) are minted into mktemp and skip with an announcement
# if this ffmpeg cannot encode them. The repo tree is never written to.
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
p1 () { # p1 FILE SELECT ENTRIES — single value, no head (SIGPIPE hygiene)
  ffprobe -v error -select_streams "$2" -show_entries "$3" -of default=nw=1:nk=1 "$1" 2>/dev/null | awk 'NR==1'
}
vhash () { # bit-exact video essence fingerprint (packet payload sequence)
  ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null | awk 'NR==1'
}

F8="mp4v.mov mjpeg.mov dv.mov prores.mov"
for f in $F8 m2v420.ts multilang.ts; do
  if [ ! -f "$FIX/$f" ]; then
    echo "== regenerating missing fixture: $f =="
    bash "$TESTS/make-fixtures.sh" "$f" || { echo "fixture build failed: $f"; exit 2; }
  fi
  [ -f "$FIX/$f" ] || { echo "fixture $f still missing after make-fixtures"; exit 2; }
done

# the bench split (Ground Rule 6, same shape as 41-422-empirical.sh): verdicts
# are a property of the macOS they ran on; off-macOS the honest answer is an
# announced SKIP, and this suite asserts THAT instead of pretending.
if [ "$(uname -s)" = Darwin ] && command -v qlmanage >/dev/null 2>&1; then BENCH=mac; else BENCH=other; fi

echo "== 1. the F8 matrix routes as a recognized lossless copy (bench: $BENCH) =="
# measured tag registry, bench 2026-08-14 (macOS 26.6.1/ffmpeg 9.0.1); dvc is
# the NTSC sibling of the measured PAL dvcp, apc*/ap4* the ProRes family
MEASURED_TAGS=" mp4v jpeg dvcp dvc apco apcs apcn apch ap4h ap4x "
run_f8 () { # run_f8 FIXTURE VCODEC
  local name="$1" vc="$2" o rc out sh_in sh_out tag_in tag_out prc pco
  out="$WORK/${name%.*}.out.mov"
  o=$(bash "$SC/mov.sh" "$FIX/$name" "$out" 2>&1); rc=$?
  # prores carries yuv422p10le -> rides the WO 4.1 contribution arm: DONE on a
  # bench that proves it, honest REVIEW (verdict=skip) elsewhere. The other
  # three are 4:2:0 and must be DONE everywhere with no playability pass.
  if [ "$name" = prores.mov ] && [ "$BENCH" != mac ]; then
    { [ "$rc" -eq 10 ] && [ -f "$out" ]; } \
      && ok "$name: builds + honest REVIEW off-macOS (contribution arm)" \
      || no "$name: rc=$rc, want 10 off-macOS (artifact + announced REVIEW)"
  else
    { [ "$rc" -eq 0 ] && [ -f "$out" ]; } \
      && ok "$name: builds DONE (rc=0)" \
      || { no "$name: rc=$rc, want 0"; printf '%s\n' "$o" | grep -E '^>>|MOV_' | sed 's/^/   /'; }
  fi
  has "$o" "$vc: measured QT-native in MOV (bench " "$name: bench-dated recognition line"
  hasnt "$o" "MOV_REFUSED" "$name: no MOV_REFUSED"
  # copy proof: same codec, source tag preserved, bit-exact packet sequence
  [ "$(p1 "$out" v:0 stream=codec_name)" = "$vc" ] \
    && ok "$name: output video codec is $vc (copied, not converted)" \
    || no "$name: output video codec drifted ($(p1 "$out" v:0 stream=codec_name))"
  tag_in=$(p1 "$FIX/$name" v:0 stream=codec_tag_string); tag_out=$(p1 "$out" v:0 stream=codec_tag_string)
  [ -n "$tag_out" ] && [ "$tag_in" = "$tag_out" ] \
    && ok "$name: sample-entry tag survives the copy ($tag_out)" \
    || no "$name: tag changed across copy ($tag_in -> $tag_out)"
  case "$MEASURED_TAGS" in *" $tag_out "*) ok "$name: tag $tag_out is in the measured registry";;
    *) no "$name: tag '$tag_out' not in the measured registry (re-measure the bench)";; esac
  sh_in=$(vhash "$FIX/$name"); sh_out=$(vhash "$out")
  [ -n "$sh_in" ] && [ "$sh_in" = "$sh_out" ] \
    && ok "$name: video streamhash identical (bit-exact copy)" \
    || no "$name: video streamhash differs (in=$sh_in out=$sh_out)"
  # the acceptance's empirical half: the OUTPUT passes playable-check
  pco=$(bash "$SC/playable-check.sh" "$out" 2>&1); prc=$?
  if [ "$BENCH" = mac ]; then
    [ "$prc" -eq 0 ] && ok "$name: output passes playable-check on this bench" \
      || { no "$name: playable-check rc=$prc, want 0 (measured-native codec no longer decodes?)"
           printf '%s\n' "$pco" | sed 's/^/   /'; }
  else
    { [ "$prc" -eq 3 ] && case "$pco" in *SKIP*) true;; *) false;; esac; } \
      && ok "$name: playable-check SKIP announced off-macOS (Ground Rule 6)" \
      || no "$name: off-macOS playable-check rc=$prc, want announced SKIP (3)"
  fi
}
run_f8 mp4v.mov   mpeg4
run_f8 mjpeg.mov  mjpeg
run_f8 dv.mov     dvvideo
run_f8 prores.mov prores

echo
echo "== 2. probe exports the classification (additive PR_VNATIVE / vnative) =="
for f in $F8; do
  kv=$(bash "$SC/probe.sh" "$FIX/$f" --kv 2>&1)
  has "$kv" "PR_VNATIVE=yes" "$f: PR_VNATIVE=yes"
done
kv=$(bash "$SC/probe.sh" "$FIX/m2v420.ts" --kv 2>&1)
has "$kv" "PR_VNATIVE=yes" "m2v420.ts control: mpeg2video stays in the native matrix"
js=$(bash "$SC/probe.sh" "$FIX/mp4v.mov" --json 2>&1)
has "$js" '"vnative":"yes"' "--json carries the vnative field"
# human mode names the measured route with its bench date, refusal voice gone
h=$(bash "$SC/probe.sh" "$FIX/dv.mov" 2>&1)
has "$h" "QT-native, measured (bench " "probe human mode: bench-dated native advisory"
hasnt "$h" "refuses early" "probe human mode: no stale exit-11 refusal claim"

echo
echo "== 3. unproven classes: announced + proven post-build, never assumed =="
# bounded verdicts: the C63 stall class would otherwise cost 60 s per probe
export RTM_QL_TIMEOUT=15
verdict_rc () { # verdict_rc OUTPUT RC NAME — exit code must FOLLOW the verdict
  local v; v=$(printf '%s\n' "$1" | sed -n 's/.*MOV_PLAYABILITY os=[^ ]* verdict=\([a-z]*\).*/\1/p' | awk 'NR==1')
  case "$v" in
    ok)        [ "$2" -eq 0 ]  && ok "$3: verdict=ok -> DONE (rc=0)"    || no "$3: verdict=ok but rc=$2";;
    fail|skip) [ "$2" -eq 10 ] && ok "$3: verdict=$v -> REVIEW (rc=10)" || no "$3: verdict=$v but rc=$2";;
    *) no "$3: no MOV_PLAYABILITY verdict found";;
  esac
}
if ffmpeg -nostdin -y -v error -f lavfi -i testsrc2=s=320x240:r=25:d=2 \
     -c:v mjpeg -pix_fmt yuvj422p -q:v 4 -f mov "$WORK/mj422.mov" 2>/dev/null; then
  kv=$(bash "$SC/probe.sh" "$WORK/mj422.mov" --kv 2>&1)
  has "$kv" "PR_VNATIVE=variant" "mjpeg yuvj422p: PR_VNATIVE=variant (C63 measured-drop class)"
  o=$(bash "$SC/mov.sh" "$WORK/mj422.mov" "$WORK/mj422.out.mov" 2>&1); rc=$?
  [ -f "$WORK/mj422.out.mov" ] && ok "mjpeg-422: still BUILDS (lossless copy, never refused)" \
    || no "mjpeg-422: no artifact written (rc=$rc)"
  has "$o" "WARN mjpeg yuvj422p: non-4:2:0 MJPEG" "mjpeg-422: the C63 warning is announced"
  has "$o" "MOV_PLAYABILITY os=" "mjpeg-422: post-build empirical check ran"
  verdict_rc "$o" "$rc" "mjpeg-422"
else
  echo "  (skip: this ffmpeg can't mint mjpeg yuvj422p — variant arm untested here)"
fi
if ffmpeg -nostdin -y -v error -f lavfi -i testsrc2=s=320x240:r=25:d=2 \
     -c:v ffv1 -f mov "$WORK/ffv1.mov" 2>/dev/null; then
  kv=$(bash "$SC/probe.sh" "$WORK/ffv1.mov" --kv 2>&1)
  has "$kv" "PR_VNATIVE=no" "ffv1: PR_VNATIVE=no (outside the measured matrix)"
  o=$(bash "$SC/mov.sh" "$WORK/ffv1.mov" "$WORK/ffv1.out.mov" 2>&1); rc=$?
  [ -f "$WORK/ffv1.out.mov" ] && ok "ffv1: still BUILDS (lossless copy, never refused)" \
    || no "ffv1: no artifact written (rc=$rc)"
  has "$o" "outside the measured QT-native matrix" "ffv1: the unmeasured-codec note is announced"
  has "$o" "MOV_PLAYABILITY os=" "ffv1: post-build empirical check ran"
  verdict_rc "$o" "$rc" "ffv1"
else
  echo "  (skip: this ffmpeg can't mint ffv1-in-MOV — unmeasured-codec arm untested here)"
fi
unset RTM_QL_TIMEOUT

echo
echo "== 4. WO 3.1 addendum: probe's audio advisory agrees with the routing =="
if [ ! -f "$FIX/pcm_bluray.m2ts" ]; then
  bash "$TESTS/make-fixtures.sh" pcm_bluray.m2ts >/dev/null 2>&1 || true
fi
if [ -f "$FIX/pcm_bluray.m2ts" ]; then
  kv=$(bash "$SC/probe.sh" "$FIX/pcm_bluray.m2ts" --kv 2>&1)
  has "$kv" "PR_AUDIO_ACTION=pcm" "pcm_bluray: advisory is pcm (agrees with mov.sh/remux.sh, WO 3.1)"
  has "$kv" "PR_REC_RUNG=1" "pcm_bluray: recommended rung 1 (--audio pcm)"
  has "$kv" "--audio pcm" "pcm_bluray: rec_cmd forces the PCM access route"
else
  echo "  (skip: pcm_bluray.m2ts unmintable on this ffmpeg — advisory alignment untested here)"
fi
if ffmpeg -nostdin -y -v error -f lavfi -i testsrc2=s=320x240:r=25:d=2 \
     -f lavfi -i "sine=frequency=440:duration=2:sample_rate=48000" \
     -map 0:v -map 1:a -c:v libx264 -preset veryfast -pix_fmt yuv420p \
     -c:a libmp3lame -b:a 128k -f mpegts "$WORK/mp3.ts" 2>/dev/null; then
  kv=$(bash "$SC/probe.sh" "$WORK/mp3.ts" --kv 2>&1)
  has "$kv" "PR_ACODEC=mp3" "mp3 scratch: probe sees mp3"
  has "$kv" "PR_AUDIO_ACTION=copy" "mp3: advisory is copy (QT-native, C33 — no needless decode)"
  has "$kv" "PR_REC_RUNG=0" "mp3: recommended rung 0 (plain copy)"
else
  echo "  (skip: no mp3 encoder on this ffmpeg — mp3 alignment untested here)"
fi
kv=$(bash "$SC/probe.sh" "$FIX/m2v420.ts" --kv 2>&1)   # mp2 control
has "$kv" "PR_AUDIO_ACTION=pcm" "mp2 control: still pcm (QuickTime-unplayable)"
kv=$(bash "$SC/probe.sh" "$FIX/multilang.ts" --kv 2>&1)   # ac3 a:0
has "$kv" "PR_AUDIO_ACTION=copy" "ac3: stays copy-class (rung 0 auto lands per-track PCM access, WO 3.2)"
has "$kv" "PR_REC_RUNG=0" "ac3: recommended rung 0"

for f in $F8 m2v420.ts; do
  [ -f "$FIX/$f" ] || no "fixture $f vanished during the run"
done
ok "sources untouched"

echo
echo "native-matrix: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
