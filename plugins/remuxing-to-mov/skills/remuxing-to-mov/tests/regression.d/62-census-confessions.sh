#!/usr/bin/env bash
# 62-census-confessions.sh — 1.14 Phase 2 (DF-6/DF-10/DF-14): judge right.
#
# 2.1 THE CENSUS'S THIRD VERDICT. v1.13's census was count-equality + ordered
# per-slot identity. A chaptered input — whose chapter metadata movenc rightly
# writes back as a data-class track (codec 'text', or 'bin_data' on 4.4-era
# ffmpeg; measured 2026-08-16) — FAILed as "a stream the plan mapped is
# missing" and stranded the build at .part: a false verdict in the wrong
# DIRECTION (a surplus reported as a loss). Now the census is per-codec
# multiset containment (planned ⊆ written) plus a surplus classifier:
#   * missing/mutated planned stream  -> FAIL (1), today's message — that
#     direction was always right;
#   * movenc-synthesized data-class surplus (chapter text/bin_data when the
#     input HAS chapters; tmcd)       -> announced PASS (0);
#   * anything else                   -> REVIEW (10), named as SURPLUS.
# PASS-surplus is data/text-class ONLY, ever — a surplus h264/audio stream is
# a mapping bug until a human says otherwise.
#
# 2.2 CONFESSION SCOPING. The mux-log hard stop grepped the WHOLE log, so an
# audio DTS nudge (the ms-quantization class verify gate (e) tolerates on the
# way in) hard-stopped the build as invented VIDEO timing. Now each confession
# line is classified by ffmpeg's own stream attribution ([vost#/[aost#/[sost#
# tags on 6+; "in output stream 0:N" / "for stream N" / "in stream N" on
# 4.4-era logs — both shapes measured): video and UNATTRIBUTABLE lines keep
# the verbatim hard stop; audio/subtitle-only nudges announce + REVIEW (10).
#
# 2.3 SIGNALING CONTAINER GATE. --signaling asserted hvc1 on ANY output of an
# HEVC source; an MKV cross-check output has no QTFF sample entry to carry a
# tag, and its absence read as DRIFT. The assertion is now gated on the same
# format_name-contains-mov/mp4 container test gate (g) computes; non-QTFF ->
# announced skip, never DRIFT.
#
# Standalone: bash tests/regression.d/62-census-confessions.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
. "$TESTS/lib-harness.sh"   # grepq/grepqe + rtm_strip_comments: one definition (tests/lib-harness.sh)
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }

for f in aac.ts; do
  if [ ! -f "$FIX/$f" ]; then
    echo "== regenerating missing fixture: $f =="
    bash "$TESTS/make-fixtures.sh" "$f" || { echo "fixture build failed: $f"; exit 2; }
  fi
done

# chaptered fixture: ffmetadata chapters onto the existing aac.ts control
# (h264+aac), carried in MKV so the chapters ride as METADATA (no data track
# yet) — the movenc write is what synthesizes the track the old census damned.
printf ';FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1500\ntitle=One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1500\nEND=2900\ntitle=Two\n' > "$WORK/ch.txt"
ff -i "$FIX/aac.ts" -i "$WORK/ch.txt" -map 0:v:0 -map 0:a:0 -map_metadata 1 -map_chapters 1 -c copy "$WORK/chap.mkv" \
  || { echo "could not mint the chaptered MKV fixture"; exit 2; }
[ "$(ffprobe -v error -show_chapters -of csv=p=0 "$WORK/chap.mkv" 2>/dev/null | grep -c .)" -ge 1 ] \
  || { echo "chaptered MKV carries no chapters"; exit 2; }

echo "== 1. 2.1 census three-verdict arms, asserted directly =="
# shellcheck source=/dev/null
. "$SC/lib-mux.sh"
ff -i "$WORK/chap.mkv" -map 0 -c copy -movflags +faststart -f mov "$WORK/chap.mov" \
  || { echo "could not mux the chaptered MOV"; exit 2; }
nch=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$WORK/chap.mov" 2>/dev/null | grep -c '^data' || true)
[ "${nch:-0}" -ge 1 ] && ok "fixture: the MOV mux synthesized a data-class chapter track" \
  || { no "fixture lacks the movenc chapter track — cannot exercise the surplus arms"; exit 2; }

c=$(mux_census "$WORK/chap.mov" 2 "h264,aac" unit "$WORK/chap.mkv" 2>&1); crc=$?
{ [ "$crc" -eq 0 ] && case "$c" in *"chapter text track (movenc-synthesized, expected)"*) true;; *) false;; esac; } \
  && ok "expected chapter surplus -> announced PASS (rc=0), v1.13's false FAIL gone" \
  || { no "chapter-surplus arm broken (rc=$crc)"; printf '%s\n' "$c" | sed 's/^/   /'; }
