#!/usr/bin/env bash
# 34-lang-dedupe.sh — work-order 3.4: the TS language dedupe MERGES, not drops.
#
# The pre-3.4 defect (measured): mpegts probing lists every stream TWICE — a
# bare top-level view first, then the in-program view, and only the program
# view carries the PMT tags (language!). remux.sh's PLAN awk deduped by stream
# index with keep-first (`if(idx in seen) next`), so the bare record won and
# EVERY track on multilang.ts reached the decision layer as lang=und despite
# eng/spa/eng in the source. Any language-aware policy built on that data
# starts broken. The fix merges the repeated views field-by-field — a known
# value beats the placeholder (und/unknown/empty/0), the earlier record wins
# when both know, and the record keeps its slot so track order and every
# order-derived tie-break (layout curation, a:N mapping) stay put.
#
# Asserted, on the multilang.ts fixture (AC-3 eng-2.0 / spa-2.0 / eng-5.1):
#   1. plan layer (--print-plan --audio-keep all): the RMX_T rows and the
#      human manifest lines read eng/spa/eng — and never a single lang=und.
#   2. non-language fields survive the merge intact (codec/channels/layout),
#      and dropped tracks merge like kept ones: under --audio-keep first the
#      a:1/a:2 WARN DROP rows carry their merged languages too. (This section
#      pinned the layouts tie-break until WO 3.5 keyed layouts on
#      layout+language — multilang's three tracks are now three distinct
#      deliverables there; that policy is pinned in 35-layouts-language.sh.)
#   3. a real mux carries the languages into the MOV (eng,spa,eng), and the
#      singleton-record path holds: a MOV lists each stream ONCE, and
#      --print-plan on that output still reads eng/spa/eng (no merge partner).
#
# Standalone: bash tests/regression.d/34-lang-dedupe.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
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

# fixture: regenerate when missing (media never ships in git)
if [ ! -f "$FIX/multilang.ts" ]; then
  echo "== regenerating missing fixture: multilang.ts =="
  bash "$TESTS/make-fixtures.sh" multilang.ts || { echo "fixture build failed"; exit 2; }
fi
[ -f "$FIX/multilang.ts" ] || { echo "multilang.ts still missing after make-fixtures"; exit 2; }
SRC="$FIX/multilang.ts"

echo "== 1. plan layer: merged languages, never und =="
p=$(bash "$SC/remux.sh" "$SRC" "$WORK/plan.mov" --audio-keep all --print-plan 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "--print-plan exits 0" || { no "--print-plan rc=$rc"; printf '%s\n' "$p" | tail -4 | sed 's/^/   /'; }
# the acceptance: the manifest lines print eng/spa/eng (source truth)
has "$p" "RMX_T ord=0 keep=1 codec=ac3 ch=2 layout=stereo lang=eng" "a:0 plan row lang=eng (pre-3.4: und)"
has "$p" "RMX_T ord=1 keep=1 codec=ac3 ch=2 layout=stereo lang=spa" "a:1 plan row lang=spa"
has "$p" "RMX_T ord=2 keep=1 codec=ac3 ch=6 layout=5.1(side) lang=eng" "a:2 plan row lang=eng"
has "$p" "KEEP a:1 ac3 2ch stereo spa" "human manifest line carries the language too"
und=$(printf '%s\n' "$p" | grep -c "lang=und" || true)
[ "$und" -eq 0 ] && ok "no plan row reads lang=und" || no "$und plan row(s) still read lang=und"
[ ! -f "$WORK/plan.mov" ] && ok "--print-plan writes nothing" || no "--print-plan wrote an output"

echo
echo "== 2. merge is field-by-field; dropped tracks merge like kept ones =="
# the RMX_T assertions above already pin codec/ch/layout per slot — here the
# dropped rows must carry their merged languages too. The drop is driven by
# the `first` policy (a:0 only) so the assertion is independent of layouts
# semantics: WO 3.5 keyed layouts on layout+language, and multilang's three
# tracks are all distinct deliverables under it (35-layouts-language.sh
# pins that; pre-3.5 this section used layouts and a:1 lost the tie-break)
p=$(bash "$SC/remux.sh" "$SRC" "$WORK/first.mov" --audio-keep first --print-plan 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "first --print-plan exits 0" || no "first --print-plan rc=$rc"
has "$p" "RMX_PLAN policy=first kept=0 dropped=1,2" "policy first keeps a:0 only (kept=0 dropped=1,2)"
has "$p" "** WARN DROP a:1 ac3 2ch stereo spa" "the WARN DROP row carries the merged language"
has "$p" "RMX_T ord=1 keep=0 codec=ac3 ch=2 layout=stereo lang=spa" "dropped track's machine row merged too"

echo
echo "== 3. languages survive the mux; singleton records hold =="
out=$(bash "$SC/remux.sh" "$SRC" "$WORK/all.mov" --audio-keep all 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "full mux exits 0" || { no "full mux rc=$rc"; printf '%s\n' "$out" | tail -4 | sed 's/^/   /'; }
langs=$(ffprobe -v error -select_streams a -show_entries stream_tags=language -of default=nw=1:nk=1 "$WORK/all.mov" 2>/dev/null | grep . | paste -sd, -)
[ "$langs" = "eng,spa,eng" ] && ok "languages survive into the MOV (eng,spa,eng)" || no "MOV languages: $langs, want eng,spa,eng"
# singleton path: MOV lists each stream ONCE — no merge partner, rows intact
p=$(bash "$SC/remux.sh" "$WORK/all.mov" "$WORK/again.mov" --audio-keep all --print-plan 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "singleton --print-plan exits 0" || no "singleton --print-plan rc=$rc"
rows=$(printf '%s\n' "$p" | grep -c "^RMX_T " || true)
[ "$rows" -eq 3 ] && ok "singleton records: 3 plan rows (none lost, none doubled)" || no "singleton plan rows: $rows, want 3"
for want in "ord=0 keep=1 codec=pcm_s16le ch=2" "ord=1 keep=1 codec=pcm_s16le ch=2" "ord=2 keep=1 codec=pcm_s16le ch=6"; do
  has "$p" "$want" "singleton row intact: $want"
done
und=$(printf '%s\n' "$p" | grep -c "lang=und" || true)
{ [ "$und" -eq 0 ] && case "$p" in *"lang=eng"*"lang=spa"*) true;; *) false;; esac; } \
  && ok "singleton rows keep eng/spa/eng" || no "singleton rows: und=$und (want 0 with eng+spa present)"

[ -f "$SRC" ] && ok "source untouched" || no "source vanished"

echo
echo "lang-dedupe: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
