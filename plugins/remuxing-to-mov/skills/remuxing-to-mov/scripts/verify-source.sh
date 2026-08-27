#!/usr/bin/env bash
# verify-source.sh — prove a SAME-CONTAINER re-wrap or surgical cut kept every
# byte it claimed to keep, at demux cost only. The source-clinic counterpart of
# verify.sh (which is QTFF-shaped by design and FAILs legitimate non-MOV
# outputs at gate (d) — a documented known limit). This is the battery the
# feed.ts case file (2019-VMA cleanup, 2026-08-26) ran by hand:
#
#   (a) FILTERED-REFERENCE STREAMHASH: per-stream MD5 of the OUTPUT vs the
#       SOURCE demuxed through the IDENTICAL bsf filters. The filters define
#       the intended selection, so a *cut* is verified as rigorously as a
#       straight copy: hash equality proves the mux added, altered and
#       reordered nothing. No filters -> plain per-stream identity (stronger
#       than the .mov path can even claim — same muxer family, no reframing).
#       Covers video+audio streams; data/subtitle streams are count-compared
#       and announced, never hashed (streamhash on opaque data codecs is not a
#       measured technique on this bench).
#   (b) CENSUS ARITHMETIC: whole-file per-stream packet counts. The expected
#       output census is MEASURED, not trusted: with filters, a framecrc pass
#       of the source through the same filters counts the intended selection;
#       without filters the source census is the expectation. Output must
#       match exactly.
#   (c) HEAD/TAIL/DURATION: first output video packet reported (and required
#       keyframe-flagged when a video filter was given); whole-file DTS
#       monotonicity vs the source's own counts; format-duration arithmetic
#       (source - trim == output +/- RTM_SRCV_DUR_TOL). A bounded head decode
#       reports the first frames' PTS + mean luma (the picture-at-zero proof).
#   (d) NOTHING-UNEXPLAINED: every defect counter on the output is either
#       inherited (== source) or an announced consequence of the plan
#       (--expect-gaps-delta for the DTS hole a head cut leaves where the
#       dropped leading pictures sat). Introduced missing timestamps or DTS
#       rot = FAIL; unexplained gap/wrap/prekey growth = REVIEW.
#
# Usage: scripts/verify-source.sh SOURCE OUTPUT
#          [--filter-v EXPR]        video bsf the cut applied (e.g. the
#                                   noise=drop=... expression, verbatim)
#          [--filter-a EXPR]        audio bsf the cut applied (all audio streams)
#          [--trim-head SECS]       intended duration removed from the head
#          [--expect-vdrop N]       cross-pin: video packets dropped must == N
#          [--expect-adrop N]       cross-pin: EVERY audio stream must drop N
#          [--expect-gaps-delta N]  explained forward-gap growth (default 0)
#          [--src-tsh FILE]         reuse a saved `ts-health.sh SRC --kv` output
#                                   (skips re-scanning a source already scanned)
# Cost: demux-only passes — streamhash src+out, framecrc src (filtered runs
# only), packet scan src+out, ts-health out (+src unless --src-tsh). All
# I/O-bound, background-able; nothing decodes except the bounded head probe.
# The filtered passes run under -copyts so absolute-PTS drop expressions bind
# to the same values the cut invocation saw (the case-file determinism rule).
#
# Exit (house contract): 0 DONE | 10 REVIEW | 1 FAIL | 2 usage.
# Machine line (stable API — extend only):
#   SRCV_SUMMARY verdict=ok|review|fail hash=match|mismatch v_src= v_out=
#     v_drop= a_drop=<csv|none> dur_delta= gaps_src= gaps_out= trim= notes=<n>
# Tunables: RTM_SRCV_DUR_TOL (duration tolerance secs, default 1.5).
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap: no stray code escapes
SRC="${1:?usage: verify-source.sh SOURCE OUTPUT [--filter-v EXPR] [--filter-a EXPR] [--trim-head SECS] ...}"
OUT="${2:?need OUTPUT}"; shift 2
FV=""; FA=""; TRIM=0; EXP_VDROP=""; EXP_ADROP=""; EXP_GAPS_D=0; SRC_TSH=""
while [ $# -gt 0 ]; do case "$1" in
  --filter-v) FV="${2:?--filter-v needs EXPR}"; shift 2;;
  --filter-a) FA="${2:?--filter-a needs EXPR}"; shift 2;;
  --trim-head) TRIM="${2:?--trim-head needs SECS}"; shift 2;;
  --expect-vdrop) EXP_VDROP="${2:?--expect-vdrop needs N}"; shift 2;;
  --expect-adrop) EXP_ADROP="${2:?--expect-adrop needs N}"; shift 2;;
  --expect-gaps-delta) EXP_GAPS_D="${2:?--expect-gaps-delta needs N}"; shift 2;;
  --src-tsh) SRC_TSH="${2:?--src-tsh needs FILE}"; shift 2;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
