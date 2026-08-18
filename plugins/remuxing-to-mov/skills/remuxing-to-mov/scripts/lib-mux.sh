#!/usr/bin/env bash
# lib-mux.sh — what every builder owes its own output. SOURCE this, don't run it.
#
# Two jobs, both born from the 1.13 defect register (2026-08-15):
#
#   rtm_part OUT      the atomic part-file name, EXTENSION-KEEPING (D6)
#   mux_census ...    the post-mux stream census the plugin never had (D5)
#
# --- D5: nothing reconciled the plan against the file -------------------------
# Every builder printed what it INTENDED to map — remux.sh's KEEP/DROP manifest
# and `RMX_PLAN … unmapped=N` are computed and printed BEFORE the mux — and
# nothing ever looked at the finished file to check the muxer agreed. The field
# report measured `ffmpeg -c copy -f mov` dropping 1 of 3 streams silently at
# `-v warning`: under the pre-1.13 gates that loss shipped GREEN, because the
# essence gates only compare the streams that ARE there and the timeline gates
# only read v:0. A census is the cheapest possible closure: one ffprobe, run on
# the PART file before it is blessed, asserting count and per-stream codec
# identity against the plan the builder already computed.
#
# Doctrine: the census runs BEFORE `mv -f "$PART" "$OUT"`, so a mismatch leaves
# nothing under the real name (the plugin's atomicity rule: never bless, keep
# the part file for the closer look).
#
# --- D6: part files were named "x.mov.part" -----------------------------------
# qlmanage/avconvert are EXTENSION-KEYED, so an operator diagnosing a kept part
# file got "the decode stack cannot handle this input" for a FILENAME problem —
# and the builders deliberately keep those artifacts on failure, so it was
# exactly the diagnosis path that broke. trim-to-idr.sh learned this in 1.9
# ("x.part.ts, not x.ts.part") and qt-groups.sh cites it; rtm_part is that
# lesson, applied once, everywhere.
#
# Usage:
#   . "$SELF_DIR/lib-mux.sh"
#   PART="$(rtm_part "$OUT")"
#   ...mux to $PART...
#   mux_census "$PART" "$NSTREAMS" "$CODECS" remux || exit 1
#   mv -f "$PART" "$OUT"

RTM_MUX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$RTM_MUX_LIB_DIR/lib-probe.sh"   # ffp: one probe window rule for every open

# rtm_sidecar OUT TAG -> a temp/intermediate name for OUT that KEEPS the real
# extension: rtm_sidecar /a/x.mov part -> /a/x.part.mov. An extensionless target
# gets .mov, because an extensionless artifact is the very thing this prevents.
rtm_sidecar () {
  local out="${1:?rtm_sidecar needs OUT}" tag="${2:?rtm_sidecar needs a TAG}" base
  base="$(basename "$out")"
  case "$base" in
    *.*) printf '%s.%s.%s' "${out%.*}" "$tag" "${out##*.}" ;;
    *)   printf '%s.%s.mov' "$out" "$tag" ;;
  esac
}

# rtm_part OUT -> the atomic part-file name for OUT ("out.mov" -> "out.part.mov")
rtm_part () { rtm_sidecar "${1:?rtm_part needs OUT}" part; }

