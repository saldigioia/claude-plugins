#!/usr/bin/env bash
# auto.sh — the escalation ladder, executable. Probe -> pick the lowest viable
# rung -> remux/rebuild -> verify -> escalate on a bad verdict. Removes the manual
# rung choice (the step where the original corruption slipped in).
#
# Usage: scripts/auto.sh INPUT OUTPUT.mov [--dry-run] [--all-audio] [--full]
#                                         [--audio auto|copy|pcm]
#   --dry-run   print the plan (chosen rung + command + escalation) and stop
#   --all-audio map every audio track on the Rung 3-SYNC resync escalation
#               (resync.sh's own default is a:0 only). Moot elsewhere: rungs
#               0/1/2 run remux.sh, which keeps every track by default (WO
#               3.3); the PAFF rungs fix their own policy (the rebuild carries
#               all tracks, pairfill a:0 only — with a printed WARN)
#   --full      pass --full to verify.sh (archival sign-off)
#   --audio M   override audio handling passed to remux.sh
#   --mp4-swap  on a post-build fidelity FAIL, take the CONTAINER-SWAP rung
#               (scripts/mp4-swap.sh — same bitstream, .mp4, mp4v+esds) instead
#               of only naming it. Rung 4 is the last route out of a bad render,
#               never the first (D2, 1.13)
#
# Guarantees: NEVER re-encodes (Rung 4 is a human decision); NEVER touches or
# deletes the source; output is written atomically by the sub-scripts.
# Exit: 0 = verified OK; 10 = REVIEW (written, needs a human look — includes a
#       contribution-profile build whose post-build playability check FAILed or
#       could not run on this platform, WO 4.1; also the Rung 3-DERIVE
#       dependency REVIEW: the measured route needs the PyAV venv, it is
#       absent, the bootstrap was printed and nothing was written — WO 1.14
#       Phase 4); 1 = FAIL;
#       11 = REFUSED (since 1.11 the backhaul gate refuses NOTHING here: the
#       4:2:2 profile builds and is playability-tested after (WO 4.1), and
#       timeline rot WARNS + builds + lets the mux-confession hard stop and
#       verify judge (WO 4.2). auto.sh itself refuses only the UNROUTABLE
#       codecs pre-flight (VC-1/VP9/AV1 video, Dolby E audio — the shared
#       WO 5.2 gate, added here in the 1.11 fix round so a direct run can
#       never die in a raw muxer error). SINCE 1.16.0 a child's own refusal
#       propagates too: a rung exiting 3 or 11 wrote nothing and found nothing
#       wrong with any artifact, so the ladder reports result=REFUSED
#       best_rung=none and exits 11 — never ">> FAIL", which sent the operator
#       hunting for damage that does not exist (WO-1.15.21 C1, field-confirmed
#       2026-08-28; TIERS.md T3.12; pinned by test 102). The discriminator is
#       whether an ARTIFACT EXISTS: a rung that built something and failed its
#       gates is still FAIL.
# WO 2.3: the final verdict is the grade of the BEST verified artifact at OUT —
# a failed escalation is reported separately and never condemns a prior rung —
# and a REVIEW that is solely gate (f)'s gap-collapse escalates to resync.sh
# (video bit-identical, audio re-timed; honestly capped at REVIEW), never to a
# timestamp-profile repair for a problem the file has proven it does not have.
set -euo pipefail
export LC_ALL=C   # comma-decimal locales disarm awk float parsing (CHECKUP-2026-08-27 A3; rationale in lib-probe.sh, which this script does not source)
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
IN="${1:?usage: auto.sh INPUT OUTPUT.mov [--dry-run] [--all-audio] [--full] [--audio MODE]}"
OUT="${2:?need OUTPUT.mov}"; shift 2
DRY=0; ALLAUD=""; FULL=""; AUDIO=""; PLAYABLE=0; MP4SWAP=0
while [ $# -gt 0 ]; do case "$1" in
  --dry-run)   DRY=1; shift;;
  --all-audio) ALLAUD="--all-audio"; shift;;
  --full)      FULL="--full"; shift;;
  --playable)  PLAYABLE=1; shift;;     # macOS: confirm QuickTime can actually play it
  --mp4-swap)  MP4SWAP=1; shift;;      # on a fidelity FAIL, take the container-swap rung (D2)
  --audio)     AUDIO="${2:?--audio needs a value}"; shift 2;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
. "$SELF_DIR/lib-paff.sh"
. "$SELF_DIR/lib-mux.sh"    # rtm_sidecar: extension-keeping intermediates (D6)
rtm_sibling_guard "$IN" "$OUT" || exit 2   # TIER 1 T1.11 write beside the source, never onto it (one writer: lib-mux.sh)

# eval only well-formed PR_/PF_ KEY=VAL lines. probe emits controlled ffprobe
# tokens (never the path) — the filter is defense-in-depth so a stray line can't
# become code. If you ever add a PR_ value that embeds $IN/$OUT, parse, don't eval.
# EMPTY ≠ ABSENT (CHECKUP-2026-08-27 A1 / WO-1.15.4): capture the probe's exit
# status — the grep used to launder it away, and a failed probe eval'd a
# manifest with a FABRICATED PR_AUD_COUNT=0 (probe.sh's END block), silently
# disabling this driver's Dolby-E refusal loop. Pre-flight refusal, exit 2.
set +e; PKV=$(bash "$SELF_DIR/probe.sh" "$IN" --kv); pkv_rc=$?; set -e
if [ "$pkv_rc" -ne 0 ] || ! printf '%s\n' "$PKV" | grep -q '^PR_AUD_COUNT='; then
  echo ">> REFUSED (pre-flight): probe.sh --kv failed (rc=$pkv_rc) or returned no audio" >&2
  echo "   manifest — cannot route this source (EMPTY is not ABSENT). Nothing written." >&2
  exit 2   # TIER 1 instrumentation: a failed probe is not a measurement (III.1)