for f in "$SRC" "$OUT"; do [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }; done
[ "$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")" != "$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")" ] \
  || { echo "SOURCE and OUTPUT are the same file" >&2; exit 2; }
[ -z "$SRC_TSH" ] || [ -f "$SRC_TSH" ] || { echo "no such --src-tsh file: $SRC_TSH" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # only our own scratch; never the inputs

verdict=PASS; notes=0
downgrade () { # downgrade REVIEW|FAIL "reason"
  notes=$((notes+1))
  case "$1" in
    FAIL)   verdict=FAIL;;
    REVIEW) [ "$verdict" = FAIL ] || verdict=REVIEW;;
  esac
  echo "   ** $1: $2"
}

echo "== verify-source: $OUT vs $SRC =="

# --- container-family sanity ------------------------------------------------------
sfmt=$(ffp1 -v error -show_entries format=format_name -of default=nw=1:nk=1 "$SRC" 2>/dev/null)
ofmt=$(ffp1 -v error -show_entries format=format_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null)
case "$ofmt" in
  *mov*|*mp4*|*m4a*)
    echo "OUTPUT is MP4-family ($ofmt) — that is verify.sh territory (the QTFF gates)." >&2
    echo "This tool proves same-container re-wraps; run: scripts/verify.sh SOURCE OUTPUT" >&2
    exit 2;;
esac
if [ "$sfmt" != "$ofmt" ]; then
  echo "   note: container names differ (src=$sfmt out=$ofmt) — same-family siblings expected;"
  echo "         proceeding, but a family change belongs to the remux ladder, not the clinic."
fi

# filters need the noise bsf (feature-gate, doctor-style: refuse up front, not mid-run)
if [ -n "$FV$FA" ]; then
  BSFS=$(ffmpeg -hide_banner -bsfs 2>/dev/null || true)
  grep -qw noise <<<"$BSFS" || { echo "this ffmpeg lacks the 'noise' bitstream filter (needed to replay the cut's selection)" >&2; exit 2; }
fi

# --- stream maps: class-ordinal translation (index -> v0,v1,...,a0,a1,...) --------
# Output stream order after a re-wrap follows the source, but raw indexes can
# renumber; classes make the comparison positional and honest.
smap () { # smap FILE -> lines "idx class"
  ffp -v error -show_entries stream=index,codec_type -of csv=p=0 "$1" 2>/dev/null | \
    awk -F, 'NF>=2{ if(seen[$1]++) next; print $1, $2 }'   # TS double-listing dedupe
}
smap "$SRC" > "$TMP/smap.src"; smap "$OUT" > "$TMP/smap.out"
NV_SRC=$(awk '$2=="video"{n++} END{print n+0}' "$TMP/smap.src")
NA_SRC=$(awk '$2=="audio"{n++} END{print n+0}' "$TMP/smap.src")
NO_SRC=$(awk '$2!="video"&&$2!="audio"{n++} END{print n+0}' "$TMP/smap.src")
NV_OUT=$(awk '$2=="video"{n++} END{print n+0}' "$TMP/smap.out")
NA_OUT=$(awk '$2=="audio"{n++} END{print n+0}' "$TMP/smap.out")
NO_OUT=$(awk '$2!="video"&&$2!="audio"{n++} END{print n+0}' "$TMP/smap.out")
echo "   streams: src v=$NV_SRC a=$NA_SRC other=$NO_SRC | out v=$NV_OUT a=$NA_OUT other=$NO_OUT"
[ "$NV_SRC" = "$NV_OUT" ] && [ "$NA_SRC" = "$NA_OUT" ] || downgrade FAIL "stream census: video/audio stream COUNT changed (a re-wrap carries every stream)"
[ "$NO_SRC" = "$NO_OUT" ] || downgrade REVIEW "data/subtitle stream count changed (src=$NO_SRC out=$NO_OUT) — count-compared only, see header"
[ "$NV_SRC" -ge 1 ] || { echo "no video stream in SOURCE" >&2; exit 2; }

