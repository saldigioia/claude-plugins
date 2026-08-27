#!/usr/bin/env bash
# ts-health.sh — one-stop capture health scan: every cheap (demux-only) defect
# class the repair ladder routes on, consolidated into a single report where
# EVERY finding names its lossless fix. Nothing here decodes video, re-encodes,
# or touches the source. Two passes over the file, both I/O-bound:
#   pass 1  transport: a full `-map 0 -c copy` demux to null, log counted —
#           continuity-counter errors (transport packet loss), TEI/corrupt
#           packets, PES size mismatches, scrambled streams. Transport loss is
#           PERMANENT: no remux restores bytes the capture never wrote; decoders
#           conceal. Small counts: proceed with eyes open. Floods: re-capture.
#   pass 2  timeline: one whole-file ffprobe packet scan (all streams, integer
#           ticks) — per class and its route:
#             missing PTS/DTS      -> Rung 2 genpts, or pairfill-paff.sh when the
#                                     PAFF/half-timestamped profile says keep the
#                                     real PTS; NEVER plain-copy (the MOV muxer
#                                     invents timing — the hard-stop class)
#             backward/duplicate DTS (rot) -> routed by MEASURED profile (WO 1.14
#                                     Phase 4): pairfill (half-timestamped PAFF),
#                                     derive-dts.sh Rung 3-DERIVE (PTS-complete
#                                     reordered, ANY codec — the rotten DTS is
#                                     discarded and re-derived), rebuild (H.264,
#                                     no surviving reorder — H.264-only, as is
#                                     pairfill); mpegts/mpeg2video + forward
#                                     gaps = the backhaul rot class (mov.sh
#                                     WARNs + builds, MOV_ROT_WARN; verify
#                                     judges the result)
#             forward gaps         -> resync.sh when raw PCM rides along
#                                     (gap-collapse desync); plain copy is safe
#                                     for compressed-audio-only shapes
#             33-bit PTS wraparound (~26.5 h rollover, delta ~ -2^33 ticks)
#                                  -> demuxers usually unwrap on remux; verify
#                                     the OUTPUT timeline (gate d) proves it
#             mid-GOP start        -> pre-roll packets before the first keyframe
#                                     decode as garbage/conceal; lossless trim at
#                                     the first IDR (scripts/trim-to-idr.sh,
#                                     cutting-concat.md), no recode
#             keyframe spacing     -> a single-GOP capture is unseekable (the
#                                     scrub-gate class); nothing fixes that
#                                     losslessly, know it before shipping
#             audio missing timestamps / header-duration drift vs video
#                                  -> diagnose.sh / resync.sh
#
# Usage: scripts/ts-health.sh INPUT [--kv]
#   default: human report + verdict; --kv: TSH_* KEY=VAL lines only.
# Exit: 0 = CLEAN; 10 = FINDINGS (each named above with its route);
#       1 = DAMAGED (scrambled, or transport loss >= TSH_LOSS_FAIL);
#       2 = usage OR pre-flight (input unreadable by ffprobe — announced, never
#           a silent 1: "could not read" is not "proven damaged", WO-1.15.4 C4).
# Tunables: TSH_LOSS_FAIL (transport-error FAIL threshold, default 100),
#           DISC_MULT (forward-gap threshold in frame durations, default 1.5).
# Test hooks (house injection style): TSH_PKT_FILE=<csv idx,pts,dts,duration,flags
#   in integer ticks> bypasses the packet probe (with TSH_FDUR_TICKS, and the
#   video stream is index 0); TSH_LOG_FILE appends to the transport-pass log.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
IN="${1:?usage: ts-health.sh INPUT [--kv]}"; MODE="${2:-human}"
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-paff.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # only our own scratch; never the source

say () { [ "$MODE" != --kv ] && echo "$@"; return 0; }

# --- pre-flight: is the input READABLE at all? ------------------------------------
# EMPTY ≠ ABSENT (CHECKUP-2026-08-27 C4 / WO-1.15.4): the first failing probe
# assignment under set -e used to exit 1 with ZERO output — and 1 is this
# contract's DAMAGED, so "I could not read the source" shipped as "source
# proven damaged", silently, at the very first probe of the scanner the clinic
# trusts. An unreadable input is a PRE-FLIGHT verdict: say so, exit 2. ffp1 is
# the SIGPIPE-safe first-line form (the reader consumes to EOF).
set +e
container=$(ffp1 -v error -show_entries format=format_name -of default=nw=1:nk=1 "$IN" 2>"$TMP/preflight.err"); pf_rc=$?
set -e
if [ "$pf_rc" -ne 0 ]; then
  echo "ts-health: cannot read $IN (ffprobe rc=$pf_rc) — pre-flight failure, NOT a damage verdict:" >&2
  sed 's/^/   /' "$TMP/preflight.err" | tail -4 >&2
  exit 2