fi
eval "$(printf '%s\n' "$PKV" | grep -E '^(PR|PF)_[A-Z0-9_]+=')"   # PR_* + PF_*
echo "== auto: $IN -> $OUT =="
echo "   probe: vcodec=$PR_VCODEC audio=$PR_ACODEC($PR_AUDIO_ACTION) paff=$PF_PAFF half_ts=${PF_HALF_TS:-no} reorder=${PF_REORDER:-no} -> first rung $PR_REC_RUNG"

# unroutable codecs — the same pre-flight refusal mov.sh issues, enforced here
# too (1.11 fix round; the 1.10.0 gate-at-every-entry-point standard). Before
# this, a direct auto.sh run on VP9 burned rungs 0->2->3 — including a
# nonsense rebuild-paff h264 extraction — and died in the raw muxer stack
# trace with a 0-byte .part littered, while batch.sh recorded the class FAIL
# instead of REFUSED. Shared classifiers + voice: lib-paff.sh (exit 11,
# MOV_REFUSED, nothing written). auto.sh has no --audio-keep, so ANY Dolby E
# track refuses — the exclude route (mov.sh/remux.sh --audio-keep) is named
# in the refusal itself.
if unroutable_v "$PR_VCODEC"; then
  unroutable_v_refuse "$PR_VCODEC"
  exit 11   # TIER 3 T3.8 cached deterministic attempt (the muxer's own rejection)
fi
ua_i=0
while [ "$ua_i" -lt "${PR_AUD_COUNT:-0}" ]; do
  eval "ua_c=\${PR_AUD_${ua_i}_CODEC:-}"
  if unroutable_a "$ua_c"; then
    unroutable_a_refuse "$ua_i"
    exit 11   # TIER 3 T3.8 cached deterministic attempt (the muxer's own rejection)
  fi
  ua_i=$((ua_i+1))
done

# backhaul gate — the same verdict mov.sh reaches at the front door, enforced
# here so batch.sh and direct auto.sh runs can never diverge. Since 1.11 the
# gate refuses NOTHING (the stale "rot still refuses (exit 11)" claim died in
# the WO 5.2 messaging pass): the 4:2:2 contribution profile prints the shared
# advisory and gets its playability PROVEN post-build below (WO 4.1), and
# timeline rot WARNS (MOV_ROT_WARN + the three routes) and builds — the
# mux-confession hard stop and verify.sh judge the result (WO 4.2).
# RTM_FORCE_BACKHAUL=1 skips the rot scan+warning only.
backhaul_gate "$IN" "$PR_VCODEC" "${PR_PIX_FMT:-}" "${PR_CONTAINER:-}" || exit $?
export RTM_BACKHAUL_GATED=1   # children (remux/rebuild/pairfill) skip the re-check
# WO 4.1: on a contribution profile the playability proof is OWED after the
# build (computed from the probe, not the gate — a gated caller like mov.sh
# exports RTM_BACKHAUL_GATED=1, which mutes the gate but never the proof)
PLAYCHECK_DUE=0
if qt_contribution_profile "${PR_PIX_FMT:-}"; then PLAYCHECK_DUE=1; fi

# For a non-PAFF broken timeline, the Rung-3 rebuild rate comes from the measured
# coded-picture rate; fall back to a clean mapping.
RB_RATE="$PF_FIELD_RATE"; RB_TS="$PF_TIMESCALE"
if [ "$RB_RATE" = unknown ]; then sg=$(pf_suggest_field_rate "$PF_CODED_RATE"); RB_RATE=${sg%% *}; RB_TS=${sg##* }; fi

rung_desc () { case "$1" in
  3-poc) echo "Rung 3-POC (poc-remux.sh — fields paired per ISO/IEC 14496-15, every frame timed from its own pic_order_cnt)";;
  0) echo "Rung 0 (pure copy)";; 1) echo "Rung 1 (copy video + PCM audio)";;
  2) echo "Rung 2 (copy + genpts)";; 3) echo "Rung 3 (field-rate rebuild @ $RB_RATE)";;
  P) echo "Rung 3-PAIR (pair-mate PTS fill — keeps every real PTS)";;
  3-derive) echo "Rung 3-DERIVE (derive-dts.sh — DTS derived from the sorted PTS column; PTS-complete reordered, codec-agnostic)";;
  S) echo "Rung 3-SYNC (resync.sh — video copy, audio re-timed to the picture)";; esac; }
run_rung () { case "$1" in
  0) bash "$SELF_DIR/remux.sh" "$IN" "$OUT" ${AUDIO:+--audio "$AUDIO"} $ALLAUD;;
  1) bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --audio "${AUDIO:-pcm}" $ALLAUD;;
  2) bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --genpts ${AUDIO:+--audio "$AUDIO"} $ALLAUD;;
  3) bash "$SELF_DIR/rebuild-paff.sh" "$IN" "$OUT" "$RB_RATE" "$RB_TS";;
  P) bash "$SELF_DIR/pairfill-paff.sh" "$IN" "$OUT";;
  3-derive) bash "$SELF_DIR/derive-dts.sh" "$IN" "$OUT";;
esac; }

