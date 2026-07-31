#!/usr/bin/env bash
# auto.sh — the escalation ladder, executable. Probe -> pick the lowest viable
# rung -> remux/rebuild -> verify -> escalate on a bad verdict. Removes the manual
# rung choice (the step where the original corruption slipped in).
#
# Usage: scripts/auto.sh INPUT OUTPUT.mov [--dry-run] [--all-audio] [--full]
#                                         [--audio auto|copy|pcm]
#   --dry-run   print the plan (chosen rung + command + escalation) and stop
#   --all-audio map every audio track (default: a:0 only)
#   --full      pass --full to verify.sh (archival sign-off)
#   --audio M   override audio handling passed to remux.sh
#
# Guarantees: NEVER re-encodes (Rung 4 is a human decision); NEVER touches or
# deletes the source; output is written atomically by the sub-scripts.
# Exit: 0 = verified OK; 10 = REVIEW (written, needs a human look); 1 = FAIL;
#       11 = REFUSED by the backhaul gate (nothing written — same criteria as
#       mov.sh; RTM_FORCE_BACKHAUL=1 is the sanctioned override).
set -euo pipefail
IN="${1:?usage: auto.sh INPUT OUTPUT.mov [--dry-run] [--all-audio] [--full] [--audio MODE]}"
OUT="${2:?need OUTPUT.mov}"; shift 2
DRY=0; ALLAUD=""; FULL=""; AUDIO=""; PLAYABLE=0
while [ $# -gt 0 ]; do case "$1" in
  --dry-run)   DRY=1; shift;;
  --all-audio) ALLAUD="--all-audio"; shift;;
  --full)      FULL="--full"; shift;;
  --playable)  PLAYABLE=1; shift;;     # macOS: confirm QuickTime can actually play it
  --audio)     AUDIO="${2:?--audio needs a value}"; shift 2;;
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to write onto the source" >&2; exit 2; }
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-paff.sh"

# eval only well-formed PR_/PF_ KEY=VAL lines. probe emits controlled ffprobe
# tokens (never the path) — the filter is defense-in-depth so a stray line can't
# become code. If you ever add a PR_ value that embeds $IN/$OUT, parse, don't eval.
eval "$(bash "$SELF_DIR/probe.sh" "$IN" --kv | grep -E '^(PR|PF)_[A-Z0-9_]+=')"   # PR_* + PF_*
echo "== auto: $IN -> $OUT =="
echo "   probe: vcodec=$PR_VCODEC audio=$PR_ACODEC($PR_AUDIO_ACTION) paff=$PF_PAFF half_ts=${PF_HALF_TS:-no} reorder=${PF_REORDER:-no} -> first rung $PR_REC_RUNG"

# backhaul refusal gate — the same criteria mov.sh enforces at the front door,
# enforced here so batch.sh and direct auto.sh runs can never build a refused
# deliverable (exit 11, nothing written; RTM_FORCE_BACKHAUL=1 is the override).
backhaul_gate "$IN" "$PR_VCODEC" "${PR_PIX_FMT:-}" "${PR_CONTAINER:-}" || exit $?
export RTM_BACKHAUL_GATED=1   # children (remux/rebuild/pairfill) skip the re-check

# For a non-PAFF broken timeline, the Rung-3 rebuild rate comes from the measured
# coded-picture rate; fall back to a clean mapping.
RB_RATE="$PF_FIELD_RATE"; RB_TS="$PF_TIMESCALE"
if [ "$RB_RATE" = unknown ]; then sg=$(pf_suggest_field_rate "$PF_CODED_RATE"); RB_RATE=${sg%% *}; RB_TS=${sg##* }; fi

rung_desc () { case "$1" in
  0) echo "Rung 0 (pure copy)";; 1) echo "Rung 1 (copy video + PCM audio)";;
  2) echo "Rung 2 (copy + genpts)";; 3) echo "Rung 3 (field-rate rebuild @ $RB_RATE)";;
  P) echo "Rung 3-PAIR (pair-mate PTS fill — keeps every real PTS)";; esac; }
run_rung () { case "$1" in
  0) bash "$SELF_DIR/remux.sh" "$IN" "$OUT" ${AUDIO:+--audio "$AUDIO"} $ALLAUD;;
  1) bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --audio "${AUDIO:-pcm}" $ALLAUD;;
  2) bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --genpts ${AUDIO:+--audio "$AUDIO"} $ALLAUD;;
  3) bash "$SELF_DIR/rebuild-paff.sh" "$IN" "$OUT" "$RB_RATE" "$RB_TS";;
  P) bash "$SELF_DIR/pairfill-paff.sh" "$IN" "$OUT";;
esac; }

