#!/usr/bin/env bash
# 80-empty-ne-absent-audio-plan.sh — CHECKUP-2026-08-27 A1 / WO-1.15.4:
# the audio plan must fail CLOSED. One failed ffprobe (the audio-manifest
# query) used to ship a silently audio-stripped MOV as ">> DONE … verified
# lossless", exit 0 — the checkup's worst confirmed finding, measured
# end-to-end twice with the exact PATH shim used here (its appendix recipe).
#
# Pins (fault injection = PATH shim failing ONLY the named query shape; the
# same probe against everything else passes through to the real ffprobe):
#   1. remux.sh: manifest-probe failure -> REFUSED exit 2, nothing written;
#   2. probe.sh --kv: no fabricated PR_AUD_COUNT=0 — the sentinel
#      PR_AUD_MANIFEST=failed is emitted and the exit is nonzero;
#   3. mov.sh end-to-end (the A1 repro): refuses exit 2 — never ">> DONE",
#      never an audio-stripped .mov on disk;
#   4. auto.sh: same refusal at its eval site;
#   5. rebuild-paff.sh: audio-census failure -> REFUSED exit 2, no OUTPUT,
#      never "note: no audio streams found; rebuilding video only";
#   6. verify.sh gates (f)/(g): census failure -> UNPROVEN + REVIEW, never
#      "no audio tracks … gate N/A" with a green OK;
#   7. mov.sh PLANOUT guard: a failed plan (--audio-keep 5 on a 1-track
#      source) is relayed — the false "no audio (or none kept)" banner never
#      prints over a refusal;
#   8. negative controls: with NO shim, a genuinely audio-free source still
#      plans "audio: none" and builds, and an audio-bearing source still
#      builds and verifies — fail-closed must not become fail-always.
#
# Standalone: bash tests/regression.d/80-empty-ne-absent-audio-plan.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }

REAL_FFPROBE="$(command -v ffprobe)"

echo "== fixtures: audio-bearing TS + audio-free TS =="
AUD="$WORK/aud.ts"; NOAUD="$WORK/noaud.ts"
ff -f lavfi -i testsrc2=s=320x240:r=25 -f lavfi -i sine=1000 -t 3 \
   -c:v libx264 -g 25 -pix_fmt yuv420p -c:a mp2 -f mpegts "$AUD" || { echo "mint failed"; exit 2; }
ff -f lavfi -i testsrc2=s=320x240:r=25 -t 2 -c:v libx264 -g 25 -pix_fmt yuv420p -f mpegts "$NOAUD"

# the checkup-appendix shim: fail ONLY the audio-manifest query shape
mkdir "$WORK/shim1"
cat > "$WORK/shim1/ffprobe" <<EOF
#!/bin/bash
case "\$*" in *"stream=index,codec_name,channels"*) exit 1;; esac
exec "$REAL_FFPROBE" "\$@"
EOF
chmod +x "$WORK/shim1/ffprobe"
# the audio-CENSUS shim (rebuild-paff / verify gates f+g query shape)
mkdir "$WORK/shim2"
cat > "$WORK/shim2/ffprobe" <<EOF
#!/bin/bash
case "\$*" in *"-select_streams a -show_entries stream=index -of csv=p=0"*) exit 1;; esac
exec "$REAL_FFPROBE" "\$@"
EOF
chmod +x "$WORK/shim2/ffprobe"