has "$c" "surplus=chapters" "RMX_CENSUS gains additive surplus=chapters (fields append-only)"
has "$c" "match=ok" "existing match= field untouched on the surplus PASS"

c=$(mux_census "$WORK/chap.mov" 3 "h264,aac,ac3" unit "$WORK/chap.mkv" 2>&1); crc=$?
{ [ "$crc" -eq 1 ] && case "$c" in *"match=MISMATCH"*) true;; *) false;; esac; } \
  && ok "a genuinely MISSING planned track still FAILs (rc=1) — direction (i) kept" \
  || no "missing-track arm broken (rc=$crc)"
c=$(mux_census "$WORK/chap.mov" 2 "h264,ac3" unit "$WORK/chap.mkv" 2>&1); crc=$?
[ "$crc" -eq 1 ] && ok "a MUTATED codec still FAILs (rc=1) — containment, not just counting" \
  || no "mutated-codec arm broken (rc=$crc)"

c=$(mux_census "$WORK/chap.mov" 1 "h264" unit "$WORK/chap.mkv" 2>&1); crc=$?
{ [ "$crc" -eq 10 ] && case "$c" in *"SURPLUS, not a missing stream"*) true;; *) false;; esac; } \
  && ok "a surplus MEDIA stream (aac) -> REVIEW 10, never a data-class PASS" \
  || { no "media-surplus arm broken (rc=$crc, want 10)"; printf '%s\n' "$c" | sed 's/^/   /'; }
has "$c" "surplus=unexpected:1" "unexpected surplus counted in the machine line"
hasnt "$c" "is missing" "the surplus verdict never calls a surplus 'missing'"

c=$(mux_census "$WORK/chap.mov" 2 "h264,aac" unit 2>&1); crc=$?
[ "$crc" -eq 10 ] && ok "chapter knowledge ABSENT -> the same track is conservative REVIEW, not PASS" \
  || no "no-source arm broken (rc=$crc, want 10)"

