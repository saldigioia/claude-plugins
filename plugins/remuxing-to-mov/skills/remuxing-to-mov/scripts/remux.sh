#!/usr/bin/env bash
# remux.sh — Rung 0/1 lossless remux into MOV.
# Exit 11 = REFUSED pre-flight, nothing written: an unroutable codec (VC-1/VP9/
# AV1 video, or a KEPT Dolby E track — the shared WO 5.2 gate, added here in
# the 1.11 fix round so a direct call can never die in a raw muxer error).
# Since 1.11 the backhaul gate itself refuses nothing (4:2:2 -> advisory +
# post-build proof; timeline rot -> warn + build). RTM_FORCE_BACKHAUL=1 is the
# sanctioned rot-scan skip (mov.sh --force-backhaul sets it);
# RTM_BACKHAUL_GATED=1 marks an already-gated caller.
# Usage: scripts/remux.sh INPUT OUTPUT.mov [--audio auto|copy|pcm] [--genpts]
#                         [--audio-keep all|first|layouts|IDX[,IDX...]]
#                         [--all-audio] [--print-plan] [--timescale N]
#                         [--drc auto|off|on]
#   --audio auto (default): per kept track — QT-DECODABLE (AAC/ALAC/MP3/raw
#                           PCM/E-AC-3) copies bit-exact; EVERYTHING else lands
#                           as PCM access audio, announced per track (WO 3.2):
#                           AC-3 (TN2429 — desktop QuickTime has no AC-3
#                           decode), DTS/MP2/MP1 (QuickTime-unplayable),
#                           FLAC/Opus/Vorbis/TrueHD (not MOV-copyable) and
#                           pcm_bluray/pcm_dvd (container-framed LPCM, not raw
#                           PCM — a MOV "copy" is an HDMV-tagged track no
#                           decoder claims, WO 3.1)
#   --audio copy : force copy (mux-only; may not play — or mux — in QuickTime)
#   --audio pcm  : force pcm_s16le on every kept track
#   --drc auto   : AC-3/E-AC-3 -> PCM decodes run at -drc_scale 0 — full
#                  dynamic range, the same audiophile default as dual-track.sh
#                  (WO 3.7, entry 1: ffmpeg's decoder default drc_scale=1.0
#                  bakes broadcast dynamic-range compression INTO the PCM
#                  samples, audible on a concert mix; pre-1.11 builds did
#                  exactly that, so DEFAULT OUTPUTS DIFFER from 1.10 on
#                  DRC-carrying sources). off = auto; --drc on keeps broadcast
#                  DRC (the decoder default 1.0). Decode-side input option
#                  ONLY: never applied to a copy (nothing is decoded), never
#                  to a non-AC-3 decode (the option doesn't exist there).
#   --genpts     : add -fflags +genpts (Rung 2, missing timestamps)
#   --audio-keep : which audio tracks survive (QTFF audit 5-2b; policy details
#                  in SKILL.md house defaults):
#                    all     (default, WO 3.3) every track — a policy default
#                            must never destroy content, and dropping buys NO
#                            playability: movenc enables exactly one audio
#                            track regardless (tkhd parse, bench 2026-08-13 —
#                            precisely TN3177)
#                    first   a:0 only — the historical behavior
#                    layouts OPT-IN curation: distinct layout+language pairs
#                            all survive (WO 3.5: same layout in another
#                            language is a distinct deliverable, never a
#                            "duplicate"); same-layout same-language
#                            duplicates curated lossless > lossy-high >
#                            lossy-low (earlier track wins ties)
#                    0,2,...  explicit audio ordinals
#                  Every decision is printed as a KEEP/DROP manifest before the
#                  mux; every DROP is a WARN. No silent mapping decisions.
#   --all-audio  : alias for --audio-keep all (kept for compatibility)
#   --print-plan : print the KEEP/DROP manifest and exit without writing
#   --timescale N: set -video_track_timescale (ms-quantized MKV conventionality
#                  fix — see probe.sh's advisory; a timescale change, never a
#                  restamp)
# Video is ALWAYS copied (bit-identical). HEVC is tagged hvc1. Output is written
# atomically (.part -> mv) so a failure never leaves a half file under the real name.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
IN="${1:?usage: remux.sh INPUT OUTPUT.mov [opts]}"; OUT="${2:?need OUTPUT.mov}"; shift 2
AUDIO=auto; GENPTS=""; KEEP=all; PLANONLY=0; TSCALE=""; DRCOPT=auto   # KEEP default all (WO 3.3)
while [ $# -gt 0 ]; do case "$1" in
  --audio) AUDIO="$2"; shift 2;;
  --drc) DRCOPT="${2:?--drc needs a value}"; shift 2;;
  --genpts) GENPTS="-fflags +genpts"; shift;;
  --all-audio) KEEP=all; shift;;
  --audio-keep) KEEP="${2:?--audio-keep needs a value}"; shift 2;;
  --audio-keep=*) KEEP="${1#*=}"; shift;;
  --print-plan) PLANONLY=1; shift;;
  --timescale) TSCALE="${2:?--timescale needs a value}"; shift 2;;
  --timescale=*) TSCALE="${1#*=}"; shift;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
