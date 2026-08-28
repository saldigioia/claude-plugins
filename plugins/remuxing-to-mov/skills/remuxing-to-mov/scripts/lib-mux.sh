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
# DETERMINISTIC on purpose: premeta/autobest must be re-derivable within a run
# (auto.sh rm-cleans a stale park by name), and cross-run safety is rtm_lock's
# job, not the name's.
rtm_sidecar () {
  local out="${1:?rtm_sidecar needs OUT}" tag="${2:?rtm_sidecar needs a TAG}" base
  base="$(basename "$out")"
  case "$base" in
    *.*) printf '%s.%s.%s' "${out%.*}" "$tag" "${out##*.}" ;;
    *)   printf '%s.%s.mov' "$out" "$tag" ;;
  esac
}

# rtm_part OUT -> the atomic part-file name for OUT — extension-keeping (D6)
# and, since WO-1.15.6 (CHECKUP-2026-08-27 A2), UNIQUE PER PROCESS:
# "out.mov" -> "out.part-<pid>-<epoch>.mov". The deterministic name was half
# the measured A2 corruption: two runs sharing one part path meant run B's
# `ffmpeg -y` truncated run A's part mid-census (A blessed foreign bytes,
# rc=0, delivered file undecodable), and a stale .part kept as FAIL evidence
# was silently truncated by the next run's -y — the very file the retention
# message told the operator to inspect. pid separates concurrent writers;
# the epoch separates a recycled pid from a weeks-old kept part. One name
# per run (a second call in the same process/second returns the same name —
# every builder mints exactly once). D6 is about the SUFFIX, not
# determinism: the real extension still comes last.
rtm_part () { rtm_sidecar "${1:?rtm_part needs OUT}" "part-$$-$(date +%s)"; }

# --- WO-1.15.6 (CHECKUP-2026-08-27 A2 + F11): one writer, atomic bless ------
#
# rtm_lock OUT — the per-OUT writer lock. mkdir is the primitive (atomic on
# POSIX; macOS ships no flock(1)); the lockdir "<OUT>.lock" holds pid + host.
# A second live writer REFUSES (return 1; callers exit 2 — pre-flight family,
# nothing written). A lock whose recorded pid is dead ON THIS HOST is stolen
# with a one-line announcement (kill-9/reboot self-heal). An EMPTY pid file is
# treated as LIVE — the holder's mkdir-to-pid-write window must never be
# stolen; never-corrupt beats auto-heal, and the refusal names the rm -rf
# remedy for a truly-orphaned lock. Re-entrancy: acquiring exports
# RTM_LOCK_HELD=<lockdir>, so a CHILD builder computing the same lockdir
# (mov.sh/auto.sh/mp4-swap.sh drive builders at their own OUT) proceeds
# without owning — the driver's single lock spans its children, its
# deterministic sidecars (idrtrim/premeta/autobest), and its post-build reads.
# Release: the acquirer installs `trap 'rtm_unlock' EXIT` at the acquisition
# site (all arg guards run before it — the lib-exit EXIT-trap caveat);
# lib-exit routes INT/TERM/HUP through exit 1, so killed runs release too.
RTM_LOCKDIR=""   # set only in the process that OWNS the lock

rtm_lock () {
  local out="${1:?rtm_lock needs OUT}" d lockdir opid ohost myhost stole=0
  d="$(cd "$(dirname "$out")" 2>/dev/null && pwd)" || d="$(dirname "$out")"
  lockdir="$d/$(basename "$out").lock"
  [ "${RTM_LOCK_HELD:-}" = "$lockdir" ] && return 0   # parent driver holds it
  myhost="$(hostname 2>/dev/null || echo unknown)"
  while :; do
    if mkdir "$lockdir" 2>/dev/null; then
      printf '%s\n' "$$" > "$lockdir/pid"
      printf '%s\n' "$myhost" > "$lockdir/host"
      RTM_LOCKDIR="$lockdir"
      export RTM_LOCK_HELD="$lockdir"
      return 0
    fi
    opid=$(cat "$lockdir/pid" 2>/dev/null || true)
    ohost=$(cat "$lockdir/host" 2>/dev/null || true)
    if [ "$stole" -eq 0 ] && [ -n "$opid" ] && [ "${ohost:-$myhost}" = "$myhost" ] \
       && ! kill -0 "$opid" 2>/dev/null; then
      echo "   (stale writer lock: holder pid $opid is gone — taking over $lockdir)"
      rm -rf "$lockdir"; stole=1; continue
    fi
    echo ">> ONE WRITER per OUT (CHECKUP-2026-08-27 A2): $lockdir" >&2
    echo "   is held by pid ${opid:-unknown, still creating}${ohost:+ on $ohost}. A second concurrent writer" >&2
    echo "   corrupts the artifact the first one blesses (measured: the census and the" >&2
    echo "   mv are not atomic against another -y). Nothing was written. Wait for that" >&2
    echo "   run, pick another OUT — or, ONLY if that run is truly gone:" >&2
    echo "   rm -rf \"$lockdir\"" >&2
    echo "RTM_LOCK verdict=refused holder=${opid:-unknown} dir=$lockdir"
    return 1
  done
}

