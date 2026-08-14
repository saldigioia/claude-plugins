#!/usr/bin/env bash
# 32-auto-per-track.sh — work-order 3.2: `--audio auto` decides PER KEPT TRACK.
#
# The pre-3.2 defect (entry 1): mov.sh's multi branch printed "non-native
# tracks land as PCM ACCESS audio" and then called remux.sh WITHOUT --audio
# pcm — whose auto rule copied AC-3 through, so the printed promise was a lie
# (desktop QuickTime does not decode AC-3, TN2429). The blunt fix — --audio
# pcm on the whole call — would needlessly decode already-native AAC. The
# real fix makes auto per-track: QT-decodable (aac/alac/mp3/raw PCM/eac3) ->
# copy bit-exact; EVERYTHING else -> PCM access, announced per track (house
# rule 5), with the disposition stamped on the RMX_T plan rows (disp=, a new
# field — contract rule 4) so plan and mux can never drift apart.
#
# Asserted, on the mixed.ts fixture (H.264 + AAC-eng stereo + AC-3-spa stereo):
#   1. remux.sh --audio-keep all under default auto: AAC copies (mp4a tag),
#      AC-3 lands as raw PCM; the plan rows carry disp=copy / disp=pcm; the
#      conversion is a per-track WARN citing TN2429; both output tracks
#      decode 0-error; languages survive into the MOV.
#   2. mov.sh multi path (--audio-keep all): the printed PCM-ACCESS promise
#      now matches the muxed file exactly — MODE=multi, mp4a + sowt/twos,
#      MOV_SUMMARY mode=multi, verified DONE (rc=0).
#   3. the needless-decode guard: the default `layouts` policy keeps BOTH
#      stereo tracks (WO 3.5: stereo/eng and stereo/spa are distinct
#      layout+language deliverables, no longer "duplicates") and still
#      COPIES the native AAC — auto never decodes it (the blunt-fix
#      regression would land it as PCM).
#   4. forced modes still override every track: --audio pcm / --audio copy
#      plan rows read disp=pcm / disp=copy for BOTH tracks (plan-only).
#
# Standalone: bash tests/regression.d/32-auto-per-track.sh
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
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
acods () { ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$1" 2>/dev/null | paste -sd, -; }
atag () { ffprobe -v error -select_streams "a:${2:-0}" -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1; }
aderr () { # aderr FILE TRACK — decode-error line count for one audio track
  ffmpeg -nostdin -v error -i "$1" -map "0:a:$2" -f null - 2>&1 | grep -c . || true
}

# fixture: regenerate when missing (media never ships in git)
if [ ! -f "$FIX/mixed.ts" ]; then
  echo "== regenerating missing fixture: mixed.ts =="
  bash "$TESTS/make-fixtures.sh" mixed.ts || { echo "fixture build failed"; exit 2; }
fi
[ -f "$FIX/mixed.ts" ] || { echo "mixed.ts still missing after make-fixtures"; exit 2; }
SRC="$FIX/mixed.ts"

echo "== 1. remux.sh auto, both tracks kept: AAC copies, AC-3 -> PCM access =="
out=$(bash "$SC/remux.sh" "$SRC" "$WORK/all.mov" --audio-keep all 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "remux exits 0" || { no "remux rc=$rc"; printf '%s\n' "$out" | tail -4 | sed 's/^/   /'; }
# the plan states the per-track disposition up front (RMX_T disp=, WO 3.2)
has "$out" "RMX_T ord=0 keep=1 codec=aac" "plan row for the AAC track present"
case "$out" in *"ord=0 keep=1 codec=aac"*"disp=copy"*) ok "AAC plan row says disp=copy";; *) no "AAC plan row lacks disp=copy";; esac
case "$out" in *"ord=1 keep=1 codec=ac3"*"disp=pcm"*) ok "AC-3 plan row says disp=pcm";; *) no "AC-3 plan row lacks disp=pcm";; esac
# the mux announces what it did, per track — copy is quiet, conversion is WARN
has "$out" "audio a:0: aac -> copy (QuickTime-native)" "AAC copy announced"
has "$out" "** WARN audio a:1: ac3 -> PCM access" "AC-3 conversion is a per-track WARN"
has "$out" "TN2429" "the WARN cites the reason AC-3 is non-native (TN2429)"
# ...and the file matches the manifest: mp4a copy + raw-PCM access track
[ "$(acods "$WORK/all.mov")" = "aac,pcm_s16le" ] && ok "output shape aac,pcm_s16le" || no "output shape: $(acods "$WORK/all.mov")"
[ "$(atag "$WORK/all.mov" 0)" = mp4a ] && ok "AAC track copied (tag mp4a)" || no "AAC tag: $(atag "$WORK/all.mov" 0), want mp4a"
case "$(atag "$WORK/all.mov" 1)" in sowt|twos) ok "AC-3-origin track is raw PCM ($(atag "$WORK/all.mov" 1))";; *) no "AC-3-origin tag: $(atag "$WORK/all.mov" 1), want sowt/twos";; esac
[ "$(aderr "$WORK/all.mov" 0)" -eq 0 ] && ok "a:0 decodes 0-error" || no "a:0 decode errors: $(aderr "$WORK/all.mov" 0)"
[ "$(aderr "$WORK/all.mov" 1)" -eq 0 ] && ok "a:1 decodes 0-error" || no "a:1 decode errors: $(aderr "$WORK/all.mov" 1)"
langs=$(ffprobe -v error -select_streams a -show_entries stream_tags=language -of default=nw=1:nk=1 "$WORK/all.mov" 2>/dev/null | grep . | paste -sd, -)
[ "$langs" = "eng,spa" ] && ok "languages survive into the MOV (eng,spa)" || no "languages: $langs, want eng,spa"

