#!/usr/bin/env bash
# derive-dts.sh — Rung 3-DERIVE: derive a clean DTS column for a reordered,
# PTS-complete video stream whose container carries no DTS worth believing.
#
# The stream class (proven on the real incident, 2026-08: the 54.6 GB 2023 VMA
# capture): reordered H.264/HEVC — ordinary interlaced broadcast included — in
# a container that stores NO DTS (Matroska: one timestamp per block; raw ES:
# none at all). ffmpeg reconstructs DTS there from has_b_frames, a FRAME-unit
# count applied as a PACKET delay — short by exactly 2x on field-coded (PAFF)
# packets — and the MOV muxer then writes that broken reconstruction into
# stts/ctts: bits perfect, timeline garbage (163,859 non-monotonic DTS events
# out of nothing). pairfill-paff.sh refuses this class (nothing is
# half-timestamped) and rebuild-paff.sh refuses it by design (a constant-rate
# restamp would play a reorder pyramid in decode order). This rung is the
# missing repair: the DTS column is fully DERIVABLE from the PTS column alone.
#
#   D      = max(i - rank(pts[i]))  over the WHOLE file (windowed D is
#            advisory; underestimating D is the one unsafe direction)
#   DTS[i] = (i-D)-th smallest PTS; pre-roll spaced at the MODAL sorted-PTS
#            delta (the coded-picture duration — never 1 tick)
#
# Depth OVERESTIMATION is safe by construction (D' >= actual keeps DTS
# monotonic and <= PTS — sorted order guarantees both; proof in derive-dts.py's
# header, asserted again at runtime). Video bits are copied byte-for-byte
# (codec-agnostic — PyAV copies packets untouched, so mpeg2video/HEVC ride the
# same rung); every other stream is carried with the same wall-clock shift, so
# A/V sync is exact. Chapters are re-attached by THIS script (PyAV cannot
# write them): repair -> chapters -> gates, so the judged artifact is the
# deliverable. Source never touched; output atomic (.part -> mv).
#
# DEPENDENCY (advisory-before-automatic — never auto-installed): PyAV in a
# plugin-owned venv under ${CLAUDE_PLUGIN_DATA}, the documented persistent
# home for plugin dependencies. MEASUREMENT NOTE (WO 1.14 Phase-3 pre-check,
# 2026-08-16): CLAUDE_PLUGIN_DATA was not observed set in this bench's live
# runtime, so the script resolves the documented fallback
# ~/.claude/plugins/data/remuxing-to-mov explicitly when the variable is
# absent — record differs, re-measure on the next live plugin runtime.
#
# Usage: scripts/derive-dts.sh INPUT OUTPUT.mov [--force] [--limit N]
#   --force   proceed past the depth-class signature gate (announced). Needed
#             when PF_DEPTH_CLASS is match-frame/none/unknown — i.e. when the
#             measured evidence does NOT establish that ffmpeg's reconstruction
#             is short. unknown (unparseable SPS) especially must never be
#             restamped blind by default.
#   --limit N bench mode: derive/write only the first N video packets. The
#             partial artifact is kept as the .part file and NEVER blessed
#             (exit 10 REVIEW).
#
# Exit: 0 verified-clean; 1 built but an output gate failed; 2 usage; 3 stream
# does not match the derive signature (family consistency with pairfill/
# rebuild; suite-pinned); 10 REVIEW (PyAV venv absent, or --limit bench).
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
RTM_EXIT_OK="0 1 2 3 10 11" # + this script's documented pre-contract 3 (signature REFUSED; suite-pinned)
IN="${1:?usage: derive-dts.sh INPUT OUTPUT.mov [--force] [--limit N]}"
OUT="${2:?need OUTPUT.mov}"; shift 2
FORCE=0; LIMIT=""
while [ $# -gt 0 ]; do case "$1" in
  --force) FORCE=1; shift;;
  --limit) LIMIT="${2:?--limit needs a value}"; shift 2;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to overwrite the source in place" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-paff.sh"   # pf_reorder_scan (unit-aware depth), PF_SCAN_WINDOW, mux_confessions
