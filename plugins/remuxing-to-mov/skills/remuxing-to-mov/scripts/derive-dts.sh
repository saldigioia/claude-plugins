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
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-paff.sh"   # pf_reorder_scan (unit-aware depth), PF_SCAN_WINDOW, mux_confessions
. "$SELF_DIR/lib-mux.sh"    # rtm_part/rtm_sidecar (extension-keeping atomics), mux_census (D5)
rtm_sibling_guard "$IN" "$OUT" || exit 2   # TIER 1 T1.11 write beside the source, never onto it (one writer: lib-mux.sh)
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
# WO-1.15.21 B1: SCOPE THE NUMBER AT THE POINT OF PRINT. The header says
# "window"; the value line did not, and read as an absolute fact — on the 2024
# VMA capture it printed `duplicate-PTS values=0` while the whole-file truth
# was 10, and the refusal below is phrased as an absolute too. A windowed zero
# is "none in the window", never "none": the absence claim is the one a window
# is least entitled to make.
echo "   packets=$DD_N (in window)  N/A-PTS=$DD_NA (in window)  duplicate-PTS values=$DD_DUP (in window)"
[ "${DD_DUP:-0}" -ne 0 ] || echo "   note: 0 duplicate PTS IN THIS WINDOW is not 0 in the file — the whole-file census is scripts/diagnose.sh, and the python pass re-checks every packet before a byte is written."
[ "${DD_N:-0}" -gt 0 ] || { echo "no video packets read" >&2; exit 3; }   # TIER 1 instrumentation: nothing was read, so nothing is claimed
# WO-1.15.20 S0: MEASURE the timestamp profile here rather than read a global
# nothing in this script sets. The F9 routing branches on half_ts, and an unset
# PF_HALF_TS defaulted to `no` — so the "this IS the pairfill class" arm could
# never fire and every refusal asserted half_ts=no and nopts_frac=? as if they
# had been measured. These come from THIS script's own window scan; an
# exported value from a parent that already probed still wins, because that one
# is measured over the head window pf_coded_rate uses and is no worse.
DD_FRAC=$(awk "BEGIN{printf \"%.3f\", ${DD_NA:-0}/${DD_N}}")
DD_HALF_TS="${PF_HALF_TS:-$(pf_half_ts_frac "$DD_FRAC")}"
DD_NOPTS_FRAC="${PF_NOPTS_FRAC:-$DD_FRAC}"
echo "   timestamp profile (this window): nopts_frac=$DD_FRAC  half_ts=$DD_HALF_TS"
# WO-1.15.20 S2: an unstamped packet is no longer an automatic refusal here.
# When the window's unstamped fraction is inside the SPARSE band and the pair
# signature is absent, this is the isolated-hole class the python pre-pass
# reconstructs from pair-mate evidence — so the window PROCEEDS and the
# whole-file census decides. This window is a hint (PF_SCAN_WINDOW packets);
# refusing here on a hint would be the 1.15.2 Item-C shape in reverse: a
# foregone refusal of a file the authoritative pass would have repaired.
DD_SPARSE=0
if [ "${DD_NA:-1}" -ne 0 ] && [ "$DD_HALF_TS" != yes ] && [ "${DD_N:-0}" -gt 0 ]; then
  awk "BEGIN{exit !(${DD_NA}/${DD_N} <= ${RTM_SPARSE_NOPTS_MAX:-0.01}+0)}" && DD_SPARSE=1
fi
if [ "${DD_NA:-1}" -ne 0 ] && [ "$DD_SPARSE" -eq 1 ]; then
  echo "   $DD_NA of $DD_N windowed packet(s) carry data but no PTS — inside the sparse"
  echo "   band (bound ${RTM_SPARSE_NOPTS_MAX:-0.01}) with half_ts=$DD_HALF_TS: the isolated-hole class."
  echo "   Proceeding to the whole-file pre-pass, which stamps each hole from its"
  echo "   pair-mate or REFUSES the file — this window does not decide it."
