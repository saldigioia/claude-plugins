#!/usr/bin/env bash
# 33-keep-all-default.sh — work-order 3.3: the default --audio-keep is `all`.
#
# The pre-3.3 defect: the default `layouts` policy dropped the Spanish track
# from multilang.ts — a same-codec same-rank tie broken purely by track order
# (reversed order drops English instead). Meanwhile the QuickTime hazard the
# policy appeared to guard is already handled by the muxer: a parsed tkhd from
# a 3-audio-track build shows movenc enables exactly one audio track
# (0x0003/0x0002/0x0002, bench 2026-08-13), which is precisely Apple TN3177's
# requirement. Dropping tracks buys nothing for playability; it only destroys
# content. 3.3 makes `all` the default in mov.sh AND remux.sh; `layouts` stays
# as the opt-in curation flag (its behavior pinned by 35-layouts-language.sh).
#
# Asserted:
#   1. mov.sh, NO --audio-keep flag, on multilang.ts (AC-3 eng-2.0 / spa-2.0 /
#      eng-5.1): verified DONE, all THREE tracks survive (languages and channel
#      counts intact), the printed policy line names the 'all' policy, the
#      RMX_PLAN row reads policy=all kept=0,1,2 dropped=none, and no WARN DROP
#      prints (nothing is dropped, so house rule 5 has nothing to announce).
#   2. tkhd parse of that default build (TN3177; parsed on bench 2026-08-13,
#      macOS 26.6.1 / ffmpeg 9.0.1 — an enabled-flags verdict is a property of
#      the muxer that wrote it): among the three SOUN tracks exactly ONE
#      carries the enabled bit (0x1) — the multi-track default cannot create
#      the "several enabled audio tracks" QuickTime hazard.
#   3. remux.sh bare default == `all`: a flagless --print-plan on dupe_lang.ts
#      keeps BOTH same-key duplicates (policy=all kept=0,1) — the old `first`
#      default kept a:0 only.
#   4. `layouts` remains the opt-in curation flag: on multilang.ts it ALSO
#      keeps all 3 (language-aware since WO 3.5); on dupe_lang.ts (MP2-eng +
#      AC-3-eng, both stereo) it still curates down to the AC-3 with the
#      eviction announced as a WARN DROP.
#
# Standalone: bash tests/regression.d/33-keep-all-default.sh
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

# fixtures: regenerate when missing (media never ships in git)
for f in multilang.ts dupe_lang.ts; do
  if [ ! -f "$FIX/$f" ]; then
    echo "== regenerating missing fixture: $f =="
    bash "$TESTS/make-fixtures.sh" "$f" || { echo "fixture build failed"; exit 2; }
  fi
  [ -f "$FIX/$f" ] || { echo "$f still missing after make-fixtures"; exit 2; }
done
ML="$FIX/multilang.ts"; DL="$FIX/dupe_lang.ts"