. "$SELF_DIR/lib-mux.sh"    # rtm_part/rtm_sidecar (extension-keeping atomics), mux_census (D5)
. "$SELF_DIR/lib-attest.sh" # precond_attest: recorded operator override of a precondition
# NOTE: no backhaul_gate here, deliberately — its timeline-rot arm measures the
# DTS column, which on this rung's input class is the demuxer's broken
# reconstruction: the very defect being repaired would fire the warning.
# Gated callers (diagnose.sh/auto.sh, Phase 4) route into this rung on the
# measured profile instead.

echo "== derive-dts: $IN -> $OUT =="

# --- pre-flight 1 (announced): the dependency gate --------------------------
DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/remuxing-to-mov}"
VENV_PY="$DATA/venv/bin/python"
echo "-- pre-flight: PyAV venv ($DATA/venv) --"
if [ -x "$VENV_PY" ] && PYAV_VER=$("$VENV_PY" -c 'import av; print(av.__version__)' 2>/dev/null); then
  echo "   PyAV $PYAV_VER via $VENV_PY"
else
  echo ">> REVIEW: this rung needs PyAV and its venv is absent or broken."
  echo "   This is the plugin's only optional-dependency rung (Bento4-style, doctor.sh"
  echo "   reports it) and it NEVER auto-installs. One-line bootstrap:"
  echo "     python3 -m venv \"$DATA/venv\" && \"$DATA/venv/bin/pip\" install av"
  echo "   Manual recipe (no venv — the derivation itself, provable by hand):"
  echo "     1. dump the video PTS column:  ffprobe -select_streams v:0 \\"
  echo "          -show_entries packet=pts -of csv=p=0 INPUT"
  echo "     2. D = max(coded_index - presentation_rank) over that column;"
  echo "        DTS[i] = (i-D)-th smallest PTS, pre-roll spaced at the modal delta"
  echo "     3. write with any packet-level tool that copies bytes untouched"
  echo "        (scripts/derive-dts.py is the vendored, gate-checked version)"
  exit 10
fi

# --- pre-flight 2 (announced): windowed signature gates ----------------------
# Each is re-checked against the WHOLE file inside derive-dts.py before a byte
# is written; the window here fails fast and names the route. Test hook:
# PF_PKT_TICKS_FILE (the pf_reorder_scan hook) feeds the same injected column.
echo "-- signature gates (${PF_SCAN_WINDOW}-packet window; python re-checks the whole file) --"
dd_raw=$( if [ -n "${PF_PKT_TICKS_FILE:-}" ]; then cat "$PF_PKT_TICKS_FILE"; else
            ffp -v error -select_streams v:0 -read_intervals "%+#${PF_SCAN_WINDOW}" \
              -show_entries packet=pts,dts -of csv=p=0 "$IN" 2>/dev/null; fi )
eval "$(printf '%s\n' "$dd_raw" | awk -F, 'NF{
    n++
    if($1=="N/A"||$1==""){ na++; next }
    c[$1]++; if(c[$1]==2) dup++
  } END{ printf "DD_N=%d DD_NA=%d DD_DUP=%d\n", n+0, na+0, dup+0 }')"
echo "   packets=$DD_N  N/A-PTS=$DD_NA  duplicate-PTS values=$DD_DUP"
[ "${DD_N:-0}" -gt 0 ] || { echo "no video packets read" >&2; exit 3; }
if [ "${DD_NA:-1}" -ne 0 ]; then
  echo ">> SIGNATURE REFUSED: $DD_NA packet(s) with no PTS in the window — a PTS-complete"
  echo "   stream is the precondition (PF_NOPTS_FRAC must be 0.000). Packets with data but"
  echo "   no PTS are the half-timestamped PAFF class: scripts/pairfill-paff.sh."
  exit 3
fi
if [ "${DD_DUP:-1}" -ne 0 ]; then
  echo ">> SIGNATURE REFUSED: $DD_DUP duplicate PTS value(s) — the derivation assumes a"
  echo "   unique display timeline. Diagnose the duplication first (scripts/diagnose.sh)."
  exit 3
fi
eval "$(pf_reorder_scan "$IN")"
echo "   reorder=$PF_REORDER  depth=$PF_DEPTH_PICS pic(s) (window)  declared=$PF_DECL_DEPTH  ppf=$PF_PPF"
echo "   class=$PF_DEPTH_CLASS  dts_short=$PF_DTS_SHORT  dts_source=$PF_DTS_SOURCE"
if [ "$PF_REORDER" != yes ]; then
  echo ">> SIGNATURE REFUSED: no presentation reorder measured — there is no DTS to"
  echo "   derive that a plain copy (remux.sh) or constant-rate rebuild (rebuild-paff.sh)"
  echo "   would not already produce."
  exit 3