elif [ "${DD_NA:-1}" -ne 0 ]; then
  echo ">> SIGNATURE REFUSED: $DD_NA packet(s) with no PTS in the window — a PTS-complete"
  echo "   stream is the precondition (PF_NOPTS_FRAC must be 0.000): this derivation indexes"
  echo "   the sorted PTS column, and an unstamped packet has no position in it."
  # F9 (2026-08-28): the route is CONDITIONAL. Sending every unstamped-packet
  # source to pairfill was circular for the half_ts=no class — pairfill's own
  # precondition is equally absent there, so the operator is handed a tool that
  # will spend a full pass and then fail its timeline gates (2024-VMA, 26.8 GB).
  if [ "$DD_HALF_TS" = yes ]; then
    echo "   half_ts=yes — this IS the half-timestamped PAFF class: scripts/pairfill-paff.sh"
    echo "   (it KEEPS the real PTS and fills each pair-mate)."
  else
    # WO-1.15.20 S2/S5: the pre-pass exists now, so the old "no rung composes
    # fill -> derive" claim is retired. What is left is the class the pre-pass
    # itself refuses: too many holes to be isolated, but too few to be the pair
    # signature — an empty band with no rung on either side of it.
    echo "   half_ts=$DD_HALF_TS (nopts_frac=$DD_NOPTS_FRAC) — this is NOT the pairfill"
    echo "   class either: pair-fill assumes ~half the packets unstamped and imposes a"
    echo "   pair-cadence DTS ramp a reorder pyramid violates. The sparse pre-pass (which"
    echo "   DOES compose 'stamp the isolated holes' -> 'derive DTS') is bounded at"
    echo "   ${RTM_SPARSE_NOPTS_MAX:-0.01} and $DD_NA of $DD_N windowed packets is past it. NO AUTOMATIC ROUTE:"
    echo "   diagnose first (scripts/diagnose.sh) and keep the source as the master."
  fi
  exit 3   # TIER 3 T3.4 unstamped-packet signature (whole file re-decides)
fi
if [ "${DD_DUP:-1}" -ne 0 ]; then
  # TIERS.md T3.5 — CONVERTED in 1.16.0. This used to refuse here, on a
  # WINDOWED count, for a condition the whole-file pass can now often settle:
  # where the bitstream states each picture's display position, the stale
  # holder of a shared rung is identifiable and movable from evidence (10 of
  # 10 on the capture that motivated this round). Refusing on the window
  # denied the file the pass that would have adjudicated it.
  echo "   $DD_DUP duplicate PTS value(s) in this window — NOT a refusal (T3.5):"
  echo "   the whole-file pass adjudicates each one from the bitstream's own display"
  echo "   positions and refuses only what the evidence cannot settle, naming it."
  echo "   Whole-file census (count, values, positions, and how many straddle an"
  echo "   unstamped run): scripts/diagnose.sh \"$IN\""
fi
eval "$(pf_reorder_scan "$IN")"
echo "   reorder=$PF_REORDER  depth=$PF_DEPTH_PICS pic(s) (window)  declared=$PF_DECL_DEPTH  ppf=$PF_PPF"
echo "   class=$PF_DEPTH_CLASS  dts_short=$PF_DTS_SHORT  dts_source=$PF_DTS_SOURCE"
if [ "$PF_REORDER" != yes ]; then
  echo ">> SIGNATURE REFUSED: no presentation reorder measured — there is no DTS to"
  echo "   derive that a plain copy (remux.sh) or constant-rate rebuild (rebuild-paff.sh)"
  echo "   would not already produce."
  exit 3   # TIER 3 routing: named routes, nothing is prevented
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
      exit 3   # TIER 3 routing: named routes + --force
    else
      echo ">> SIGNATURE REFUSED: depth class $PF_DEPTH_CLASS — the declaration accounts"
      echo "   for the measured depth, so ffmpeg's own reconstruction is not provably short"
      echo "   here. If the container timeline is rotten anyway, rerun with --force."
      precond_attest_route dd-depth-class derive-dts.sh
      exit 3   # TIER 3 routing: named routes + --force
    fi ;;
esac

# --- the repair (python writes an intermediate; extension kept — D6) ---------
trap 'rtm_unlock' EXIT   # writer-lock release however this run ends (WO-1.15.6 A2)
rtm_writer_preflight "$OUT" "$IN" || exit 2   # TIER 1 T1.5/T1.6 one writer + disk pre-flight
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
  3) echo ">> whole-file precondition REFUSED the derivation (see above)."; rm -f "$PYOUT"; exit 3;;   # TIER 3 T3.4/T3.5 relay of the whole-file refusal
  10) exit 10;;
  *) echo ">> derivation FAILED (python exit $prc); partial output removed."; rm -f "$PYOUT"; exit 1;;