# Rung 3-DERIVE escalation signature (WO 1.14 Phase 4): PTS-complete
# (nopts_frac ~ 0) + reorder pyramid + depth class NOT unknown (an unparseable
# SPS is never restamped automatically — derive-dts.sh itself refuses that
# class without --force, and match-frame is left to its gate too: a failed
# attempt is settled by the best-artifact machinery, never a cascade).
derive_sig_esc () {
  [ "${PF_REORDER:-no}" = yes ] || return 1
  # WO-1.15.20 S2: the rung covers the sparse-unstamped class too now — its
  # pre-pass stamps isolated holes from their pair-mates before deriving — so
  # the routing predicate is pf_derive_routable, not PTS-completeness alone.
  # The bound this widens to is a ROUTE HINT measured over a 240-packet head
  # window; the rung reads every packet and settles fill-or-refuse itself (S3).
  pf_derive_routable || return 1   # F9/WO-1.15.20: shared bounds (lib-paff.sh)
  [ "${PF_DEPTH_CLASS:-unknown}" != unknown ]
}

RESULT=FAIL; USED_RUNG=""
# WO 2.3 (escalation honesty; measured on the trimmed BBC build): verify failed
# ONLY gate (f) — the A/V duration gap-collapse — and NAMED its own remedy
# ("resync.sh to fix"), yet the ladder escalated to pair-fill, a timestamp-
# profile repair for a problem the file had just proven it does not have
# (every timeline/decode/scrub gate passed). Pair-fill missed its own gates
# ~18x and the cascade downgraded the run to "FAIL: no verified lossless MOV"
# — condemning the Rung-1 artifact on disk with proven-lossless video (VCL
# MATCH). Two rules fix that:
#   RIGHT RUNG — a REVIEW whose verify note is SOLELY the gate-(f) gap-collapse
#   signature escalates to resync.sh: video stays a bit-identical copy, audio
#   is re-timed to the picture, and the verdict is honestly capped at REVIEW
#   (re-timed audio is not a bit-exact copy, so it is never an OK). Copy-class
#   rungs (0/1/2) only — a half-timestamped PAFF source still needs pair-fill
#   for its VIDEO timeline, and resync's genpts copy would invent it.
#   NO VERDICT CASCADE — the best verified artifact is parked before a riskier
#   escalation and restored when the escalation does worse; the final verdict
#   is the grade of the artifact actually at OUT, and the escalation's own
#   failure is reported separately (pair-fill's timeline gates themselves are
#   untouched: the cascade was the defect, not the gates).
BEST_RESULT=FAIL; BEST_RUNG=none        # grade + rung of the artifact at OUT
# EXTENSION-KEEPING park name (D6, 1.13): "$OUT.autobest" hid the extension, so
# the one artifact an operator most wants to inspect mid-ladder — the verified
# rung the escalation is about to overwrite — could not be opened by the
# extension-keyed macOS tools (qlmanage/avconvert) at all.
BEST_SAVE="$(rtm_sidecar "$OUT" autobest)"   # parks the best artifact during a riskier attempt
GATE_F_ONLY=0
rank () { case "$1" in OK) echo 2;; REVIEW) echo 1;; *) echo 0;; esac; }
# WO-1.15.21 C1 / TIERS.md T3.12: REFUSED is not FAIL. A refusal means a gate
# did its job — nothing written, source unchanged, a named reason — while FAIL
# means an artifact exists and did not verify. They rank the same (neither is
# an artifact) and they are REPORTED differently, because the operator's next
# move differs: a FAIL sends you looking for damage, a REFUSED sends you to
# the named route. ANY_REFUSED records that at least one rung refused, so the
# terminal verdict can tell "nothing built because gates refused" from
# "nothing built because everything failed".
ANY_REFUSED=0; REFUSED_RUNGS=""
note_refusal () {   # $1 = rung, $2 = child rc
  ANY_REFUSED=1; REFUSED_RUNGS="${REFUSED_RUNGS:+$REFUSED_RUNGS,}$1(exit $2)"
}
save_best () {  # park a REVIEW-or-better artifact before the next attempt overwrites OUT
  [ -f "$OUT" ] && [ "$(rank "$BEST_RESULT")" -ge 1 ] && mv -f "$OUT" "$BEST_SAVE"
  return 0
}
settle_best () {  # $1 = rung just attempted: reconcile OUT vs the parked best
  if [ -f "$OUT" ] && [ "$(rank "$RESULT")" -ge "$(rank "$BEST_RESULT")" ]; then
    rm -f "$BEST_SAVE"                  # at least as good -> the new artifact is the best now
    BEST_RESULT=$RESULT; BEST_RUNG="$1"
  elif [ -f "$BEST_SAVE" ]; then
    # the escalation did worse (or wrote nothing): put the better artifact back —
    # a failed escalation never condemns the rung that already verified.
    echo "   (rung $1 did worse than the verified $(rung_desc "$BEST_RUNG") artifact — restoring it)"
    rm -f "$OUT"
    mv -f "$BEST_SAVE" "$OUT"
  fi
}
attempt () {  # $1 = rung; sets RESULT to OK|REVIEW|FAIL (+ GATE_F_ONLY on the gap-collapse signature)
  USED_RUNG="$1"; GATE_F_ONLY=0
  echo "-- attempting $(rung_desc "$1") --"
  save_best
  local rrc=0
  run_rung "$1" || rrc=$?
  if [ "$rrc" -ne 0 ]; then
    case "$rrc" in
      3|11) echo "   (rung $1 REFUSED, exit $rrc — nothing built; its reason is above)"
            note_refusal "$1" "$rrc"; RESULT=REFUSED ;;
      *)    echo "   (rung $1 command failed to produce output)"; RESULT=FAIL ;;
    esac
    settle_best "$1"; return 0
  fi
  local o
  o=$(bash "$SELF_DIR/verify.sh" "$IN" "$OUT" $FULL 2>&1) || true
  echo "$o" | sed 's/^/   verify: /'
  case "$o" in *">> OK"*) RESULT=OK;; *">> REVIEW"*) RESULT=REVIEW;; *) RESULT=FAIL;; esac
  # gate-(f)-ONLY detection. It used to anchor on the whole REVIEW NOTE being
  # the (f) gap-collapse sentence — which meant any other gate adding a note,
  # however benign, silently changed the route. Since 1.16.0 verify.sh emits a
  # LEDGER with one row per gate, so the claim "only gate (f)" can be READ
  # rather than inferred from prose: every gate is pass/n-a/superseded except
  # (f), which is flagged. The note match stays as the confirming half.
  local f_row others
  f_row=$(printf '%s\n' "$o" | sed -n 's/^ *VERIFY_LEDGER gate=f verdict=\([a-z\/]*\) .*/\1/p' | head -1)
  others=$(printf '%s\n' "$o" | sed -n 's/^ *VERIFY_LEDGER gate=\([a-z]*\) verdict=\([a-z\/]*\) .*/\1 \2/p' \
           | awk '$1!="f" && $2!="pass" && $2!="n/a" && $2!="superseded"{n++} END{print n+0}')
  if [ "${f_row:-}" = flagged ] && [ "${others:-1}" -eq 0 ]; then GATE_F_ONLY=1; fi
  case "$(printf '%s\n' "$o" | sed -n 's/^>> REVIEW: //p' | head -1)" in
    "A/V duration mismatch up to "*"gap-collapse desync signature"*"resync.sh to fix.") GATE_F_ONLY=1;;
  esac
  settle_best "$1"
}
POC_BOOT=0; POC_TRIED=0
attempt_pocmux () {   # Rung 3-POC — same dependency shape as 3-DERIVE
  USED_RUNG=3-poc; GATE_F_ONLY=0; POC_TRIED=1
  echo "-- attempting $(rung_desc 3-poc) --"
  save_best
  local rc=0 o
  o=$(bash "$SELF_DIR/poc-remux.sh" "$IN" "$OUT" 2>&1) || rc=$?
  printf '%s\n' "$o" | sed 's/^/   /'
  case "$rc" in
    0)  RESULT=OK ;;
    10) if [ -f "$OUT" ]; then RESULT=REVIEW
        else POC_BOOT=1; RESULT=FAIL; fi ;;   # venv absent: nothing written
    3|11) note_refusal 3-poc "$rc"; RESULT=REFUSED ;;
    *)  RESULT=FAIL ;;
  esac
  settle_best 3-poc
}
DERIVE_BOOT=0; DERIVE_TRIED=0
attempt_derive () {  # Rung 3-DERIVE — special-cased for its exit-10 dependency REVIEW
  USED_RUNG=3-derive; GATE_F_ONLY=0; DERIVE_TRIED=1
  echo "-- attempting $(rung_desc 3-derive) --"
  save_best
  local rc=0 o
  o=$(bash "$SELF_DIR/derive-dts.sh" "$IN" "$OUT" 2>&1) || rc=$?
  printf '%s\n' "$o" | sed 's/^/   /'
  if [ "$rc" -eq 0 ] && [ -f "$OUT" ]; then
    local v
    v=$(bash "$SELF_DIR/verify.sh" "$IN" "$OUT" $FULL 2>&1) || true
    printf '%s\n' "$v" | sed 's/^/   verify: /'
    case "$v" in *">> OK"*) RESULT=OK;; *">> REVIEW"*) RESULT=REVIEW;; *) RESULT=FAIL;; esac
  elif [ "$rc" -eq 10 ] && [ ! -f "$OUT" ]; then
    # venv absent (the rung printed its one-line bootstrap + manual recipe
    # above): a missing OPTIONAL dependency is a human item — the ladder's
    # verdict surfaces it as REVIEW below, never a crash and never a bare FAIL.
    DERIVE_BOOT=1; RESULT=FAIL
  elif [ "$rc" -eq 3 ] || [ "$rc" -eq 11 ]; then
    # WO-1.15.21 C1: THE site. A signature refusal wrote nothing and found
    # nothing wrong with any artifact; reporting it as FAIL sent the operator
    # hunting for damage that does not exist.
    note_refusal 3-derive "$rc"; RESULT=REFUSED
  else
    RESULT=FAIL      # a failed gate on a build that DID happen
  fi
  settle_best 3-derive
}
attempt_resync () {  # gate-(f)-only escalation: the remedy verify itself named
  USED_RUNG=S; GATE_F_ONLY=0
  echo "-- attempting $(rung_desc S) --"
  save_best
  local rc=0
  # resync.sh verifies its own build (incl. the --silence content gate) and can
  # REFUSE (exit 11, mid-stream layout change) — capture its code, never mask it.
  bash "$SELF_DIR/resync.sh" "$IN" "$OUT" $ALLAUD | sed 's/^/   /' || rc=$?
  case "$rc" in
    0|10) RESULT=REVIEW ;;  # honest cap: video lossless, audio RE-TIMED (not a bit-exact copy)
    11)   note_refusal S 11; RESULT=REFUSED ;;   # resync's own layout guard: nothing built
    *)    RESULT=FAIL ;;    # 1 FAIL: no resync artifact to bless
  esac
  settle_best S
}