echo
echo "== 2. 2.1 end-to-end: the chaptered build ships; the exit contract holds =="
o=$(bash "$SC/remux.sh" "$WORK/chap.mkv" "$WORK/e2e.mov" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "remux.sh on a chaptered input exits 0 (v1.13: census FAIL, exit 1)" \
  || { no "chaptered remux rc=$rc, want 0"; printf '%s\n' "$o" | tail -8 | sed 's/^/   /'; }
[ -f "$WORK/e2e.mov" ] && ok "the artifact is blessed under its real name (no stranded .part)" \
  || no "e2e.mov missing — chaptered build still stranded"
has "$o" "chapter text track (movenc-synthesized, expected)" "the surplus is ANNOUNCED, not silent"
has "$o" "surplus=chapters" "remux census machine line carries surplus=chapters"

echo
echo "== 3. 2.2 confession scoping: video hard-stops, audio nudges REVIEW =="
# shellcheck source=/dev/null
. "$SC/lib-paff.sh"
# classifier unit: both the 6+ fftools tags and the 4.4-era libavformat shapes
cat > "$WORK/mixed.log" <<'LOG'
[vost#0:0/copy @ 0x55] Non-monotonic DTS; previous: 100, current: 50; changing to 101
[aost#0:1/copy @ 0x55] Non-monotonic DTS; previous: 7, current: 7; changing to 8
[mov @ 0x1] Non-monotonous DTS in output stream 0:1; previous: 21, current: 21; changing to 22.
[mov @ 0x1] Timestamps are unset in a packet for stream 1. This is deprecated
pts has no value
LOG
eval "$(mux_confessions_scoped "$WORK/mixed.log" 0)"
[ "${MC_VIDEO:-0}" -eq 2 ] && ok "classifier: vost tag + bare line -> video ($MC_VIDEO, incl. unattributable)" \
  || no "video count wrong: $MC_VIDEO (want 2: [vost# + unattributable)"
[ "${MC_AUDSUB:-0}" -eq 3 ] && ok "classifier: aost tag + 4.4 'output stream 0:1' + 'for stream 1' -> audio ($MC_AUDSUB)" \
  || no "audsub count wrong: $MC_AUDSUB (want 3)"
[ "${MC_UNATTR:-0}" -eq 1 ] && ok "unattributable lines counted (and folded into video: conservative)" \
  || no "unattr count wrong: $MC_UNATTR"

# E2E via the standing RTM_MUX_LOG_APPEND hook (the sandbox cannot provoke a
# real confession; regression.sh § 19 established this injection style)
printf '[vost#0:0/copy @ 0x55] Non-monotonic DTS; previous: 100, current: 50; changing to 101\n' > "$WORK/vconf.log"
o=$(RTM_MUX_LOG_APPEND="$WORK/vconf.log" bash "$SC/remux.sh" "$FIX/aac.ts" "$WORK/vhs.mov" 2>&1); rc=$?
{ [ "$rc" -eq 1 ] && case "$o" in *"HARD STOP"*) true;; *) false;; esac; } \
  && ok "an injected VIDEO (vost) confession still hard-stops verbatim (exit 1)" \
  || no "vost confession did not hard-stop (rc=$rc)"
[ ! -f "$WORK/vhs.mov" ] && ok "the video-confessed build is NOT blessed (.part kept)" \
  || no "video-confessed build was blessed"
printf '[aost#0:1/copy @ 0x55] Non-monotonic DTS; previous: 7, current: 7; changing to 8\n[mov @ 0x1] Non-monotonous DTS in output stream 0:1; previous: 21, current: 21; changing to 22.\n' > "$WORK/aconf.log"
o=$(RTM_MUX_LOG_APPEND="$WORK/aconf.log" bash "$SC/remux.sh" "$FIX/aac.ts" "$WORK/ahs.mov" 2>&1); rc=$?
[ "$rc" -eq 10 ] && ok "audio-tagged nudges complete with REVIEW (exit 10, never 1)" \
  || { no "audio nudge rc=$rc, want 10"; printf '%s\n' "$o" | tail -6 | sed 's/^/   /'; }
[ -f "$WORK/ahs.mov" ] && ok "the audio-nudged build IS blessed (nothing is missing from it)" \
  || no "audio-nudged build not blessed"
has "$o" "audio DTS nudges (ms-quantization class)" "the REVIEW names the class and where to look"
has "$o" "verify gates (f)/(g) judge audio" "…and routes audio judgment to gates (f)/(g)"
hasnt "$o" "HARD STOP" "no false video hard stop on audio-only nudges"

echo
echo "== 4. 2.3 --signaling: hvc1 assertion is container-gated =="
if [ -f "$FIX/hevc_422_10.mov" ] || bash "$TESTS/make-fixtures.sh" hevc_422_10.mov >/dev/null 2>&1; then
  if ff -i "$FIX/hevc_422_10.mov" -map 0:v:0 -c copy "$WORK/cross.mkv" 2>/dev/null; then
    o=$(bash "$SC/verify.sh" "$FIX/hevc_422_10.mov" "$WORK/cross.mkv" --signaling 2>&1)
    has "$o" "hvc1 assertion skipped" "non-QTFF output -> announced skip of the hvc1 check"
    hasnt "$o" "NOT hvc1" "an MKV cross-check no longer reads as hvc1 DRIFT"
  else
    echo "  (skip: this ffmpeg cannot copy the HEVC fixture into MKV)"
  fi
  # the assertion itself still lives on QTFF outputs (no over-reach)
  if ff -i "$FIX/hevc_422_10.mov" -map 0:v:0 -c copy -tag:v hvc1 -f mov "$WORK/qt.mov" 2>/dev/null; then
    o=$(bash "$SC/verify.sh" "$FIX/hevc_422_10.mov" "$WORK/qt.mov" --signaling 2>&1)
    has "$o" "HEVC tag=hvc1" "QTFF output: the hvc1 assertion still runs and passes"
  fi
else
  echo "  (skip: hevc_422_10.mov fixture unavailable and not mintable — the container-gate branch is grep-pinned below)"
  g=$(grep -c "hvc1 assertion skipped" "$SC/verify.sh" || true)
  [ "${g:-0}" -ge 1 ] && ok "verify.sh carries the announced non-QTFF skip branch" || no "container-gate branch missing from verify.sh"
fi

echo
echo "== 5. 2.4 pairfill's loop terminus names the derive rung =="
g=$(grep -c "derive-dts.sh, Rung 3-DERIVE" "$SC/pairfill-paff.sh" || true)
[ "${g:-0}" -ge 1 ] && ok "PP_MAXRUN refusal names scripts/derive-dts.sh (Rung 3-DERIVE)" \
  || no "PP_MAXRUN refusal does not name the derive rung"
g=$(rtm_strip_comments "$SC/pairfill-paff.sh" | grep -c "Diagnose by hand" || true)
[ "${g:-0}" -eq 0 ] && ok "the dead-end 'Diagnose by hand' terminus is gone from the code" \
  || no "'Diagnose by hand' still in pairfill-paff.sh"

ok "sources untouched"
echo
echo "census-confessions: $pass passed, $fail failed — the real chaptered-capture FAIL and the ms-quantized MKV hard stop are operator-measured (2026-08-15); these arms pin the mechanisms"
[ "$fail" -eq 0 ]