esac
dp_line=$(printf '%s\n' "$py_out" | grep '^DERIVE_PY ' | head -1)
DP_PACKETS=$(printf '%s\n' "$dp_line" | sed -n 's/.*packets=\([0-9][0-9]*\).*/\1/p')
DP_DEPTH=$(printf '%s\n' "$dp_line"   | sed -n 's/.*depth=\([0-9][0-9]*\).*/\1/p')
DP_SHIFT_MS=$(printf '%s\n' "$dp_line" | sed -n 's/.*shift_ms=\([0-9.]*\).*/\1/p')
# WO-1.15.20 S2: how many of those PTS are RECONSTRUCTIONS rather than carried
# timestamps. Rides every DERIVE_DTS row so the artifact's provenance records
# it; absent from an older python (or a bench build) reads 0, never blank.
DP_STAMPED=$(printf '%s\n' "$dp_line" | sed -n 's/.*stamped=\([0-9][0-9]*\).*/\1/p')
case "$DP_STAMPED" in ''|*[!0-9]*) DP_STAMPED=0;; esac
PLAN_N=$(printf '%s\n' "$py_out" | sed -n 's/^DERIVE_PLAN n=\([0-9][0-9]*\).*/\1/p' | head -1)
PLAN_C=$(printf '%s\n' "$py_out" | sed -n 's/^DERIVE_PLAN n=[0-9]* codecs=\(.*\)$/\1/p' | head -1)
{ [ -n "$DP_PACKETS" ] && [ -n "$PLAN_N" ]; } || { echo ">> python summary lines missing — not blessing."; exit 1; }

if [ -n "$LIMIT" ]; then
  echo ">> REVIEW: --limit bench artifact kept at $PYOUT — partial by design, NOT blessed"
  echo "   (identity/census gates need the whole file; rerun without --limit to deliver)."
  echo "DERIVE_DTS depth=$DP_DEPTH shift_ms=$DP_SHIFT_MS packets=$DP_PACKETS census=skipped stamped=$DP_STAMPED verdict=bench$DD_ATTESTED"
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
    grep -m4 -iE "$RTM_CONFESSION_RE" "$MUXLOG" | sed 's/^/   /'
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
# WO-1.15.20 S2: the source side is its carried PTS PLUS the values the sparse
# pre-pass reconstructed. The output legitimately presents instants the source
# had no timestamp for — that is the whole repair — so this gate is told
# exactly WHICH extra values to expect (the DERIVE_STAMP rows, one per
# reconstruction) rather than loosened to tolerate any surplus. A build that
# invents one more PTS than it declared still fails here, and so does one that
# declares a stamp it did not write.
pts_norm () {  # pts_norm FILE [EXTRA_TICKS_FILE]
  local tb; tb=$(ffp1 -v error -select_streams v:0 -show_entries stream=time_base -of default=nw=1:nk=1 "$1" 2>/dev/null)
  # an `if` and not `[ -n ] && [ -s ] && cat`: the && chain returns NONZERO
  # when there is nothing to append, and this group is the left side of a pipe
  # under pipefail — the no-stamps call (the ordinary one) died there.
  { ffp -v error -select_streams v:0 -show_entries packet=pts -of csv=p=0 "$1" 2>/dev/null
    if [ -n "${2:-}" ] && [ -s "$2" ]; then cat "$2"; fi; } | \
    awk -F, -v tb="$tb" 'BEGIN{ split(tb,a,"/"); if(a[2]+0==0){a[1]=1;a[2]=1} }
      NF && $1!="N/A" { v[++n]=$1+0; if(n==1||$1+0<mn) mn=$1+0 }
      END{ for(i=1;i<=n;i++) printf "%.0f\n", (v[i]-mn)*a[1]/a[2]*1000000 }' | LC_ALL=C sort -n
}
PN_S="$(mktemp)"; PN_O="$(mktemp)"; PN_X="$(mktemp)"
printf '%s\n' "$py_out" | sed -n 's/.*DERIVE_STAMP idx=[0-9]* pts=\([0-9-][0-9]*\).*/\1/p' > "$PN_X"
PN_XN=$(grep -c . "$PN_X" || true)
[ "$PN_XN" -eq "$DP_STAMPED" ] || {
  echo ">> the pre-pass announced $DP_STAMPED reconstruction(s) but emitted $PN_XN stamp row(s)"
  echo "   — the provenance record and the census disagree; NOT blessing. Kept: $PART"
  rm -f "$PN_S" "$PN_O" "$PN_X"; exit 1; }
