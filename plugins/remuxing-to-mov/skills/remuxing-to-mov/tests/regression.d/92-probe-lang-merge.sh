#!/usr/bin/env bash
# 92-probe-lang-merge.sh — the WO 3.4 merge, applied to its unfixed sibling.
#
# The bug (found 2026-08-27 running the field battery on the 2022-08-28 VMA
# capture): a program-bearing TS emits every stream section TWICE — a bare
# top-level view and the in-program view — and only ONE of them carries the
# PMT tags, i.e. language. probe.sh's audio manifest deduped by index
# KEEP-FIRST (`if(idx in seen) next`), so it kept whichever view arrived
# first — the tag-less one — and reported PR_AUD_n_LANG=und for every track
# on a source whose tracks are all eng.
#
# This is WO 3.4 exactly. 3.4 diagnosed it ("the keep-first dedupe read every
# TS track as lang=und"), fixed it at remux.sh with a field-by-field MERGE,
# and pinned it in 34-lang-dedupe.sh — but only against remux.sh's PLAN. The
# sibling manifest in probe.sh was never converted, and no test asserted
# probe.sh's PR_AUD_*_LANG, so the machine API kept shipping und while the
# SAME RUN's human `-- audio --` section printed eng. Measured on the field
# source: remux.sh --print-plan said lang=eng x4, probe.sh --kv said und x4.
#
# Blast radius, swept before writing this: PR_AUD_*_LANG has no consumer in
# scripts/ — this corrupts the documented --kv/--json machine API (and any
# operator or agent reading it), not the build path. Of the 11 index-dedupe
# sites in the tree, probe.sh's was the ONLY one deduping a query that
# requests stream_tags; the other ten extract index/codec/type, identical in
# both views, where keep-first is harmless. §4 pins that as a class guard.
#
# Asserted:
#   1. multilang.ts (AC-3 eng-2.0 / spa-2.0 / eng-5.1): --kv reads eng/spa/eng
#      in track order, never und, and PR_AUD_COUNT stays 3 (a merge that
#      double-counted would also "fix" the language).
#   2. the merge is field-by-field: codec/channels/layout survive intact, and
#      the record keeps its slot so a:N order and order-derived tie-breaks hold.
#   3. the cross-check that would have caught it: probe.sh --kv and remux.sh
#      --print-plan must agree track-for-track on the same file.
#   4. class guard: no stream_tags query in scripts/ rides a keep-first dedupe.
#   5. dupe_lang.ts (MP2-eng + AC-3-eng) — both eng, count 2.
#   6. no regression on a single-view (non-program) source: a MOV with a real
#      language still reads it, and an untagged track still reads und (the
#      placeholder must survive — the merge only ever replaces und with a
#      KNOWN value, never invents one).
#
# Standalone: bash tests/regression.d/92-probe-lang-merge.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

# grepq / grepqe PATTERN — read stdin to EOF, THEN answer. `x | grep -q PAT`
# closes the pipe on the first match and SIGPIPEs its writer: the same early-exit
# shape as the 1.15.2 `ffp … | head -1` field defect. Measured 2026-08-28 on
# verify.sh (95 KB): "printf: write error: Broken pipe", and under pipefail the
# non-zero pipeline flipped a PASS into a FALSE FAIL. Never `| grep -q` over
# source in this suite (94 §10 sweeps for it).
# A leading `--` is SWALLOWED, not searched for: converting a `grep -q -- PAT`
# call site left the `--` in place, so the pattern became "--" and the guard
# matched every long option in the file — PASS, guarding nothing. Measured
# 2026-08-28 (mutation-audit case G21, the third self-inflicted vacuity this
# round). The `--` below is what protects a pattern that starts with a dash.
grepq  () { [ "${1:-}" = -- ] && shift; [ "$(grep -c  -- "$1")" -gt 0 ]; }
grepqe () { [ "${1:-}" = -- ] && shift; [ "$(grep -cE -- "$1")" -gt 0 ]; }
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }
kv () { bash "$SC/probe.sh" "$1" --kv 2>/dev/null; }
kvget () { printf '%s\n' "$2" | sed -n "s/^$1=//p" | tr -d "'"; }

for f in multilang.ts dupe_lang.ts; do
  [ -f "$FIX/$f" ] || { echo "== regenerating missing fixture: $f =="; bash "$TESTS/make-fixtures.sh" "$f" || { echo "fixture build failed"; exit 2; }; }
done

echo "== precondition: the fixture really does double-list (else this test proves nothing) =="
views=$(ffprobe -v error -select_streams a -show_entries stream=index:stream_tags=language \
        -of compact=p=0:nk=0 "$FIX/multilang.ts" 2>/dev/null | grep -c '^index=')
