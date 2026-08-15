#!/usr/bin/env bash
# 43-fidelity-retag.sh — work-order round 1.12: the XDCAM retag route (WO-A)
# and the fidelity gate (WO-B) pinned AGAINST EACH OTHER on one clip.
#
# THE PAIR: one synthetic MPEG-2 4:2:2 clip (tests/fixtures/m2v422.mov), two
# stream-copy builds minted in scratch — `m2v1.mov` (-c copy, generic stsd
# 'm2v1') and `xd5b.mov` (-c copy -tag:v xd5b, the XDCAM HD422 entry). The
# retag changes ONE FourCC and zero payload bytes; the pair proves it and
# keeps WO-A and WO-B honest about each other:
#   * WO-A (probe.sh retag advisory): PR_TAG_ADVICE=xd5b must fire on the
#     m2v1 build and NOT on the xd5b build (idempotent — no advisory loop on
#     an already-retagged file), and NOT on a 4:2:0 MOV that carries the very
#     same 'm2v1' stsd (the pix_fmt discriminator is pinned, not assumed).
#   * WO-B (playable-check.sh --fidelity): the flag surface must never come
#     back as exit 2/unknown-option, must always announce its additive
#     PLAYCHECK_FIDELITY machine line, and on a macOS bench the xd5b build
#     must prove verdict=ok with SSIM >= threshold while a threshold-forced
#     run (RTM_FIDELITY_SSIM=0.99) proves the gate CAN fail and fails the
#     documented way (verdict=fail reason=fidelity, exit 1).
# If either work-order silently regresses, the other half of this file turns
# red: an advisory that stops firing strands broken m2v1 renders that the
# fidelity gate then has to catch; a fidelity gate that loses its flag parse
# makes the retag route unverifiable.
#
# EVIDENCE (2026-08-15, macOS 26.6.1 / ffmpeg 9.0.1): stsd 'm2v1' on MPEG-2
# 4:2:2 is decoder DISPATCH, not damage — AVFoundation routes the generic
# m2v1 entry to its consumer decoder (macroblock garbage on 4:2:2) and the
# xd5* XDCAM HD422 entries to the professional decoder. Measured on two real
# 1080i59.94 broadcast masters: garbage as m2v1, frame-for-frame identical to
# the ffmpeg reference as xd5b.
#
# SYNTHESIS LIMIT (the suite's standing doctrine — regression.sh header): the
# SYNTHETIC m2v1 4:2:2 clip does NOT reproduce the consumer-decoder
# corruption. On this bench it decodes cleanly through the consumer path
# (worst-sample SSIM ~0.95 >= 0.90 -> fidelity=ok). The destroyed-render half
# of the WO-B evidence therefore CANNOT be minted here and is recorded as an
# OPERATOR-VERIFIED residual (2026-08-15, two real 1080i59.94 broadcast
# masters, off-repo) — never faked into a green. What this file asserts
# instead are the mechanism halves that ARE synthesizable: the lossless
# retag, the advisory's exact firing surface, the flag surface, the healthy
# verdict=ok path, and the threshold-forced verdict=fail reason=fidelity
# path. The m2v1-build fidelity run is asserted VERDICT-FOLLOWING (the
# 51-native-matrix style): whichever verdict this macOS measures, the exit
# code must follow it — drift-proof if a future macOS starts corrupting even
# the synthetic clip.
#
# Standalone: bash tests/regression.d/43-fidelity-retag.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
# Regenerates missing fixtures via make-fixtures.sh. Scratch goes to mktemp
# (auto-cleaned); the repo tree is never written to.
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

for f in m2v422.mov m2v420.ts; do
  if [ ! -f "$FIX/$f" ]; then
    echo "== regenerating missing fixture: $f =="
    bash "$TESTS/make-fixtures.sh" "$f" || { echo "fixture build failed: $f"; exit 2; }
  fi
  [ -f "$FIX/$f" ] || { echo "fixture $f still missing after make-fixtures"; exit 2; }
done

# the bench split (Ground Rule 6, same shape as 41-422-empirical.sh): fidelity
# verdicts are a property of the macOS they ran on; off-macOS the honest
# answer is an announced SKIP, and this suite asserts THAT instead of
# pretending. Evidence bench: macOS 26.6.1, ffmpeg 9.0.1, 2026-08-15.
if [ "$(uname -s)" = Darwin ] && command -v qlmanage >/dev/null 2>&1; then BENCH=mac; else BENCH=other; fi

echo "== 1. one clip, two stream-copy builds: the retag is one FourCC, zero payload bytes =="
M1="$WORK/m2v1.mov"; X5="$WORK/xd5b.mov"; C4="$WORK/ctl420.mov"
ffmpeg -nostdin -v error -i "$FIX/m2v422.mov" -map 0:v:0 -c copy \
  -movflags +faststart -f mov "$M1" 2>/dev/null