echo
echo "== 1. remux.sh: manifest-probe failure refuses (exit 2), nothing written =="
o=$(PATH="$WORK/shim1:$PATH" bash "$SC/remux.sh" "$AUD" "$WORK/r1.mov" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "remux refuses exit 2 on a failed manifest probe" \
  || no "remux rc=$rc (pre-fix: built video-only, exit 0)"
has "$o" "audio-manifest probe FAILED" "the refusal names the failed probe"
hasnt "$o" "audio: none" "a failed probe never reads as 'no audio'"
{ [ ! -f "$WORK/r1.mov" ] && [ ! -f "$WORK/r1.part.mov" ]; } \
  && ok "refusal writes nothing" || no "refusal left an output"

echo
echo "== 2. probe.sh --kv: no fabricated zero on a failed producer =="
o=$(PATH="$WORK/shim1:$PATH" bash "$SC/probe.sh" "$AUD" --kv 2>&1); rc=$?
hasnt "$o" "PR_AUD_COUNT=0" "no fabricated PR_AUD_COUNT=0 (the disabled-Dolby-E-loop class)"
has "$o" "PR_AUD_MANIFEST=failed" "the additive failure sentinel is emitted"
[ "$rc" -ne 0 ] && ok "probe.sh --kv exits nonzero (rc=$rc)" || no "probe.sh --kv exited 0 over a failed manifest"

echo
echo "== 3. mov.sh end-to-end (the A1 repro): refuse, never a silent audio-strip =="
o=$(PATH="$WORK/shim1:$PATH" bash "$SC/mov.sh" "$AUD" "$WORK/m1.mov" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "mov.sh refuses exit 2 (pre-fix: '>> DONE … verified lossless', rc=0, 0 audio streams)" \
  || no "mov.sh rc=$rc (want 2)"
hasnt "$o" ">> DONE" "no DONE over a failed probe"
hasnt "$o" "no audio (or none kept)" "the failed probe never reads as 'no audio'"
[ ! -f "$WORK/m1.mov" ] && ok "no artifact shipped" || no "an artifact shipped on a failed probe"

echo
echo "== 4. auto.sh: the same refusal at its eval site =="
o=$(PATH="$WORK/shim1:$PATH" bash "$SC/auto.sh" "$AUD" "$WORK/a1.mov" 2>&1); rc=$?
{ [ "$rc" -eq 2 ] && [ ! -f "$WORK/a1.mov" ]; } && ok "auto.sh refuses exit 2, nothing written" \
  || no "auto.sh rc=$rc (want 2, no output)"
has "$o" "REFUSED (pre-flight)" "auto names the pre-flight refusal"

echo
echo "== 5. rebuild-paff.sh: census failure refuses, never a video-only rebuild =="
BF0="$WORK/bf0.ts"
ff -f lavfi -i testsrc2=s=160x120:r=25 -f lavfi -i sine=600 -t 2 \
   -map 0:v -map 1:a -c:v libx264 -g 25 -bf 0 -c:a mp2 -pix_fmt yuv420p -f mpegts "$BF0"
o=$(PATH="$WORK/shim2:$PATH" bash "$SC/rebuild-paff.sh" "$BF0" "$WORK/rb.mov" 30000/1001 30000 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "rebuild-paff refuses exit 2 on a failed census" \
  || no "rebuild-paff rc=$rc (pre-fix: 'rebuilding video only')"
hasnt "$o" "no audio streams found" "a failed census never reads as 'no audio streams'"
[ ! -f "$WORK/rb.mov" ] && ok "no OUTPUT written" || no "rebuild shipped on a failed census"

echo
echo "== 6. verify.sh gates (f)/(g): failed census -> UNPROVEN + REVIEW, never N/A+OK =="
CP="$WORK/cp.mov"
bash "$SC/remux.sh" "$AUD" "$CP" >/dev/null 2>&1 || { echo "control build failed"; exit 1; }
o=$(PATH="$WORK/shim2:$PATH" bash "$SC/verify.sh" "$AUD" "$CP" 2>&1); rc=$?
has "$o" "sync parity UNPROVEN" "gate (f): failed census is UNPROVEN, not N/A"
has "$o" "audio playability UNPROVEN" "gate (g): failed census is UNPROVEN, not N/A"
hasnt "$o" "gate N/A" "no gate silently reads N/A off a failed probe"
has "$o" ">> REVIEW" "the verdict is REVIEW (UNPROVEN never OK, never FAIL)"
hasnt "$o" ">> OK" "no green verdict with the audio gates disarmed"

echo
echo "== 7. mov.sh PLANOUT guard: a failed plan is relayed, never read as 'no audio' =="
o=$(bash "$SC/mov.sh" "$AUD" "$WORK/k5.mov" --audio-keep 5 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "bad keep-index propagates the plan's exit 2" || no "rc=$rc (want 2)"
has "$o" "no audio track a:5" "the plan's own refusal reaches the operator"
hasnt "$o" "no audio (or none kept)" "the false 'no audio' banner never prints over a failed plan"

echo
echo "== 8. negative controls: fail-closed did not become fail-always =="
o=$(bash "$SC/remux.sh" "$NOAUD" "$WORK/na.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK/na.mov" ]; } && ok "audio-free source still builds (exit 0)" \
  || no "audio-free source broken (rc=$rc)"
has "$o" "audio: none" "a SUCCESSFUL empty probe still reads 'audio: none'"
o=$(bash "$SC/mov.sh" "$AUD" "$WORK/ok.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK/ok.mov" ]; } && ok "audio-bearing source still builds + verifies via mov.sh" \
  || no "unshimmed mov.sh broken (rc=$rc)"
naud=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$WORK/ok.mov" 2>/dev/null | grep -c . || true)
[ "${naud:-0}" -ge 1 ] && ok "the audio actually shipped ($naud track(s))" || no "control output lost its audio"

echo
echo "empty-ne-absent-audio-plan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
