#!/usr/bin/env bash
# 46-scan-align.sh — 1.13 D1/D4/D3: two gates that were reporting verdicts their
# evidence could not support, plus the MP2 inversion.
#
# D1 THE FIDELITY THRESHOLD WAS PROGRESSIVE-TUNED. `--fidelity`'s 0.90 default
# false-FAILs healthy INTERLACED material: the field report's real 1080i59.94
# capture measured 0.8866-0.9684 on healthy windows against 0.8146-0.8471 on
# corrupt ones (bands nearly touching, and 0.8866 already failing), and
# tests/fixtures/m2v422i.mov — a perfectly healthy synthetic interlaced 4:2:2
# clip minted for exactly this — scores ~0.867 through a healthy AVFoundation
# render on this bench. Since 1.13 a declared interlaced field_order is judged
# against RTM_FIDELITY_SSIM_INTERLACED (0.86) and every sample reports its
# Y/U/V split, because the deficit is chroma-plane, not field-structure
# (normalization sweep in the script header: every candidate moved it <=0.005).
#
# D4 "MISALIGNED" WAS A HASH INEQUALITY, NOT A MEASUREMENT. The dual-track gate
# md5'd both tracks WHOLE, so any length delta flipped the hash and printed a
# TIMING claim ("Dual-track audio misaligned") the test could not support — the
# field report hit exactly that with a 1040-sample delta equal to the tracks'
# declared start_pts, cross-correlation 1.000000 at offset 0. It now measures:
# lengths, declared start_pts, the common window's content, and a shift by the
# measured delta — and reserves the word for a mismatch that survives all four.
#
# D3 the MP2 inversion: gate (g) PASSED an MP2-only file (no audio at all in
# QuickTime) while FAILing configurations that work.
#
# Standalone: bash tests/regression.d/46-scan-align.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
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
p1 () { ffprobe -v error -select_streams "$2" -show_entries "$3" -of default=nw=1:nk=1 "$1" 2>/dev/null | awk 'NR==1'; }

for f in m2v422i.mov m2v422.mov m2v420.ts; do
  if [ ! -f "$FIX/$f" ]; then
    echo "== regenerating missing fixture: $f =="
    bash "$TESTS/make-fixtures.sh" "$f" || { echo "fixture build failed: $f"; exit 2; }
  fi
done
if [ "$(uname -s)" = Darwin ] && command -v qlmanage >/dev/null 2>&1 && command -v avconvert >/dev/null 2>&1; then BENCH=mac; else BENCH=other; fi

echo "== 1. D1: the interlaced fixture really is interlaced (the premise) =="
fo=$(p1 "$FIX/m2v422i.mov" v:0 stream=field_order)
case "$fo" in tt|bb|tb|bt) ok "m2v422i.mov declares field_order=$fo";; *) no "m2v422i.mov field_order='$fo' — the fixture stopped being interlaced";; esac
[ "$(p1 "$FIX/m2v422i.mov" v:0 stream=pix_fmt)" = yuv422p ] && ok "and it is 4:2:2 (the contribution class the gate guards)" || no "pix_fmt drifted"
[ "$(p1 "$FIX/m2v422.mov" v:0 stream=field_order)" = progressive ] \
  && ok "the progressive sibling m2v422.mov is the control" || no "m2v422.mov is no longer progressive — the A/B is gone"