case "$DRCOPT" in auto|off|on) ;; *) echo "bad --drc: $DRCOPT" >&2; exit 2;; esac
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to overwrite the source in place" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-paff.sh"   # mux_confessions, backhaul_gate

# backhaul gate (1.11: advises + warns, refuses nothing — 4:2:2 announces the
# contribution profile and defers to the post-build proof, WO 4.1; timeline rot
# WARNs, emits MOV_ROT_WARN, and builds, WO 4.2) — remux.sh is the muxer every
# rung-0/1/2 route funnels through, so the advisory fires even on a direct call.
# A gated caller (mov.sh/auto.sh) exports RTM_BACKHAUL_GATED=1 and skips this.
backhaul_gate "$IN" || exit $?

# unroutable video — the same pre-flight refusal mov.sh issues (1.11 fix
# round; shared classifiers + voice in lib-paff.sh). Before this, a direct
# remux.sh call on VP9 died mid-mux in the raw "vp9 only supported in MP4"
# stack trace and littered a 0-byte .part. Exit 11, nothing written. The
# probed vcodec also drives the hvc1 tag below (one probe, two uses). Dolby E
# is per-track and policy-aware — checked on the KEPT set in the mux loop.
vcodec=$(ffp -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
if unroutable_v "$vcodec"; then
  unroutable_v_refuse "$vcodec"
  exit 11
fi

# --- per-track audio manifest -> KEEP/DROP plan (QTFF audit 5-2b) ---
# One awk pass computes the whole selection so the policy lives in ONE place
# (mov.sh consumes it via --print-plan instead of duplicating the logic).
# Codec ranking for layout+language curation: lossless (pcm/flac/alac/truehd/mlp) >
# lossy-high (eac3/ac3/aac/opus/vorbis/dts) > lossy-low (mp2/mp1/mp3);
# unknown ranks lowest; the earlier track wins ties. TS sources list each
# stream TWICE (a bare top-level view, then the in-program view) and only the
# program view carries the PMT tags (language!) -> dedupe by stream index,
# MERGING the two views field-by-field instead of keeping the first verbatim
# (WO 3.4: the keep-first dedupe read every TS track as lang=und).
PLAN=$(ffp -v error -select_streams a \
    -show_entries stream=index,codec_name,channels,channel_layout:stream_tags=language \
    -of compact=p=0:nk=0 "$IN" 2>/dev/null | \
  awk -F'|' -v pol="$KEEP" '
    # BEGIN{n=0} is load-bearing: an UNINITIALIZED n used as an array subscript
    # is the empty string (not 0) in POSIX awk, silently storing record 0 at
    # C[""] — while n++ still counts it. Caught by probe on the first fixture.
    BEGIN{ n=0 }
    function rank(c){ if(c ~ /^pcm_/ || c=="flac" || c=="alac" || c=="truehd" || c=="mlp") return 3
                      if(c=="eac3" || c=="ac3" || c=="aac" || c=="opus" || c=="vorbis" || c=="dts" || c=="dca") return 2
                      if(c=="mp2" || c=="mp1" || c=="mp3") return 1
                      return 0 }
    function rname(r){ return r==3?"lossless":(r==2?"lossy-high":(r==1?"lossy-low":"unknown")) }
    NF{
      c="unknown"; ch=0; lay=""; lang="und"; idx=""
      for(i=1;i<=NF;i++){ eq=index($i,"="); k=substr($i,1,eq-1); v=substr($i,eq+1)
        if(k=="index")idx=v; else if(k=="codec_name")c=v; else if(k=="channels")ch=v
        else if(k=="channel_layout")lay=v; else if(k=="tag:language")lang=v }
      # WO 3.4 merge: when an index repeats, a KNOWN value beats the parser
      # placeholder (unknown/0/empty/und) field-by-field — never whole-record
      # replacement, so a tagged record with a missing layout cannot clobber a
      # known one, whichever view arrives first. When both views know, the
      # EARLIER wins; the record keeps its original slot, so track order and
      # every order-derived tie-break (layout curation, a:N mapping) hold.
      if(idx!=""){
        if(idx in pos){ o=pos[idx]
          if(C[o]=="unknown" && c!="unknown") C[o]=c
          if(CH[o]+0==0     && ch+0!=0)      CH[o]=ch
          if(L[o]==""       && lay!="")      L[o]=lay
          if(G[o]=="und"    && lang!="und")  G[o]=lang
          next }
        pos[idx]=n
      }
      C[n]=c; CH[n]=ch; L[n]=lay; G[n]=lang; n++
    }
    END{
      # "Nch" fallback is synthesized only AFTER every view has been merged —
      # doing it at store time would fill the slot and block a later view
      # carrying the real layout name
      for(o=0;o<n;o++) if(L[o]=="") L[o]=CH[o]"ch"
      # WO 3.5: the curation key is layout + LANGUAGE (3.4 made the language
      # data real) — the same layout in a different language is a distinct
      # deliverable, never a "duplicate": keyed on layout alone, a Spanish
      # lossless track would evict an English lossy one. Two und tracks with
      # the same layout share a key ON PURPOSE (curate by rank): und carries
      # no evidence they are different deliverables, and inventing per-track
      # pseudo-languages would disable curation exactly where tags are missing.
      if(pol=="layouts")
        for(o=0;o<n;o++){ k=L[o]"/"G[o]
          if(!(k in best) || rank(C[o])>rank(C[best[k]])) best[k]=o }
      split(pol, want, ","); for(w in want) wantset[want[w]]=1
      for(o=0;o<n;o++){
        keep=0; rule=""
        if(pol=="all"){ keep=1; rule="policy all" }
        else if(pol=="first"){ if(o==0){keep=1; rule="policy first (a:0)"} else rule="policy first keeps a:0 only" }
        else if(pol=="layouts"){
          k=L[o]"/"G[o]
          cnt=0; for(p=0;p<n;p++) if(L[p]"/"G[p]==k) cnt++
          if(best[k]==o){ keep=1; rule=(cnt==1?"distinct layout+language "k:"best of layout+language "k" ("rname(rank(C[o]))")") }
          else { b=best[k]; rule="duplicate layout+language "k": "C[o]" ("rname(rank(C[o]))") loses to a:"b" "C[b]" ("rname(rank(C[b]))")" }
        }
        else { if(o in wantset){keep=1; rule="requested index"} else rule="not in requested indices" }
        printf "%d|%s|%s|%s|%s|%s|%s\n", o, C[o], CH[o], L[o], G[o], (keep?"KEEP":"DROP"), rule
      }
    }' || true)

# validate explicit-indices policy: every requested ordinal must exist
case "$KEEP" in
  all|first|layouts) ;;
  *) naud=$(printf '%s\n' "$PLAN" | grep -c . || true)
     for req in $(printf '%s' "$KEEP" | tr ',' ' '); do
       case "$req" in ''|*[!0-9]*) echo "bad --audio-keep value: $KEEP" >&2; exit 2;; esac
       [ "$req" -lt "${naud:-0}" ] || { echo "--audio-keep $KEEP: no audio track a:$req (source has ${naud:-0})" >&2; exit 2; }
     done;;