rtm_unlock () {
  [ -n "${RTM_LOCKDIR:-}" ] && rm -rf "$RTM_LOCKDIR"
  RTM_LOCKDIR=""
  return 0
}

# rtm_free_bytes DIR -> free bytes on DIR's volume, empty when unmeasurable.
# Test hook: RTM_DISK_FREE_KB injects the reading (kilobytes; non-numeric
# values simulate a broken meter). df -Pk: POSIX portable-format kilobytes.
rtm_free_bytes () {
  local kb
  if [ -n "${RTM_DISK_FREE_KB:-}" ]; then kb="$RTM_DISK_FREE_KB"
  else kb=$(df -Pk "${1:?rtm_free_bytes needs DIR}" 2>/dev/null | awk 'NR==2{print $4}'); fi
  case "$kb" in ''|*[!0-9]*) return 0;; esac
  printf '%s' $((kb * 1024))
}

# rtm_disk_preflight OUT SRC [STAGE_DIR] — F11: free bytes on OUT's volume
# (and the staging volume, when the builder has one — rebuild-paff's WORK)
# must be >= the source's size, else refuse (return 1; callers exit 2,
# nothing written). Deliberately ONE rule (the TSH_LOSS_FAIL precedent):
# a lossless remux writes roughly the source's size. The genuinely-smaller
# classes (cuts/trims) skip with RTM_DISK_CHECK=0 — an OPERATOR knob, which
# is legitimate here where 1.15.2 Defect-B forbade one: this is a resource
# heuristic, not an evidence gate, and every output gate still judges the
# build. A failed df announces "could not measure" and NEVER refuses —
# EMPTY != ABSENT applies to refusals too: a broken meter is not a full disk.
rtm_disk_preflight () {
  local out="${1:?rtm_disk_preflight needs OUT}" src="${2:?rtm_disk_preflight needs SRC}" stage="${3:-}"
  local need free d
  if [ "${RTM_DISK_CHECK:-1}" != 1 ]; then
    echo "   (disk pre-flight skipped: RTM_DISK_CHECK=0 — the build's own gates still judge)"
    return 0
  fi
  need=$(wc -c < "$src" 2>/dev/null | tr -d ' ') || need=""
  case "$need" in ''|*[!0-9]*) return 0;; esac   # unreadable source size: not this gate's business
  for d in "$(dirname "$out")" ${stage:+"$stage"}; do
    free=$(rtm_free_bytes "$d")
    if [ -z "$free" ]; then
      echo "   (disk pre-flight could not measure free space on $d — proceeding unverified)"
      continue
    fi
    if [ "$free" -lt "$need" ]; then
      echo ">> REFUSED (pre-flight): not enough free space on $d — free $free bytes <" >&2
      echo "   source $need bytes. A lossless remux writes roughly the source's size, and" >&2
      echo "   an ENOSPC an hour in leaves a truncated .part whose short size reads like a" >&2
      echo "   different defect (CHECKUP-2026-08-27 F11). Nothing was written. Free space" >&2
      echo "   and retry — or, when the intended output is genuinely smaller (a cut/trim)," >&2
      echo "   skip this check with RTM_DISK_CHECK=0 (operator knob; references/knobs.md)." >&2
      echo "RTM_DISK verdict=refused free=$free need=$need vol=$d"
      return 1
    fi
  done
  return 0
}

# rtm_writer_preflight OUT SRC [STAGE_DIR] — what every builder owes BEFORE
# its first write: the writer lock, then the disk check. Callers install
# `trap 'rtm_unlock' EXIT` first (extending an existing cleanup trap where
# one exists), then `rtm_writer_preflight "$OUT" "$IN" || exit 2`.
rtm_writer_preflight () {
  rtm_lock "${1:?rtm_writer_preflight needs OUT}" || return 1
  rtm_disk_preflight "$1" "${2:?rtm_writer_preflight needs SRC}" "${3:-}" || return 1
  return 0
}

# --- the census VERDICT, given one writer (WO-1.15.17 Item 4) -----------------
# Ten builders consume mux_census, and each re-implemented the same sentence:
# "rc 0 or 10 is acceptable, anything else is a census failure". The wrapping
# differs legitimately per builder — the stage name, the message wording, the
# retention pointer, the exit contract, the machine rows — and STAYS per
# builder. The verdict is one fact, and adding an acceptable rc used to mean
# finding and editing ten sites. Share the FACT, not the presentation (1.15.14).
#
#   rtm_census_failed RC   the census could not confirm the plan -> do not bless
#   rtm_census_review RC   complete, but an unexpected surplus -> REVIEW
#
# Both are PREDICATES for an `if`; never the last command of a script (a false
# return here is a verdict, not an error). A non-numeric rc fails CLOSED for
# rtm_census_failed and reads not-review for rtm_census_review — EMPTY is not
# ABSENT (WO-1.15.4): a rc nobody could read is never a blessing.
rtm_census_failed () {
  local rc="${1:-}"
  case "$rc" in ''|*[!0-9]*) return 0;; esac
  [ "$rc" -ne 0 ] && [ "$rc" -ne 10 ]
}
rtm_census_review () {
  local rc="${1:-}"
  case "$rc" in ''|*[!0-9]*) return 1;; esac
  [ "$rc" -eq 10 ]
}

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