echo
if [ "$BENCH" = mac ]; then
  echo "== 2. D1 (macOS): scan-keyed threshold + the per-plane split =="
  oi=$(bash "$SC/playable-check.sh" --fidelity "$FIX/m2v422i.mov" 2>&1); rci=$?
  has "$oi" "scan: INTERLACED" "the interlaced scan is DETECTED and announced"
  has "$oi" "scan=interlaced" "the machine line carries scan=interlaced"
  has "$oi" "thresh=0.86" "the in-force threshold is on the machine line (0.86, RTM_FIDELITY_SSIM_INTERLACED)"
  case "$oi" in *" y="*" u="*" v="*) ok "the Y/U/V plane split is reported (a FAIL can NAME chroma-geometry damage)";; *) no "no per-plane fields on PLAYCHECK_FIDELITY";; esac
  ssim=$(printf '%s\n' "$oi" | sed -n 's/^PLAYCHECK_FIDELITY [^ ]* [^ ]* ssim=\([0-9.]*\).*/\1/p' | awk 'NR==1')
  yv=$(printf '%s\n' "$oi" | sed -n 's/.* y=\([0-9.]*\) .*/\1/p' | awk 'NR==1')
  if [ -n "$ssim" ] && awk -v s="$ssim" 'BEGIN{exit !(s<0.90)}'; then
    ok "the healthy interlaced clip scores $ssim — BELOW the 0.90 progressive default (the false-FAIL D1 fixes)"
    [ "$rci" -eq 0 ] && ok "and it PASSES anyway, on the interlaced floor (verdict=ok, exit 0)" \
      || { no "healthy interlaced clip still FAILs (rc=$rci, ssim=$ssim) — the scan key is not working"; printf '%s\n' "$oi" | tail -10 | sed 's/^/   /'; }
    if [ -n "$yv" ] && awk -v y="$yv" -v s="$ssim" 'BEGIN{exit !(y>s)}'; then
      ok "Y ($yv) sits above All ($ssim) — the deficit is chroma, exactly as measured 2026-08-15"
    else
      echo "  NOTE Y=$yv vs All=$ssim on this bench — the chroma-carries-the-deficit shape has drifted; re-read known-limits.md 'Interlaced sources sit in a lower fidelity-SSIM band'."
    fi
  elif [ -n "$ssim" ]; then
    # drift-proof arm: if a future macOS renders this clip near-perfectly the
    # band claim is obsolete, but the exit code must still follow the verdict
    echo "  NOTE this macOS scores the interlaced clip $ssim (>= 0.90) — the measured band has moved."
    [ "$rci" -eq 0 ] && ok "verdict follows the measurement (exit 0)" || no "ssim=$ssim but rc=$rci"
  else
    no "no ssim parsed from the interlaced run (rc=$rci)"; printf '%s\n' "$oi" | tail -10 | sed 's/^/   /'
  fi
  # the progressive control keeps the 0.90 default — the pinned 1.12 behavior
  op=$(RTM_FIDELITY_SSIM=0.90 bash "$SC/playable-check.sh" --fidelity "$FIX/m2v422.mov" 2>&1); rcp=$?
  has "$op" "scan=progressive" "the progressive control is keyed progressive"
  has "$op" "thresh=0.90" "and judged against the unchanged 0.90 default"
  [ "$rcp" -eq 0 ] && ok "the progressive control still passes (1.12 behavior preserved)" || no "progressive control rc=$rcp"
  # the fail arm must remain reachable on an interlaced source too
  of=$(RTM_FIDELITY_SSIM_INTERLACED=0.999 bash "$SC/playable-check.sh" --fidelity "$FIX/m2v422i.mov" 2>&1); rcf=$?
  [ "$rcf" -eq 1 ] && ok "RTM_FIDELITY_SSIM_INTERLACED=0.999 forces a FAIL — the interlaced gate CAN fail" || no "forced interlaced fail rc=$rcf, want 1"
  has "$of" "verdict=fail reason=fidelity" "and fails the documented way"
  has "$of" "SIGNATURE:" "a FAIL now NAMES its plane signature instead of one opaque scalar"
  has "$of" "mp4swap" "and routes to the container swap before Rung 4 (D2)"
else
  echo "== 2. (skip: off-macOS — the AVFoundation half of the fidelity gate needs a Mac) =="
  o=$(bash "$SC/playable-check.sh" --fidelity "$FIX/m2v422i.mov" 2>&1); rc=$?
  [ "$rc" -eq 3 ] && ok "off-macOS: announced SKIP (exit 3), never a silent pass" || no "off-macOS rc=$rc, want 3"
  has "$o" "verdict=skip" "the machine line carries verdict=skip"
  echo "  NOT proven here: the interlaced band itself, the scan-keyed threshold in action,"
  echo "  and the plane split. Evidence bench: macOS 26.6.1 / ffmpeg 9.0.1, 2026-08-15."
fi

echo
echo "== 3. D4: dual-track alignment is MEASURED, and 'misaligned' means misaligned =="
bash "$SC/dual-track.sh" "$FIX/m2v420.ts" "$WORK/dt.mov" >/dev/null 2>&1
[ -s "$WORK/dt.mov" ] && ok "dual-track build exists (PCM access + preserved MP2 original)" || { no "dual-track build failed"; exit 1; }
o=$(bash "$SC/verify.sh" "$FIX/m2v420.ts" "$WORK/dt.mov" --audio 2>&1); rc=$?
case "$o" in
  *"== decoded original, aligned"*)
    ok "the healthy pair takes the fast path (whole-track hashes equal) — no extra decodes paid";;
  *"whole-track hash differs"*)
    ok "the hash differed and the gate MEASURED instead of asserting (the D4 behavior)"
    has "$o" "declared start_pts" "it reports both tracks' declared start_pts"
    has "$o" "common window" "it compares the common window instead of unequal-length hashes"
    hasnt "$o" "NOT aligned with the original decode" "the old unsupported timing verdict is gone";;
  *) no "gate (--audio) produced neither shape"; printf '%s\n' "$o" | tail -12 | sed 's/^/   /';;