# mux_census FILE PLANNED_N PLANNED_CODECS_CSV [STAGE] [SOURCE]
#   PLANNED_N            how many streams the builder mapped (its own plan)
#   PLANNED_CODECS_CSV   expected codec_name per output stream; "?" for a slot
#                        the builder will not assert; "" to assert the count
#                        only (identity unchecked, announced)
#   STAGE                label for the machine line (remux/dual-track/…)
#   SOURCE               optional: the INPUT file (probed here for chapters —
#                        one ffprobe) or a literal chapter count. The surplus
#                        classifier needs to know whether the input carries
#                        chapters; absent/unknown reads as "no chapters"
#                        (conservative: a chapter-shaped surplus then lands
#                        REVIEW, never a silent PASS).
#
# THREE verdicts (1.14 / DF-6), replacing the old binary count + ordered
# per-slot identity (which reported a legitimate movenc-synthesized chapter
# track as "a stream the plan mapped is missing" and stranded every chaptered
# build at .part):
#   * missing/mutated  — a planned stream is absent from the file, or came out
#     as another codec: return 1 (FAIL), today's message — that direction was
#     always right;
#   * expected surplus — a data-class track movenc synthesizes from metadata
#     the plan already carries (chapter text/bin_data when the input HAS
#     chapters; tmcd if ever written under -write_tmcd): return 0, announced
#     PASS;
#   * unexpected surplus — any other stream the plan never mapped: return 10
#     (REVIEW), named honestly as SURPLUS, never as missing.
# Comparison is per-codec MULTISET CONTAINMENT (planned ⊆ written) plus the
# surplus classifier. PASS-surplus is data/text-class ONLY, ever — a surplus
# h264 or audio stream is a mapping question a human answers (a duplicated
# media stream is a mapping bug, not muxer metadata), and lands REVIEW no
# matter what the source carries.
#
# Machine line (append-only; existing fields never renamed or removed):
#   RMX_CENSUS stage=… planned=N written=M codecs=ok|mismatch|na \
#              match=ok|MISMATCH surplus=none|chapters|tmcd|unexpected:N
# The caller reports and decides (nothing is exited from here: a library that
# exits steals the builder's own cleanup).
mux_census () {
  local f="${1:?mux_census needs FILE}" wantn="${2:-}" wantc="${3:-}" stage="${4:-mux}" src="${5:-}"
  local gotc gotn cverd=na chapn=0 surptag=none
  local MX_MISS=0 MX_SURP=0 MX_UNEXP=0 MX_NEXP=0 MX_ULIST="" MX_ELIST=""
  # index-deduped: an mpegts output (trim-to-idr) lists every stream twice —
  # a bare top-level view then the in-program one (the same quirk verify.sh and
  # remux.sh's manifest dedupe). MOV/MP4 outputs list once and are unaffected.
  gotc=$(ffp -v error -show_entries stream=index,codec_name -of csv=p=0 "$f" 2>/dev/null | \
         awk -F, 'NF{ if(seen[$1]++) next; printf "%s%s", s, $2; s="," }')
  gotn=$(printf '%s' "$gotc" | awk -F, '{print ($0=="" ? 0 : NF)}')
  case "$wantn" in ''|*[!0-9]*) wantn=-1;; esac
  # chapter awareness: csv=p=0 strips the section name, so count rows, and read
  # grep -c's OUTPUT, never its exit status (the `|| echo 0` double-0 trap)
  if [ -n "$src" ]; then
    if [ -f "$src" ]; then
      chapn=$(ffp -v error -show_chapters -of csv=p=0 "$src" 2>/dev/null | grep -c . || true)
    else
      case "$src" in *[!0-9]*|'') : ;; *) chapn="$src";; esac
    fi
  fi
  chapn=${chapn:-0}
  # multiset containment planned ⊆ written + surplus split. "?" wildcards bind
  # to MEDIA-class streams first: a "?" is a mapped stream the builder will not
  # name, and the movenc-synthesized extras are data-class — a chapter track
  # must never silently satisfy an unasserted media slot.
  eval "$(awk -v want="$wantc" -v got="$gotc" -v wantn="$wantn" -v chapn="$chapn" '
    function isdata(c){ return (c=="text" || c=="bin_data" || c=="tmcd") }
    BEGIN{
      ng=(got=="")?0:split(got,g,",")
      nw=(want=="")?0:split(want,w,",")
      wild=0; miss=0
      if (want=="" && wantn>=0) wild=wantn      # count-only plan: N unasserted slots
      for(i=1;i<=ng;i++) cnt[g[i]]++
      for(i=1;i<=nw;i++){ if(w[i]=="?"){wild++;continue}
        if(cnt[w[i]]>0) cnt[w[i]]--; else miss++ }
      for(i=1;i<=ng && wild>0;i++){ c=g[i]; if(cnt[c]>0 && !isdata(c)){cnt[c]--; wild--} }
      for(i=1;i<=ng && wild>0;i++){ c=g[i]; if(cnt[c]>0){cnt[c]--; wild--} }
      miss+=wild                                # more planned slots than written streams
      surp=0; unexp=0; nexp=0; ul=""; el=""
      for(i=1;i<=ng;i++){ c=g[i]; if(cnt[c]<=0) continue; cnt[c]--; surp++
        if(c=="tmcd" || (chapn>0 && (c=="text"||c=="bin_data"))){ nexp++; el=el (el==""?"":",") c }
        else { unexp++; ul=ul (ul==""?"":",") c } }
      printf "MX_MISS=%d MX_SURP=%d MX_UNEXP=%d MX_NEXP=%d MX_ULIST=%s MX_ELIST=%s\n", \
        miss+0, surp+0, unexp+0, nexp+0, ul, el
    }')"
  if [ -n "$wantc" ]; then
    cverd=ok
    if [ "${MX_MISS:-0}" -gt 0 ]; then cverd=mismatch; fi
  fi
  if [ "${MX_UNEXP:-0}" -gt 0 ]; then surptag="unexpected:$MX_UNEXP"
  elif [ "${MX_NEXP:-0}" -gt 0 ]; then
    case "$MX_ELIST" in *text*|*bin_data*) surptag=chapters;; *) surptag=tmcd;; esac
  fi
  if [ "${MX_MISS:-0}" -gt 0 ]; then
    echo ">> CENSUS MISMATCH: the muxer did not write the plan."
    echo "   planned: ${wantn} stream(s)${wantc:+ [$wantc]}"
    echo "   written: ${gotn} stream(s) [${gotc:-none}]"
    echo "   A stream the plan mapped is missing (or came out as another codec)."
    echo "   Measured 2026-08-15: 'ffmpeg -c copy -f mov' dropped 1 of 3 streams with"
    echo "   nothing but a -v warning line — silently, and every essence gate downstream"
    echo "   passed because it only ever examined the streams that survived."
    echo "RMX_CENSUS stage=$stage planned=$wantn written=$gotn codecs=$cverd match=MISMATCH surplus=$surptag"   # machine-readable (additive, D5 1.13; surplus= 1.14)
    return 1
  fi
  if [ "${MX_UNEXP:-0}" -gt 0 ]; then
    echo ">> CENSUS REVIEW: $MX_UNEXP surplus stream(s) the plan never mapped [$MX_ULIST]."
    echo "   Every planned stream IS present — this is a SURPLUS, not a missing stream."
    echo "   planned: ${wantn} stream(s)${wantc:+ [$wantc]}"
    echo "   written: ${gotn} stream(s) [${gotc:-none}]"
    echo "   Only data-class tracks movenc synthesizes from carried metadata (chapter"
    echo "   text/bin_data, tmcd) can pass as expected; a surplus MEDIA stream is a"
    echo "   mapping question a human answers — review before shipping."
    echo "RMX_CENSUS stage=$stage planned=$wantn written=$gotn codecs=$cverd match=ok surplus=$surptag"   # machine-readable (additive, D5 1.13; surplus= 1.14)
    return 10
  fi
  echo "   census: $gotn stream(s) written, plan matched (${gotc:-none})"
  if [ "${MX_NEXP:-0}" -gt 0 ]; then
    case "$MX_ELIST" in *text*|*bin_data*)
      echo "   census: +$MX_NEXP chapter text track (movenc-synthesized, expected)";; esac
    case "$MX_ELIST" in *tmcd*)
      echo "   census: +1 tmcd timecode track (movenc-synthesized, expected)";; esac
  fi
  echo "RMX_CENSUS stage=$stage planned=$wantn written=$gotn codecs=$cverd match=ok surplus=$surptag"   # machine-readable (additive, D5 1.13; surplus= 1.14)
  return 0
}