tagged=$(ffprobe -v error -select_streams a -show_entries stream=index:stream_tags=language \
        -of compact=p=0:nk=0 "$FIX/multilang.ts" 2>/dev/null | grep -c 'tag:language=')
[ "$views" -gt "$tagged" ] && [ "$tagged" -gt 0 ] \
  && ok "multilang.ts emits $views stream rows, only $tagged carry tag:language (the two-view shape)" \
  || no "fixture does not reproduce the two-view shape (rows=$views tagged=$tagged) — test is vacuous"

echo
echo "== 1. multilang.ts: --kv reads the real languages, in track order =="
K=$(kv "$FIX/multilang.ts")
l0=$(kvget PR_AUD_0_LANG "$K"); l1=$(kvget PR_AUD_1_LANG "$K"); l2=$(kvget PR_AUD_2_LANG "$K")
cnt=$(kvget PR_AUD_COUNT "$K")
[ "$l0" = eng ] && ok "PR_AUD_0_LANG=eng" || no "PR_AUD_0_LANG=${l0:-<empty>} (want eng)"
[ "$l1" = spa ] && ok "PR_AUD_1_LANG=spa" || no "PR_AUD_1_LANG=${l1:-<empty>} (want spa)"
[ "$l2" = eng ] && ok "PR_AUD_2_LANG=eng" || no "PR_AUD_2_LANG=${l2:-<empty>} (want eng)"
case "$l0$l1$l2" in *und*) no "a track still reads und — the keep-first dedupe is still dropping the tagged view";; *) ok "not a single und across the three tracks";; esac
[ "$cnt" = 3 ] && ok "PR_AUD_COUNT=3 (the merge did not double-count the two views)" \
  || no "PR_AUD_COUNT=${cnt:-<empty>} (want 3)"

echo
echo "== 2. the merge is field-by-field: non-language fields survive, slots hold =="
c0=$(kvget PR_AUD_0_CODEC "$K"); c2=$(kvget PR_AUD_2_CODEC "$K")
h0=$(kvget PR_AUD_0_CHANNELS "$K"); h2=$(kvget PR_AUD_2_CHANNELS "$K")
y0=$(kvget PR_AUD_0_LAYOUT "$K"); y2=$(kvget PR_AUD_2_LAYOUT "$K")
[ "$c0" = ac3 ] && [ "$c2" = ac3 ] && ok "codecs intact (ac3/ac3)" || no "codec clobbered by the merge (a:0=$c0 a:2=$c2)"
[ "$h0" = 2 ] && [ "$h2" = 6 ] && ok "channels intact (2 / 6) — no whole-record replacement" || no "channels clobbered (a:0=$h0 a:2=$h2, want 2/6)"
[ "$y0" = stereo ] && ok "a:0 layout stereo" || no "a:0 layout=$y0 (want stereo)"
case "$y2" in 5.1*) ok "a:2 layout $y2 (the 5.1 track kept its slot AND its layout)";; *) no "a:2 layout=$y2 (want 5.1*)";; esac
[ "$h2" = 6 ] && [ "$l2" = eng ] && ok "slot order held: the 6ch track is still a:2 (order-derived tie-breaks hold)" \
  || no "track order shifted under the merge"

echo
echo "== 3. the cross-check that would have caught it: --kv agrees with remux.sh --print-plan =="
PLAN=$(bash "$SC/remux.sh" "$FIX/multilang.ts" "$WORK/never.mov" --print-plan 2>/dev/null)
planlangs=$(printf '%s\n' "$PLAN" | sed -n 's/^RMX_T .*lang=\([a-z][a-z][a-z]\).*/\1/p' | paste -sd, -)
kvlangs="$l0,$l1,$l2"
[ -n "$planlangs" ] && [ "$planlangs" = "$kvlangs" ] \
  && ok "probe --kv ($kvlangs) == remux --print-plan ($planlangs)" \
  || no "the two manifests disagree: --kv=$kvlangs plan=${planlangs:-<empty>}"
[ ! -f "$WORK/never.mov" ] && ok "--print-plan wrote nothing" || no "--print-plan wrote a file"

echo
echo "== 4. class guard: no stream_tags query rides a keep-first dedupe =="
# Scoped to the OFFENDING IDIOM, not the file: `idx in seen` is the shape that
# deduped the per-track manifest (the one query in the tree carrying
# stream_tags). A file-level grep false-positives on remux.sh, which holds a
# tags query AND — for the non-audio OTHERS list — a legitimate keep-first
# `seen[$1]++` over index/codec/type, fields identical in both views.
offenders=""
for _f in "$SC"/*.sh; do
  # comments stripped and BASENAMES reported: an un-stripped grep is satisfied
  # by a comment that merely quotes the idiom (measured FALSE-POSITIVE
  # 2026-08-28, tests/mutation-audit.sh case P10), and a full sandbox path in a
  # failure line is unreadable.
  sed 's/#.*//' "$_f" | grepqe 'idx in seen\) *next' && offenders="$offenders $(basename "$_f")"
