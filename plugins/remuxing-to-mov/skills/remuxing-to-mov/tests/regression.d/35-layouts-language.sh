#!/usr/bin/env bash
# 35-layouts-language.sh — work-order 3.5: `layouts` curates on layout+LANGUAGE.
#
# The pre-3.5 defect: even as a policy the operator chose, `layouts` keyed its
# best[] table on channel layout ALONE — same-layout different-language tracks
# were "duplicates", so a Spanish lossless track would evict an English lossy
# one (and on multilang.ts the spa stereo silently lost to the eng stereo on
# the tie-break). 3.4 made the language data real (the TS view merge); 3.5
# makes the curation key layout+language: same layout in another language is
# a distinct deliverable, both kept. Same layout + same language still curates
# by codec rank (lossless > lossy-high > lossy-low, earlier track wins ties),
# and two und-language tracks with the same layout share a key on purpose —
# und carries no evidence of distinct deliverables (regression.sh section 21
# pins that all-und shape; the choice is documented in remux.sh's PLAN awk).
#
# Asserted:
#   1. multilang.ts (AC-3 eng-2.0 / spa-2.0 / eng-5.1), --audio-keep layouts:
#      ALL THREE tracks keep — the spa stereo is a distinct deliverable, no
#      track drops, and every rule line names its layout+language key.
#   2. dupe_lang.ts (MP2-eng + AC-3-eng, both stereo): exactly ONE keeps, and
#      it is a:1 AC-3 — rank beat order (a first-wins regression keeps a:0);
#      the eviction is a WARN DROP naming both codecs' ranks (house rule 5),
#      and the dropped machine row carries its merged language (the TS
#      double-listing merge holds on dropped rows too).
#   3. real muxes match the plans: multilang -> 3 audio tracks, eng/spa/eng,
#      2/2/6ch; dupe_lang -> exactly 1 track, eng, PCM access (AC-3 under
#      auto, TN2429).
#
# Standalone: bash tests/regression.d/35-layouts-language.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
# Regenerates its fixtures via make-fixtures.sh when missing. Scratch goes to
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
alangs () { ffprobe -v error -select_streams a -show_entries stream_tags=language -of default=nw=1:nk=1 "$1" 2>/dev/null | grep . | paste -sd, -; }
achs () { ffprobe -v error -select_streams a -show_entries stream=channels -of csv=p=0 "$1" 2>/dev/null | paste -sd, -; }
acods () { ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$1" 2>/dev/null | paste -sd, -; }

# fixtures: regenerate when missing (media never ships in git)
for f in multilang.ts dupe_lang.ts; do
  if [ ! -f "$FIX/$f" ]; then
    echo "== regenerating missing fixture: $f =="
    bash "$TESTS/make-fixtures.sh" "$f" || { echo "fixture build failed"; exit 2; }
  fi
  [ -f "$FIX/$f" ] || { echo "$f still missing after make-fixtures"; exit 2; }
done
ML="$FIX/multilang.ts"; DL="$FIX/dupe_lang.ts"

echo "== 1. multilang: same layout, different language = distinct deliverables =="
p=$(bash "$SC/remux.sh" "$ML" "$WORK/ml.mov" --audio-keep layouts --print-plan 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "layouts --print-plan exits 0" || { no "layouts --print-plan rc=$rc"; printf '%s\n' "$p" | tail -4 | sed 's/^/   /'; }
has "$p" "RMX_PLAN policy=layouts kept=0,1,2 dropped=none" "all three tracks keep (pre-3.5: spa stereo evicted)"
# the rule text names the layout+language key on every decision (WO 3.5)
has "$p" "KEEP a:0 ac3 2ch stereo eng — distinct layout+language stereo/eng" "a:0 rule names stereo/eng"
has "$p" "KEEP a:1 ac3 2ch stereo spa — distinct layout+language stereo/spa" "a:1 rule names stereo/spa (the pre-3.5 victim)"
has "$p" "KEEP a:2 ac3 6ch 5.1(side) eng — distinct layout+language 5.1(side)/eng" "a:2 rule names 5.1(side)/eng"
drops=$(printf '%s\n' "$p" | grep -c "WARN DROP" || true)
[ "$drops" -eq 0 ] && ok "no WARN DROP line (nothing is a duplicate here)" || no "$drops WARN DROP line(s) on a no-duplicate source"
[ ! -f "$WORK/ml.mov" ] && ok "--print-plan writes nothing" || no "--print-plan wrote an output"

echo
echo "== 2. dupe_lang: same layout + same language still curates, by rank =="
p=$(bash "$SC/remux.sh" "$DL" "$WORK/dl.mov" --audio-keep layouts --print-plan 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "layouts --print-plan exits 0" || { no "layouts --print-plan rc=$rc"; printf '%s\n' "$p" | tail -4 | sed 's/^/   /'; }
# the winner is a:1 — rank (lossy-high > lossy-low) beat track order
has "$p" "RMX_PLAN policy=layouts kept=1 dropped=0" "exactly one keeps and it is a:1 (rank beat order)"
has "$p" "KEEP a:1 ac3 2ch stereo eng — best of layout+language stereo/eng (lossy-high)" "the AC-3 wins its key on rank"
# the eviction is announced with both ranks (house rule 5: every DROP a WARN)
has "$p" "** WARN DROP a:0 mp2 2ch stereo eng — duplicate layout+language stereo/eng: mp2 (lossy-low) loses to a:1 ac3 (lossy-high)" "the drop names the key, both codecs and both ranks"
# dropped rows merge like kept ones (3.4's TS double-listing merge holds here)
has "$p" "RMX_T ord=0 keep=0 codec=mp2 ch=2 layout=stereo lang=eng" "dropped machine row carries its merged language"

echo
echo "== 3. real muxes match the plans =="
out=$(bash "$SC/remux.sh" "$ML" "$WORK/ml3.mov" --audio-keep layouts 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "multilang mux exits 0" || { no "multilang mux rc=$rc"; printf '%s\n' "$out" | tail -4 | sed 's/^/   /'; }
[ "$(alangs "$WORK/ml3.mov")" = "eng,spa,eng" ] && ok "3 tracks survive with languages (eng,spa,eng)" || no "MOV languages: $(alangs "$WORK/ml3.mov"), want eng,spa,eng"
[ "$(achs "$WORK/ml3.mov")" = "2,2,6" ] && ok "channel counts preserved (2,2,6)" || no "MOV channels: $(achs "$WORK/ml3.mov"), want 2,2,6"
out=$(bash "$SC/remux.sh" "$DL" "$WORK/dl1.mov" --audio-keep layouts 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "dupe_lang mux exits 0" || { no "dupe_lang mux rc=$rc"; printf '%s\n' "$out" | tail -4 | sed 's/^/   /'; }
has "$out" "** WARN DROP a:0 mp2" "the drop is announced on the real mux too"
[ "$(acods "$WORK/dl1.mov")" = pcm_s16le ] && ok "exactly one track, PCM access (AC-3 under auto, TN2429)" || no "dupe_lang output shape: $(acods "$WORK/dl1.mov"), want pcm_s16le"
[ "$(alangs "$WORK/dl1.mov")" = eng ] && ok "the survivor keeps its language (eng)" || no "dupe_lang MOV language: $(alangs "$WORK/dl1.mov"), want eng"

{ [ -f "$ML" ] && [ -f "$DL" ]; } && ok "sources untouched" || no "a source vanished"

echo
echo "layouts-language: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