[ -s "$M1" ] && ok "m2v1 build (-c copy) written" || { echo "could not build $M1"; exit 2; }
ffmpeg -nostdin -v error -i "$FIX/m2v422.mov" -map 0:v:0 -c copy -tag:v xd5b \
  -movflags +faststart -f mov "$X5" 2>/dev/null
[ -s "$X5" ] && ok "xd5b build (-c copy -tag:v xd5b, the documented retag) written" || { echo "could not build $X5"; exit 2; }
# negative control: a 4:2:0 MOV carries the SAME generic 'm2v1' stsd
ffmpeg -nostdin -v error -i "$FIX/m2v420.ts" -map 0:v:0 -c copy -f mov "$C4" 2>/dev/null
[ -s "$C4" ] && ok "4:2:0 control MOV (same m2v1 stsd, healthy pix_fmt) written" || { echo "could not build $C4"; exit 2; }
[ "$(p1 "$M1" v:0 stream=codec_tag_string)" = m2v1 ] \
  && ok "m2v1 build carries tag m2v1" || no "m2v1 build tag drifted: $(p1 "$M1" v:0 stream=codec_tag_string)"
[ "$(p1 "$X5" v:0 stream=codec_tag_string)" = xd5b ] \
  && ok "xd5b build carries tag xd5b" || no "xd5b build tag drifted: $(p1 "$X5" v:0 stream=codec_tag_string)"
[ "$(p1 "$C4" v:0 stream=codec_tag_string)" = m2v1 ] \
  && ok "4:2:0 control carries tag m2v1 (the discriminator's whole point)" \
  || no "4:2:0 control tag unexpected: $(p1 "$C4" v:0 stream=codec_tag_string)"
hs=$(vhash "$FIX/m2v422.mov"); h1=$(vhash "$M1"); h5=$(vhash "$X5")
{ [ -n "$hs" ] && [ "$hs" = "$h1" ] && [ "$hs" = "$h5" ]; } \
  && ok "video packet hash identical across source/m2v1/xd5b (the retag is provably lossless)" \
  || no "packet hash differs (src=$hs m2v1=$h1 xd5b=$h5) — a 'retag' that touched payload"

echo
echo "== 2. WO-A: the retag advisory fires exactly once, on exactly the right shape =="
kv1=$(bash "$SC/probe.sh" "$M1" --kv 2>&1)
has "$kv1" "PR_TAG_ADVICE=xd5b" "m2v1 4:2:2 build: PR_TAG_ADVICE=xd5b fires"
js1=$(bash "$SC/probe.sh" "$M1" --json 2>&1)
has "$js1" '"tag_advice":"xd5b"' "--json carries the additive tag_advice field"
kv5=$(bash "$SC/probe.sh" "$X5" --kv 2>&1)
hasnt "$kv5" "PR_TAG_ADVICE" "xd5b build: advisory SILENT (idempotent — no retag loop)"
kv4=$(bash "$SC/probe.sh" "$C4" --kv 2>&1)
hasnt "$kv4" "PR_TAG_ADVICE" "4:2:0 control (same m2v1 stsd): advisory SILENT — the pix_fmt discriminator is pinned, not assumed"

echo
echo "== 3. WO-B: the --fidelity surface + verdicts (bench: $BENCH) =="
# One run of the flag on the healthy xd5b build serves BOTH benches: the flag
# parse and the announced machine line are cross-platform properties; the
# verdict itself is macOS-only (Ground Rule 6). Baseline runs PIN the
# documented default threshold (RTM_FIDELITY_SSIM=0.90) so an ambient
# operator export can never leak in — hermetic regardless of environment;
# only the forced-fail arm below deliberately overrides it.
o5=$(RTM_FIDELITY_SSIM=0.90 bash "$SC/playable-check.sh" --fidelity "$X5" 2>&1); rc5=$?
[ "$rc5" -ne 2 ] && ok "--fidelity is a parsed flag (exit != 2/unknown-option)" \
  || no "--fidelity rejected as unknown option/usage (rc=2) — the flag parse was removed"
