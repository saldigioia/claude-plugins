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
eval "$(pf_reorder_scan "$IN")"
if [ "$PF_FIELD_RATE" = unknown ]; then
  RB="scripts/rebuild-paff.sh \"$IN\" OUT.mov <FIELD_RATE> <TIMESCALE>  (pick from the field-rate table)"
else
  RB="scripts/rebuild-paff.sh \"$IN\" OUT.mov $PF_FIELD_RATE $PF_TIMESCALE"
fi
PFILL="scripts/pairfill-paff.sh \"$IN\" OUT.mov"
# preferred repair for a broken timeline on THIS stream
if [ "$PF_HALF_TS" = yes ] || [ "$PF_REORDER" = yes ]; then REPAIR="$PFILL"; else REPAIR="$RB"; fi
if [ "$PF_PAFF" = yes ]; then
  echo "** FIELD-CODED (PAFF) H.264: coded-pic rate ${PF_CODED_RATE}/s ~= 2x frame rate ${PF_NOMINAL_FPS}/s."
  echo "** genpts is guilty-until-proven here. **"
fi
if awk "BEGIN{exit !(${PF_NOPTS_FRAC:-0}>0)}"; then
  echo "** ${PF_NOPTS_FRAC} of video packets carry NO timestamps (half_ts=$PF_HALF_TS)."
  [ "$PF_HALF_TS" = yes ] && echo "**   ~half untimestamped = the PAIR signature: each one is the mate of the timestamped field before it -> $PFILL"
fi
echo "** reorder pyramid: $PF_REORDER (pts!=dts on $PF_PTSNEDTS pkt(s), $PF_BACKPTS backward PTS step(s), max offset $PF_MAXOFF_TICKS ticks)"
[ "$PF_REORDER" = yes ] && echo "**   real PTS must be KEPT — a constant-rate restamp (rebuild-paff) would play fields in DECODE order (shuffled motion, invisible to default verify)."