# PAFF routing by TIMESTAMP PROFILE (post-mortem 2026-07-25). "All PAFF ->
# constant-rate rebuild" was wrong: on a stream with a reorder pyramid the
# rebuild sets PTS=DTS and plays fields in DECODE order — shuffled motion the
# default verify tier cannot see. So a reordered stream must KEEP its real PTS,
# and auto NEVER falls back from pairfill to the flattening rebuild when a
# pyramid is present.
BASE_RUNG="$PR_REC_RUNG"; [ "$PF_PAFF" = yes ] && { BASE_RUNG=0; [ "$PR_AUDIO_ACTION" = pcm ] && BASE_RUNG=1; }
# The Rung 3-POC routing measurement, from the SHARED writer (lib-paff.sh) —
# diagnose.sh recommends this rung off the same predicate, and a driver that
# re-derived it would drift from the tool it is driving (IV.2).
if [ "$PF_PAFF" = yes ] && [ "${PF_CODEC:-${PR_VCODEC:-na}}" = h264 ]; then
  eval "$(pf_poc_probe "$IN")" || true
fi

if [ "$DRY" -eq 1 ]; then
  echo ">> DRY-RUN — no files written."
  if [ "$PF_PAFF" = yes ]; then
    if [ "${PF_HALF_TS:-no}" = yes ]; then
      echo "   plan: $(rung_desc P)  [pair-timestamped PAFF -> fill the pair-mates]"
      echo "   cmd : pairfill-paff.sh \"$IN\" \"$OUT\""
      [ "${PF_REORDER:-no}" = yes ] && echo "   no rebuild fallback: reorder pyramid present (rebuild would shuffle motion)." \
        || echo "   escalation if verify is not OK: Rung 3 (rebuild @ $RB_RATE — no reorder survives)."
    elif [ "${PF_REORDER:-no}" = yes ]; then
      echo "   plan: $(rung_desc "$BASE_RUNG")  [full-TS reordered PAFF: a copy KEEPS the true pyramid; scrub-gated]"
      if derive_sig_esc; then
        echo "   escalation if verify is not OK: gate-(f)-only gap-collapse -> resync.sh (audio"
        echo "   re-timed, REVIEW-grade); otherwise $(rung_desc 3-derive)"
        echo "   [pairfill signature absent (half_ts=no); derive signature measured: nopts_frac=${PF_NOPTS_FRAC:-?}"
        echo "   + reorder, depth_class=${PF_DEPTH_CLASS:-?}]. Never the flattening rebuild."
      else
        echo "   escalation if verify is not OK: gate-(f)-only gap-collapse -> resync.sh (audio"
        echo "   re-timed, REVIEW-grade); otherwise $(rung_desc P). Never the flattening rebuild."
      fi
    else
      echo "   plan: $(rung_desc 3)  [field-coded, no reorder -> genpts is guilty-until-proven]"
      echo "   cmd : rebuild-paff.sh \"$IN\" \"$OUT\" $RB_RATE $RB_TS"
    fi
  else
    echo "   plan: $(rung_desc "$PR_REC_RUNG")"
    echo "   cmd : $PR_REC_CMD"
    if [ "$PR_REC_RUNG" = 3-derive ]; then
      # WO-1.15.20 S2: the label must follow the measurement. Widening the
      # route to the sparse class made a flat "(PTS-complete)" false for half
      # the profiles that reach here — 0.008 is not complete, it is sparse
      # enough for the pre-pass to complete it (Article II.3).
      DRY_TSNOTE="PTS-complete"
      pf_sparse_nopts && DRY_TSNOTE="sparse-unstamped: the rung's pre-pass stamps the holes from their pair-mates first"
      echo "   [probe measured the derive profile: nopts_frac=${PF_NOPTS_FRAC:-?} ($DRY_TSNOTE) + reorder,"
      echo "   depth_class=${PF_DEPTH_CLASS:-?}, dts_short=${PF_DTS_SHORT:-?}]"
      echo "   escalation if verify is not OK: copy ladder fallback (Rung 0, scrub-gated);"
      echo "   venv-absent exit 10 surfaces the rung's bootstrap as REVIEW."
    elif derive_sig_esc; then
      echo "   escalation if verify is not OK: gate-(f)-only gap-collapse -> resync.sh (audio"
      echo "   re-timed, REVIEW-grade); otherwise Rung 2 (genpts) -> $(rung_desc 3-derive)"
      echo "   [derive signature measured: nopts_frac=${PF_NOPTS_FRAC:-?} + reorder, depth_class=${PF_DEPTH_CLASS:-?}]"
      echo "   -> Rung 3 (rebuild @ $RB_RATE; refuses reordered streams)."
    else
      echo "   escalation if verify is not OK: gate-(f)-only gap-collapse -> resync.sh (audio"
      echo "   re-timed, REVIEW-grade); otherwise Rung 2 (genpts) -> Rung 3 (rebuild @ $RB_RATE; refuses reordered streams)."
    fi
  fi
  echo "   then: verify.sh \"$IN\" \"$OUT\" $FULL  (re-encode/Rung 4 is never automatic)"
  exit 0