esac

# WO 3.2: ONE function decides a kept track's disposition, consulted by the
# manifest (RMX_T disp=) AND the mux mapping below, so the printed plan can
# never drift from what is actually muxed. Under auto the rule is the
# QT-DECODABLE whitelist (mirrors mov.sh native_c): QuickTime PLAYS
# aac/alac/mp3/raw PCM/eac3 as-is -> copy keeps them bit-exact; EVERYTHING
# else -> PCM access audio. The pre-3.2 shape special-cased the known
# offenders and copied the rest — which let AC-3 ride a plain copy through
# mov.sh's multi branch while its banner promised "PCM ACCESS" (entry 1).
# AC-3 is non-native BY DESIGN: TN2429, desktop QuickTime does not decode
# AC-3 (no-change list — never "simplify" it back to a copy).
track_disp () {  # track_disp CODEC -> copy|pcm under the active --audio policy
  case "$AUDIO" in pcm) echo pcm; return;; copy) echo copy; return;; esac
  case "$1" in
    # WO 3.1: container-framed LPCM is NOT raw PCM — must outrank the pcm_*
    # glob (a MOV "copy" is an HDMV-tagged track no decoder claims; even
    # ffmpeg cannot decode the file it just wrote — real 18.5 GB Blu-ray case)
    pcm_bluray|pcm_dvd)      echo pcm ;;
    aac|alac|mp3|pcm_*|eac3) echo copy;;  # QT-decodable (eac3 = DD+, native)
    *)                       echo pcm ;;  # ac3 (TN2429)/dts/mp2/flac/unknown/...
  esac
}
pcm_why () {  # pcm_why CODEC — the announced per-track reason (house rule 5)
  case "$1" in
    pcm_bluray|pcm_dvd)          echo "container-framed LPCM; a MOV copy would be undecodable" ;;
    flac|opus|vorbis|truehd|mlp) echo "not MOV-copyable" ;;
    ac3)                         echo "TN2429: desktop QuickTime has no AC-3 decode; dual-track.sh preserves the original" ;;
    dts|dca|mp2|mp1)             echo "QuickTime-unplayable; dual-track.sh preserves the original" ;;
    *)                           echo "not QuickTime-native" ;;
  esac
}

