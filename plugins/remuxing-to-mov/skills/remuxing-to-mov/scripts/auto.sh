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
# Exit: 0 = verified OK; 10 = REVIEW (written, needs a human look); 1 = FAIL.
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
echo "   probe: vcodec=$PR_VCODEC audio=$PR_ACODEC($PR_AUDIO_ACTION) paff=$PF_PAFF -> first rung $PR_REC_RUNG"

# For a non-PAFF broken timeline, the Rung-3 rebuild rate comes from the measured
# coded-picture rate; fall back to a clean mapping.
RB_RATE="$PF_FIELD_RATE"; RB_TS="$PF_TIMESCALE"
if [ "$RB_RATE" = unknown ]; then sg=$(pf_suggest_field_rate "$PF_CODED_RATE"); RB_RATE=${sg%% *}; RB_TS=${sg##* }; fi

rung_desc () { case "$1" in
  0) echo "Rung 0 (pure copy)";; 1) echo "Rung 1 (copy video + PCM audio)";;
  2) echo "Rung 2 (copy + genpts)";; 3) echo "Rung 3 (field-rate rebuild @ $RB_RATE)";; esac; }
run_rung () { case "$1" in
  0) bash "$SELF_DIR/remux.sh" "$IN" "$OUT" ${AUDIO:+--audio "$AUDIO"} $ALLAUD;;
  1) bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --audio "${AUDIO:-pcm}" $ALLAUD;;
  2) bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --genpts ${AUDIO:+--audio "$AUDIO"} $ALLAUD;;
  3) bash "$SELF_DIR/rebuild-paff.sh" "$IN" "$OUT" "$RB_RATE" "$RB_TS";;
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

if [ "$DRY" -eq 1 ]; then
  echo ">> DRY-RUN — no files written."
  if [ "$PF_PAFF" = yes ]; then
    echo "   plan: $(rung_desc 3)  [field-coded -> genpts is guilty-until-proven]"
    echo "   cmd : rebuild-paff.sh \"$IN\" \"$OUT\" $RB_RATE $RB_TS"
  else
    echo "   plan: $(rung_desc "$PR_REC_RUNG")"
    echo "   cmd : $PR_REC_CMD"
    echo "   escalation if verify is not OK: Rung 2 (genpts) -> Rung 3 (rebuild @ $RB_RATE)."
  fi
  echo "   then: verify.sh \"$IN\" \"$OUT\" $FULL  (re-encode/Rung 4 is never automatic)"
  exit 0
fi

if [ "$PF_PAFF" = yes ]; then
  attempt 3                                   # field-coded: straight to rebuild
else
  attempt "$PR_REC_RUNG"                       # Rung 0/1
  if [ "$RESULT" != OK ]; then
    echo "-- verdict $RESULT -> escalating (timestamps) --"
    attempt 2                                  # genpts
    if [ "$RESULT" != OK ] && [ "$RB_RATE" != unknown ]; then
      echo "-- verdict $RESULT -> escalating (field-rate rebuild) --"
      attempt 3
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