esac
[ "$rc" -le 1 ] && ok "verify stays inside its contract on the --audio path (rc=$rc)" || no "verify rc=$rc"
# the word "misaligned" must no longer appear on a pair whose content matches
case "$o" in
  *"misaligned"*)
    case "$o" in
      *"MISALIGNED: the common window differs"*) ok "'misaligned' appears only as the measured verdict";;
      *) no "the unsupported 'misaligned' claim is still reachable on matching content";;
    esac;;
  *) ok "no 'misaligned' claim on a pair whose content matches";;
esac
# and a genuinely different track must still be caught
ffmpeg -nostdin -y -v error -i "$FIX/m2v420.ts" -map 0:v:0 -map 0:a:0 -map 0:a:0 \
  -c:v copy -c:a:0 pcm_s24le -filter:a:0 "volume=0.5" -c:a:1 copy \
  -movflags +faststart -f mov "$WORK/skew.mov" 2>/dev/null
if [ -s "$WORK/skew.mov" ]; then
  o=$(bash "$SC/verify.sh" "$FIX/m2v420.ts" "$WORK/skew.mov" --audio 2>&1)
  case "$o" in
    *"MISALIGNED"*|*"NOT aligned"*|*"Dual-track audio"*)
      ok "a genuinely WRONG access track is still caught (an attenuated decode != the original)";;
    *) no "a half-volume access track passed the alignment gate — the real defect class is now invisible";;
  esac
else
  echo "  (skip: could not mint the wrong-access-track control)"
fi

echo
echo "== 4. D3: the MP2 inversion — the gate no longer passes the configuration that fails =="
bash "$SC/remux.sh" "$FIX/m2v420.ts" "$WORK/mp2only.mov" --audio copy >/dev/null 2>&1
[ "$(p1 "$WORK/mp2only.mov" a:0 stream=codec_tag_string)" = .mp2 ] \
  && ok "the MP2-only build carries the '.mp2' sample entry" || no "expected a .mp2 entry"
o=$(bash "$SC/verify.sh" "$FIX/m2v420.ts" "$WORK/mp2only.mov" 2>&1); rc=$?
has "$o" "MP2 audio with NO PCM access track" "gate (g) names the no-playable-audio configuration"
has "$o" ">> REVIEW" "and REVIEWs it (pre-1.13 this shipped as a clean OK)"
[ "$rc" -eq 0 ] && ok "REVIEW keeps verify's documented exit 0 (the verdict is the printed text)" || no "verify rc=$rc on a REVIEW"
o=$(bash "$SC/verify.sh" "$FIX/m2v420.ts" "$WORK/dt.mov" 2>&1)
hasnt "$o" "MP2 audio with NO PCM access track" "the dual-track pair (MP2 + PCM access) is NOT flagged — the access track is what plays"
has "$o" ">> OK" "and it verifies clean"

echo
echo "== 5. D3: an off-list sample entry is a PRIOR, not a verdict =="
src_txt=$(cat "$SC/verify.sh")
has "$src_txt" "|ipcm)" "ipcm is on the QTFF audio allowlist (C101)"
has "$src_txt" "ALWAYS probe (D3)" "the decode probe now runs for off-list tags too (it used to be skipped)"
# the dead-track class must STILL fail: it fails the DECODE, which is the point
if [ -f "$FIX/pcm_bluray.m2ts" ]; then
  bash "$SC/remux.sh" "$FIX/pcm_bluray.m2ts" "$WORK/dead.mov" --audio copy >/dev/null 2>&1 || true
  if [ -s "$WORK/dead.mov" ]; then
    o=$(bash "$SC/verify.sh" "$FIX/pcm_bluray.m2ts" "$WORK/dead.mov" 2>&1); rc=$?
    { [ "$rc" -eq 1 ] && case "$o" in *"no decoder claims"*) true;; *) false;; esac; } \
      && ok "the dead-HDMV-track class STILL FAILs (off-list AND undecodable — the allowlist demotion did not weaken it)" \
      || { no "dead HDMV track no longer FAILs (rc=$rc)"; printf '%s\n' "$o" | grep -a 'a:0' | sed 's/^/   /'; }
  else
    echo "  (skip: the pcm_bluray copy-mux produced nothing on this ffmpeg)"
  fi
else
  echo "  (skip: pcm_bluray.m2ts absent — its encoder is bench-dependent; the dead-track arm is covered by 31-pcm-bluray.sh)"
fi

for f in m2v422i.mov m2v422.mov m2v420.ts; do
  [ -f "$FIX/$f" ] || no "fixture $f vanished during the run"
done
ok "sources untouched"

echo
echo "scan-align: $pass passed, $fail failed — the interlaced band is bench-measured (macOS 26.6.1, 2026-08-15) and separates by only ~0.02; see known-limits.md"
[ "$fail" -eq 0 ]