# backhaul/contribution profile facts — they reframe every verdict below.
CONT=$(ffp -v error -show_entries format=format_name -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
PIX=$(ffp -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$IN" 2>/dev/null | head -1)
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
echo "-- (1) decode-to-null integrity + transport counters --"
ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$IN" -map 0:v:0 -f null - 2>"$TMP/null.err" || true
ndecode=$(grep -ciE 'error while decoding|concealing|invalid data' "$TMP/null.err" || true)
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
echo "   decode-damage lines: ${ndecode:-0} (pre-keyframe pre-roll packets: ${prekey:-0} -> unexplained: $nreal) | non-monotonic-DTS warnings: ${nmono:-0}"
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
elif [ "$nreal" -ge 5 ]; then
  echo "** WARN: $nreal decode-damage line(s) beyond the pre-roll, but every transport"
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
        echo "   Reorder pyramid present -> keep the surviving PTS: $PFILL"
        echo "   (constant-rate rebuild would play fields in decode order)"
      else
        echo "   No reorder detected -> field-rate rebuild is safe: $RB"
      fi
    else
      echo ">> VERDICT: MISSING TIMESTAMPS. Try Rung-2 genpts (remux.sh --genpts);"
      echo "   if it still glitches, full rebuild: $RB"
      [ "$PF_REORDER" = yes ] && echo "   NOTE: reorder pyramid present — if genpts output misbehaves, prefer $PFILL (keeps real PTS) over a flattening rebuild."
    fi
    exit 0
  fi
  mkv_ok=0
fi

# (3) packet DTS monotonicity (backward OR duplicate). <= catches equal DTS.
echo "-- (3) DTS monotonicity scan --"
read -r ndup nback < <(ffp -v error -select_streams v:0 -read_intervals "%+#5000" \
  -show_entries packet=dts -of csv=p=0 "$IN" 2>/dev/null | \
  awk -F, 'NR>1 && $1!="N/A" && p!="N/A"{ if($1<p)bk++; else if($1==p)du++ } {p=$1}
    END{print (du+0), (bk+0)}')
echo "   first 5000 packets: duplicate(equal) DTS=${ndup:-0}  backward DTS=${nback:-0}"

# (4) forward-gap (discontinuity) scan — timestamps that are present AND monotonic
# but JUMP forward (dropped frames). Steps (1)-(3) and the MKV mux all PASS these;
# only a delta scan finds them. They are the class that silently desyncs raw PCM
# audio on a blind copy (MOV PCM can't hold a gap) — the remux-sync post-mortem.
echo "-- (4) discontinuity (forward-gap) scan --"
eval "$(disc_scan "$IN")"
echo "   forward gaps: ${DISC_COUNT:-0}  (dropped ~${DISC_MISSING:-0}s; frame=${DISC_FRAMEDUR:-?}s)"
# same demux pass, whole file: the DTS-rot counters the windowed step-(3) scan
# can miss when the defects sit mid-file at splice points (the 2009/2012 class)
echo "   whole-file DTS rot: backward=${DISC_BACK:-0}  duplicate=${DISC_DUP:-0}"

# --- verdict ---
# rot condition includes the WHOLE-FILE counters from step (4): the windowed
# step-(3) scan read 0 on the 2009/2012 backhaul feeds whose defects sat
# mid-file at splice points.
if [ "${nmono:-0}" -ge 10 ] || [ "${ndup:-0}" -gt 0 ] || [ "${nback:-0}" -gt 0 ] || [ "${DISC_BACK:-0}" -gt 0 ] || [ "${DISC_DUP:-0}" -gt 0 ]; then
  if [ "$PF_CODEC" = mpeg2video ] && [ "$IS_TS" = yes ] && [ "${DISC_COUNT:-0}" -gt 0 ]; then
    echo ">> VERDICT: BACKHAUL TIMELINE ROT — mpegts/mpeg2video with ${DISC_COUNT} forward"
    echo "   gap(s) (~${DISC_MISSING:-0}s dropped) PLUS non-monotonic DTS (whole-file"
    echo "   backward=${DISC_BACK:-0} duplicate=${DISC_DUP:-0}; windowed dup=${ndup:-0} back=${nback:-0};"
    echo "   decode warnings=${nmono:-0}). Route: build + verify will judge (warn) —"
    echo "   since 1.11 (WO 4.2) mov.sh WARNS on this class and builds: the"
    echo "   mux-confession gate hard-stops if the copy mux invents timing (measured,"
    echo "   kept), and verify's timeline/parity gates judge any finished build with"
    echo "   evidence. Do NOT route this to resync.sh — its rebuild left near-zero"
    echo "   sample durations on this class (verify gate (d) FAIL). Honest routes if"
    echo "   the build's verdict says no:"
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
      echo "     repair:    $PFILL   (keeps real PTS; rebuild-paff would shuffle motion)"
    else
      echo "     reliable:  $RB"
      echo "     or verify a copy with the scrub gate before trusting it:"
      echo "                scripts/verify.sh \"$IN\" OUT.mov   (fails on a glitchy scrub)"
    fi
  elif [ "${DISC_COUNT:-0}" -gt 0 ]; then
    echo ">> VERDICT: DISCONTINUOUS SOURCE — ${DISC_COUNT} forward timestamp gap(s),"
    echo "   first @ ${DISC_FIRST}s (~${DISC_MISSING}s dropped). Video timing is otherwise"
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
    if [ "${nreal:-0}" -eq 0 ]; then
      echo ">> VERDICT: MID-GOP START (pre-roll only, ${prekey} packets) — losslessly trim at"
      echo "   the first IDR: scripts/trim-to-idr.sh"
    else
      echo ">> VERDICT: MID-GOP START (${prekey} pre-roll packets; $nreal decode line(s) beyond"
      echo "   them — see step 1) — losslessly trim at the first IDR: scripts/trim-to-idr.sh"
    fi
    echo "   The capture JOINED the broadcast mid-GOP: packets before the first keyframe"
    echo "   reference frames that were never captured, decode as garbage, and every"
    echo "   player conceals them. That is pre-roll, NOT damage (damage needs nonzero"
    echo "   transport counters — step 1). After the trim, remux as usual (Rung 0)."
  else
    echo ">> VERDICT: timing looks sound -> plain copy (Rung 0): scripts/remux.sh."
    echo "   (If MOV still glitches despite this, repair by profile: $REPAIR)"
  fi
else
  echo ">> VERDICT: timestamps problematic (MKV refused) -> repair: $REPAIR"
fi
# A discontinuous source still needs an audio gap-fill even when the video path is
# a rebuild (PAFF / non-monotonic) — flag it so it isn't missed on those branches.
if [ "${DISC_COUNT:-0}" -gt 0 ] && { [ "${nmono:-0}" -ge 10 ] || [ "${ndup:-0}" -gt 0 ] || [ "${nback:-0}" -gt 0 ] || [ "$PF_PAFF" = yes ]; }; then
  echo "   ALSO: ${DISC_COUNT} discontinuit(ies) present — if any audio track is raw PCM,"
  echo "   gap-fill it (scripts/resync.sh) so audio stays pinned through the rebuild."
fi
# Mid-GOP pre-roll rides along with any other verdict (a capture can join the
# broadcast mid-GOP AND have gaps/rot/PAFF) — surface the lossless trim route
# whenever the dedicated MID-GOP START verdict above did not fire.
if [ "${prekey:-0}" -gt 0 ] && [ "${midgop_said:-0}" -eq 0 ]; then
  echo "   ALSO: capture starts MID-GOP (${prekey} pre-keyframe pre-roll packet(s), concealed"
  echo "   by players, not damage) — losslessly trim at the first IDR: scripts/trim-to-idr.sh"
fi