echo "== 1. mov.sh flagless default: all three tracks survive, verified DONE =="
out=$(bash "$SC/mov.sh" "$ML" "$WORK/ml.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && case "$out" in *">> DONE"*) true;; *) false;; esac; } \
  && ok "default build -> verified DONE (rc=0)" \
  || { no "default build rc=$rc (want 0 + DONE)"; printf '%s\n' "$out" | tail -6 | sed 's/^/   /'; }
# the printed policy line matches the new default (the WO 3.3 acceptance)
has "$out" "3 audio tracks survive the 'all' policy" "policy line names 'all' as the active default"
has "$out" "RMX_PLAN policy=all kept=0,1,2 dropped=none" "flagless plan is policy=all, nothing dropped (pre-3.3: layouts dropped the spa track)"
has "$out" "MOV_SUMMARY mode=multi" "MOV_SUMMARY carries mode=multi (WO 3.2 per-track auto handles the shape)"
has "$out" "audio_dropped=none" "MOV_SUMMARY records zero drops"
drops=$(printf '%s\n' "$out" | grep -c "WARN DROP" || true)
[ "$drops" -eq 0 ] && ok "no WARN DROP line (nothing dropped -> nothing to announce)" || no "$drops WARN DROP line(s) on a keep-all default"
[ "$(alangs "$WORK/ml.mov")" = "eng,spa,eng" ] && ok "3 tracks with languages survive (eng,spa,eng)" || no "MOV languages: $(alangs "$WORK/ml.mov"), want eng,spa,eng"
[ "$(achs "$WORK/ml.mov")" = "2,2,6" ] && ok "channel counts preserved (2,2,6)" || no "MOV channels: $(achs "$WORK/ml.mov"), want 2,2,6"

echo
echo "== 2. tkhd parse: exactly one audio track enabled (TN3177; bench 2026-08-13) =="
# Parse the track-header flags straight off the bytes (no MP4Box dependency):
# walk the top-level boxes to find moov (faststart puts it up front, but the
# walk works either way), then scan ONLY the moov bytes for tkhd/hdlr boxes —
# never mdat, where any fourcc can occur as payload noise. tkhd layout:
# size(4) 'tkhd' version(1) flags(3); enabled = flags & 0x1. Each tkhd is
# paired with the NEXT hdlr's handler_type (vide/soun) — its own trak's mdia —
# so the audio verdict never leans on trak order. od feeds awk decimal bytes
# (POSIX; the remux.sh:69 class of trap) and awk consumes to EOF (no early
# exit — SIGPIPE hygiene under pipefail).
tkhd_soun () {  # tkhd_soun FILE -> "SOUN_TOTAL SOUN_ENABLED FLAGS_CSV"
  local f="$1" sz off bsz typ moov_off="" moov_sz="" hdr
  sz=$(wc -c < "$f" | tr -d ' '); off=0
  while [ "$off" -lt "$sz" ]; do
    hdr=$(od -A n -t u1 -j "$off" -N 8 "$f" | tr -s ' \n' '  ')
    # shellcheck disable=SC2086
    set -- $hdr
    [ $# -ge 8 ] || break
    bsz=$(( $1*16777216 + $2*65536 + $3*256 + $4 ))
    typ=$(printf "\\$(printf '%03o' "$5")\\$(printf '%03o' "$6")\\$(printf '%03o' "$7")\\$(printf '%03o' "$8")")
    if [ "$typ" = moov ]; then moov_off=$off; moov_sz=$bsz; break; fi
    [ "$bsz" -ge 8 ] || break   # size 0/1 (to-EOF / 64-bit) never applies to these outputs
    off=$((off + bsz))
  done
  [ -n "$moov_off" ] || return 1
  dd if="$f" bs=1 skip="$moov_off" count="$moov_sz" status=none | od -v -A n -t u1 | awk '
    { for(i=1;i<=NF;i++) b[n++]=$i+0 }
    END{
      # tkhd: fourcc preceded by its 4-byte box size (a tkhd is 92 or 104
      # bytes, so the three high size bytes are 0 — that guard keeps a stray
      # "tkhd" inside a metadata string from counting)
      for(j=4;j<n-8;j++){
        if(b[j]==116 && b[j+1]==107 && b[j+2]==104 && b[j+3]==100 &&
           b[j-4]==0 && b[j-3]==0 && b[j-2]==0){
          tp[tn]=j; tf[tn]=b[j+5]*65536 + b[j+6]*256 + b[j+7]; tn++ }
        else if(b[j]==104 && b[j+1]==100 && b[j+2]==108 && b[j+3]==114){
          # handler_type sits 12 bytes past the fourcc: ver/flags(4) + pre_defined(4)
          hp[hn]=j; ht[hn]=sprintf("%c%c%c%c", b[j+12], b[j+13], b[j+14], b[j+15]); hn++ }
      }
      soun=0; en=0; s=""
      for(t=0;t<tn;t++){
        # this trak-s handler is the first hdlr past its tkhd
        typ=""
        for(h=0;h<hn;h++) if(hp[h]>tp[t]){ typ=ht[h]; break }
        if(typ=="soun"){ soun++; if(tf[t]%2==1) en++
          s=s (s==""?"":",") sprintf("0x%04x", tf[t]) }
      }
      printf "%d %d %s\n", soun, en, (s==""?"-":s)
    }'
}
tk=$(tkhd_soun "$WORK/ml.mov") || tk=""
if [ -z "$tk" ]; then
  no "tkhd parse failed (no moov found?)"
else
  soun=${tk%% *}; rest=${tk#* }; en=${rest%% *}; flags=${rest#* }
  [ "$soun" -eq 3 ] && ok "three soun tracks found via tkhd->hdlr pairing" || no "soun tkhd count=$soun, want 3"
  [ "$en" -eq 1 ] && ok "exactly ONE audio track enabled (TN3177) — observed flags $flags" \
                  || no "enabled audio tracks=$en (flags $flags), want exactly 1 (TN3177)"
fi

echo
echo "== 3. remux.sh bare default == all: both same-key duplicates keep =="
p=$(bash "$SC/remux.sh" "$DL" "$WORK/dl.mov" --print-plan 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "flagless --print-plan exits 0" || { no "flagless --print-plan rc=$rc"; printf '%s\n' "$p" | tail -4 | sed 's/^/   /'; }
has "$p" "RMX_PLAN policy=all kept=0,1 dropped=none" "remux.sh default keeps both (old default 'first' kept a:0 only)"
drops=$(printf '%s\n' "$p" | grep -c "WARN DROP" || true)
[ "$drops" -eq 0 ] && ok "no WARN DROP under the default" || no "$drops WARN DROP line(s) under the keep-all default"
[ ! -f "$WORK/dl.mov" ] && ok "--print-plan writes nothing" || no "--print-plan wrote an output"

echo
echo "== 4. layouts stays available as the OPT-IN curation flag =="
# language-aware since WO 3.5: on multilang.ts layouts ALSO keeps all 3
p=$(bash "$SC/remux.sh" "$ML" "$WORK/ml_lay.mov" --audio-keep layouts --print-plan 2>&1)
has "$p" "RMX_PLAN policy=layouts kept=0,1,2 dropped=none" "layouts on multilang keeps all 3 (language-aware, WO 3.5)"
# the same-language duplicate is where layouts still curates down
p=$(bash "$SC/remux.sh" "$DL" "$WORK/dl_lay.mov" --audio-keep layouts --print-plan 2>&1)
has "$p" "RMX_PLAN policy=layouts kept=1 dropped=0" "layouts on dupe_lang still curates (AC-3 wins on rank)"
has "$p" "** WARN DROP a:0 mp2" "the opt-in curation still announces its eviction (house rule 5)"

{ [ -f "$ML" ] && [ -f "$DL" ]; } && ok "sources untouched" || no "a source vanished"

echo
echo "keep-all-default: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