KEPT=""; DROPPED=""
if [ -n "$PLAN" ]; then
  echo "-- audio keep/drop manifest (policy: $KEEP) --"
  while IFS='|' read -r ord codec ch lay lang verdict rule; do
    [ -n "$ord" ] || continue
    if [ "$verdict" = KEEP ]; then
      echo "   KEEP a:$ord $codec ${ch}ch $lay $lang — $rule"
      KEPT="${KEPT:+$KEPT,}$ord"
      # machine row per track (mov.sh's classifier consumes these via
      # --print-plan). disp= is the WO 3.2 extension (contract rule 4: new
      # field, nothing renamed): what THIS invocation does to the kept track
      # under its --audio policy — the plan states every conversion up front.
      echo "RMX_T ord=$ord keep=1 codec=$codec ch=$ch layout=$lay lang=$lang disp=$(track_disp "$codec")"
    else
      echo "** WARN DROP a:$ord $codec ${ch}ch $lay $lang — $rule"
      DROPPED="${DROPPED:+$DROPPED,}$ord"
      echo "RMX_T ord=$ord keep=0 codec=$codec ch=$ch layout=$lay lang=$lang"
    fi
  done <<EOF
$PLAN
EOF
else
  echo "audio: none"
fi

# --- non-audio stream census (1.11 fix round; house rule 5) -------------------
# Every builder maps 0:v:0 + the kept audio — subtitle/data/attachment streams
# and any SECOND video stream (another program's video in a multi-program TS,
# an extra angle, cover art) do not survive, and until this fix that drop was
# silent at run time (documented in references/known-limits.md, but the log
# said nothing — house rule 5 says every DROP is a WARN). One demux-cheap
# probe; the WARN prints in --print-plan too (mov.sh's dual branch surfaces
# '** WARN' plan lines). MOV can carry some of these by hand (c608 captions
# via -map 0:s -c:s copy; another program via -map 0:p:N first) — manual,
# operator-invoked routes, never automatic.
# NOTE ffprobe csv orders fields by ITS canonical section order regardless of
# the request order: index,codec_name,codec_type — $2 is the NAME, $3 the TYPE.
OTHERS=$(ffp -v error -show_entries stream=index,codec_type,codec_name -of csv=p=0 "$IN" 2>/dev/null | \
  awk -F, 'NF{ if(seen[$1]++) next                       # TS double-listing dedupe
      if($3=="video"){ v++; if(v>1) print $1"|"$3"|"$2 }
      else if($3!="audio") print $1"|"$3"|"$2 }' || true)
UNMAPPED=0
if [ -n "$OTHERS" ]; then
  while IFS='|' read -r oidx otype ocodec; do
    [ -n "$oidx" ] || continue
    UNMAPPED=$((UNMAPPED+1))
    echo "** WARN DROP stream #$oidx ($otype ${ocodec:-unknown}) — not mapped: only v:0 + kept audio survive this route"
  done <<EOF
$OTHERS
EOF
  echo "   (subtitle/caption/data carriage into MOV is a manual step — see references/"
  echo "    known-limits.md; another program's video: isolate it first with -map 0:p:N)"