# --- (a) filtered-reference streamhash (video+audio, demux only) ------------------
echo "-- (a) filtered-reference streamhash (demux only) --"
hash_va () { # hash_va FILE apply_filters(1|0) -> per-stream hash lines
  local f="$1" af="$2"; local args=()
  [ "$af" = 1 ] && [ -n "$FV" ] && args+=(-bsf:v "$FV")
  [ "$af" = 1 ] && [ -n "$FA" ] && args+=(-bsf:a "$FA")
  # -copyts on the reference pass: absolute-PTS drop expressions must bind to
  # the same raw values the cut invocation saw (case-file determinism rule)
  ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -copyts -i "$f" -map 0:v -map "0:a?" \
    -c copy ${args[@]+"${args[@]}"} -f streamhash -hash md5 - 2>/dev/null || true
}
sh_src=$(hash_va "$SRC" 1); sh_out=$(hash_va "$OUT" 0)
if [ -z "$sh_src" ] || [ -z "$sh_out" ]; then
  downgrade FAIL "streamhash pass produced no output (src=$([ -n "$sh_src" ] && echo ok || echo empty) out=$([ -n "$sh_out" ] && echo ok || echo empty))"
  HASH=mismatch
elif [ "$sh_src" = "$sh_out" ]; then
  n_h=$(printf '%s\n' "$sh_out" | grep -c .)
  echo "   MATCH: $n_h stream hash(es) identical — every kept byte proven, selection exact."
  HASH=match
else
  # diff exits 1 on a difference — that is the datum, not a failure; without
  # the guard the ERR trap kills the run before the verdict prints (measured)
  echo "   MISMATCH:"; { diff <(printf '%s\n' "$sh_src") <(printf '%s\n' "$sh_out") || true; } | sed 's/^/     /' | head -12
  downgrade FAIL "streamhash mismatch — the output is NOT the intended selection of the source"
  HASH=mismatch
fi

# --- (b) census arithmetic --------------------------------------------------------
echo "-- (b) census arithmetic (whole-file packet scan) --"
# per-file scan: class-ordinal packet counts + video timeline counters
scan () { # scan FILE SMAP -> KV on stdout (P_* + CNT=<class-ordinal csv "v0=N a0=N ...">)
  local f="$1" m="$2" vidx
  vidx=$(awk '$2=="video"{print $1; exit}' "$m")
  ffp -v error -show_entries packet=stream_index,pts,dts,flags -of csv=p=0 "$f" 2>/dev/null | \
  awk -F, -v vidx="$vidx" -v mapf="$m" '
    BEGIN{ while((getline line < mapf)>0){ split(line,a," "); cls[a[1]]=a[2] } }
    NF{
      idx=$1; pts=$2; dts=$3; fl=$4
      cnt[idx]++
      if(idx==vidx){
        vn++
        if(pts=="N/A"||pts=="") vnap++
        if(dts=="N/A"||dts==""){ vnad++ } else {
          t=dts+0
          if(hav){ d=t-pd
            if(d<-4294967296){ wrap++ } else if(d<0){ back++ } else if(d==0){ dup++ } }
          pd=t; hav=1
        }
        if(index(fl,"K") && fk==0) fk=vn
      }
    }
    END{
      # one KV per line: the caller prefixes every line (S_/O_) before eval
      printf "P_VN=%d\nP_NAPTS=%d\nP_NADTS=%d\nP_BACK=%d\nP_DUP=%d\nP_WRAP=%d\nP_PREKEY=%d\n", \
        vn+0, vnap+0, vnad+0, back+0, dup+0, wrap+0, (fk?fk-1:vn)+0
      for(i in cnt){ c=cls[i]; if(c=="video") vo[++nv2]=i; else if(c=="audio") ao[++na2]=i; else oo[++no2]=i }
      # ordinals follow ascending index inside each class (insertion order is
      # not guaranteed by awk for-in — sort the small arrays)
      for(x=1;x<=nv2;x++) for(y=x+1;y<=nv2;y++) if(vo[y]+0<vo[x]+0){t=vo[x];vo[x]=vo[y];vo[y]=t}
      for(x=1;x<=na2;x++) for(y=x+1;y<=na2;y++) if(ao[y]+0<ao[x]+0){t=ao[x];ao[x]=ao[y];ao[y]=t}
      s=""
      for(x=1;x<=nv2;x++) s = s (s==""?"":" ") "v" (x-1) "=" cnt[vo[x]]
      for(x=1;x<=na2;x++) s = s (s==""?"":" ") "a" (x-1) "=" cnt[ao[x]]
      for(x=1;x<=no2;x++) s = s (s==""?"":" ") "o" (x-1) "=" cnt[oo[x]]
      printf "CNT=\"%s\"\n", s
    }'
}
scan "$SRC" "$TMP/smap.src" > "$TMP/scan.src"; scan "$OUT" "$TMP/smap.out" > "$TMP/scan.out"
eval "$(sed 's/^/S_/' "$TMP/scan.src")"   # S_P_VN, S_CNT, ...
eval "$(sed 's/^/O_/' "$TMP/scan.out")"   # O_P_VN, O_CNT, ...