fi
DD_ATTESTED=""   # " attested=dd-depth-class" on a precond_attest override (appended to DERIVE_DTS)
case "$PF_DEPTH_CLASS" in
  match-field|understated)
    echo "   depth class $PF_DEPTH_CLASS: ffmpeg's frame-unit reconstruction is short on"
    echo "   this stream — the derive signature. Proceeding." ;;
  *)
    if [ "$PF_DTS_SHORT" = yes ]; then
      echo "   PF_DTS_SHORT=yes: measured depth exceeds the declared packet delay — the"
      echo "   routing discriminant holds even though the class reads $PF_DEPTH_CLASS. Proceeding."
    elif [ "$FORCE" -eq 1 ]; then
      echo "** FORCED past the depth-class gate (--force): class=$PF_DEPTH_CLASS."
      echo "**   The measurements do NOT establish a short reconstruction; the derivation"
      echo "**   is still lossless and DTS<=PTS by construction, but this is the human's call."
    elif precond_attest dd-depth-class derive-dts.sh "$OUT" \
           "PF_DEPTH_CLASS=$PF_DEPTH_CLASS" "PF_DEPTH_PICS=$PF_DEPTH_PICS" \
           "PF_DECL_DEPTH=$PF_DECL_DEPTH" "PF_PPF=$PF_PPF" "PF_DTS_SHORT=$PF_DTS_SHORT"; then
      # the sidecar-recorded flavor of --force (2026-08-18): same override, but
      # the operator's evidence claim lands in <OUT>.precond-waiver.txt and the
      # summary line carries attested= — every output gate below still runs.
      DD_ATTESTED=" attested=dd-depth-class"
    elif [ "$PF_DEPTH_CLASS" = unknown ]; then
      echo ">> SIGNATURE REFUSED: depth class unknown (declared depth='$PF_DECL_DEPTH',"
      echo "   ppf='$PF_PPF') — an unparseable SPS must not be restamped blind; a healthy"
      echo "   file would get a derived timeline on evidence that cannot support one."
      echo "   Diagnose first (scripts/diagnose.sh), or rerun with --force (announced)."
      precond_attest_route dd-depth-class derive-dts.sh
      exit 3
    else
      echo ">> SIGNATURE REFUSED: depth class $PF_DEPTH_CLASS — the declaration accounts"
      echo "   for the measured depth, so ffmpeg's own reconstruction is not provably short"
      echo "   here. If the container timeline is rotten anyway, rerun with --force."
      precond_attest_route dd-depth-class derive-dts.sh
      exit 3
    fi ;;
esac

# --- the repair (python writes an intermediate; extension kept — D6) ---------
trap 'rtm_unlock' EXIT   # writer-lock release however this run ends (WO-1.15.6 A2)
rtm_writer_preflight "$OUT" "$IN" || exit 2
PART="$(rtm_part "$OUT")"
NCHAP=$(ffp -v error -show_chapters -of csv "$IN" 2>/dev/null | grep -c '^chapter' || true)
case "$NCHAP" in ''|*[!0-9]*) NCHAP=0;; esac
PYOUT="$PART"
{ [ "$NCHAP" -gt 0 ] && [ -z "$LIMIT" ]; } && PYOUT="$(rtm_sidecar "$OUT" derive)"
echo "-- deriving (video bits copied untouched; DTS derived from the sorted PTS column) --"
LIMARGS=(); [ -n "$LIMIT" ] && LIMARGS=(--limit "$LIMIT")
set +e
py_out=$("$VENV_PY" "$SELF_DIR/derive-dts.py" "$IN" "$PYOUT" ${LIMARGS[@]+"${LIMARGS[@]}"} 2>&1); prc=$?
set -e
printf '%s\n' "$py_out" | sed 's/^/   /'
case "$prc" in
  0) : ;;
  3) echo ">> whole-file precondition REFUSED the derivation (see above)."; rm -f "$PYOUT"; exit 3;;
  10) exit 10;;
  *) echo ">> derivation FAILED (python exit $prc); partial output removed."; rm -f "$PYOUT"; exit 1;;
