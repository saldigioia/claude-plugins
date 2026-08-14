#!/usr/bin/env bash
# 22-trim-to-idr.sh — work-order 2.2: the mid-GOP pre-roll trim the plugin
# always PRESCRIBED (ts-health.sh: "lossless trim at the first IDR") is now
# PERFORMED by a bundled script, and mov.sh runs it automatically — announced,
# never silent.
#
# The defect this pins: on a mid-GOP capture (late-sps.ts — 102 video packets
# before the first IDR), the pre-1.11 build was NOT even a faithful copy of the
# head: ffmpeg streamcopy silently drops initial non-keyframe VIDEO packets
# (-copyinkf default) while every AUDIO pre-roll packet lands, so the built MOV
# failed verify's A/V duration parity as a phantom "gap-collapse desync"
# (REVIEW at ~4.25 s mismatch) — and the only sanctioned fix was a trim no
# bundled script could perform (the hole that forced manual ffmpeg on the BBC
# file). trim-to-idr.sh closes the diagnose -> validate -> APPLY gap.
#
# Asserted here, on the late-sps.ts fixture:
#   1. standalone trim: exit 0, TTI_SUMMARY row, output exists (no .part
#      litter), ts-health's own counter reads 0 pre-keyframe packets, and the
#      trimmed video decodes with ZERO errors (the pre-roll was the garbage);
#   2. LOSSLESS on the kept region (Ground Rule 2): video packet count ==
#      source minus pre-roll, and per-packet size+CRC (framecrc) of the output
#      equals the source's kept tail — byte-identical, no re-encode;
#   3. no-op honesty: trimming an already-IDR-first file writes NOTHING, exit 0;
#   4. guards: same-path refusal + missing input -> exit 2 (usage);
#   5. mov.sh auto path: the announce line (with the --no-idr-trim escape
#      hatch) appears, the build reaches an honest DONE (the phantom REVIEW is
#      gone), MOV_SUMMARY carries idr_trim=<n>, and the temp intermediate is
#      deleted after the verified DONE;
#   6. --no-idr-trim restores the old behavior — announced (pre-roll KEPT
#      line), no trim temp ever created, and the honest old outcome (REVIEW on
#      A/V parity, idr_trim=skipped) — the flag must not be a silent no-op.
#
# Standalone: bash tests/regression.d/22-trim-to-idr.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env/fixture failure.
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

# fixture: regenerate when missing (media never ships in git)
if [ ! -f "$FIX/late-sps.ts" ]; then
  echo "== regenerating missing fixture: late-sps.ts =="
  bash "$TESTS/make-fixtures.sh" late-sps.ts || { echo "fixture build failed"; exit 2; }
fi
SRC="$FIX/late-sps.ts"
# the fixture needs the raised probe window by design (SPS ~8 MB in)
PROBE="-probesize 200M -analyzeduration 200M"