[ "$PN_XN" -eq 0 ] || echo "   ($PN_XN reconstructed PTS added to the source side — see the DERIVE_STAMP rows)"
pts_norm "$IN" "$PN_X" > "$PN_S"
pts_norm "$PART"        > "$PN_O"
if cmp -s "$PN_S" "$PN_O"; then
  echo "   PASS: sorted PTS multisets identical ($(grep -c . "$PN_S") values; every real"
  echo "   presentation instant preserved)"
  rm -f "$PN_S" "$PN_O" "$PN_X"
else
  echo ">> PTS MULTISET GATE FAILED — the output does not present the source's timeline."
  diff "$PN_S" "$PN_O" | head -6 | sed 's/^/   /'
  rm -f "$PN_S" "$PN_O" "$PN_X"
  echo "   NOT blessing. Kept: $PART"; exit 1
fi

echo "-- output gate 3/4: video packet-hash identity (verify gate (a) method) --"
# EMPTY ≠ ABSENT (WO-1.15.4 C3's shape, closed here 1.15.19): `|| true` inside
# phash swallowed the hash pass's exit status, and `[ -n "$sp" ] && [ "$sp" =
# "$op" ]` then sent TWO EMPTY hashes to the else arm — measured pre-fix, this
# gate printed ">> PACKET-HASH GATE FAILED — the copied bitstream is not
# identical." with `src=` and `out=` blank and exited 1. That is a positive
# claim of bitstream corruption from evidence that was never collected, on a
# builder's blessing path. The rc now travels; an unprovable gate is UNPROVEN
# (REVIEW), which is NOT a licence to bless: the remaining gate still runs
# (C7's lesson — a REVIEW must never skip the battery, and gate 4 may still
# find a REAL breach worth exit 1), and the .part is kept for re-judging.
# WO-1.15.20 S2 (found running this rung's own new fixture end-to-end): the
# raw streamhash is CONTAINER-SENSITIVE, and this gate had no second arm.
# H.264 rides mpegts as Annex-B with in-band SPS/PPS and MOV as length-prefixed
# avcC, so a byte-perfect TS -> MOV copy hashes differently every time. This
# gate therefore FAILed exit 1 — a positive claim that "the copied bitstream is
# not identical" — on every .ts source, which is the whole motivating class of
# the rung. Measured on tests/fixtures/sparse-nopts.ts with stamped=0 (the
# no-holes control), so it long predates the pre-pass.
# verify.sh gate (a) has always had the answer and this now mirrors it: try the
# exact hash first, and only when it disagrees fall back to the VCL arbiter,
# which strips SEI/SPS/PPS/AUD and normalizes Annex-B so parameter-set
# PLACEMENT cannot masquerade as an essence change. What remains is the coded
# picture data — the correct lossless arbiter for H.264.
phash () { ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$1" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null; }
vcl_hash () { local b=""
  [ "$(ffp1 -v error -select_streams v:0 -show_entries stream=is_avc -of default=nw=1:nk=1 "$1" 2>/dev/null)" = true ] && b="h264_mp4toannexb,"
  ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$1" -map 0:v:0 -c:v copy \
    -bsf:v "${b}filter_units=remove_types=6|7|8|9" -f streamhash -hash md5 - 2>/dev/null; }
DD_BSFS=$(ffmpeg -hide_banner -bsfs 2>/dev/null || true)
DD_HAVE_VCL=0
{ grep -qw filter_units <<<"$DD_BSFS" && grep -qw h264_mp4toannexb <<<"$DD_BSFS"; } && DD_HAVE_VCL=1
[ "${RTM_FORCE_NO_VCL:-0}" = 1 ] && DD_HAVE_VCL=0
sp_rc=0; sp=$(phash "$IN")   || sp_rc=$?
op_rc=0; op=$(phash "$PART") || op_rc=$?
G3_UNPROVEN=0
if [ "$sp_rc" -ne 0 ] || [ "$op_rc" -ne 0 ] || [ -z "$sp" ] || [ -z "$op" ]; then
  G3_UNPROVEN=1
  echo ">> PACKET-HASH GATE UNPROVEN — the hash pass did not produce evidence"
  echo "   (src rc=$sp_rc$([ -z "$sp" ] && echo ', empty'), out rc=$op_rc$([ -z "$op" ] && echo ', empty'))."
  echo "   This is NOT a claim that the bitstream differs — an accusation needs two"
  echo "   non-empty hashes. Fix the read/decode problem and re-run; gate 4 still runs."
elif [ "$sp" = "$op" ]; then
  echo "   PASS: video packets bit-identical (demux-only streamhash match)"
elif [ "$DD_HAVE_VCL" -ne 1 ]; then
  G3_UNPROVEN=1
  echo ">> PACKET-HASH GATE UNPROVEN — the raw hashes differ, but this ffmpeg lacks"
  echo "   filter_units/h264_mp4toannexb, so the container-neutral VCL comparison that"
  echo "   would tell an essence change from a parameter-set REPACKAGING cannot run."
  echo "   Not an accusation: a TS->MOV copy differs here by construction."
else
  echo "   raw hashes differ — trying the container-neutral VCL arbiter (Annex-B"
  echo "   normalized, SEI/SPS/PPS/AUD stripped: parameter-set placement is not essence)"
  sv_rc=0; sv=$(vcl_hash "$IN")   || sv_rc=$?
  ov_rc=0; ov=$(vcl_hash "$PART") || ov_rc=$?
  if [ "$sv_rc" -ne 0 ] || [ "$ov_rc" -ne 0 ] || [ -z "$sv" ] || [ -z "$ov" ]; then
    G3_UNPROVEN=1
    echo ">> PACKET-HASH GATE UNPROVEN — the VCL pass produced no evidence"
    echo "   (src rc=$sv_rc$([ -z "$sv" ] && echo ', empty'), out rc=$ov_rc$([ -z "$ov" ] && echo ', empty'))."
  elif [ "$sv" = "$ov" ]; then
    echo "   PASS: VCL payload identical ($sv) — the coded pictures are bit-identical;"
    echo "   only parameter-set placement differs, which is the container's business."
  else
    echo ">> PACKET-HASH GATE FAILED — the copied bitstream is not identical."
    echo "     src=$sp"
    echo "     out=$op"
    echo "     src VCL=$sv"
    echo "     out VCL=$ov"
    echo "   NOT blessing. Kept: $PART"; exit 1
  fi
fi

echo "-- output gate 4/4: post-mux census (D5) --"
if ! mux_census "$PART" "$CEN_N" "$CEN_C" derive-dts; then
  echo "   NOT blessing the output. Kept: $PART"
  exit 1
fi

if [ "${G3_UNPROVEN:-0}" -eq 1 ]; then
  # every OTHER gate passed, so this is not a FAIL — but blessing needs proof,
  # not the absence of a disproof (UNPROVEN != FAILED, 1.15.2). REVIEW (10),
  # artifact kept where the operator can re-judge it.
  echo ">> NOT blessing on an unproven gate: the derived timeline and the PTS multiset"
  echo "   both check out and the post-mux census passed, but packet identity could not"
  echo "   be measured, so losslessness is UNPROVEN — not disproven."
  echo "   Kept: $PART ($(wc -c < "$PART" | tr -d ' ') bytes)"
  echo "   Re-judge: ffmpeg -i \"$IN\" -map 0:v:0 -c copy -f streamhash -hash md5 -"
  echo "             ffmpeg -i \"$PART\" -map 0:v:0 -c copy -f streamhash -hash md5 -"
  echo "   Then bless by hand (mv) if they match, or delete: rm -f \"$PART\""
  echo "DERIVE_DTS depth=$DP_DEPTH shift_ms=$DP_SHIFT_MS packets=$DP_PACKETS census=ok stamped=$DP_STAMPED verdict=unproven why=packet_hash$DD_ATTESTED"
  exit 10
fi
mv -f "$PART" "$OUT"
echo "wrote: $OUT"
echo "DERIVE_DTS depth=$DP_DEPTH shift_ms=$DP_SHIFT_MS packets=$DP_PACKETS census=ok stamped=$DP_STAMPED verdict=ok$DD_ATTESTED"
echo "sign-off: scripts/verify.sh \"$IN\" \"$OUT\""
echo "  (these gates prove the container timeline and packet identity; verify.sh's scrub"
echo "   gate + A/V parity complete the archival proof set)"