done
[ -z "$offenders" ] && ok "the keep-first manifest idiom (idx in seen) survives nowhere in scripts/" \
  || no "keep-first dedupe over the per-track manifest still in: $offenders"
# ONE WRITER (1.15.14). 1.15.10 fixed the COPY; it did not fix the COPYING —
# the query, the parse and the merge still lived in probe.sh AND remux.sh, so
# the identical bug could land again in whichever copy the next edit missed.
# The fact now has a single home. These pins are the class guard: not "does
# probe.sh merge correctly" (a per-copy question that scales with copies) but
# "does the merge exist exactly once" — which stays one assertion forever.
# count OCCURRENCES over comment-stripped source, never FILES: `grep -l` is
# blind to a second copy pasted into the SAME file (measured MISSED 2026-08-28,
# mutation-audit case G11b — the identical blind spot 94 §5 was rewritten to
# close), and an un-stripped grep trips on a comment that quotes the idiom
# (measured FALSE-POSITIVE, case P11).
n_merge=$(cat "$SC"/*.sh 2>/dev/null | sed 's/#.*//' | grep -c 'G\[o\]=="und"')
[ "$n_merge" = 1 ] && ok "the WO 3.4 merge exists exactly once in scripts/ ($n_merge)" \
  || no "the merge appears $n_merge time(s) in scripts/ — want exactly 1 (the shared writer)"
grep -q 'G\[o\]=="und"' "$SC/lib-probe.sh" && ok "…and that file is lib-probe.sh (the shared writer)" \
  || no "the merge is not in lib-probe.sh"
for consumer in probe.sh remux.sh; do
  grep -q 'rtm_aud_manifest' "$SC/$consumer" \
    && ok "$consumer consumes rtm_aud_manifest" || no "$consumer does not call the shared writer"
  grep -q 'G\[o\]=="und"' "$SC/$consumer" \
    && no "$consumer still carries its own copy of the merge" || ok "$consumer holds no private copy"
done
# the presentation fallbacks are deliberately NOT shared — each consumer keeps
# its own, and the shared writer must not impose either.
grep -q '"unknown"' "$SC/probe.sh" && ok "probe.sh keeps its own 'unknown' layout fallback" \
  || no "probe.sh lost its layout fallback"
grep -q 'CH\[o\]"ch"' "$SC/remux.sh" && ok "remux.sh keeps its own 'Nch' fallback (different on purpose)" \
  || no "remux.sh lost its Nch fallback"

echo
echo "== 5. dupe_lang.ts (MP2-eng + AC-3-eng): both languages real =="
K2=$(kv "$FIX/dupe_lang.ts")
d0=$(kvget PR_AUD_0_LANG "$K2"); d1=$(kvget PR_AUD_1_LANG "$K2"); dc=$(kvget PR_AUD_COUNT "$K2")
[ "$d0" = eng ] && [ "$d1" = eng ] && ok "both tracks read eng" || no "dupe_lang langs: a:0=$d0 a:1=$d1 (want eng/eng)"
[ "$dc" = 2 ] && ok "PR_AUD_COUNT=2" || no "PR_AUD_COUNT=${dc:-<empty>} (want 2)"

echo
echo "== 6. single-view source: real language read, untagged still reads und =="
# Container note (measured, ffmpeg 9.0.1): movenc does NOT write mdhd language
# from -metadata:s:a:0, so a .mov fixture reads und for BOTH tracks and cannot
# tell a working read from a broken one. Matroska carries it — use that, so
# this section fails only when the merge is actually wrong.
M="$WORK/single.mkv"
ff -f lavfi -i "testsrc2=s=160x120:r=25" -f lavfi -i "sine=440" -f lavfi -i "sine=880" -t 2 \
   -map 0:v -map 1:a -map 2:a -c:v libx264 -pix_fmt yuv420p -c:a aac \
   -metadata:s:a:0 language=deu "$M" 2>/dev/null || { echo "   (single-view fixture mint failed)"; }
if [ -f "$M" ]; then
  K3=$(kv "$M"); s0=$(kvget PR_AUD_0_LANG "$K3"); s1=$(kvget PR_AUD_1_LANG "$K3")
  [ "$s0" = deu ] && ok "tagged track on a single-view container reads deu" || no "single-view tagged track read $s0 (want deu)"
  case "$s1" in und|"") ok "untagged track still reads und — the merge never invents a language";; *) no "untagged track read $s1 (want und)";; esac
else
  no "could not mint the single-view fixture"
fi

echo
echo "probe-lang-merge: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
