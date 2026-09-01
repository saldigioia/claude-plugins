#!/usr/bin/env bash
# 121-hvcc-stub-and-headers.sh — 1.19.0 (REMUX-PIPELINE retrace 2026-09-01):
# the PS-less hvcC stub class, the decoder-config census, the container-aware
# confession note, and dim-scan --headers.
#
# THE FIELD CASE. An MKV whose CodecPrivate was a 23-byte hvcC stub with
# numOfArrays=0 (VPS/SPS/PPS in-band, length-prefixed) muxed under the
# hardcoded -tag:v hvc1 into a .mov with an EMPTY 8-byte hvcC — mux exit 0,
# bits perfect, file undecodable (585,358 decode errors). The error that DID
# surface was an unrelated DTS confession on a container that stores no DTS,
# and the session spent ~48 min, ~16 of them in a dim-scan full decode whose
# question a demux-only SPS census answers.
#
# Four teeth pinned here: (1) rtm_hevc_ps_stub detects the stub and the
# builders reroute through the inline hevc_mp4toannexb bsf — SAME mux, so the
# PTS column is untouched (the restamping that condemned the raw-elementary
# route came from the intermediate FILE, not the Annex-B conversion; measured
# max |delta| 0.000000); (2) mux_census refuses to bless a QTFF part whose
# h264/hevc extradata is missing (dcfg=empty, exit 1, part kept); (3) the
# DTS hard stop on Matroska sources names the reconstructed-DTS caveat;
# (4) dim-scan --headers proves static dimensions demux-only (~20x cheaper),
# and stays honest about its scope (>1 distinct PS routes to decode mode).
#
# Hooks: RTM_TEST_EXTRADATA_HEX (stub verdict), RTM_TEST_DCFG_BYTES (census
# byte count), RTM_MUX_LOG_APPEND (confession injection) — knobs.md.
#
# Standalone: bash tests/regression.d/121-hvcc-stub-and-headers.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [present: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -y -v error "$@"; }

# the exact 23-byte stub from the field capture (numOfArrays = byte 22 = 00)
STUBHEX="0101600000000000b00000007bf000fcfdf8f800004f00"

echo "== 0. fixtures =="
HEVC=1
# grep -c, never grep -q: -q's early close SIGPIPEs ffmpeg under pipefail and
# the condition silently reads false (the D1 class, measured on THIS test's
# first run 2026-09-01 — every HEVC lane skipped on a bench that has libx265)
x265n=$(ffmpeg -hide_banner -encoders 2>/dev/null | grep -c libx265 || true)
if [ "${x265n:-0}" -gt 0 ]; then
  ff -f lavfi -i testsrc2=s=320x240:r=25 -t 3 -c:v libx265 -x265-params log-level=none -f mpegts "$WORK/h.ts" 2>/dev/null \
    && ff -i "$WORK/h.ts" -c copy "$WORK/h.mkv" || HEVC=0
else HEVC=0; fi
[ "$HEVC" -eq 1 ] || echo "  SKIP: no libx265 — HEVC lanes announced-skipped, h264 lanes still run"
ff -f lavfi -i testsrc2=s=320x240:r=25 -t 2 -c:v libx264 -g 25 -pix_fmt yuv420p -f mpegts "$WORK/a.ts"
ff -f lavfi -i testsrc2=s=640x480:r=25 -t 2 -c:v libx264 -g 25 -pix_fmt yuv420p -f mpegts "$WORK/b.ts"
cat "$WORK/a.ts" "$WORK/b.ts" > "$WORK/splice.ts"

echo
echo "== 1. the stub detector is a byte-precise predicate =="
det () { RTM_TEST_EXTRADATA_HEX="$1" bash -c ". '$SC/lib-probe.sh' 2>/dev/null; . '$SC/lib-mux.sh'; rtm_hevc_ps_stub /dev/null"; }
det "$STUBHEX" && ok "the field capture's exact stub hex -> DETECTED" || no "stub hex not detected"
det "0301600000000000b00000007bf000fcfdf8f800004f00" && no "wrong configurationVersion detected as stub" || ok "non-hvcC first byte -> not a stub"
det "0101" && no "truncated extradata detected as stub" || ok "truncated extradata -> not a stub"
if [ "$HEVC" -eq 1 ]; then
  fullhex=$(bash -c ". '$SC/lib-probe.sh' 2>/dev/null; . '$SC/lib-mux.sh'; rtm_extradata_hex '$WORK/h.mkv'")
  [ -n "$fullhex" ] && ok "rtm_extradata_hex reads a real hvcC ($((${#fullhex}/2)) bytes)" || no "extradata hex read empty"
  det "$fullhex" && no "a FULL hvcC detected as stub" || ok "a full hvcC (numOfArrays>0) -> not a stub"
fi