echo "== 1. standalone: trim-to-idr.sh cuts the pre-roll, gated + machine-readable =="
out=$(bash "$SC/trim-to-idr.sh" "$SRC" "$WORK/trim.ts" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "trim exits 0" || { no "trim rc=$rc, want 0"; printf '%s\n' "$out" | tail -5 | sed 's/^/   /'; }
has "$out" "TTI_SUMMARY prekey=" "TTI_SUMMARY machine row emitted"
prekey=$(printf '%s\n' "$out" | sed -n 's/^TTI_SUMMARY prekey=\([0-9]*\).*/\1/p' | head -1)
[ "${prekey:-0}" -gt 0 ] && ok "fixture had pre-roll to trim (prekey=$prekey)" || no "prekey not >0 ($prekey) — fixture no longer mid-GOP?"
[ -s "$WORK/trim.ts" ] && ok "output written" || no "no output written"
litter=$(ls "$WORK" | grep -c '\.part' || true)
[ "${litter:-0}" -eq 0 ] && ok "no .part litter after the blessed trim" || no "a .part survived success"
kv=$(bash "$SC/ts-health.sh" "$WORK/trim.ts" --kv 2>/dev/null)
has "$kv" "TSH_PREKEY=0" "ts-health's own counter reads 0 pre-keyframe packets in the output"
errs=$(ffmpeg -nostdin -v error -i "$WORK/trim.ts" -map 0:v:0 -f null - 2>&1 | grep -c . || true)
[ "${errs:-1}" -eq 0 ] && ok "trimmed video decodes with 0 errors (pre-roll was the garbage)" \
  || no "trimmed output still throws $errs decode error lines"

echo
echo "== 2. kept region is byte-identical to the source (stream copy, Ground Rule 2) =="
# shellcheck disable=SC2086  # PROBE is deliberate word-split input options
srcn=$(ffprobe $PROBE -v error -select_streams v:0 -show_entries packet=flags -of csv=p=0 "$SRC" 2>/dev/null | grep -c .)
outn=$(ffprobe -v error -select_streams v:0 -show_entries packet=flags -of csv=p=0 "$WORK/trim.ts" 2>/dev/null | grep -c .)
[ "$outn" -eq $((srcn - prekey)) ] && ok "video packet parity: out $outn == src $srcn - pre-roll $prekey" \
  || no "packet parity broken: out=$outn src=$srcn prekey=$prekey"
# per-packet size+CRC over the kept tail — timestamps differ (rebased), bytes must not
vtail () { grep -v '^#' | awk -F', *' '{print $5", "$6}'; }
# shellcheck disable=SC2086
a=$(ffmpeg -nostdin -v error $PROBE -i "$SRC" -map 0:v:0 -c copy -f framecrc - 2>/dev/null | vtail | tail -"$outn" | cksum)
b=$(ffmpeg -nostdin -v error -i "$WORK/trim.ts" -map 0:v:0 -c copy -f framecrc - 2>/dev/null | vtail | cksum)
[ -n "$a" ] && [ "$a" = "$b" ] && ok "framecrc per-packet size+CRC identical over the kept region" \
  || no "kept region not byte-identical (src-tail=$a out=$b)"

echo
echo "== 3. no-op honesty: an IDR-first file is not 're-trimmed' =="
out=$(bash "$SC/trim-to-idr.sh" "$WORK/trim.ts" "$WORK/noop.ts" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "nothing-to-trim exits 0" || no "nothing-to-trim rc=$rc"
has "$out" "nothing to trim" "says so explicitly"
has "$out" "TTI_SUMMARY prekey=0" "machine row reports prekey=0"
[ ! -f "$WORK/noop.ts" ] && ok "writes nothing (no pointless full copy)" || no "no-op wrote an output"

echo
echo "== 4. guards: same-path + missing input refuse with usage code =="
bash "$SC/trim-to-idr.sh" "$WORK/trim.ts" "$WORK/trim.ts" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "same-path refusal -> 2" || no "same-path rc=$rc, want 2"
bash "$SC/trim-to-idr.sh" "$WORK/nope.ts" "$WORK/x.ts" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "missing input -> 2" || no "missing input rc=$rc, want 2"

echo
echo "== 5. mov.sh auto path: announced trim, honest DONE, temp deleted =="
out=$(bash "$SC/mov.sh" "$SRC" "$WORK/auto.mov" 2>&1); rc=$?
has "$out" "mid-GOP start: trimming pre-roll to first IDR ($prekey pre-keyframe packets)" "announce line (with the count)"
has "$out" "no-idr-trim to skip" "announce line names the escape hatch"
{ [ "$rc" -eq 0 ] && case "$out" in *">> DONE"*) true;; *) false;; esac; } \
  && ok "auto-trimmed build reaches DONE (the phantom parity REVIEW is gone)" \
  || { no "auto path rc=$rc (want 0 + DONE)"; printf '%s\n' "$out" | tail -6 | sed 's/^/   /'; }
has "$out" "idr_trim=$prekey" "MOV_SUMMARY carries idr_trim=$prekey"
tmps=$(ls "$WORK" | grep -c 'idrtrim' || true)
[ "${tmps:-0}" -eq 0 ] && ok "trimmed intermediate deleted after the verified DONE" \
  || no "temp intermediate littered: $(ls "$WORK" | grep idrtrim | paste -sd, -)"
outv=$(ffprobe -v error -select_streams v:0 -show_entries packet=flags -of csv=p=0 "$WORK/auto.mov" 2>/dev/null | grep -c .)
[ "$outv" -eq "$outn" ] && ok "final MOV carries exactly the kept region ($outv video packets)" \
  || no "final MOV packet count $outv != trimmed $outn"

echo
echo "== 6. --no-idr-trim restores the old behavior — announced, never silent =="
out=$(bash "$SC/mov.sh" "$SRC" "$WORK/old.mov" --no-idr-trim 2>&1); rc=$?
hasnt "$out" "trimming pre-roll to first IDR" "no trim performed"
has "$out" "KEPT (--no-idr-trim)" "the keep decision is announced (no silent mapping decisions)"
has "$out" "idr_trim=skipped" "MOV_SUMMARY records the skip"
# the old outcome, preserved honestly: streamcopy drops the video pre-roll
# silently, audio keeps its full span -> A/V parity REVIEW (measured 4.25 s)
{ [ "$rc" -eq 10 ] && case "$out" in *">> REVIEW"*) true;; *) false;; esac; } \
  && ok "old behavior intact: REVIEW on A/V duration parity (rc=10)" \
  || no "old-behavior outcome changed (rc=$rc) — flag no longer reproduces pre-1.11"
tmps=$(ls "$WORK" | grep -c 'idrtrim' || true)
[ "${tmps:-0}" -eq 0 ] && ok "no trim temp created under --no-idr-trim" || no "flagged run still created a temp"

echo
echo "trim-to-idr: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