fi

# ONE WRITER per OUT (WO-1.15.6 / CHECKUP-2026-08-27 A2): the ladder holds one
# lock across every rung attempt, the .autobest park, and each verify read of
# OUT; children re-enter via RTM_LOCK_HELD and run the disk pre-flight
# themselves. Acquired after --dry-run (which writes nothing) has exited.
trap 'rtm_unlock' EXIT
rtm_lock "$OUT" || exit 2
# T1.10 final-OUT no-clobber: the ladder claims OUT ONCE, here, before any
# rung runs. Every child then re-enters under this lock and is never asked
# again, so escalation still replaces the ladder's own artifact freely.
rtm_claim_out "$OUT" || exit 2   # TIER 1 T1.10 final-OUT no-clobber

rm -f "$BEST_SAVE"   # a stale park from a killed earlier run must never be "restored"

if [ "$PF_PAFF" = yes ]; then
  if [ "${PF_HALF_TS:-no}" = yes ]; then
    attempt P                                  # pair class: keep real PTS, fill mates
    # WO-1.15.3 Item 1 step 6 (decided, deliberate): pairfill's capability
    # pre-flight (pic_order_cnt_type != 0 -> exit 3, nothing built) lands here
    # as a generic RESULT=FAIL like any pairfill non-OK, and the ESTABLISHED
    # fallbacks stand: PF_REORDER=no proceeds to the flattening rebuild
    # (doctrine-legal for a no-pyramid stream), reorder + derive signature
    # escalates to Rung 3-DERIVE. NEITHER carries a POC gate — the deliverable
    # is judged by its own rung's gates only, and pairfill's refusal message
    # says exactly that. The refusal guarantees only that pairfill itself
    # wrote nothing.
    if [ "$RESULT" != OK ]; then
      if [ "${PF_REORDER:-no}" = no ]; then
        echo "-- verdict $RESULT and no reorder pyramid -> field-rate rebuild --"
        attempt 3
      elif derive_sig_esc; then
        # WO 1.14 Phase 4: pair-fill did not verify (or refused, exit 3) and
        # the derive signature holds — the rung between 3-PAIR and terminal.
        echo "-- verdict $RESULT + derive signature (nopts_frac=${PF_NOPTS_FRAC:-?}, reorder=yes, depth_class=${PF_DEPTH_CLASS:-?}) -> Rung 3-DERIVE --"
        attempt_derive
      fi
    fi
  elif [ "${PF_REORDER:-no}" = yes ]; then
    # TIERS.md T3.1 — CUT in 1.16.0, and this is the exemplar case for the
    # whole re-aim. F9 (2026-08-28) skipped this rung whenever the source had
    # unstamped packets, reasoning: the muxer cannot write a packet with no
    # PTS, so it invents one, so the confession gate refuses the output, so
    # the write is a foregone waste. Every clause was plausible and the
    # conclusion was false. MEASURED 2026-08-29 on the capture that motivated
    # the skip: all nine plain `-c copy` variants return rc=0 and write every
    # packet (scripts/attempt-battery.sh reproduces it on demand). What ffmpeg
    # silently produces instead is a wrong TIMELINE — which is gates
    # (d)/(j)/(k)'s job, not a reason to refuse the attempt.
    #
    # The prediction is not deleted, it is demoted to what it always was: a
    # warning with its measurement attached, ahead of an attempt that settles
    # the question. The costs are asymmetric — a doomed build wastes a pass;
    # a refusal on a false prediction cost three sessions and never produced
    # the evidence that would have corrected it, because it never ran.
    if ! pf_pts_complete; then
      echo "-- Rung $BASE_RUNG (copy) — WARNING, not a refusal: nopts_frac=${PF_NOPTS_FRAC:-?} (head window)."
      echo "   Packets carrying data but no PTS make the muxer invent timing for them, so"
      echo "   this build may fail its timeline gates ((d) N/A stamps, (j) duplicate display"
      echo "   slots, (k) presentation order vs POC). Attempting anyway: the artifact and its"
      echo "   gate counts are evidence, and a prediction about them is not."
    fi
    attempt "$BASE_RUNG"                       # full-TS pyramid: copy keeps the truth; scrub-gated
    if [ "$RESULT" = REVIEW ] && [ "$GATE_F_ONLY" -eq 1 ]; then
      # the measured BBC cascade: gate (f) alone is a SYNC defect — pair-fill is a
      # timestamp-profile repair for a problem this file just proved it does not
      # have (every timeline gate passed). resync is the remedy verify named; the
      # video side stays the same bit-identical copy that keeps the pyramid.
      echo "-- verify failed ONLY gate (f) (gap-collapse) -> resync.sh, not pair-fill --"
      attempt_resync
    elif [ "$RESULT" != OK ]; then
      if pf_poc_routable; then
        # 1.16.0: the class no rung before this one fitted — fields coded
        # adjacently and sharing frame_num (so the STRUCTURE is paired) while
        # their timestamps are not one field duration apart (so every delta
        # heuristic reads "no pairing here" and refuses). Rung 3-POC reads the
        # pairing and the display positions from the slice headers directly.
        echo "-- verdict $RESULT; the slice headers show ${PP_PAIRS:-0} complementary field pair(s)"
        echo "   with pic_order_cnt readable (poc_type=${PCAP_POC_TYPE:--1}) -> Rung 3-POC --"
        attempt_pocmux
        if [ "$RESULT" != OK ] && [ "$POC_BOOT" -eq 0 ] && derive_sig_esc; then
          echo "-- verdict $RESULT -> Rung 3-DERIVE --"
          attempt_derive
        fi
      elif derive_sig_esc; then
        # WO 1.14 Phase 4: the pairfill SIGNATURE is absent here (half_ts=no —
        # pairfill's own precondition names derive for exactly this shape) and
        # the derive signature is measured, so the ladder goes straight to it.
        echo "-- verdict $RESULT; pairfill signature absent (half_ts=no) + derive signature (nopts_frac=${PF_NOPTS_FRAC:-?}, reorder=yes, depth_class=${PF_DEPTH_CLASS:-?}) -> Rung 3-DERIVE --"
        attempt_derive
      elif [ "${PF_HALF_TS:-no}" = yes ]; then
        echo "-- verdict $RESULT -> pair-fill (keeps real PTS; never the flattening rebuild) --"
        attempt P
      else
        # F9 (2026-08-28): pair-fill is NOT a general fallback. Its model is a
        # pair-cadence DTS ramp, which a deep reorder pyramid violates by
        # construction — and its precondition (half_ts=yes) is absent here.
        # Reaching it anyway cost the 2024-VMA capture a full 26.8 GB write
        # that its own timeline gates then rejected ("not the pair class at
        # all"), after derive_sig_esc had correctly declined the source.
        # WO-1.15.20 S2 narrows what this branch means. The composition F9
        # said did not exist NOW DOES — derive-dts's pre-pass stamps isolated
        # holes from their pair-mates and then derives — and derive_sig_esc
        # routes to it. What is left here is the band BETWEEN the two rungs:
        # too many unstamped packets to be isolated holes, too few to be the
        # pair signature. Nothing composes across that gap, and the verdict
        # says which side of it the file sits on rather than repeating a claim
        # this round retired.
        echo "-- verdict $RESULT; NO AUTOMATIC ROUTE (reorder=yes, half_ts=no,"
        echo "   nopts_frac=${PF_NOPTS_FRAC:-?}). The sparse pre-pass (Rung 3-DERIVE) stamps"
        echo "   ISOLATED unstamped packets from their pair-mates and is bounded at"
        echo "   ${RTM_SPARSE_NOPTS_MAX}; pair-fill needs the ~0.5 pair signature. This file sits"
        echo "   between them, so neither precondition holds."
        echo "   That fraction is a 240-packet head-window hint: if the whole-file count is"
        echo "   sparser than it reads, scripts/derive-dts.sh \"$IN\" OUT.mov reads every"
        echo "   packet and decides for itself (it writes nothing unless it can place all)."
        echo "   Diagnose: scripts/diagnose.sh \"$IN\"  (the source remains the master)."
      fi
    fi
  else
    attempt 3                                  # no reorder survives: constant-rate rebuild is safe
  fi