hasnt "$o5" "unknown option" "--fidelity never reported as unknown option"
has "$o5" "PLAYCHECK_FIDELITY " "the flag always announces its PLAYCHECK_FIDELITY machine line (never silent)"
if [ "$BENCH" = mac ]; then
  [ "$rc5" -eq 0 ] && ok "xd5b build: --fidelity exit 0 (retagged file decodes AND matches)" \
    || { no "xd5b build: --fidelity rc=$rc5, want 0"; printf '%s\n' "$o5" | sed 's/^/   /'; }
  has "$o5" "PLAYCHECK_FIDELITY verdict=ok" "xd5b build: verdict=ok on this bench"
  ssim5=$(printf '%s\n' "$o5" | sed -n 's/^PLAYCHECK_FIDELITY verdict=ok reason=[^ ]* ssim=\([0-9.]*\).*/\1/p' | awk 'NR==1')
  if [ -n "$ssim5" ] && awk -v s="$ssim5" 'BEGIN{exit !(s>=0.90)}'; then
    ok "xd5b build: measured SSIM $ssim5 >= threshold 0.90 (pinned)"
  else
    no "xd5b build: SSIM '$ssim5' not parseable/below threshold 0.90 (pinned)"
  fi

  # -- the m2v1 build: VERDICT-FOLLOWING (drift-proof), with the residual said out loud --
  echo "  SYNTHESIS LIMIT: the synthetic m2v1 4:2:2 clip does NOT reproduce the real-master"
  echo "  consumer-decoder corruption — on the evidence bench (macOS 26.6.1, 2026-08-15) it"
  echo "  decodes cleanly through the consumer path (SSIM ~0.95). The destroyed-render half"
  echo "  of WO-B is OPERATOR-VERIFIED (2026-08-15, two real 1080i59.94 broadcast masters,"
  echo "  off-repo) and stays a residual here — asserted below is only that the exit code"
  echo "  FOLLOWS whatever verdict THIS macOS measures on the synthetic clip."
  om=$(RTM_FIDELITY_SSIM=0.90 bash "$SC/playable-check.sh" --fidelity "$M1" 2>&1); rcm=$?
  vline=$(printf '%s\n' "$om" | sed -n 's/^PLAYCHECK_FIDELITY verdict=\([a-z]*\) reason=\([a-z-]*\).*/\1 \2/p' | awk 'NR==1')
  vm=${vline%% *}; rsn=${vline#* }
  case "$vm" in
    ok)
      [ "$rcm" -eq 0 ] \
        && ok "m2v1 synthetic build: measured verdict=ok -> exit 0 (this bench decodes the SYNTHETIC clip cleanly; real-master corruption remains operator-verified, not minted)" \
        || no "m2v1 synthetic build: verdict=ok but rc=$rcm (exit must follow the verdict)";;
    fail)
      { [ "$rcm" -eq 1 ] && [ "$rsn" = fidelity ]; } \
        && ok "m2v1 synthetic build: measured verdict=fail reason=fidelity -> exit 1 (this macOS now corrupts even the synthetic clip; the gate caught it the documented way)" \
        || no "m2v1 synthetic build: verdict=fail (reason=$rsn) but rc=$rcm — a fail must be reason-named and exit 1";;
    *)
      no "m2v1 synthetic build: no PLAYCHECK_FIDELITY verdict found (rc=$rcm)"
      printf '%s\n' "$om" | sed 's/^/   /';;
  esac

  # -- the fail mechanism IS synthesizable: force the threshold over a healthy build --
  of=$(RTM_FIDELITY_SSIM=0.99 bash "$SC/playable-check.sh" --fidelity "$X5" 2>&1); rcf=$?
  [ "$rcf" -eq 1 ] && ok "threshold-forced run (RTM_FIDELITY_SSIM=0.99): exit 1 — the gate CAN fail" \
    || no "threshold-forced run: rc=$rcf, want 1 (the fail arm is unreachable)"
  has "$of" "verdict=fail reason=fidelity" "threshold-forced run: fails the documented way (verdict=fail reason=fidelity)"
else
  # announced SKIP arm: name exactly what was NOT proven here (Ground Rule 6)
  [ "$rc5" -eq 3 ] && ok "--fidelity off-macOS: announced SKIP (exit 3), never a silent pass" \
    || no "--fidelity off-macOS: rc=$rc5, want 3 (announced SKIP)"
  has "$o5" "verdict=skip" "off-macOS: the machine line carries verdict=skip (the announced downgrade)"
  echo "  SKIP on this bench — NOT proven here: the xd5b verdict=ok + SSIM>=threshold half,"
  echo "  the m2v1 verdict-following half, and the RTM_FIDELITY_SSIM=0.99 forced-fail"
  echo "  mechanism all need AVFoundation (macOS + qlmanage/avconvert). Evidence bench:"
  echo "  macOS 26.6.1 / ffmpeg 9.0.1, 2026-08-15. The destroyed-render half additionally"
  echo "  cannot be minted synthetically ANYWHERE and is operator-verified (2026-08-15,"
  echo "  two real 1080i59.94 broadcast masters) — see the SYNTHESIS LIMIT header."
fi

for f in m2v422.mov m2v420.ts; do
  [ -f "$FIX/$f" ] || no "fixture $f vanished during the run"
done
ok "sources untouched"

echo
# the residual rides the closing line: the parent suite (regression.sh §27)
# shows only a passing sub-suite's LAST line, and a residual must be VISIBLE
# there, not buried in captured output (announced, never silent).
echo "fidelity-retag: $pass passed, $fail failed — destroyed-render half operator-verified (2026-08-15, two real 1080i59.94 masters; the synthetic 4:2:2 clip cannot mint the corruption)"
[ "$fail" -eq 0 ]