RESULT=FAIL; USED_RUNG=""
attempt () {  # $1 = rung; sets RESULT to OK|REVIEW|FAIL
  USED_RUNG="$1"
  echo "-- attempting $(rung_desc "$1") --"
  if ! run_rung "$1"; then echo "   (rung $1 command failed to produce output)"; RESULT=FAIL; return; fi
  local o
  o=$(bash "$SELF_DIR/verify.sh" "$IN" "$OUT" $FULL 2>&1) || true
  echo "$o" | sed 's/^/   verify: /'
  case "$o" in *">> OK"*) RESULT=OK;; *">> REVIEW"*) RESULT=REVIEW;; *) RESULT=FAIL;; esac
}

# PAFF routing by TIMESTAMP PROFILE (post-mortem 2026-07-25). "All PAFF ->
# constant-rate rebuild" was wrong: on a stream with a reorder pyramid the
# rebuild sets PTS=DTS and plays fields in DECODE order — shuffled motion the
# default verify tier cannot see. So a reordered stream must KEEP its real PTS,
# and auto NEVER falls back from pairfill to the flattening rebuild when a
# pyramid is present.
BASE_RUNG="$PR_REC_RUNG"; [ "$PF_PAFF" = yes ] && { BASE_RUNG=0; [ "$PR_AUDIO_ACTION" = pcm ] && BASE_RUNG=1; }

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
      echo "   escalation if verify is not OK: $(rung_desc P). Never the flattening rebuild."
    else
      echo "   plan: $(rung_desc 3)  [field-coded, no reorder -> genpts is guilty-until-proven]"
      echo "   cmd : rebuild-paff.sh \"$IN\" \"$OUT\" $RB_RATE $RB_TS"
    fi
  else
    echo "   plan: $(rung_desc "$PR_REC_RUNG")"
    echo "   cmd : $PR_REC_CMD"
    echo "   escalation if verify is not OK: Rung 2 (genpts) -> Rung 3 (rebuild @ $RB_RATE; refuses reordered streams)."
  fi
  echo "   then: verify.sh \"$IN\" \"$OUT\" $FULL  (re-encode/Rung 4 is never automatic)"
  exit 0
fi

if [ "$PF_PAFF" = yes ]; then
  if [ "${PF_HALF_TS:-no}" = yes ]; then
    attempt P                                  # pair class: keep real PTS, fill mates
    if [ "$RESULT" != OK ] && [ "${PF_REORDER:-no}" = no ]; then
      echo "-- verdict $RESULT and no reorder pyramid -> field-rate rebuild --"
      attempt 3
    fi
  elif [ "${PF_REORDER:-no}" = yes ]; then
    attempt "$BASE_RUNG"                       # full-TS pyramid: copy keeps the truth; scrub-gated
    if [ "$RESULT" != OK ]; then
      echo "-- verdict $RESULT -> pair-fill (keeps real PTS; never the flattening rebuild) --"
      attempt P
    fi
  else
    attempt 3                                  # no reorder survives: constant-rate rebuild is safe
  fi
else
  attempt "$PR_REC_RUNG"                       # Rung 0/1
  if [ "$RESULT" != OK ]; then
    echo "-- verdict $RESULT -> escalating (timestamps) --"
    attempt 2                                  # genpts
    if [ "$RESULT" != OK ] && [ "$RB_RATE" != unknown ]; then
      echo "-- verdict $RESULT -> escalating (field-rate rebuild) --"
      attempt 3                                # refuses by itself on a reordered stream
    fi
  fi
fi

if [ "$PLAYABLE" -eq 1 ] && [ "$RESULT" = OK ]; then
  echo "-- playability (macOS only; no-op elsewhere) --"
  set +e; bash "$SELF_DIR/playable-check.sh" "$OUT" | sed 's/^/   /'; prc=${PIPESTATUS[0]}; set -e
  [ "$prc" -eq 1 ] && { RESULT=REVIEW; echo "   -> lossless, but NOT QuickTime-playable: REVIEW"; }
fi

echo
echo "AUTO_SUMMARY result=$RESULT rung=${USED_RUNG:-none}"   # machine-readable for batch.sh
case "$RESULT" in
  OK)     echo ">> DONE: $OUT — verified lossless + timeline-clean."; exit 0;;
  REVIEW) echo ">> REVIEW: $OUT written, but verify wants a closer look (see above)."
          echo "   Source untouched. Inspect, or run: scripts/verify.sh \"$IN\" \"$OUT\" --full"; exit 10;;
  FAIL)   echo ">> FAIL: no verified lossless MOV without re-encoding."
          echo "   Source untouched; the last attempt is at $OUT (unverified)."
          echo "   Re-encode (Rung 4) is a manual decision — see references/delivery-encode.md."
          exit 1;;
esac