echo
echo "== 2. mov.sh multi path: the printed promise matches the muxed file =="
out=$(bash "$SC/mov.sh" "$SRC" "$WORK/multi.mov" --audio-keep all 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && case "$out" in *">> DONE"*) true;; *) false;; esac; } \
  && ok "mov.sh -> verified DONE (rc=0)" \
  || { no "mov.sh rc=$rc (want 0 + DONE)"; printf '%s\n' "$out" | tail -6 | sed 's/^/   /'; }
has "$out" "2 audio tracks survive the 'all' policy" "multi shape announced"
has "$out" "non-native tracks land as PCM ACCESS" "the promise banner prints"
has "$out" "** WARN audio a:1: ac3 -> PCM access" "the mux keeps the promise, announced per track (pre-3.2: silent AC-3 copy-through)"
has "$out" "audio a:0: aac -> copy (QuickTime-native)" "the native track is copied, not blanket-decoded"
has "$out" "MOV_SUMMARY mode=multi" "MOV_SUMMARY carries mode=multi"
[ "$(acods "$WORK/multi.mov")" = "aac,pcm_s16le" ] && ok "muxed shape matches the manifest (aac,pcm_s16le)" || no "muxed shape: $(acods "$WORK/multi.mov")"
[ "$(atag "$WORK/multi.mov" 0)" = mp4a ] && ok "AAC track tag mp4a" || no "AAC tag: $(atag "$WORK/multi.mov" 0)"
case "$(atag "$WORK/multi.mov" 1)" in sowt|twos) ok "PCM access track tag $(atag "$WORK/multi.mov" 1)";; *) no "access tag: $(atag "$WORK/multi.mov" 1)";; esac
[ "$(aderr "$WORK/multi.mov" 0)" -eq 0 ] && [ "$(aderr "$WORK/multi.mov" 1)" -eq 0 ] \
  && ok "every output audio track decodes 0-error (the acceptance bar)" \
  || no "decode errors: a:0=$(aderr "$WORK/multi.mov" 0) a:1=$(aderr "$WORK/multi.mov" 1)"

echo
echo "== 3. needless-decode guard: default (all) keeps both languages, COPIES the AAC =="   # 1.11: default --audio-keep=all
# 1.11: default --audio-keep=all (WO 3.3) — the flagless default keeps BOTH
# tracks under 'policy all' (33-keep-all-default.sh owns the default's own
# pins; the layouts distinct-deliverable branch moved to an explicit flag,
# pinned by 35-layouts-language.sh); the guard itself is unchanged — the
# native AAC rides a bit-exact copy, never a decode
out=$(bash "$SC/mov.sh" "$SRC" "$WORK/lay.mov" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "default-policy build DONE (rc=0)" || no "default-policy rc=$rc"
has "$out" "KEEP a:1 ac3 2ch stereo spa — policy all" "the spa stereo keeps under the flagless default (policy all)"   # 1.11: default --audio-keep=all
[ "$(acods "$WORK/lay.mov")" = "aac,pcm_s16le" ] && ok "both languages survive; AAC still COPIED, never decoded (aac,pcm_s16le)" || no "default shape: $(acods "$WORK/lay.mov"), want aac,pcm_s16le"
[ "$(atag "$WORK/lay.mov" 0)" = mp4a ] && ok "copied AAC tag mp4a" || no "AAC tag: $(atag "$WORK/lay.mov" 0)"

echo
echo "== 4. forced modes override every track (plan-only) =="
p=$(bash "$SC/remux.sh" "$SRC" "$WORK/p.mov" --audio-keep all --audio pcm --print-plan 2>&1)
n=$(printf '%s\n' "$p" | grep -c "disp=pcm" || true)
[ "$n" -eq 2 ] && ok "--audio pcm: both plan rows disp=pcm" || no "--audio pcm plan rows disp=pcm count=$n, want 2"
p=$(bash "$SC/remux.sh" "$SRC" "$WORK/p.mov" --audio-keep all --audio copy --print-plan 2>&1)
n=$(printf '%s\n' "$p" | grep -c "disp=copy" || true)
[ "$n" -eq 2 ] && ok "--audio copy: both plan rows disp=copy" || no "--audio copy plan rows disp=copy count=$n, want 2"
[ ! -f "$WORK/p.mov" ] && ok "--print-plan writes nothing" || no "--print-plan wrote an output"

[ -f "$SRC" ] && ok "source untouched" || no "source vanished"

echo
echo "auto-per-track: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