elif [ "$PR_REC_RUNG" = 3-derive ]; then
  # WO 1.14 Phase 4: probe measured the auto-proceed derive profile (PTS-complete
  # + reorder + provably short DTS column) — Rung 3-DERIVE is the first rung.
  attempt_derive
  if [ "$RESULT" != OK ] && [ "$DERIVE_BOOT" -eq 0 ]; then
    echo "-- verdict $RESULT -> copy ladder fallback (Rung 0; scrub-gated) --"
    attempt 0
    if [ "$RESULT" = REVIEW ] && [ "$GATE_F_ONLY" -eq 1 ]; then
      echo "-- verify failed ONLY gate (f) (gap-collapse) -> resync.sh, not a timestamp rung --"
      attempt_resync
    fi
  fi
else
  attempt "$PR_REC_RUNG"                       # Rung 0/1
  if [ "$RESULT" = REVIEW ] && [ "$GATE_F_ONLY" -eq 1 ]; then
    echo "-- verify failed ONLY gate (f) (gap-collapse) -> resync.sh, not a timestamp rung --"
    attempt_resync
  elif [ "$RESULT" != OK ]; then
    echo "-- verdict $RESULT -> escalating (timestamps) --"
    attempt 2                                  # genpts
    if [ "$RESULT" = REVIEW ] && [ "$GATE_F_ONLY" -eq 1 ]; then
      echo "-- genpts left ONLY the gate-(f) gap-collapse -> resync.sh --"
      attempt_resync
    elif [ "$RESULT" != OK ]; then
      # WO 1.14 Phase 4: the derive rung sits between the timestamp rungs and
      # the rebuild/terminal advice — attempted once, on measured evidence.
      if [ "$DERIVE_TRIED" -eq 0 ] && derive_sig_esc; then
        echo "-- verdict $RESULT + derive signature (nopts_frac=${PF_NOPTS_FRAC:-?}, reorder=yes, depth_class=${PF_DEPTH_CLASS:-?}) -> Rung 3-DERIVE --"
        attempt_derive
      fi
      if [ "$RESULT" != OK ] && [ "$RB_RATE" != unknown ]; then
        echo "-- verdict $RESULT -> escalating (field-rate rebuild) --"
        attempt 3                              # refuses by itself on a reordered stream
      fi
    fi
  fi
