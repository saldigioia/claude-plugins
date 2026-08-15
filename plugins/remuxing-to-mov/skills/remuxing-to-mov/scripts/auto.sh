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
#
# Guarantees: NEVER re-encodes (Rung 4 is a human decision); NEVER touches or
# deletes the source; output is written atomically by the sub-scripts.
# Exit: 0 = verified OK; 10 = REVIEW (written, needs a human look — includes a
#       contribution-profile build whose post-build playability check FAILed or
#       could not run on this platform, WO 4.1); 1 = FAIL;
#       11 = REFUSED (since 1.11 the backhaul gate refuses NOTHING here: the
#       4:2:2 profile builds and is playability-tested after (WO 4.1), and
#       timeline rot WARNS + builds + lets the mux-confession hard stop and
#       verify judge (WO 4.2). auto.sh itself refuses only the UNROUTABLE
#       codecs pre-flight (VC-1/VP9/AV1 video, Dolby E audio — the shared
#       WO 5.2 gate, added here in the 1.11 fix round so a direct run can
#       never die in a raw muxer error); an 11 can also propagate from a
#       child's own refusal — e.g. resync.sh's mid-stream layout guard on the
#       Rung 3-SYNC escalation.)
# WO 2.3: the final verdict is the grade of the BEST verified artifact at OUT —
# a failed escalation is reported separately and never condemns a prior rung —
# and a REVIEW that is solely gate (f)'s gap-collapse escalates to resync.sh
# (video bit-identical, audio re-timed; honestly capped at REVIEW), never to a
# timestamp-profile repair for a problem the file has proven it does not have.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
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
. "$SELF_DIR/lib-paff.sh"

# eval only well-formed PR_/PF_ KEY=VAL lines. probe emits controlled ffprobe
# tokens (never the path) — the filter is defense-in-depth so a stray line can't
# become code. If you ever add a PR_ value that embeds $IN/$OUT, parse, don't eval.
eval "$(bash "$SELF_DIR/probe.sh" "$IN" --kv | grep -E '^(PR|PF)_[A-Z0-9_]+=')"   # PR_* + PF_*
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
  exit 11
fi
ua_i=0
while [ "$ua_i" -lt "${PR_AUD_COUNT:-0}" ]; do
  eval "ua_c=\${PR_AUD_${ua_i}_CODEC:-}"
  if unroutable_a "$ua_c"; then
    unroutable_a_refuse "$ua_i"
    exit 11
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
  0) echo "Rung 0 (pure copy)";; 1) echo "Rung 1 (copy video + PCM audio)";;
  2) echo "Rung 2 (copy + genpts)";; 3) echo "Rung 3 (field-rate rebuild @ $RB_RATE)";;
  P) echo "Rung 3-PAIR (pair-mate PTS fill — keeps every real PTS)";;
  S) echo "Rung 3-SYNC (resync.sh — video copy, audio re-timed to the picture)";; esac; }
run_rung () { case "$1" in
  0) bash "$SELF_DIR/remux.sh" "$IN" "$OUT" ${AUDIO:+--audio "$AUDIO"} $ALLAUD;;
  1) bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --audio "${AUDIO:-pcm}" $ALLAUD;;
  2) bash "$SELF_DIR/remux.sh" "$IN" "$OUT" --genpts ${AUDIO:+--audio "$AUDIO"} $ALLAUD;;
  3) bash "$SELF_DIR/rebuild-paff.sh" "$IN" "$OUT" "$RB_RATE" "$RB_TS";;
  P) bash "$SELF_DIR/pairfill-paff.sh" "$IN" "$OUT";;