esac
dp_line=$(printf '%s\n' "$py_out" | grep '^DERIVE_PY ' | head -1)
DP_PACKETS=$(printf '%s\n' "$dp_line" | sed -n 's/.*packets=\([0-9][0-9]*\).*/\1/p')
DP_DEPTH=$(printf '%s\n' "$dp_line"   | sed -n 's/.*depth=\([0-9][0-9]*\).*/\1/p')
DP_SHIFT_MS=$(printf '%s\n' "$dp_line" | sed -n 's/.*shift_ms=\([0-9.]*\).*/\1/p')
PLAN_N=$(printf '%s\n' "$py_out" | sed -n 's/^DERIVE_PLAN n=\([0-9][0-9]*\).*/\1/p' | head -1)
PLAN_C=$(printf '%s\n' "$py_out" | sed -n 's/^DERIVE_PLAN n=[0-9]* codecs=\(.*\)$/\1/p' | head -1)
{ [ -n "$DP_PACKETS" ] && [ -n "$PLAN_N" ]; } || { echo ">> python summary lines missing — not blessing."; exit 1; }

if [ -n "$LIMIT" ]; then
  echo ">> REVIEW: --limit bench artifact kept at $PYOUT — partial by design, NOT blessed"
  echo "   (identity/census gates need the whole file; rerun without --limit to deliver)."
  echo "DERIVE_DTS depth=$DP_DEPTH shift_ms=$DP_SHIFT_MS packets=$DP_PACKETS census=skipped verdict=bench$DD_ATTESTED"
  exit 10
fi

# --- chapters: re-attached by the rung itself (incident deviation 3) ---------
CEN_N="$PLAN_N"; CEN_C="$PLAN_C"
if [ "$NCHAP" -gt 0 ]; then
  echo "-- re-attaching $NCHAP chapter(s) from the source (-map_chapters pass; PyAV cannot write them) --"
  MUXLOG="$(mktemp)"
  if ! ffmpeg -nostdin -y -hide_banner -nostats "${FF_INPUT_OPTS[@]}" -i "$PYOUT" -i "$IN" \
         -map 0 -map_chapters 1 -c copy -movflags +faststart -f mov "$PART" 2>"$MUXLOG"; then
    echo ">> chapter re-attach FAILED:"; sed 's/^/   /' "$MUXLOG" | tail -6
    echo "   derived (chapterless) intermediate kept at $PYOUT; mux log: $MUXLOG"; exit 1
  fi
  conf=$(mux_confessions "$MUXLOG")
  if [ "${conf:-0}" -gt 0 ]; then
    echo ">> HARD STOP: the chapter pass logged $conf timeline confession(s) — the muxer"
    echo "   invented timing on a stream this rung just derived. NOT blessing."
    grep -m4 -iE 'pts has no value|timestamps are unset|non-?monoton(ic|ous) dts|non monotonically increasing dts' "$MUXLOG" | sed 's/^/   /'
    echo "   Kept: $PART (log: $MUXLOG)"; exit 1
  fi
  rm -f "$MUXLOG" "$PYOUT"
  # movenc synthesizes the chapter track (text/bin_data by ffmpeg version) as
  # the LAST stream; this rung re-attached it on purpose, so it is IN the plan
  # ("?" — data-class slot, identity by codec varies by ffmpeg). Post-Phase-2
  # mux_census would also tolerate it as announced expected surplus; pre-Phase-2
  # equality works because the plan carries the slot explicitly.
  CEN_N=$((PLAN_N + 1)); CEN_C="$PLAN_C,?"
else
  echo "   chapters: none in the source (no re-attach pass owed)"
fi

# --- output gates (each announced; any breach: FAIL, nothing blessed) --------
echo "-- output gate 1/4: whole-file timeline (0 N/A, strictly monotonic DTS, DTS<=PTS) --"
eval "$(ffp -v error -select_streams v:0 -show_entries packet=pts,dts -of csv=p=0 "$PART" 2>/dev/null | \
  awk -F, 'NF{
      n++
      if($1=="N/A"||$1==""){ nap++ }
      if($2=="N/A"||$2==""){ nad++; next }
      d=$2+0
      if(havd){ if(d<pd) back++; else if(d==pd) dup++ }
      pd=d; havd=1
      if($1!="N/A" && $1!="" && d>$1+0) viol++
    } END{ printf "OG_N=%d OG_NAPTS=%d OG_NADTS=%d OG_BACK=%d OG_DUP=%d OG_VIOL=%d\n",
           n+0, nap+0, nad+0, back+0, dup+0, viol+0 }')"
