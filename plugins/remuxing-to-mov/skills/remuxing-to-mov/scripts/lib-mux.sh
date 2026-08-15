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

# mux_census FILE PLANNED_N PLANNED_CODECS_CSV [STAGE]
#   PLANNED_N            how many streams the builder mapped (its own plan)
#   PLANNED_CODECS_CSV   expected codec_name per output stream, IN ORDER;
#                        "?" for a slot the builder will not assert; "" to
#                        assert the count only (identity unchecked, announced)
#   STAGE                label for the machine line (remux/dual-track/…)
#
# Prints the additive machine line
#     RMX_CENSUS stage=… planned=N written=M codecs=ok|mismatch|na match=ok|MISMATCH
# plus a human line. Returns 0 when the file matches the plan, 1 when it does
# not — the caller reports and refuses to bless (nothing is exited from here:
# a library that exits steals the builder's own cleanup).
mux_census () {
  local f="${1:?mux_census needs FILE}" wantn="${2:-}" wantc="${3:-}" stage="${4:-mux}"
  local gotc gotn cverd=na ok=1
  # index-deduped: an mpegts output (trim-to-idr) lists every stream twice —
  # a bare top-level view then the in-program one (the same quirk verify.sh and
  # remux.sh's manifest dedupe). MOV/MP4 outputs list once and are unaffected.
  gotc=$(ffp -v error -show_entries stream=index,codec_name -of csv=p=0 "$f" 2>/dev/null | \
         awk -F, 'NF{ if(seen[$1]++) next; printf "%s%s", s, $2; s="," }')
  gotn=$(printf '%s' "$gotc" | awk -F, '{print ($0=="" ? 0 : NF)}')
  case "$wantn" in ''|*[!0-9]*) wantn=-1;; esac
  [ "$wantn" -ge 0 ] && [ "$gotn" -ne "$wantn" ] && ok=0
  if [ -n "$wantc" ]; then
    cverd=ok
    # per-slot compare; "?" is a wildcard. A count mismatch already failed
    # above, so a short/long list here just marks the identity half mismatch.
    printf '%s\n' "$wantc" | awk -F, -v got="$gotc" 'BEGIN{ n=split(got,g,","); }
      { for(i=1;i<=NF;i++){ if($i=="?") continue; if(i>n || g[i]!=$i) { exit 1 } }
        if(NF!=n) exit 1 }' || { cverd=mismatch; ok=0; }
  fi
  if [ "$ok" -eq 1 ]; then
    echo "   census: $gotn stream(s) written, plan matched (${gotc:-none})"
    echo "RMX_CENSUS stage=$stage planned=$wantn written=$gotn codecs=$cverd match=ok"   # machine-readable (additive, D5 1.13)
    return 0
  fi
  echo ">> CENSUS MISMATCH: the muxer did not write the plan."
  echo "   planned: ${wantn} stream(s)${wantc:+ [$wantc]}"
  echo "   written: ${gotn} stream(s) [${gotc:-none}]"
  echo "   A stream the plan mapped is missing (or came out as another codec)."
  echo "   Measured 2026-08-15: 'ffmpeg -c copy -f mov' dropped 1 of 3 streams with"
  echo "   nothing but a -v warning line — silently, and every essence gate downstream"
  echo "   passed because it only ever examined the streams that survived."
  echo "RMX_CENSUS stage=$stage planned=$wantn written=$gotn codecs=$cverd match=MISMATCH"   # machine-readable (additive, D5 1.13)
  return 1
}