esac; }

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
BEST_SAVE="$OUT.autobest"               # parks the best artifact during a riskier attempt
GATE_F_ONLY=0
rank () { case "$1" in OK) echo 2;; REVIEW) echo 1;; *) echo 0;; esac; }
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
  if ! run_rung "$1"; then echo "   (rung $1 command failed to produce output)"; RESULT=FAIL; settle_best "$1"; return 0; fi
  local o
  o=$(bash "$SELF_DIR/verify.sh" "$IN" "$OUT" $FULL 2>&1) || true
  echo "$o" | sed 's/^/   verify: /'
  case "$o" in *">> OK"*) RESULT=OK;; *">> REVIEW"*) RESULT=REVIEW;; *) RESULT=FAIL;; esac
  # gate-(f)-ONLY detection: the whole REVIEW note must BE the (f) gap-collapse
  # sentence — any other gate's text breaks the anchors, because "only gate (f)"
  # is the claim. A verify.sh wording change degrades this to the generic
  # escalation (harmless), never to a wrong route.
  case "$(printf '%s\n' "$o" | sed -n 's/^>> REVIEW: //p' | head -1)" in
    "A/V duration mismatch up to "*"gap-collapse desync signature"*"resync.sh to fix.") GATE_F_ONLY=1;;
  esac
  settle_best "$1"
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
    *)    RESULT=FAIL ;;    # 11 REFUSED / 1 FAIL: no resync artifact to bless
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
      echo "   escalation if verify is not OK: gate-(f)-only gap-collapse -> resync.sh (audio"
      echo "   re-timed, REVIEW-grade); otherwise $(rung_desc P). Never the flattening rebuild."
    else
      echo "   plan: $(rung_desc 3)  [field-coded, no reorder -> genpts is guilty-until-proven]"
      echo "   cmd : rebuild-paff.sh \"$IN\" \"$OUT\" $RB_RATE $RB_TS"
    fi
  else
    echo "   plan: $(rung_desc "$PR_REC_RUNG")"
    echo "   cmd : $PR_REC_CMD"
    echo "   escalation if verify is not OK: gate-(f)-only gap-collapse -> resync.sh (audio"
    echo "   re-timed, REVIEW-grade); otherwise Rung 2 (genpts) -> Rung 3 (rebuild @ $RB_RATE; refuses reordered streams)."
  fi
  echo "   then: verify.sh \"$IN\" \"$OUT\" $FULL  (re-encode/Rung 4 is never automatic)"
  exit 0
fi

rm -f "$BEST_SAVE"   # a stale park from a killed earlier run must never be "restored"

if [ "$PF_PAFF" = yes ]; then
  if [ "${PF_HALF_TS:-no}" = yes ]; then
    attempt P                                  # pair class: keep real PTS, fill mates
    if [ "$RESULT" != OK ] && [ "${PF_REORDER:-no}" = no ]; then
      echo "-- verdict $RESULT and no reorder pyramid -> field-rate rebuild --"
      attempt 3
    fi
  elif [ "${PF_REORDER:-no}" = yes ]; then
    attempt "$BASE_RUNG"                       # full-TS pyramid: copy keeps the truth; scrub-gated
    if [ "$RESULT" = REVIEW ] && [ "$GATE_F_ONLY" -eq 1 ]; then
      # the measured BBC cascade: gate (f) alone is a SYNC defect — pair-fill is a
      # timestamp-profile repair for a problem this file just proved it does not
      # have (every timeline gate passed). resync is the remedy verify named; the
      # video side stays the same bit-identical copy that keeps the pyramid.
      echo "-- verify failed ONLY gate (f) (gap-collapse) -> resync.sh, not pair-fill --"
      attempt_resync
    elif [ "$RESULT" != OK ]; then
      echo "-- verdict $RESULT -> pair-fill (keeps real PTS; never the flattening rebuild) --"
      attempt P
    fi
  else
    attempt 3                                  # no reorder survives: constant-rate rebuild is safe
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
    elif [ "$RESULT" != OK ] && [ "$RB_RATE" != unknown ]; then
      echo "-- verdict $RESULT -> escalating (field-rate rebuild) --"
      attempt 3                                # refuses by itself on a reordered stream
    fi
  fi
fi

# WO 2.3: the final verdict is the grade of the artifact actually at OUT — the
# best verified attempt — never the last (possibly failed) escalation's verdict.
RESULT="$BEST_RESULT"

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
      echo "   -> verified lossless but NOT QuickTime-decodable on THIS macOS: REVIEW."
      echo "      A QuickTime-native deliverable needs Rung 4 (scripts/rung4.sh, operator-"
      echo "      attested re-encode); the artifact itself remains a legitimate lossless"
      echo "      NLE/archival master (IINA/VLC/mpv decode it)."
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
  REVIEW)
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