# expected census: measured from the filtered selection, or == source
if [ -n "$FV$FA" ]; then
  fcargs=()
  [ -n "$FV" ] && fcargs+=(-bsf:v "$FV")
  [ -n "$FA" ] && fcargs+=(-bsf:a "$FA")
  ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -copyts -i "$SRC" -map 0:v -map "0:a?" \
    -c copy "${fcargs[@]}" -f framecrc - 2>/dev/null | \
    awk -F', *' '!/^#/ && NF{ cnt[$1]++ }
      END{ s=""; for(i=0;i<100;i++) if(i in cnt) s = s (s==""?"":" ") "m" i "=" cnt[i]
           printf "E_CNT=\"%s\"\n", s }' > "$TMP/exp.kv"
  eval "$(cat "$TMP/exp.kv")"
  # framecrc mapped v-then-a: mapped ordinal m<i> = v0..v(NV-1), then a0..
  EXPECTED=$(awk -v nv="$NV_SRC" -v ec="$E_CNT" 'BEGIN{
    n=split(ec, kv, " ")
    for(i=1;i<=n;i++){ split(kv[i],p,"="); mi=substr(p[1],2)+0
      if(mi<nv) printf "%sv%d=%s", (out++?" ":""), mi, p[2]
      else      printf "%sa%d=%s", (out++?" ":""), mi-nv, p[2] } }')
  echo "   expected census MEASURED from the filtered source selection (framecrc pass)"
else
  EXPECTED=$(printf '%s' "$S_CNT" | tr ' ' '\n' | grep -v '^o' | paste -sd' ' - || true)
fi
O_CNT_VA=$(printf '%s' "$O_CNT" | tr ' ' '\n' | grep -v '^o' | paste -sd' ' - || true)
echo "   source:   $S_CNT"
echo "   expected: ${EXPECTED:-<none>}"
echo "   output:   $O_CNT"
if [ "$O_CNT_VA" != "$EXPECTED" ]; then
  downgrade FAIL "census mismatch: output v/a packet counts differ from the measured expectation"
fi
# data/subtitle streams: direct src-vs-out count compare (never filtered)
S_O=$(printf '%s' "$S_CNT" | tr ' ' '\n' | grep '^o' | paste -sd' ' - || true)
O_O=$(printf '%s' "$O_CNT" | tr ' ' '\n' | grep '^o' | paste -sd' ' - || true)
[ "$S_O" = "$O_O" ] || downgrade REVIEW "data/subtitle packet counts changed (src: ${S_O:-none} | out: ${O_O:-none})"
# drops, for the report + optional cross-pins
V_DROP=$((S_P_VN - O_P_VN))
A_DROPS=$(awk -v s="$S_CNT" -v o="$O_CNT" 'BEGIN{
  n=split(s,sk," "); m=split(o,ok," ")
  for(i=1;i<=n;i++){ split(sk[i],p,"="); sc[p[1]]=p[2] }
  for(i=1;i<=m;i++){ split(ok[i],p,"="); oc[p[1]]=p[2] }
  out=""
  for(i=0;i<100;i++){ k="a" i; if(k in sc) out = out (out==""?"":",") sc[k]-oc[k] }
  print (out==""?"none":out) }')
echo "   drops: video=$V_DROP audio=$A_DROPS"
if [ -n "$EXP_VDROP" ] && [ "$V_DROP" != "$EXP_VDROP" ]; then
  downgrade FAIL "video drop count $V_DROP != planned $EXP_VDROP"
