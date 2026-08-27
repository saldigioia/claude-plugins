#!/usr/bin/env bash
# 82-c6-d4-start-pts.sh — CHECKUP-2026-08-27 C6 / WO-1.15.4: verify.sh's
# spo() must read ffprobe's fields BY KEY, and the re-armed D4 branch must
# recognize the field-report signature (2026-08-15) it was built for.
#
# The defect: ffprobe emits stream fields in ITS canonical order regardless of
# the request order (measured on this bench: line 1 = time_base, line 2 =
# start_pts), so the nk=1 form read them SWAPPED, split() got an empty
# denominator, and spo() printed 0 unconditionally — the D4 "delta == declared
# start_pts, content aligned" branch was DEAD CODE, the benign signature
# re-reported as REVIEW, and the report printed a FALSE measurement
# ("declared start_pts a:0=0") inviting the exact "fix" the D4 comment warns
# against. Deferred from the one-liner round BECAUSE it re-arms untested
# verdict logic — so it lands here WITH this fixture:
#
#   a:0 = PCM access, first 91200 samples, declared start_pts 4800
#         (-itsoffset 0.1 at 48 kHz — measured this session);
#   a:1 = bit-exact copy of the source's full 96000-sample track.
#   Decode delta = 4800 samples == the declared start_pts DELTA: the
#   field-report shape (there: 1040 samples), byte-for-byte mechanics.
#
# Pins: 1. the TRUE declared start_pts is printed (was 0); 2. the D4 arm
# fires ("ALIGNED at offset 0 … not drift") and the file reads >> OK;
# 3. NEGATIVE control — an offset that does NOT equal the delta must still
# read "NOT explained" REVIEW (the re-armed branch must not always-pass).
#
# Standalone: bash tests/regression.d/82-c6-d4-start-pts.sh
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

echo "== fixture: dual-track MOV, length delta == declared start_pts (4800 @ 48 kHz) =="
SRCM="$WORK/src.mov"
ff -f lavfi -i testsrc2=s=320x240:r=25 -f lavfi -i sine=440:r=48000 -t 2 \
   -c:v libx264 -g 25 -pix_fmt yuv420p -c:a pcm_s16le "$SRCM" || { echo "mint failed"; exit 2; }
ff -i "$SRCM" -map 0:a:0 -af atrim=end_sample=91200 -c:a pcm_s16le "$WORK/short.wav"
OUTM="$WORK/out.mov"
ff -i "$SRCM" -itsoffset 0.1 -i "$WORK/short.wav" -map 0:v:0 -map 1:a:0 -map 0:a:0 \
   -c:v copy -c:a:0 pcm_s16le -c:a:1 copy "$OUTM"
sp0=$(ffprobe -v error -select_streams a:0 -show_entries stream=start_pts -of default=nw=1 "$OUTM" 2>/dev/null | sed -n 's/^start_pts=//p')
[ "$sp0" = 4800 ] || { echo "  (fixture self-check failed: a:0 start_pts=$sp0, want 4800 — bench mints differently; not asserting further)"; exit 2; }
ok "fixture self-check: a:0 declares start_pts=4800"

echo
echo "== 1+2. the true start_pts is measured and the D4 arm fires -> OK =="
o=$(bash "$SC/verify.sh" "$SRCM" "$OUTM" --audio 2>&1); rc=$?
has "$o" "declared start_pts a:0=4800" "spo() reads the TRUE declared start_pts (pre-fix printed 0)"
hasnt "$o" "declared start_pts a:0=0 a:1=0" "the false 0/0 measurement is gone"
has "$o" "ALIGNED at offset 0:" "the D4 field-signature arm fires (was dead code)"
has "$o" "= the declared start_pts DELTA" "the delta is EXPLAINED by the declared offset"
hasnt "$o" "NOT explained" "the benign signature no longer reads unexplained"
{ [ "$rc" -eq 0 ] && case "$o" in *">> OK"*) true;; *) false;; esac; } \
  && ok "verdict >> OK exit 0 (pre-fix: REVIEW on a false measurement)" \
  || no "verdict wrong (rc=$rc)"

echo
echo "== 3. NEGATIVE control: offset != delta must STILL read 'NOT explained' REVIEW =="
OUTB="$WORK/outbad.mov"
ff -i "$SRCM" -itsoffset 0.06 -i "$WORK/short.wav" -map 0:v:0 -map 1:a:0 -map 0:a:0 \
   -c:v copy -c:a:0 pcm_s16le -c:a:1 copy "$OUTB"
o=$(bash "$SC/verify.sh" "$SRCM" "$OUTB" --audio 2>&1); rc=$?
has "$o" "NOT explained" "a 2880-sample offset does not explain a 4800-sample delta"
has "$o" ">> REVIEW" "unexplained delta stays REVIEW (the re-armed branch is not always-pass)"
hasnt "$o" "= the declared start_pts DELTA" "no false explanation minted"

echo
echo "c6-d4-start-pts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
