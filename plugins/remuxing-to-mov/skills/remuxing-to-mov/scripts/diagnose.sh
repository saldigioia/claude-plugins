#!/usr/bin/env bash
# diagnose.sh — run the glitch-diagnosis ladder in order and print a verdict.
# Usage: scripts/diagnose.sh INPUT
# Ladder: (1) decode-to-null integrity + transport counters + pre-roll count —
#             "SOURCE DAMAGED" needs transport EVIDENCE (ts-health.sh pass-1's
#             continuity/TEI/PES/scrambled counters, computed the same way here),
#             never a decode-noise tally alone
#         (2) MKV strict-mux test (catches MISSING timestamps)
#         (3) packet DTS monotonicity scan (catches backward AND duplicate DTS)
#         (4) discontinuity (forward-gap) scan + whole-file DTS-rot counters
# Executable form of references/timeline-repair.md. "Non-monotonic" includes
# DUPLICATE (equal) DTS — ffmpeg flags "X >= X" as invalid, and a field-coded
# stream on a non-integer timebase produces these throughout.
# Tunables: TSH_LOSS_FAIL — transport-error re-capture threshold (default 100),
# deliberately the SAME knob ts-health.sh honors so the two scanners cannot
# disagree on where "proceed with eyes open" ends and "re-capture" begins.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
IN="${1:?usage: diagnose.sh INPUT}"
# F6 (WO-1.15.9): reject stray arguments — `diagnose.sh IN --deep` used to be
# a silent no-op (--deep is clean.sh's flag), which reads as "diagnosed deep".
[ $# -le 1 ] || { echo "unknown opt: $2 (diagnose.sh takes only INPUT; --deep belongs to clean.sh)" >&2; exit 2; }
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-paff.sh"   # shared PAFF detection
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # only our own scratch; never the source

echo "== diagnosing: $IN =="

# Field-coded (PAFF) + timestamp-profile check up front — it changes every
# verdict below. Two facts pick the repair (post-mortem 2026-07-25):
#   * untimestamped fraction ~0.5 = the PAIR class (only the first field of each
#     pair has PES timestamps) — the detector now counts these packets, so the
#     rate no longer false-reads 1x on exactly this class;
#   * a reorder pyramid (pts!=dts / backward PTS) makes the constant-rate rebuild
#     WRONG (PTS=DTS plays decode order) — the real PTS must be KEPT (pairfill).
eval "$(pf_detect "$IN")"
# PF_PPF_IN hands pf_detect's already-measured essence result down so the bounded
# decode probe runs ONCE per diagnose, not once per function that wants it.
eval "$(PF_PPF_IN="${PF_PPF:-}" pf_reorder_scan "$IN")"
# P1.3: two of the reorder fields below are derived from the demuxer's dts
# column. On a container that stores no DTS that column is ffmpeg's
# reconstruction, so those numbers describe the READER, not the source — the
# annotation says so wherever they are printed. The numbers themselves stay
# visible; only the attribution is corrected. PF_BACKPTS is container-real
# (it comes from the pts column) and carries no annotation.
DTSQ=""
[ "${PF_DTS_SOURCE:-carried}" = reconstructed ] && DTSQ=" (demuxer-reconstructed — not a source property)"
if [ "$PF_FIELD_RATE" = unknown ]; then
  RB="scripts/rebuild-paff.sh \"$IN\" OUT.mov <FIELD_RATE> <TIMESCALE>  (pick from the field-rate table)"
else
  RB="scripts/rebuild-paff.sh \"$IN\" OUT.mov $PF_FIELD_RATE $PF_TIMESCALE"
fi
PFILL="scripts/pairfill-paff.sh \"$IN\" OUT.mov"
DERIVE="scripts/derive-dts.sh \"$IN\" OUT.mov"
# preferred repair for a broken timeline on THIS stream — Phase 4 (WO 1.14):
# chosen by the MEASURED profile, and every verdict that prints the route also
# prints the measurements that drove it ($REPAIR_WHY). The old rule
# (half_ts OR reorder -> pairfill) sent fully-timestamped reordered streams
# into pairfill's exit 3 with PF_NOPTS_FRAC=0.000 in scope and ignored — the
# 2023-VMA misroute.
FRAC0=0; awk "BEGIN{exit !((${PF_NOPTS_FRAC:-0})+0 <= 0.001)}" && FRAC0=1
if [ "$PF_HALF_TS" = yes ] && [ "${PF_CODEC:-na}" = h264 ]; then
  REPAIR="$PFILL"
  REPAIR_WHY="half_ts=yes (nopts_frac=$PF_NOPTS_FRAC — the pair signature): keep every real PTS, fill the pair-mates"
elif [ "$PF_REORDER" = yes ] && [ "$FRAC0" -eq 1 ]; then
  if [ "${PF_DEPTH_CLASS:-unknown}" = unknown ]; then
    # NOT an automatic route: an unparseable SPS must never be restamped blind.
    DRV_UNK=1
    REPAIR="OPERATOR CALL — no automatic route (depth class unknown): scripts/derive-dts.sh \"$IN\" OUT.mov --force only on a human decision (see the depth-class advisory above)"
    REPAIR_WHY="nopts_frac=$PF_NOPTS_FRAC + reorder=yes, but depth_class=unknown — evidence that cannot support a derivation must not route one automatically"
  else
    REPAIR="$DERIVE"
    REPAIR_WHY="nopts_frac=$PF_NOPTS_FRAC (PTS-complete) + reorder=yes (depth_class=$PF_DEPTH_CLASS, dts_short=${PF_DTS_SHORT:-unknown}, dts_source=${PF_DTS_SOURCE:-carried}): derive DTS from the sorted PTS — absent, reconstructed or carried-but-rotten DTS is discarded either way"
  fi
elif [ "${PF_CODEC:-na}" != h264 ] && [ "${PF_CODEC:-na}" != na ]; then
  # non-H.264 timeline rot (mpeg2video .mpg/.vob included): pairfill refuses the
  # codec outright (exit 3) and rebuild-paff extracts -f h264 — both are
  # H.264-only. derive-dts is codec-agnostic (packets copied untouched).
  REPAIR="$DERIVE"
  REPAIR_WHY="codec=$PF_CODEC (non-H.264: pairfill exits 3 on codec, rebuild's -f h264 extraction cannot apply) -> derive-dts is the codec-agnostic timeline repair; its own gate refuses if PTS is incomplete (nopts_frac=$PF_NOPTS_FRAC)"
elif [ "$PF_HALF_TS" = yes ] || [ "$PF_REORDER" = yes ]; then
  REPAIR="$PFILL"
  REPAIR_WHY="reorder=$PF_REORDER with partial timestamps (nopts_frac=$PF_NOPTS_FRAC, half_ts=$PF_HALF_TS): pairfill keeps every surviving PTS; its own gates refuse (exit 3) if the shape is not the pair class"
else
  REPAIR="$RB"
  REPAIR_WHY="reorder=no, half_ts=no (nopts_frac=$PF_NOPTS_FRAC): no reorder pyramid survives, so the constant-rate rebuild is safe (H.264-only)"
fi
if [ "$PF_PAFF" = yes ]; then
  echo "** FIELD-CODED (PAFF) H.264: coded-pic rate ${PF_CODED_RATE}/s vs container frame rate ${PF_NOMINAL_FPS}/s (ratio ${PF_RATIO})."
  echo "** genpts is guilty-until-proven here. **"
fi
# P1.2: which hypothesis about the container's declared rate won — announced
# whether it fired or not, because "not field-coded" at ratio ~1 is a CHOICE
# between two readings of the denominator, not an observation.
pf_hyp_note "${PF_RATIO_HYP:-none}" "${PF_RATIO:-0}" "${PF_PPF:-unknown}" "${PF_NOMINAL_FPS:-0}" "${PF_FIELD_RATE:-unknown}"
# P1.5: the coded rate is now the modal presentation-sorted delta, which the
# reorder lead cannot stretch. Show both numbers whenever they disagree.
if awk "BEGIN{a=${PF_CODED_RATE:-0}; b=${PF_CODED_RATE_SPAN:-0}; d=a-b; if(d<0)d=-d; exit !(d>0.05)}"; then
  echo "**   coded-picture rate ${PF_CODED_RATE}/s by modal sorted-PTS delta; the legacy min/max-span"
  echo "**   method read ${PF_CODED_RATE_SPAN}/s on this window. The span method absorbs anything that"
  echo "**   stretches min..max — a reorder pyramid's presentation lead above all (measured 59.44 on a"
  echo "**   true 59.94), a gap inside the window too; the modal delta cancels both. method=${PF_RATE_METHOD}"
fi
if awk "BEGIN{exit !(${PF_NOPTS_FRAC:-0}>0)}"; then
  echo "** ${PF_NOPTS_FRAC} of video packets carry NO timestamps (half_ts=$PF_HALF_TS)."
  [ "$PF_HALF_TS" = yes ] && echo "**   ~half untimestamped = the PAIR signature: each one is the mate of the timestamped field before it -> $PFILL"
fi
echo "** reorder pyramid: $PF_REORDER (pts!=dts on $PF_PTSNEDTS pkt(s)${DTSQ}, $PF_BACKPTS backward PTS step(s), max offset $PF_MAXOFF_TICKS ticks${DTSQ})"
# P1.1: the depth, in the unit the packets are actually in
echo "** reorder depth: ${PF_DEPTH_PICS} coded picture(s) measured | declared ${PF_DECL_DEPTH} frame(s) x ${PF_PPF} picture(s)/frame = ${PF_DEPTH_EXPECTED} -> ${PF_DEPTH_CLASS} (dts-short=${PF_DTS_SHORT:-unknown})"
pf_depth_note "$PF_DEPTH_CLASS" "$PF_DEPTH_PICS" "$PF_DECL_DEPTH" "$PF_PPF" "$PF_DEPTH_EXPECTED" "$PF_DEPTH_TS"
[ "${PF_DTS_SOURCE:-carried}" = reconstructed ] && \
  echo "** DTS provenance: RECONSTRUCTED by the demuxer (this container stores none) — any count keyed to the dts column below describes ffmpeg's model of this stream, not the stream."
[ "$PF_REORDER" = yes ] && echo "**   real PTS must be KEPT — a constant-rate restamp (rebuild-paff) would play fields in DECODE order (shuffled motion, invisible to default verify)."
# Phase 4 (WO 1.14): unparseable-SPS advisory — a PTS-complete reorder pyramid
# whose depth class cannot be established gets NO automatic restamp route,
# announced here so every verdict below inherits the context. Keyed to the
# routing arm that actually hit the unknown class (DRV_UNK), so a profile with
# its own legitimate route (e.g. the half-ts pair class) is not contradicted.
if [ "${DRV_UNK:-0}" -eq 1 ]; then
  echo "**   depth class UNKNOWN (SPS unparseable in the probe window) with a reorder pyramid:"
  echo "**   NO automatic restamp route — a healthy file must not get a derived timeline on"
  echo "**   evidence that cannot support one. scripts/derive-dts.sh ... --force is the"
  echo "**   OPERATOR'S call (the rung announces the force), after a human look at the stream."
fi

# backhaul/contribution profile facts — they reframe every verdict below.
CONT=$(ffp1 -v error -show_entries format=format_name -of default=nw=1:nk=1 "$IN" 2>/dev/null)
PIX=$(ffp1 -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$IN" 2>/dev/null)
IS_TS=no; case "$CONT" in *mpegts*) IS_TS=yes;; esac
if qt_contribution_profile "$PIX"; then
  # 1.11 (WO 4.1 demotion; wording fixed in the WO 5.2 messaging pass): the
  # pre-1.11 banner here still asserted the categorical "QT-UNDECODABLE ...
  # mov.sh refuses this profile early (exit 11)" verdict AFTER that refusal
  # was falsified on the bench (2026-08-13) — the shared advisory is the one
  # announcement now (yuv422p* at any bit depth, same predicate as the
  # builders), and playability is proven on the finished build.
  contribution_advisory "$PF_CODEC" "$PIX"
  echo "** Every verdict below governs whether a verified lossless MASTER can be"
  echo "** built; QuickTime playability of this profile is proven post-build"
  echo "** (playable-check.sh; fail/unverified -> REVIEW with rung4.sh named)."
fi

# (1) decode-to-null: separates real decode damage from timestamp defects —
# and from mid-GOP pre-roll, which is neither.
#
# WHY the decode tally is no longer trusted alone (2026-08-13 bench finding,
# the false-SOURCE-DAMAGED class): on a healthy BBC capture that merely JOINED
# the broadcast mid-GOP, the 73 "decode-damage" lines counted here were exactly
# the 73 pre-keyframe packets ts-health.sh counts — reference-less pre-roll
# every player conceals — while every transport corruption counter (continuity
# / TEI / PES mismatch / scrambled) sat at ZERO. The old ">= 5 lines -> SOURCE
# DAMAGED. Re-capture." verdict told the operator to destroy a healthy,
# irreplaceable capture. And the tally under-detects the real thing: TEI-marked
# packets are dropped by the DEMUXER, so a genuinely shot-up transport can
# decode "clean" here. Damage is therefore keyed to transport EVIDENCE
# (ts-health pass-1's counters, computed identically below); decode noise fully
# explained by the pre-keyframe count is the MID-GOP START class instead —
# losslessly trimmable, never "damage".
#
# P1.7 — SCOPE. The census maps 0:v:0, but it counted every line the whole
# invocation wrote, from any component that emits one. It then DIFFERENCED that
# total against a VIDEO-packet pre-roll number (nreal, below) and read the
# remainder as video damage — two numbers of two different things, subtracted.
# So the census is filtered to the v:0 DECODER's own message class (the
# `[<vcodec> @ ...]` prefix, which only the mapped video stream can emit here),
# and the raw unscoped count stays printed beside it: the fix is a scoping fix
# and the reader is entitled to see what was excluded.
# WHAT THE FILTER COSTS ON REAL DAMAGE: on decoder-INTERNAL complaints, nothing.
# On a bit-smeared H.264 TS the raw and scoped counts are identical (21 and 21 on
# the copy of gap.ts used to check this, and 25/25 on a heavier smear re-measured
# 2026-08-16), because those lines are emitted BY the video decoder and carry its
# `[h264 @ ...]` prefix.
# BUT IT IS NOT COST-FREE, and it was claimed to be (P1c). ffmpeg 9.0.1 emits the
# TOP-LEVEL decode failure through a different context — `[vist#0:0/h264 @ ...]
# [dec:h264 @ ...] Decoding error: Invalid data found when processing input` —
# which matches $DMG and does NOT match `^\[h264 @`. Measured on this bench
# 2026-08-16: a plain `-v error` decode of tests/fixtures/late-sps.ts emits 102
# such lines; raw counts 102, the scope counts 0. (diagnose's own 200M probe
# window happens to find that fixture's SPS, so the file reads 0/0 HERE — but a
# source whose SPS genuinely never parses lands exactly on that 102 -> 0 cliff.)
# So the scope is an ATTRIBUTION aid, never a gate input: the two verdicts that
# consume this census (the >=5 unexplained WARN and the MID-GOP START branch) are
# armed on the RAW count — HEAD's evidence, undiminished — and the scoped count
# is printed beside it for attribution. Never reduce what a gate sees.
# NOTE the two independent narrowings, which are easy to conflate: this prefix
# filter, and the $DMG pattern (`error while decoding|concealing|invalid data`)
# that defines what counts as damage in the first place. A line has to pass
# BOTH. Plenty of real decoder complaints pass neither — an mpeg2video smear
# emits `mb incr damaged` / `ac-tex damaged` / `Invalid mb type`, none of which
# $DMG matches — so this census is a lower bound on decode noise by
# construction, which is why damage is keyed to the transport counters below
# and never to this number alone.
echo "-- (1) decode-to-null integrity + transport counters --"
ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$IN" -map 0:v:0 -f null - 2>"$TMP/null.err" || true
DMG='error while decoding|concealing|invalid data'
ndecode_raw=$(grep -ciE "$DMG" "$TMP/null.err" || true)
if [ -n "${PF_CODEC:-}" ] && [ "${PF_CODEC:-na}" != na ]; then
  ndecode=$(grep -aiE "^\[${PF_CODEC} @" "$TMP/null.err" | grep -ciE "$DMG" || true)
else
  ndecode="$ndecode_raw"      # no video codec name to scope by -> the honest fallback is the raw count
fi
nmono=$(grep -ciE 'non.?monotonical' "$TMP/null.err" || true)
sort "$TMP/null.err" | uniq -c | sort -rn | head -8 | sed 's/^/   /'
# transport pass: demux-only -c copy of EVERY stream — ts-health.sh pass 1,
# same commands, same grep patterns, so the two scanners define "transport
# corruption" identically. Loss here is PERMANENT (bytes the capture never
# wrote); it is also ZERO on the pre-roll class, which is the whole point.
ffmpeg -nostdin -v warning "${FF_INPUT_OPTS[@]}" -i "$IN" -map 0 -c copy -f null - 2>"$TMP/transport.log" || true
cc=$(grep -ci 'continuity check failed' "$TMP/transport.log" || true)
crp=$(grep -ci 'packet corrupt' "$TMP/transport.log" || true)
pes=$(grep -ci 'pes packet size mismatch' "$TMP/transport.log" || true)
scr=$(grep -ci 'scrambled' "$TMP/transport.log" || true)
tloss=$((cc + crp + pes))
# pre-keyframe pre-roll: video packets before the first K flag (ts-health's
# V_PREKEY, window-bounded here — pre-roll lives at the head, and 20000 packets
# of it would be the single-GOP finding, a different class). The { ||true; }
# grouping keeps a probe failure (garbage input) from killing the pipeline
# under set -e/pipefail; awk consumes to EOF — an early exit would SIGPIPE
# ffprobe (the make-fixtures lesson).
prekey=$({ ffp -v error -select_streams v:0 -read_intervals "%+#20000" \
    -show_entries packet=flags -of csv=p=0 "$IN" 2>/dev/null || true; } | \
  awk 'NF{n++; if(!fk && index($0,"K")) fk=n} END{print (fk? fk-1 : n)+0}')
# decode lines minus pre-roll packets = the damage-shaped noise LEFT once the
# mid-GOP explanation is used up (line-vs-packet is 1:1 on the measured class:
# 73 lines were exactly the 73 pre-keyframe packets on the BBC capture)
nreal=$(( ${ndecode:-0} > ${prekey:-0} ? ${ndecode:-0} - ${prekey:-0} : 0 ))
# P1c: nreal_raw is what the two verdicts below are ARMED on — the unscoped
# count is HEAD's evidence, and the prefix scope demonstrably cannot see
# ffmpeg 9's top-level `[vist#…/CODEC @ …] Decoding error:` form (see the scope
# note above). nreal stays for attribution and stays printed.
nreal_raw=$(( ${ndecode_raw:-0} > ${prekey:-0} ? ${ndecode_raw:-0} - ${prekey:-0} : 0 ))
echo "   decode-damage lines: ${ndecode:-0} scoped to the v:0 decoder (${PF_CODEC:-?}); whole-invocation raw count: ${ndecode_raw:-0}"
echo "   (pre-keyframe pre-roll packets: ${prekey:-0} -> unexplained: $nreal_raw raw / $nreal scoped) | non-monotonic-DTS warnings: ${nmono:-0}${DTSQ}"
if [ "${nreal_raw:-0}" -ne "${nreal:-0}" ]; then
  echo "   NOTE: the two disagree — $(( nreal_raw - nreal )) damage-shaped line(s) did not carry the v:0"
  echo "   decoder's own prefix (ffmpeg 9 routes the top-level decode failure through a"
  echo "   [vist#…/${PF_CODEC:-?} @ …] context). The verdicts below are armed on the RAW figure — a"
  echo "   gate is never shown less than it had; the scoped figure is attribution only."
fi
echo "   transport counters: continuity=$cc corrupt(TEI)=$crp PES-mismatch=$pes scrambled=$scr"
[ "$tloss" -gt 0 ] && sort "$TMP/transport.log" | uniq -c | sort -rn | head -4 | sed 's/^/   /'
if [ "${scr:-0}" -gt 0 ] || [ "$tloss" -ge "${TSH_LOSS_FAIL:-100}" ]; then
  echo ">> VERDICT: SOURCE DAMAGED (dropped/corrupt packets: CC=$cc TEI=$crp PES=$pes scrambled=$scr)."
  echo "   Transport loss is PERMANENT — no remux repairs this. Re-capture."
  exit 0
fi
if [ "$tloss" -gt 0 ]; then
  echo ">> VERDICT: SOURCE DAMAGED (transport loss: CC=$cc TEI=$crp PES=$pes — PERMANENT,"
  echo "   bytes the capture never wrote; decoders conceal). The count is small (under"
  echo "   ${TSH_LOSS_FAIL:-100}, the shared ts-health re-capture threshold), so remuxing what"
  echo "   survives stays legitimate — expect matching decode noise source==output"
  echo "   (verify's baseline classification). The ladder continues: the timeline"
  echo "   verdict below still routes the survivors."
elif [ "$nreal_raw" -ge 5 ]; then
  echo "** WARN: $nreal_raw decode-damage line(s) beyond the pre-roll, but every transport"
  echo "**   counter is ZERO — NOT the re-capture class on this evidence (the"
  echo "**   false-SOURCE-DAMAGED post-mortem, 2026-08-13). Noise this shape carries"
  echo "**   through a lossless remux unchanged; verify.sh's baseline classification"
  echo "**   proves source==output."
fi
echo "   (a few mmco/ref-frame lines are benign and carry through losslessly)"

# (2) strict mux to MKV — Matroska refuses the absent timestamps MOV swallows.
echo "-- (2) MKV strict-mux test --"
if ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$IN" -map 0:v:0 -map "0:a?" -c copy "$TMP/t.mkv" 2>"$TMP/mkv.err"; then
  echo "   MKV mux OK -> timestamps are present (not missing)."
  mkv_ok=1
else
  echo "   MKV mux FAILED:"; sed 's/^/     /' "$TMP/mkv.err" | tail -3
  if grep -qiE 'timestamp.*unset|unknown timestamp' "$TMP/mkv.err"; then
    if [ "$PF_PAFF" = yes ] || [ "$PF_HALF_TS" = yes ]; then
      echo ">> VERDICT: MISSING TIMESTAMPS on FIELD-CODED (PAFF) H.264."
      echo "   Skip genpts (guilty-until-proven on PAFF); a straight copy makes the MOV"
      echo "   muxer INVENT the timeline (the shipped-broken-file class)."
      if [ "$PF_HALF_TS" = yes ]; then
        echo "   Pair signature (~half the packets untimestamped) -> keep every real PTS"
        echo "   and fill the pair-mates:"
        echo "   $PFILL"
        [ "$PF_REORDER" = yes ] && echo "   (reorder pyramid present — rebuild-paff.sh would shuffle motion; it now refuses this class)"
      elif [ "$PF_REORDER" = yes ]; then
        echo "   Reorder pyramid present -> repair by measured profile: $REPAIR"
        echo "   (route evidence: $REPAIR_WHY)"
        echo "   (constant-rate rebuild would play fields in decode order)"
      else
        echo "   No reorder detected -> field-rate rebuild is safe: $RB"
      fi
    else
      echo ">> VERDICT: MISSING TIMESTAMPS. Try Rung-2 genpts (remux.sh --genpts);"
      if [ "${PF_CODEC:-na}" = h264 ]; then
        echo "   if it still glitches, full rebuild: $RB"
      else
        echo "   if it still glitches: rebuild-paff is H.264-only (codec=${PF_CODEC:-?}, its -f h264"
        echo "   extraction cannot apply) — the codec-agnostic timeline repair is $DERIVE"
        echo "   (requires PTS-complete; its own gate refuses otherwise)."
      fi
      [ "$PF_REORDER" = yes ] && { echo "   NOTE: reorder pyramid present — if genpts output misbehaves, repair by profile: $REPAIR"; echo "   (route evidence: $REPAIR_WHY)"; }
    fi
    exit 0
  fi
  mkv_ok=0
fi

# (3) packet DTS monotonicity (backward OR duplicate). <= catches equal DTS.
# P1.1: the window is PF_SCAN_WINDOW now — one named constant for both windowed
# advisory scans (this one and pf_reorder_scan), which used 5000 and 3000 for no
# recorded reason. Not RTM_IDR_WINDOW; that is a different knob entirely.
echo "-- (3) DTS monotonicity scan --"
read -r ndup nback < <(ffp -v error -select_streams v:0 -read_intervals "%+#${PF_SCAN_WINDOW}" \
  -show_entries packet=dts -of csv=p=0 "$IN" 2>/dev/null | \
  awk -F, 'NR>1 && $1!="N/A" && p!="N/A"{ if($1<p)bk++; else if($1==p)du++ } {p=$1}
    END{print (du+0), (bk+0)}')
echo "   first ${PF_SCAN_WINDOW} packets: duplicate(equal) DTS=${ndup:-0}  backward DTS=${nback:-0}${DTSQ}"

# (4) forward-gap (discontinuity) scan — timestamps that are present AND monotonic
# but JUMP forward (dropped frames). Steps (1)-(3) and the MKV mux all PASS these;
# only a delta scan finds them. They are the class that silently desyncs raw PCM
# audio on a blind copy (MOV PCM can't hold a gap) — the remux-sync post-mortem.
echo "-- (4) discontinuity (forward-gap) scan --"
eval "$(disc_scan "$IN")"
# P1.4: the DROPPED-TIME claim is a claim about the program's timeline, so it
# comes from the PRESENTATION arm (sorted PTS). The coded-order figure stays
# printed next to it — where the two disagree, the gap between them IS the
# reconstructed-DTS artifact. INCIDENT TESTIMONY, not a local measurement (the
# 54.6 GB 2023 VMA capture is not on this machine and cannot be re-measured
# here): ~5,475 s reported "dropped" from a 10,944 s program against a real loss
# of 4.58 s, a ~1,000x overstatement. The MECHANISM is what lib-paff.sh's two
# arms are pinned on, and that IS reproducible in the suite on constructed shapes.
echo "   forward gaps: ${DISC_P_COUNT:-0} in presentation order (dropped ~${DISC_P_MISSING:-0}s; frame=${DISC_FRAMEDUR:-?}s)"
echo "   coded-order (dts-column) census for comparison: ${DISC_COUNT:-0} gap(s), ~${DISC_MISSING:-0}s${DTSQ}"
disc_budget_note "${DISC_P_NA:-0}" "${DISC_P_COUNT:-0}"
# same demux pass, whole file: the DTS-rot counters the windowed step-(3) scan
# can miss when the defects sit mid-file at splice points (the 2009/2012 class)
echo "   whole-file DTS rot: backward=${DISC_BACK:-0}  duplicate=${DISC_DUP:-0}${DTSQ}"

# --- verdict ---
# rot condition includes the WHOLE-FILE counters from step (4): the windowed
# step-(3) scan read 0 on the 2009/2012 backhaul feeds whose defects sat
# mid-file at splice points.
if [ "${nmono:-0}" -ge 10 ] || [ "${ndup:-0}" -gt 0 ] || [ "${nback:-0}" -gt 0 ] || [ "${DISC_BACK:-0}" -gt 0 ] || [ "${DISC_DUP:-0}" -gt 0 ]; then
  if [ "$PF_CODEC" = mpeg2video ] && [ "$IS_TS" = yes ] && [ "${DISC_COUNT:-0}" -gt 0 ]; then
    # F5 (same defect class as the two sentences below): one census per clause.
    # Coded-order count arms this verdict; presentation order carries the
    # dropped-time claim. Both labelled, neither borrowed for the other's job.
    echo ">> VERDICT: BACKHAUL TIMELINE ROT — mpegts/mpeg2video with ${DISC_COUNT} forward gap(s)"
    echo "   in coded (dts-column) order; presentation order ${DISC_P_COUNT:-0} gap(s), ~${DISC_P_MISSING:-0}s"
    echo "   dropped. PLUS non-monotonic DTS (whole-file"
    echo "   backward=${DISC_BACK:-0} duplicate=${DISC_DUP:-0}; windowed dup=${ndup:-0} back=${nback:-0};"
    echo "   decode warnings=${nmono:-0}). Route: build + verify will judge (warn) —"
    echo "   since 1.11 (WO 4.2) mov.sh WARNS on this class and builds: the"
    echo "   mux-confession gate hard-stops if the copy mux invents timing (measured,"
    echo "   kept), and verify's timeline/parity gates judge any finished build with"
    echo "   evidence. Do NOT route this to resync.sh — its rebuild left near-zero"
    echo "   sample durations on this class (verify gate (d) FAIL). Honest routes if"
    echo "   the build's verdict says no:"
    if [ "$FRAC0" -eq 1 ]; then
      echo "     repair   $DERIVE"
      echo "              (Rung 3-DERIVE, codec-agnostic — route evidence: nopts_frac=$PF_NOPTS_FRAC"
      echo "               PTS-complete + whole-file rot backward=${DISC_BACK:-0} duplicate=${DISC_DUP:-0}: the"
      echo "               rotten DTS column is discarded and re-derived from the sorted PTS."
      echo "               pairfill/rebuild-paff are H.264-only and do NOT apply to ${PF_CODEC:-this codec}.)"
    fi
    echo "     keep     the .ts — it is already the archival master"
    echo "     playback ffmpeg -i \"$IN\" -map 0:v:0 -map '0:a?' -c copy OUT.mkv"
    echo "              (Matroska stores per-block timestamps — the discontinuous"
    echo "               timeline survives honestly; plays in IINA/VLC/mpv)"
    echo "     rung4    scripts/rung4.sh — operator-attested re-encode, the only"
    echo "              sanctioned path to a QuickTime-native deliverable"
  else
    echo ">> VERDICT: NON-MONOTONIC / DUPLICATE DTS (broken timeline, common on a"
    echo "   field-coded stream muxed on a non-integer timebase). Repair for THIS"
    echo "   stream's timestamp profile: $REPAIR"
    echo "   route evidence: $REPAIR_WHY"
    [ "$REPAIR" = "$PFILL" ] && echo "   (real PTS survives / reorder present -> keep it; a constant-rate rebuild would flatten the pyramid)"
  fi
elif [ "${mkv_ok:-1}" -eq 1 ]; then
  if [ "$PF_PAFF" = yes ]; then
    echo ">> VERDICT: timing PASSES the mux tests, but this is FIELD-CODED (PAFF)"
    echo "   H.264 — the strict-mux test proves timestamps are present and monotonic,"
    echo "   NOT that the timeline is seekable. That gap is exactly where the silent"
    echo "   corruption lives. Treat plain copy / genpts as provisional:"
    if [ "$PF_REORDER" = yes ]; then
      echo "     first:     plain copy (keeps the true timeline) gated by the scrub test:"
      echo "                scripts/verify.sh \"$IN\" OUT.mov   (fails on a glitchy scrub)"
      echo "     repair:    $REPAIR"
      echo "                (route evidence: $REPAIR_WHY;"
      echo "                 rebuild-paff would shuffle motion)"
    else
      echo "     reliable:  $RB"
      echo "     or verify a copy with the scrub gate before trusting it:"
      echo "                scripts/verify.sh \"$IN\" OUT.mov   (fails on a glitchy scrub)"
    fi
  elif [ "${DISC_COUNT:-0}" -gt 0 ]; then
    # F5: ONE census per clause. The verdict is ARMED by the coded-order count
    # (unchanged — arming is not this round's business), so that is what the
    # first clause reports, labelled as such; every DROPPED-TIME / timeline
    # claim comes from the presentation arm, labelled as such. The two used to
    # be spliced into one sentence, which read "N forward timestamp gap(s) …
    # (~0s dropped)" whenever coded > 0 and presentation = 0.
    echo ">> VERDICT: DISCONTINUOUS SOURCE — ${DISC_COUNT} forward timestamp gap(s) in coded"
    echo "   (dts-column) order, first @ ${DISC_FIRST}s; presentation order: ${DISC_P_COUNT:-0} gap(s),"
    echo "   ~${DISC_P_MISSING:-0}s dropped — the presentation figure is the timeline claim. Video timing is otherwise"
    echo "   sound, so the mux 'succeeds' — but a blind -c copy COLLAPSES these gaps in"
    echo "   raw PCM audio, sliding it out of sync with the picture. Do NOT plain-copy"
    echo "   PCM here. Gap-fill the audio (video stays bit-identical):"
    echo "     scripts/resync.sh \"$IN\" OUT.mov"
    echo "   Then confirm: scripts/verify.sh \"$IN\" OUT.mov  (the duration-parity gate)."
  elif [ "${prekey:-0}" -gt 0 ]; then
    # the class the false-SOURCE-DAMAGED post-mortem is about — and equally NOT
    # "timing looks sound -> plain copy": a plain copy carries the pre-roll
    # garbage into the .mov, where players still have nothing to decode it from
    midgop_said=1
    # P1c: armed on the RAW figure. "pre-roll ONLY" is a claim that NOTHING is
    # left unexplained, and it must not be reachable by narrowing the evidence.
    if [ "${nreal_raw:-0}" -eq 0 ]; then
      echo ">> VERDICT: MID-GOP START (pre-roll only, ${prekey} packets) — losslessly trim at"
      echo "   the first IDR: scripts/trim-to-idr.sh"
    else
      echo ">> VERDICT: MID-GOP START (${prekey} pre-roll packets; $nreal_raw decode line(s) beyond"
      echo "   them — see step 1) — losslessly trim at the first IDR: scripts/trim-to-idr.sh"
    fi
    echo "   The capture JOINED the broadcast mid-GOP: packets before the first keyframe"
    echo "   reference frames that were never captured, decode as garbage, and every"
    echo "   player conceals them. That is pre-roll, NOT damage (damage needs nonzero"
    echo "   transport counters — step 1). After the trim, remux as usual (Rung 0)."
  else
    echo ">> VERDICT: timing looks sound -> plain copy (Rung 0): scripts/remux.sh."
    echo "   (If MOV still glitches despite this, repair by profile: $REPAIR"
    echo "    route evidence: $REPAIR_WHY)"
  fi
else
  echo ">> VERDICT: timestamps problematic (MKV refused) -> repair: $REPAIR"
  echo "   route evidence: $REPAIR_WHY"
fi
# A discontinuous source still needs an audio gap-fill even when the video path is
# a rebuild (PAFF / non-monotonic) — flag it so it isn't missed on those branches.
if [ "${DISC_COUNT:-0}" -gt 0 ] && { [ "${nmono:-0}" -ge 10 ] || [ "${ndup:-0}" -gt 0 ] || [ "${nback:-0}" -gt 0 ] || [ "$PF_PAFF" = yes ]; }; then
  # F5: the TIMELINE claim ("there are holes the PCM audio will collapse") is a
  # presentation-order claim, so it leads with the presentation census; the
  # coded-order count that ARMS this note is printed beside it, labelled.
  # Arming is deliberately untouched.
  echo "   ALSO: ${DISC_P_COUNT:-0} discontinuit(ies) in presentation order (~${DISC_P_MISSING:-0}s), coded-order"
  echo "   census ${DISC_COUNT} — if any audio track is raw PCM, gap-fill it"
  echo "   (scripts/resync.sh) so audio stays pinned through the rebuild."
fi
# Mid-GOP pre-roll rides along with any other verdict (a capture can join the
# broadcast mid-GOP AND have gaps/rot/PAFF) — surface the lossless trim route
# whenever the dedicated MID-GOP START verdict above did not fire.
if [ "${prekey:-0}" -gt 0 ] && [ "${midgop_said:-0}" -eq 0 ]; then
  echo "   ALSO: capture starts MID-GOP (${prekey} pre-keyframe pre-roll packet(s), concealed"
  echo "   by players, not damage) — losslessly trim at the first IDR: scripts/trim-to-idr.sh"
fi