fi
if [ -n "$EXP_ADROP" ] && [ "$A_DROPS" != none ]; then
  bad=$(printf '%s' "$A_DROPS" | tr ',' '\n' | grep -cv "^${EXP_ADROP}\$" || true)
  [ "${bad:-0}" -eq 0 ] || downgrade FAIL "audio drops ($A_DROPS) != planned $EXP_ADROP per stream"
fi

# --- (d) nothing-unexplained: defect counters, inherited or announced -------------
echo "-- (d) defect counters: inherited or explained (ts-health both sides) --"
set +e; O_TSH=$(bash "$SELF_DIR/ts-health.sh" "$OUT" --kv 2>/dev/null); set -e
if [ -z "$O_TSH" ]; then downgrade FAIL "ts-health could not scan the OUTPUT"; fi
s_thrc=0
if [ -n "$SRC_TSH" ]; then S_TSH=$(cat "$SRC_TSH")
else set +e; S_TSH=$(bash "$SELF_DIR/ts-health.sh" "$SRC" --kv 2>/dev/null); s_thrc=$?; set -e; fi
# EMPTY ≠ ABSENT (CHECKUP-2026-08-27 C2 / WO-1.15.4): the SOURCE baseline was
# never validated — an empty/failed scan (or an empty --src-tsh file) made
# every ${s_*:-0} read 0 and this gate accused "backward DTS INTRODUCED
# (0 -> N)" on a byte-identical copy (measured). No baseline means the
# inherited-vs-introduced attribution is UNPROVEN: one announced REVIEW, and
# the four comparisons that need the s_* counters are skipped, never guessed.
S_BASE=ok
printf '%s\n' "$S_TSH" | grep -q '^TSH_VERDICT=' || S_BASE=missing
if [ "$S_BASE" = missing ]; then
  downgrade REVIEW "no source ts-health baseline (scan rc=$s_thrc${SRC_TSH:+; --src-tsh file invalid}) — inherited-vs-introduced attribution UNPROVEN for gaps/rot/wrap; the output's own counters print unattributed below"
fi
tsv () { printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1; }
o_scr=$(tsv TSH_SCRAMBLED "$O_TSH"); s_gaps=$(tsv TSH_GAPS "$S_TSH"); o_gaps=$(tsv TSH_GAPS "$O_TSH")
s_back=$(tsv TSH_BACK "$S_TSH");    o_back=$(tsv TSH_BACK "$O_TSH")
s_dup=$(tsv TSH_DUP "$S_TSH");      o_dup=$(tsv TSH_DUP "$O_TSH")
s_wrap=$(tsv TSH_WRAP "$S_TSH");    o_wrap=$(tsv TSH_WRAP "$O_TSH")
echo "   src: gaps=${s_gaps:-?} back=${s_back:-?} dup=${s_dup:-?} wrap=${s_wrap:-?} napts=$S_P_NAPTS nadts=$S_P_NADTS prekey=$S_P_PREKEY"
echo "   out: gaps=${o_gaps:-?} back=${o_back:-?} dup=${o_dup:-?} wrap=${o_wrap:-?} napts=$O_P_NAPTS nadts=$O_P_NADTS prekey=$O_P_PREKEY scrambled=${o_scr:-?}"
[ "${o_scr:-0}" -eq 0 ] || downgrade FAIL "OUTPUT reads scrambled"
[ "$O_P_NAPTS" -le "$S_P_NAPTS" ] || downgrade FAIL "missing PTS INTRODUCED ($S_P_NAPTS -> $O_P_NAPTS) — the re-wrap lost timestamps"
[ "$O_P_NADTS" -le "$S_P_NADTS" ] || downgrade FAIL "missing DTS INTRODUCED ($S_P_NADTS -> $O_P_NADTS)"
if [ "$S_BASE" = ok ]; then
  [ "${o_back:-0}" -le "${s_back:-0}" ] || downgrade FAIL "backward DTS INTRODUCED (${s_back:-0} -> ${o_back:-0})"
  [ "${o_dup:-0}" -le "${s_dup:-0}" ] || downgrade FAIL "duplicate DTS INTRODUCED (${s_dup:-0} -> ${o_dup:-0})"
  allow_gaps=$(( ${s_gaps:-0} + EXP_GAPS_D ))
  if [ "${o_gaps:-0}" -gt "$allow_gaps" ]; then
    downgrade REVIEW "forward gaps grew beyond the plan (src=${s_gaps:-0} + explained $EXP_GAPS_D < out=${o_gaps:-0})"
  elif [ "${o_gaps:-0}" -gt 0 ]; then
    echo "   forward gaps on output: ${o_gaps:-0} — inherited/explained (src=${s_gaps:-0}, plan +$EXP_GAPS_D)"
  fi
  if [ "${o_wrap:-0}" -gt "${s_wrap:-0}" ]; then downgrade REVIEW "PTS wraparound count grew (${s_wrap:-0} -> ${o_wrap:-0})"
  elif [ "${o_wrap:-0}" -lt "${s_wrap:-0}" ]; then echo "   wraparounds ${s_wrap:-0} -> ${o_wrap:-0}: the demuxer unwrapped on read (expected on a re-wrap)"; fi