fi
echo "RMX_PLAN policy=$KEEP kept=${KEPT:-none} dropped=${DROPPED:-none} unmapped=$UNMAPPED"   # machine-readable (unmapped= additive, 1.11 fix round)
[ "$PLANONLY" -eq 1 ] && exit 0

# --- per-track audio handling: auto decides per KEPT track (WO 3.2) ---------
# The disposition comes from track_disp above — the same call that stamped
# disp= on the RMX_T rows — so the mux does exactly what the manifest said.
# Every auto conversion is a WARN (house rule 5: the original bitstream is
# not preserved, and nobody chose that silently); a forced mode announces
# itself as forced (the human already chose).
AARGS=(); outi=0; DRCDEC=0
if [ -n "$KEPT" ]; then
  for ord in $(printf '%s' "$KEPT" | tr ',' ' '); do
    codec=$(printf '%s\n' "$PLAN" | awk -F'|' -v o="$ord" '$1==o{print $2; exit}')
    # unroutable audio (1.11 fix round): a KEPT Dolby E track refuses here just
    # like mov.sh's front door — its "PCM treatment" is full-scale noise, not a
    # render. Policy-aware by construction: a keep-list that excludes the
    # track already WARNed the drop above and never reaches this arm.
    if unroutable_a "$codec"; then
      unroutable_a_refuse "$ord"
      exit 11
    fi
    AARGS=(${AARGS[@]+"${AARGS[@]}"} -map "0:a:$ord")
    if [ "$(track_disp "$codec")" = copy ]; then
      AARGS=(${AARGS[@]+"${AARGS[@]}"} "-c:a:$outi" copy)
      case "$AUDIO" in
        copy) echo "audio a:$ord: $codec -> copy (forced)";;
        *)    echo "audio a:$ord: $codec -> copy (QuickTime-native)";;
      esac
    else
      AARGS=(${AARGS[@]+"${AARGS[@]}"} "-c:a:$outi" pcm_s16le)
      case "$AUDIO" in
        pcm) echo "audio a:$ord: $codec -> PCM (forced)";;
        *)   echo "** WARN audio a:$ord: $codec -> PCM access ($(pcm_why "$codec"))";;
      esac
      # depth honesty (1.11 fix round; a review-named known limitation): the
      # access track here is pcm_s16le, so a source whose decoder-native format
      # is >16-bit integer (pcm_bluray/pcm_dvd at s32 — 24-bit LPCM in a
      # 32-bit fmt) loses real bit depth, and until this fix it lost it
      # SILENTLY as to depth. Announce it (house rule 5). Depth-aware access
      # encoding on this path is a recorded 1.12 candidate; today the
      # depth-true access build is dual-track.sh --pcm auto (where the class
      # allows a preserved original) or a manual -c:a pcm_s24le remux.
      sfmt=$(ffp -v error -select_streams "a:$ord" -show_entries stream=sample_fmt -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
      case "$sfmt" in
        s32|s32p|s64|s64p)
          echo "** WARN audio a:$ord: decoder-native format '$sfmt' exceeds 16-bit — the PCM"
          echo "        access track is pcm_s16le, so bit DEPTH IS REDUCED (see references/"
          echo "        known-limits.md; depth-true route: dual-track.sh --pcm auto, or a"
          echo "        manual -c:a pcm_s24le remux)";;
      esac
      # a KEPT ac3/eac3 track is about to be DECODED -> the DRC choice is live
      case "$codec" in ac3|eac3) DRCDEC=1;; esac
    fi
    outi=$((outi+1))
  done
fi

# --- DRC on the decode path (WO 3.7, entry 1 open question) -----------------
# ffmpeg's AC-3/E-AC-3 decoder applies drc_scale=1.0 by DEFAULT, baking
# broadcast dynamic-range compression into the decoded samples — audible on a
# concert mix. dual-track.sh already ships the audiophile default (--drc auto
# = -drc_scale 0, full dynamic range); this is the same rule on remux.sh's
# decode path, so the two builders can no longer disagree about the samples.
# NOTE pre-1.11 builds decoded at 1.0 — default PCM output differs from 1.10
# on DRC-carrying sources (that is the fix, not a drift). The flag is a
# DECODER input option, set only when a kept ac3/eac3 track actually decodes
# to PCM: never on a copy (nothing is decoded — and an unconsumed decoder
# option would just litter the mux log), never on a non-AC-3 decode (mp2/dts
# decoders have no drc_scale). The decision prints either way — house rule 5's
# spirit: no silent choices about what lands in the samples.
DRC=""
if [ "$DRCDEC" -eq 1 ]; then
  case "$DRCOPT" in
    auto|off) DRC="-drc_scale 0"
              echo "audio DRC: ac3/eac3 -> PCM decodes at -drc_scale 0 (full dynamic range; --drc on keeps broadcast DRC)";;
    on)       echo "audio DRC: broadcast DRC kept (--drc on: decoder default drc_scale=1.0)";;
  esac