echo "   packets=$OG_N  N/A-PTS=$OG_NAPTS  N/A-DTS=$OG_NADTS  backward-DTS=$OG_BACK  duplicate-DTS=$OG_DUP  DTS>PTS=$OG_VIOL"
echo "   (a negative head DTS is the standard container representation of the pre-roll"
echo "    after muxer edit-list normalization — monotonicity and DTS<=PTS are the claims)"
if [ "${OG_N:-0}" -ne "$DP_PACKETS" ] || [ "${OG_NAPTS:-1}" -ne 0 ] || [ "${OG_NADTS:-1}" -ne 0 ] \
   || [ "${OG_BACK:-1}" -ne 0 ] || [ "${OG_DUP:-1}" -ne 0 ] || [ "${OG_VIOL:-1}" -ne 0 ]; then
  echo ">> TIMELINE GATE FAILED — the written timeline is not the derived one."
  echo "   NOT blessing. Kept: $PART"; exit 1
fi

echo "-- output gate 2/4: PTS multiset identity vs source (offset-normalized) --"
# Muxers rescale time bases (1/1000 -> 1/16000 measured on this bench) and
# rebase the pre-roll shift into an edit list, so the comparison normalizes
# each side to microseconds relative to its own minimum PTS. The uniform shift
# is applied to ALL streams identically, so a global rebase cancels out of
# both the video identity and A/V sync.
pts_norm () {
  local tb; tb=$(ffp -v error -select_streams v:0 -show_entries stream=time_base -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1)
  ffp -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$1" 2>/dev/null | \
    awk -F, -v tb="$tb" 'BEGIN{ split(tb,a,"/"); if(a[2]+0==0){a[1]=1;a[2]=1} }
      NF && $1!="N/A" { v[++n]=$1+0; if(n==1||$1+0<mn) mn=$1+0 }
      END{ for(i=1;i<=n;i++) printf "%.0f\n", (v[i]-mn)*a[1]/a[2]*1000000 }' | LC_ALL=C sort -n
}
PN_S="$(mktemp)"; PN_O="$(mktemp)"
pts_norm "$IN"   > "$PN_S"
pts_norm "$PART" > "$PN_O"
if cmp -s "$PN_S" "$PN_O"; then
  echo "   PASS: sorted PTS multisets identical ($(grep -c . "$PN_S") values; every real"
  echo "   presentation instant preserved)"
  rm -f "$PN_S" "$PN_O"
else
  echo ">> PTS MULTISET GATE FAILED — the output does not present the source's timeline."
  diff "$PN_S" "$PN_O" | head -6 | sed 's/^/   /'
  rm -f "$PN_S" "$PN_O"
  echo "   NOT blessing. Kept: $PART"; exit 1
fi

echo "-- output gate 3/4: video packet-hash identity (verify gate (a) method) --"
phash () { ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$1" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null || true; }
sp=$(phash "$IN"); op=$(phash "$PART")
if [ -n "$sp" ] && [ "$sp" = "$op" ]; then
  echo "   PASS: video packets bit-identical (demux-only streamhash match)"
else
  echo ">> PACKET-HASH GATE FAILED — the copied bitstream is not identical."
  echo "     src=$sp"
  echo "     out=$op"
  echo "   NOT blessing. Kept: $PART"; exit 1
fi

echo "-- output gate 4/4: post-mux census (D5) --"
if ! mux_census "$PART" "$CEN_N" "$CEN_C" derive-dts; then
  echo "   NOT blessing the output. Kept: $PART"
  exit 1
fi

mv -f "$PART" "$OUT"
echo "wrote: $OUT"
echo "DERIVE_DTS depth=$DP_DEPTH shift_ms=$DP_SHIFT_MS packets=$DP_PACKETS census=ok verdict=ok$DD_ATTESTED"
echo "sign-off: scripts/verify.sh \"$IN\" \"$OUT\""
echo "  (these gates prove the container timeline and packet identity; verify.sh's scrub"
echo "   gate + A/V parity complete the archival proof set)"