fi

# WO 2.3: the final verdict is the grade of the artifact actually at OUT — the
# best verified attempt — never the last (possibly failed) escalation's verdict.
RESULT="$BEST_RESULT"
# WO 1.14 Phase 4: when Rung 3-DERIVE was the measured route but could not run
# for want of its announced OPTIONAL dependency (PyAV venv, exit 10 — bootstrap
# printed by the rung), and nothing else verified, the honest ladder outcome is
# REVIEW with the remedy named — never a bare FAIL and never a crash.
if [ "$DERIVE_BOOT" -eq 1 ] && [ "$RESULT" = FAIL ] && [ ! -f "$OUT" ]; then
  RESULT=REVIEW
fi
if [ "$POC_BOOT" -eq 1 ] && [ "$RESULT" = FAIL ] && [ ! -f "$OUT" ]; then
  # same shape as the derive rung: a missing OPTIONAL dependency is a human
  # item with a printed bootstrap, never a bare FAIL and never a crash.
  RESULT=REVIEW
fi
# WO-1.15.21 C1: nothing verified, nothing at OUT, and at least one rung
# REFUSED -> the ladder's outcome is REFUSED, with no rung claimed. A rung that
# BUILT something and failed its gates keeps FAIL: the discriminator is whether
# an artifact exists, never how loud the child was.
if [ "$RESULT" = FAIL ] && [ ! -f "$OUT" ] && [ "$ANY_REFUSED" -eq 1 ]; then
  RESULT=REFUSED; BEST_RUNG=none; BEST_RESULT=REFUSED
fi