fi
# --- cheap header facts ---------------------------------------------------------
fdur_fmt=$(ffp -v error -show_entries format=duration -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
case "$fdur_fmt" in ''|N/A) fdur_fmt=0;; esac
vcodec=$(ffp -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
pixfmt=$(ffp -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
vidx=$(ffp -v error -select_streams v:0 -show_entries stream=index -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
tb=$(ffp -v error -select_streams v:0 -show_entries stream=time_base -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
rfr=$(ffp -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
tickrate=${tb##*/}; case "$tickrate" in ''|*[!0-9]*) tickrate=90000;; esac
fps=$(pf_eval_fps "${rfr:-0}")
fdur_ticks="${TSH_FDUR_TICKS:-}"
[ -n "$fdur_ticks" ] || fdur_ticks=$(awk "BEGIN{f=${fps:-0}+0; t=${tickrate}+0; if(f>0) printf \"%.0f\", t/f; else print 0}")
[ -n "${TSH_PKT_FILE:-}" ] && vidx=0

say "== ts-health: $IN =="
say "   container=$container  video=$vcodec/${pixfmt:-?}  tickrate=$tickrate  frame=${fdur_ticks} ticks"

# --- pass 1: transport (full demux to null, log counted) ------------------------
say "-- transport (whole-file -c copy demux) --"
ffmpeg -nostdin -v warning "${FF_INPUT_OPTS[@]}" -i "$IN" -map 0 -c copy -f null - 2>"$TMP/t.log" || true
[ -n "${TSH_LOG_FILE:-}" ] && cat "$TSH_LOG_FILE" >> "$TMP/t.log"
cc=$(grep -ci 'continuity check failed' "$TMP/t.log" || true)
crp=$(grep -ci 'packet corrupt' "$TMP/t.log" || true)
pes=$(grep -ci 'pes packet size mismatch' "$TMP/t.log" || true)
scr=$(grep -ci 'scrambled' "$TMP/t.log" || true)
say "   continuity errors=$cc  corrupt(TEI) packets=$crp  PES size mismatches=$pes  scrambled=$scr"
[ "$MODE" != --kv ] && [ $((cc + crp + pes)) -gt 0 ] && sort "$TMP/t.log" | uniq -c | sort -rn | head -4 | sed 's/^/   /'

# --- pass 2: whole-file packet scan, all streams, integer ticks -----------------
say "-- timeline (whole-file packet scan, demux only) --"
{ if [ -n "${TSH_PKT_FILE:-}" ]; then cat "$TSH_PKT_FILE"; else
    ffp -v error -show_entries packet=stream_index,pts,dts,duration,flags \
      -of csv=p=0 "$IN" 2>/dev/null; fi; } | \
awk -F, -v vidx="${vidx:-0}" -v fdur="${fdur_ticks:-0}" -v mult="${DISC_MULT:-1.5}" '
  NF{
    # $5, not $NF: ffprobe 8 appends a trailing comma on packets carrying side
    # data (the test-18 lesson), which would shift $NF onto an empty field
    idx=$1; pts=$2; dts=$3; fl=$5
    if(idx==vidx){
      vn++
      if(pts=="N/A"||pts=="") vnap++
      if(dts=="N/A"||dts==""){ vnad++ } else {
        t=dts+0
        if(hav){ d=t-pd
          if(d<-4294967296){ wrap++ }              # 33-bit PTS rollover, not rot
          else if(d<0){ back++ }
          else if(d==0){ dup++ }
          else { np++; dl[np]=d }
        }
        pd=t; hav=1
        if(index(fl,"K")){ nk++; if(pk!=""){ g=t-pk; if(g>maxk) maxk=g }; pk=t }
      }
      if(index(fl,"K") && firstk==0) firstk=vn
    } else {
      an[idx]++
      if(pts=="N/A"||pts=="") ana[idx]++
    }
  }
  END{
    fd=fdur+0
    if(fd<=0 && np>0){ s=0; for(i=1;i<=np;i++) s+=dl[i]; fd=s/np }
    thr=mult*fd; gaps=0; miss=0
    if(fd>0) for(i=1;i<=np;i++) if(dl[i]>thr){ gaps++; miss+=dl[i]-fd }
    prek=(firstk==0)? vn : firstk-1
    printf "V_N=%d V_NAPTS=%d V_NADTS=%d V_BACK=%d V_DUP=%d V_WRAP=%d V_GAPS=%d V_MISS_T=%.0f V_PREKEY=%d V_KEYS=%d V_MAXKGAP_T=%.0f\n", \
      vn+0, vnap+0, vnad+0, back+0, dup+0, wrap+0, gaps, miss, prek+0, nk+0, maxk+0
    for(k in an) printf "A_%s=%d/%d\n", k, ana[k]+0, an[k]
  }' > "$TMP/scan.kv"
eval "$(grep '^V_' "$TMP/scan.kv")"
gap_s=$(awk "BEGIN{printf \"%.3f\", ${V_MISS_T:-0}/${tickrate}}")
maxk_s=$(awk "BEGIN{printf \"%.2f\", ${V_MAXKGAP_T:-0}/${tickrate}}")
say "   video packets=$V_N  N/A-PTS=$V_NAPTS  N/A-DTS=$V_NADTS  backward-DTS=$V_BACK  duplicate-DTS=$V_DUP"
say "   forward gaps=$V_GAPS (~${gap_s}s dropped)  PTS wraparounds=$V_WRAP  pre-keyframe packets=$V_PREKEY  keyframes=$V_KEYS (max gap ${maxk_s}s)"
if [ "$MODE" != --kv ] && grep -q '^A_' "$TMP/scan.kv"; then
  say "   audio streams (missing-ts/packets): $(grep '^A_' "$TMP/scan.kv" | sed 's/^A_//' | paste -sd'  ' -)"
fi

# audio header-duration parity vs video (cheap; TS often reports only format
# duration — then parity is N/A here and verify.sh gate (f) owns it post-build)
vdur=$(ffp -v error -select_streams v:0 -show_entries stream=duration -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
worst_ad=0
if [ -n "$vdur" ] && [ "$vdur" != N/A ]; then
  while IFS=, read -r _aidx adur; do
    [ -n "$adur" ] && [ "$adur" != N/A ] || continue
    d=$(awk "BEGIN{x=($vdur)-($adur); if(x<0)x=-x; printf \"%.3f\", x}")
    awk "BEGIN{exit !(($d) > ($worst_ad))}" && worst_ad=$d
  done < <(ffp -v error -select_streams a -show_entries stream=index,duration -of csv=p=0 "$IN" 2>/dev/null | sort -u)
fi

# --- findings + routes ----------------------------------------------------------
findings=0; damaged=0
finding () { findings=$((findings+1)); say "   [$1] $2"; say "        -> $3"; }
say "-- findings --"
if [ "${scr:-0}" -gt 0 ]; then
  damaged=1
  finding transport "scrambled stream(s) detected" "encrypted capture — nothing in this toolchain can recover it"
fi
tloss=$((cc + crp + pes))
if [ "$tloss" -gt 0 ]; then
  if [ "$tloss" -ge "${TSH_LOSS_FAIL:-100}" ]; then
    damaged=1
    finding transport "$tloss transport-level errors (CC=$cc corrupt=$crp PES=$pes) — heavy packet loss" \
      "PERMANENT: no remux restores lost bytes. Re-capture; if impossible, decoders conceal — diagnose.sh step 1 quantifies the visual damage"
  else
    finding transport "$tloss transport-level error(s) (CC=$cc corrupt=$crp PES=$pes)" \
      "PERMANENT but small: bytes are gone, decoders conceal. Remux is still legitimate; expect matching decode noise source==output (verify's baseline classification)"
  fi
fi
if [ "${V_NAPTS:-0}" -gt 0 ] || [ "${V_NADTS:-0}" -gt 0 ]; then
  eval "$(pf_detect "$IN")"   # windowed, cheap: picks the right missing-ts repair
  if { [ "$PF_PAFF" = yes ] || [ "$PF_HALF_TS" = yes ]; } && [ "${vcodec:-na}" = h264 ]; then
    finding timeline "video missing timestamps (N/A PTS=$V_NAPTS DTS=$V_NADTS; PAFF/half_ts=$PF_HALF_TS)" \
      "scripts/pairfill-paff.sh (keeps real PTS; H.264-only). NEVER plain-copy — the MOV muxer invents timing (hard-stop class)"
  elif [ "$PF_PAFF" = yes ] || [ "$PF_HALF_TS" = yes ]; then
    finding timeline "video missing timestamps (N/A PTS=$V_NAPTS DTS=$V_NADTS; PAFF-shaped profile but codec=${vcodec:-?})" \
      "pairfill-paff.sh is H.264-only (it refuses this codec, exit 3) — Rung 2 genpts (remux.sh --genpts), verify-gated; scripts/diagnose.sh reads the full profile. NEVER plain-copy (the MOV muxer invents timing)"
  else
    finding timeline "video missing timestamps (N/A PTS=$V_NAPTS DTS=$V_NADTS)" \
      "Rung 2 genpts (remux.sh --genpts), verify-gated; escalate per diagnose.sh if it still glitches"
  fi
fi
if [ "${V_BACK:-0}" -gt 0 ] || [ "${V_DUP:-0}" -gt 0 ]; then
  if [ "$vcodec" = mpeg2video ] && [ "${V_GAPS:-0}" -gt 0 ]; then
    case "$container" in *mpegts*)
      # P1.4: this finding quoted V_GAPS raw even when V_NADTS > 0 — the very
      # condition the gap finding twenty lines below refuses to report a gap
      # count under, because deltas measured across missing timestamps span the
      # holes. Same guard, same words, applied here: the rot half stands on its
      # own counters, the gap half is named unreliable instead of asserted.
      if [ "${V_NADTS:-0}" -gt 0 ]; then
        finding timeline "DTS rot (backward=$V_BACK duplicate=$V_DUP) on mpegts/mpeg2video, plus $V_GAPS APPARENT forward gap(s) measured ACROSS $V_NADTS missing timestamp(s) — the gap count is unreliable until the timestamps are repaired" \
          "repair the missing timestamps first (route above), then re-run this scan; the rot itself routes via scripts/diagnose.sh. Do not spend the apparent gap seconds as a tolerance budget anywhere"
      else
        finding timeline "DTS rot (backward=$V_BACK duplicate=$V_DUP) + $V_GAPS forward gap(s) on mpegts/mpeg2video" \
          "the backhaul rot class — mov.sh WARNs and builds (MOV_ROT_WARN); the verdict is measured (mux-confession hard stop + verify.sh), expect REVIEW/FAIL. Honest routes stay: keep the .ts / lossless MKV / rung4.sh"
      fi;;
      *) finding timeline "DTS rot (backward=$V_BACK duplicate=$V_DUP)" "scripts/diagnose.sh routes the repair by timestamp profile";;
    esac
  else
    # WO 1.14 Phase 4: the old route here said "pairfill or rebuild; lossless
    # either way" — struck. The rungs are only lossless IN PRESENTATION when
    # they match the measured profile (a constant-rate rebuild of a reordered
    # stream plays decode order), and both are H.264-only; the PTS-complete
    # reordered class (DTS absent/reconstructed/rotten alike) is derive-dts.
    finding timeline "DTS rot (backward=$V_BACK duplicate=$V_DUP)" \
      "scripts/diagnose.sh routes by MEASURED profile: pairfill-paff.sh (half-timestamped PAFF), scripts/derive-dts.sh Rung 3-DERIVE (PTS-complete reordered, any codec — the rotten DTS column is discarded and re-derived from the sorted PTS), rebuild-paff.sh (H.264, no surviving reorder). The rung must match the profile — the wrong one is NOT lossless in presentation order"
  fi
fi
if [ "${V_GAPS:-0}" -gt 0 ] && [ "${V_BACK:-0}" -eq 0 ] && [ "${V_DUP:-0}" -eq 0 ]; then
  if [ "${V_NADTS:-0}" -gt 0 ]; then
    # deltas span the holes when timestamps are missing — gap counts measured
    # across survivors are inflated; the timestamp repair comes first
    finding timeline "$V_GAPS apparent forward gap(s) measured ACROSS $V_NADTS missing timestamps — unreliable until the missing-timestamp repair lands" \
      "repair the timestamps first (route above), then re-run this scan for a trustworthy gap count"
  else
    finding timeline "$V_GAPS forward gap(s), ~${gap_s}s dropped (present+monotonic — the mux will 'succeed')" \
      "scripts/resync.sh IN OUT.mov when raw PCM audio rides along (gap-collapse desync); compressed-audio/video-only shapes plain-copy safely — verify gate (f) confirms"
  fi
fi
if [ "${V_WRAP:-0}" -gt 0 ]; then
  finding timeline "$V_WRAP 33-bit PTS wraparound(s) (~26.5 h rollover)" \
    "remux normally: demuxers unwrap on read. Proof lives in the OUTPUT — verify.sh gate (d) must show a strictly monotonic result"
fi
if [ "${V_PREKEY:-0}" -gt 0 ]; then
  finding timeline "capture starts mid-GOP: $V_PREKEY packet(s) before the first keyframe" \
    "lossless trim at the first IDR: scripts/trim-to-idr.sh (keyframe-bound copy cut, references/cutting-concat.md; gop-probe.sh checks the boundary) — no re-encode; players otherwise conceal the pre-roll"
fi
if [ "${V_KEYS:-0}" -lt 2 ] && [ -z "${TSH_PKT_FILE:-}" ] && awk "BEGIN{exit !(${fdur_fmt:-0} > 30)}" 2>/dev/null; then
  finding timeline "single-GOP capture (${V_KEYS:-0} keyframe(s) over ${fdur_fmt}s) — effectively unseekable" \
    "no lossless fix exists; ship only with that stated (verify's scrub gate flags it)"
fi
if awk "BEGIN{exit !(($worst_ad) > 0.5)}"; then
  finding audio "audio/video header durations differ by up to ${worst_ad}s" \
    "scripts/diagnose.sh (usually the gap-collapse class -> resync.sh); verify gate (f) owns the post-build proof"
fi
# 1.11 (WO 4.1 demotion; wording fixed in the WO 5.2 messaging pass): the
# pre-1.11 finding asserted "QuickTime CANNOT decode this profile ... mov.sh
# refuses (exit 11)" after that categorical verdict was falsified on the bench
# (macOS 26.6.1, 2026-08-13) and the refusal demoted — decode support drifts
# by macOS version, so the honest claim is the per-file post-build proof.
if [ "$pixfmt" = yuv422p ] && { [ "$vcodec" = mpeg2video ] || [ "$vcodec" = h264 ]; }; then
  finding codec "$vcodec 4:2:2 (yuv422p) — contribution/backhaul profile: QuickTime decode is a per-OS empirical fact, proven on the finished build, never assumed (the categorical refusal was falsified on macOS 26.6.1, 2026-08-13)" \
    "build losslessly — scripts/mov.sh announces the profile and proves playability post-build (playable-check.sh; fail/unverified -> REVIEW with rung4.sh named); the source stays the master either way"
fi

# --- verdict --------------------------------------------------------------------
if [ "$damaged" -eq 1 ]; then VERDICT=DAMAGED; rc=1
elif [ "$findings" -gt 0 ]; then VERDICT=FINDINGS; rc=10
else VERDICT=CLEAN; rc=0; fi
if [ "$MODE" = --kv ]; then
  printf 'TSH_CC=%s\nTSH_CORRUPT=%s\nTSH_PES=%s\nTSH_SCRAMBLED=%s\n' "$cc" "$crp" "$pes" "$scr"
  printf 'TSH_VPKTS=%s\nTSH_NAPTS=%s\nTSH_NADTS=%s\nTSH_BACK=%s\nTSH_DUP=%s\nTSH_WRAP=%s\nTSH_GAPS=%s\nTSH_GAP_SECS=%s\nTSH_PREKEY=%s\nTSH_KEYS=%s\nTSH_MAXKGAP_S=%s\n' \
    "$V_N" "$V_NAPTS" "$V_NADTS" "$V_BACK" "$V_DUP" "$V_WRAP" "$V_GAPS" "$gap_s" "$V_PREKEY" "$V_KEYS" "$maxk_s"
  printf 'TSH_AUD_WORST_DELTA=%s\nTSH_FINDINGS=%s\nTSH_VERDICT=%s\n' "$worst_ad" "$findings" "$VERDICT"
else
  case "$VERDICT" in
    CLEAN)    echo ">> CLEAN: no transport loss, timeline sound, timestamps complete — plain-copy territory (verify the output as always).";;
    FINDINGS) echo ">> FINDINGS: $findings issue(s) above, each with its route — lossless wherever a fix exists (re-encode only where explicitly named).";;
    DAMAGED)  echo ">> DAMAGED: transport-level loss/encryption (above). Timestamp repairs still apply to what survives, but the missing data is gone — re-capture is the only true fix.";;
  esac
fi
exit "$rc"