fi

# --- video tag (HEVC needs hvc1 for QuickTime; vcodec probed at the gate above) ---
VTAG=""; [ "$vcodec" = hevc ] && VTAG="-tag:v hvc1"

# --- color: +write_colr is redundant on modern ffmpeg but harmless; include only if tagged ---
cp=$(ffp -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1 || true)
MOVFLAGS="+faststart"; { [ -n "$cp" ] && [ "$cp" != unknown ]; } && MOVFLAGS="+faststart+write_colr"

PART="${OUT}.part"; MUXLOG="$(mktemp)"
mux_once () {  # mux_once INPUT_OPT... — one attempt; only the probe window varies (WO 1.2)
  # $DRC sits BEFORE -i (WO 3.7): -drc_scale is a decoder option and must ride
  # the input side; after -i ffmpeg would reject it as an unknown output option
  # shellcheck disable=SC2086
  ffmpeg -nostdin -y -hide_banner -nostats $GENPTS $DRC "$@" -i "$IN" -map 0:v:0 \
    ${AARGS[@]+"${AARGS[@]}"} \
    -c:v copy $VTAG \
    ${TSCALE:+-video_track_timescale "$TSCALE"} \
    -movflags "$MOVFLAGS" -f mov \
    "$PART" 2>"$MUXLOG"
}
if ! mux_once "${FF_INPUT_OPTS[@]}"; then
  # A probe-shaped failure means the window undershot the stream's parameter
  # sets, not that the mux itself is defective -> retry ONCE at 1G (lib-paff.sh,
  # WO 1.2). Any other failure fails now, and a second miss fails too — the
  # retry never masks a genuinely different error (exit-code contract: 1 FAIL).
  if probe_shaped_failure "$MUXLOG"; then
    probe_retry_notice
    if ! mux_once "${FF_RETRY_OPTS[@]}"; then
      echo ">> mux FAILED (after 1G retry):"; sed 's/^/   /' "$MUXLOG" | tail -8
      exit 1
    fi
  else
    echo ">> mux FAILED:"; sed 's/^/   /' "$MUXLOG" | tail -8
    exit 1
  fi
fi
[ -n "${RTM_MUX_LOG_APPEND:-}" ] && [ -f "$RTM_MUX_LOG_APPEND" ] && cat "$RTM_MUX_LOG_APPEND" >> "$MUXLOG"   # test hook
[ -s "$MUXLOG" ] && sed 's/^/   mux: /' "$MUXLOG" | tail -6
# HARD STOP (post-mortem 2026-07-25): "pts has no value" / "Timestamps are unset" /
# non-monotonic DTS in a COPY mux's log is the muxer announcing it INVENTED the
# timeline. The video bits can be perfect while the written timing is garbage —
# the shipped-broken files rendered thumbnails and passed the essence checks.
# Never bless such an output, regardless of what any later check says.
conf=$(mux_confessions "$MUXLOG")
if [ "${conf:-0}" -gt 0 ]; then
  echo ">> HARD STOP: the muxer logged $conf timeline confession(s):"
  grep -iE 'pts has no value|timestamps are unset|non-?monotonic dts' "$MUXLOG" | sort | uniq -c | sort -rn | head -4 | sed 's/^/   /'
  echo "   The muxer invented timing for packets the source never timestamped."
  echo "   NOT blessing the output (kept at $PART; log: $MUXLOG)."
  echo "   Run scripts/diagnose.sh \"$IN\" — half-timestamped PAFF routes to"
  echo "   scripts/pairfill-paff.sh; timestamp-free streams to scripts/rebuild-paff.sh."
  exit 1
fi
rm -f "$MUXLOG"
mv -f "$PART" "$OUT"
echo "wrote: $OUT"
echo "verify with: scripts/verify.sh \"$IN\" \"$OUT\""