# --- post-build playability (WO 4.1): prove, don't guess -------------------
# Runs when the source is the 4:2:2 contribution class (the demoted gate's
# MANDATORY post-build proof — any REVIEW-or-better artifact is tested; FAIL
# has nothing verified to bless) or when the caller asked via --playable
# (legacy semantics kept: only an OK build is checked, and a non-macOS SKIP
# stays a no-op there). playability_verdict reuses playable-check.sh — the
# verdict self-dates its macOS (Ground Rule 6) — and emits the additive
# MOV_PLAYABILITY machine line. A FAIL verdict, or a platform that cannot
# verify a contribution-profile build, demotes to REVIEW: never a silent OK,
# never 11/1 — the artifact exists and its essence verified.
if [ -f "$OUT" ] && { { [ "$PLAYCHECK_DUE" -eq 1 ] && [ "$RESULT" != FAIL ]; } || { [ "$PLAYABLE" -eq 1 ] && [ "$RESULT" = OK ]; }; }; then
  # WO-B (2026-08-15): when the check is due because of the CONTRIBUTION
  # PROFILE (PLAYCHECK_DUE, qt_contribution_profile), it gets the fidelity
  # storey — the thumbnail-only check false-greened two real broadcast 4:2:2
  # masters on macOS 26.6.1 (rendered, destroyed; renders != renders
  # correctly). The legacy --playable opt-in stays thumbnail-only.
  AC_FID=""
  if [ "$PLAYCHECK_DUE" -eq 1 ] && [ "$RESULT" != FAIL ]; then AC_FID="--fidelity"; fi
  if [ -n "$AC_FID" ]; then
    echo "-- playability (macOS AVFoundation; empirical, per-file — thumbnail floor + fidelity SSIM vs ffmpeg reference) --"
  else
    echo "-- playability (macOS AVFoundation; empirical, per-file) --"
  fi
  playability_verdict "$OUT" ${AC_FID:+"$AC_FID"}
  case "$PLAY_VERDICT" in
    fail)
      RESULT=REVIEW; BEST_RESULT=REVIEW
      echo "   -> verified lossless but NOT correctly QuickTime-rendered on THIS macOS:"
      echo "      REVIEW. The artifact remains a legitimate lossless NLE/archival master"
      echo "      (IINA/VLC/mpv decode it); the next rung is the LOSSLESS CONTAINER SWAP,"
      echo "      not a re-encode (D2, 1.13)."
      if [ "$MP4SWAP" -eq 1 ]; then
        echo "-- container swap (--mp4-swap) --"
        set +e; bash "$SELF_DIR/mp4-swap.sh" "$IN" "${OUT%.*}.mp4" $FULL | sed 's/^/   /'; swrc=${PIPESTATUS[0]}; set -e
        case "$swrc" in
          0) echo "   >> the CONTAINER SWAP WORKS: ${OUT%.*}.mp4 is verified lossless AND renders correctly.";;
          *) echo "   >> the container swap did not produce a proven artifact (above; rc=$swrc).";;
        esac
      else
        echo "      Take the swap:  scripts/mp4-swap.sh \"$IN\" \"${OUT%.*}.mp4\""
        echo "      (or re-run with --mp4-swap). Only if THAT fails: Rung 4 (scripts/rung4.sh,"
        echo "      operator-attested re-encode)."
      fi
      ;;
    skip)
      if [ "$PLAYCHECK_DUE" -eq 1 ]; then
        RESULT=REVIEW; BEST_RESULT=REVIEW
        echo "   -> playability unverified on this platform: REVIEW — contribution-profile"
        echo "      output must be proven on the target Mac (scripts/playable-check.sh OUT)."
      fi
      ;;
  esac
fi

echo
# machine-readable for batch.sh. Field order is deliberate: batch.sh reads the
# last attempted rung with a greedy '.*rung=' sed, so the additive best_* fields
# (Ground Rule 4) sit BEFORE the plain rung= — after it, "best_rung=" would be
# the rightmost match and silently change what batch records.
echo "AUTO_SUMMARY result=$RESULT best_rung=$BEST_RUNG best_result=$BEST_RESULT rung=${USED_RUNG:-none}"
case "$RESULT" in
  OK)     echo ">> DONE: $OUT — verified lossless + timeline-clean."; exit 0;;
  REFUSED)
    echo ">> REFUSED: every route this ladder had refused this source at its own"
    echo "   pre-flight — nothing was built and nothing is wrong with any artifact."
    echo "   Refused rung(s): $REFUSED_RUNGS. Each refusal above names its measurement"
    echo "   and its route; that is where to go next, not to a damage hunt."
    echo "   Source untouched. Diagnose: scripts/diagnose.sh \"$IN\""
    exit 11;;   # TIER 3 T3.12 the ladder relays its children's refusals as REFUSED
  REVIEW)
    if [ "$DERIVE_BOOT" -eq 1 ] && [ ! -f "$OUT" ]; then
      echo ">> REVIEW: Rung 3-DERIVE is the measured route for this stream (PTS-complete +"
      echo "   reorder pyramid), but its PyAV venv is absent — nothing was written. The"
      echo "   one-line bootstrap and the manual recipe are printed above (derive-dts.sh"
      echo "   pre-flight); install the venv and re-run. Source untouched."
      exit 10
    fi
    if [ "$BEST_RUNG" = S ]; then
      echo ">> REVIEW: $OUT written — video BIT-IDENTICAL (lossless proven), audio RE-TIMED to"
      echo "   the picture (resync gap-fill; NOT a bit-exact copy of the source audio — that"
      echo "   residual is the review item)."
    elif [ "$BEST_RUNG" != "${USED_RUNG:-none}" ]; then
      echo ">> REVIEW: $OUT is the verified $(rung_desc "$BEST_RUNG") artifact (REVIEW-grade — its verify block is above)."
      echo "   The $(rung_desc "$USED_RUNG") escalation failed SEPARATELY (also above); a failed"
      echo "   escalation does not condemn this artifact."
    else
      echo ">> REVIEW: $OUT written, but verify wants a closer look (see above)."
    fi
    echo "   Source untouched. Inspect, or run: scripts/verify.sh \"$IN\" \"$OUT\" --full"; exit 10;;
  FAIL)   echo ">> FAIL: no verified lossless MOV without re-encoding."
          if [ -f "$OUT" ]; then echo "   Source untouched; the last attempt is at $OUT (unverified)."
          else echo "   Source untouched; no attempt produced a verifiable output."; fi
          echo "   Re-encode (Rung 4) is a manual decision — see references/delivery-encode.md."
          exit 1;;
esac