echo
echo "== 2. the reroute: announced, built, decodable, PTS column untouched =="
if [ "$HEVC" -eq 1 ]; then
  o=$(RTM_TEST_EXTRADATA_HEX="$STUBHEX" bash "$SC/remux.sh" "$WORK/h.mkv" "$WORK/reroute.mov" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ -f "$WORK/reroute.mov" ] && ok "stub verdict -> build proceeds (rc=0)" || no "reroute build rc=$rc"
  has "$o" "RMX_HVCC route=annexb-bsf reason=ps-stub" "the reroute announces its machine line"
  has "$o" "hevc_mp4toannexb" "…and names the bsf"
  d=$(ffmpeg -nostdin -v error -i "$WORK/reroute.mov" -f null - 2>&1 | grep -c . || true)
  [ "${d:-1}" -eq 0 ] && ok "rerouted output decodes clean (0 error lines)" || no "rerouted output decode errors: $d"
  ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$WORK/h.mkv" > "$WORK/s.txt"
  ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$WORK/reroute.mov" > "$WORK/o.txt"
  md=$(paste "$WORK/s.txt" "$WORK/o.txt" | awk 'NR==1{s0=$1;o0=$2}{d=($2-o0)-($1-s0);if(d<0)d=-d;if(d>m)m=d}END{printf "%.6f", m+0}')
  awk -v m="$md" 'BEGIN{exit !((m+0)<=0.002)}' && ok "PTS column equal through the bsf (max |delta| ${md}s)" \
    || no "bsf route moved the PTS column (max |delta| ${md}s)"
  o=$(bash "$SC/remux.sh" "$WORK/h.mkv" "$WORK/plain.mov" 2>&1); rc=$?
  hasnt "$o" "RMX_HVCC" "a full-hvcC source never triggers the reroute"
  [ "$rc" -eq 0 ] && ok "plain HEVC MKV remux unchanged (rc=0)" || no "plain remux rc=$rc"
else
  echo "  SKIP: HEVC lanes (no libx265 on this bench)"
fi

echo
echo "== 3. decoder-config census: an empty avcC/hvcC is never blessed =="
o=$(RTM_TEST_DCFG_BYTES=0 bash "$SC/remux.sh" "$WORK/a.ts" "$WORK/dcfg.mov" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "dcfg=empty -> census FAIL exit 1" || no "dcfg-empty rc=$rc, want 1"
has "$o" "NO decoder configuration" "the census names the defect"
has "$o" "dcfg=empty" "RMX_CENSUS carries the additive dcfg field"
[ -f "$WORK/dcfg.mov" ] && no "empty-config build was blessed to OUT" || ok "nothing blessed to OUT"
ls "$WORK"/dcfg.part* >/dev/null 2>&1 && ok "the part is kept for the closer look" || no "no part kept"
o=$(bash "$SC/remux.sh" "$WORK/a.ts" "$WORK/good.mov" 2>&1); rc=$?
has "$o" "dcfg=ok" "a real h264 build reports dcfg=ok"
[ "$rc" -eq 0 ] && ok "…and blesses normally (rc=0)" || no "clean build rc=$rc"

echo
echo "== 4. the Matroska confession note points at the right subsystem =="
if [ "$HEVC" -eq 1 ]; then MKVSRC="$WORK/h.mkv"; else ff -i "$WORK/a.ts" -c copy "$WORK/a.mkv"; MKVSRC="$WORK/a.mkv"; fi
printf 'Non-monotonic DTS in output stream 0:0; previous: 100, current: 50\n' > "$WORK/conf.log"
o=$(RTM_MUX_LOG_APPEND="$WORK/conf.log" bash "$SC/remux.sh" "$MKVSRC" "$WORK/conf.mov" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "injected video confession -> HARD STOP (exit 1) unchanged" || no "confession rc=$rc, want 1"
has "$o" "MKV stores NO DTS" "the MKV note fires on a Matroska source"
has "$o" "verify.sh on the" "…and routes to verify-the-part first"
o=$(RTM_MUX_LOG_APPEND="$WORK/conf.log" bash "$SC/remux.sh" "$WORK/a.ts" "$WORK/conf2.mov" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "TS confession still hard-stops" || no "TS confession rc=$rc"
hasnt "$o" "MKV stores NO DTS" "…and the MKV note stays scoped to Matroska sources"

echo
echo "== 5. dim-scan --headers: demux-only, honest scope =="
o=$(bash "$SC/dim-scan.sh" "$WORK/a.ts" --headers 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "clean h264 -> CLEAN exit 0" || no "clean headers rc=$rc"
has "$o" "distinct_ps=1 verdict=clean" "machine line: one distinct SPS"
o=$(bash "$SC/dim-scan.sh" "$WORK/splice.ts" --headers 2>&1); rc=$?
[ "$rc" -eq 10 ] && ok "spliced resolutions -> FINDINGS exit 10" || no "splice headers rc=$rc"
has "$o" "verdict=findings" "machine line says findings"
has "$o" "decode mode" "…and routes confirmation to the decode mode (scope honesty)"
o=$(bash "$SC/dim-scan.sh" "$WORK/splice.ts" 2>&1); rc=$?
if [ "$rc" -eq 10 ]; then ok "decode mode agrees on the splice (exit 10)"
elif [ "$rc" -eq 1 ]; then echo "  SKIP: this ffmpeg's frame probe cannot read the concat fixture — agreement lane unproven here"
else no "decode mode rc=$rc on splice"; fi
if [ "$HEVC" -eq 1 ]; then
  o=$(bash "$SC/dim-scan.sh" "$WORK/h.mkv" --headers 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "HEVC MKV headers lane -> CLEAN" || no "hevc headers rc=$rc"
fi

echo
echo "hvcc-stub-and-headers: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