else
  echo "   (back/dup/gaps/wrap comparisons SKIPPED — no source baseline to difference against;"
  echo "    output shows back=${o_back:-?} dup=${o_dup:-?} gaps=${o_gaps:-?} wrap=${o_wrap:-?}, unattributed)"
fi
[ "$O_P_PREKEY" -le "$S_P_PREKEY" ] || downgrade REVIEW "pre-keyframe packets grew ($S_P_PREKEY -> $O_P_PREKEY)"

# --- (c) head / duration ----------------------------------------------------------
echo "-- (c) head + duration --"
eval "$(ffp -v error -select_streams v:0 -read_intervals '%+#1' \
          -show_entries packet=pts_time,flags -of csv=p=0 "$OUT" 2>/dev/null | \
        awk -F, 'NR==1{printf "h_pts=%s h_key=%d\n", $1, (index($2,"K")>0)} END{if(NR==0) print "h_pts=na h_key=0"}')"
echo "   first output video packet: pts=${h_pts:-na} key=$h_key"
if [ -n "$FV" ] && [ "$h_key" -ne 1 ]; then
  downgrade REVIEW "a video cut should land on the selected keyframe; first packet is not keyframe-flagged"
fi
# bounded head decode: first frames' PTS + mean luma (the picture-at-zero proof;
# report-only — the cut script owns its own strict first-AU gate)
headluma=$(ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$OUT" -map 0:v:0 -frames:v 8 \
  -vf signalstats,metadata=print:file=- -f null - 2>/dev/null | \
  awk -F'[:= ]+' '/pts_time/{t=$NF} /YAVG/{printf "%s%s@%.0f", (n++?" ":""), t, $NF}' || true)
echo "   head decode (pts@luma-mean): ${headluma:-<no frames decoded>}"
[ -n "$headluma" ] || downgrade REVIEW "head decode produced no frames"
sdur=$(ffp1 -v error -show_entries format=duration -of default=nw=1:nk=1 "$SRC" 2>/dev/null)
odur=$(ffp1 -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" 2>/dev/null)
DUR_DELTA=na
if [ -n "$sdur" ] && [ "$sdur" != N/A ] && [ -n "$odur" ] && [ "$odur" != N/A ]; then
  DUR_DELTA=$(awk "BEGIN{printf \"%.3f\", ($odur) - (($sdur) - ($TRIM))}")
  echo "   duration: out=${odur}s vs source ${sdur}s - trim ${TRIM}s (delta ${DUR_DELTA}s, tol ${RTM_SRCV_DUR_TOL:-1.5}s)"
  awk "BEGIN{d=($DUR_DELTA); if(d<0)d=-d; exit !(d<=${RTM_SRCV_DUR_TOL:-1.5})}" || \
    downgrade FAIL "duration arithmetic breached (source - trim != output within tolerance)"
else
  echo "   duration: not comparable (src=${sdur:-?} out=${odur:-?}) — container reports none"
fi

# --- verdict ----------------------------------------------------------------------
case "$verdict" in
  PASS)   V=ok;     rc=0;  echo ">> OK: same-container output proven — selection exact, census reconciled, nothing unexplained.";;
  REVIEW) V=review; rc=10; echo ">> REVIEW: kept bytes proven where hashes matched, but $notes note(s) above want a human look.";;
  FAIL)   V=fail;   rc=1;  echo ">> FAIL: the output does not match its plan ($notes note(s) above). Do not bless it.";;
esac
echo "SRCV_SUMMARY verdict=$V hash=${HASH:-na} v_src=$S_P_VN v_out=$O_P_VN v_drop=$V_DROP a_drop=$A_DROPS dur_delta=$DUR_DELTA gaps_src=${s_gaps:-na} gaps_out=${o_gaps:-na} trim=$TRIM notes=$notes"
exit "$rc"
