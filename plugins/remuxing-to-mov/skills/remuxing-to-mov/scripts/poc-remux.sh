#!/usr/bin/env bash
# poc-remux.sh — Rung 3-POC: the driver for the field-pair-aware, POC-timed
# lossless remux (scripts/poc-remux.py does the work).
#
# WHERE IT SITS IN THE LADDER. Between Rung 3-PAIR (pairfill-paff) and Rung 3
# (the constant-rate rebuild). Its class is the one no rung above it fits:
# field-coded H.264 whose fields are CODED-ADJACENT but not stamped one field
# duration apart, so every timestamp-delta heuristic reads "no pairing here".
# diagnose.sh routes to it on that measurement.
#
# WHAT IT DOES DIFFERENTLY, and it is one sentence: it reads the bitstream's
# own slice headers instead of inferring their contents from timestamp
# arithmetic. Field pairing comes from field_pic_flag/bottom_field_flag/
# frame_num (ISO/IEC 14496-15's own definition); display positions come from
# pic_order_cnt. Both were sitting unread while three sessions of this plugin
# refused a 25 GB capture on a proxy for them.
#
# WHAT IT NEVER DOES: re-encode (packet payloads are copied byte for byte),
# touch the source, or write a timestamp it cannot evidence. Every hole is
# filled from its own POC or the whole file is refused; every duplicate display
# slot is adjudicated from POC or the whole file is refused.
#
# THE OUTPUT IS GATED BEFORE IT IS BLESSED, through the full verify suite —
# including the container-level gates (h) declared-vs-stored structure, (j)
# duplicate display slots, (k) presentation order vs POC and (l) the anchor.
# A rung that repairs a timeline must not be the judge of its own timeline.
#
# Usage: scripts/poc-remux.sh INPUT OUTPUT.mov [--audio all|first|none]
#                                              [--dry-run] [--limit N] [--full]
#                                              [--no-faststart]
# Exit: 0 verified-clean | 1 built but an output gate failed | 2 usage/pre-flight
#       3 REFUSED (no trusted evidence — nothing written) | 10 REVIEW (PyAV
#       venv absent, or verify wants a look) | 11 REFUSED (unroutable codec)
#
# Machine lines:
#   POC_SUMMARY paired= singles= holes_filled= dups_moved= anchor= frames=
#               pictures= depth= step= verdict=
#   RMX_CENSUS stage=poc-remux …          (the shared plan-vs-file census)
set -euo pipefail
export LC_ALL=C
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap (WO 1.4): no stray code escapes
RTM_EXIT_OK="0 1 2 3 10 11" # + this rung's documented pre-contract 3 (REFUSED; family consistency with pairfill/rebuild/derive)
IN="${1:?usage: poc-remux.sh INPUT OUTPUT.mov [--audio all|first|none] [--dry-run] [--limit N] [--full]}"
OUT="${2:?need OUTPUT.mov}"; shift 2
AUDIO=all; DRY=0; LIMIT=""; FULL=""; NOFS=""
while [ $# -gt 0 ]; do case "$1" in
  --audio)   AUDIO="${2:?--audio needs all|first|none}"; shift 2;;
  --dry-run) DRY=1; shift;;
  --limit)   LIMIT="${2:?--limit needs a value}"; shift 2;;
  --full)    FULL="--full"; shift;;
  --no-faststart) NOFS="--no-faststart"; shift;;   # 1.16.7 (announced opt-out)
  *) echo "unknown opt: $1" >&2; exit 2;;
esac; done
case "$AUDIO" in all|first|none) ;; *) echo "bad --audio: $AUDIO (all|first|none)" >&2; exit 2;; esac
case "${LIMIT:-0}" in ''|*[!0-9]*) echo "--limit must be a whole number (got: $LIMIT)" >&2; exit 2;; esac
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
. "$SELF_DIR/lib-paff.sh"   # unroutable_v/_a classifiers, RTM_CONFESSION_RE
. "$SELF_DIR/lib-mux.sh"    # rtm_part/rtm_sibling_guard/rtm_writer_preflight, mux_census
rtm_sibling_guard "$IN" "$OUT" || exit 2   # TIER 1 T1.11 write beside the source, never onto it (one writer: lib-mux.sh)

echo "== poc-remux (Rung 3-POC): $IN -> $OUT =="

# --- pre-flight: the unroutable codecs, at every entry point (1.10.0) -------
PR_VC=$(ffp1 -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$IN" 2>/dev/null || true)
if unroutable_v "${PR_VC:-}"; then
  unroutable_v_refuse "${PR_VC:-}"
  exit 11   # TIER 3 T3.8 cached deterministic attempt
fi

# --- pre-flight: the dependency gate (the derive-dts precedent) -------------
DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/remuxing-to-mov}"
VENV_PY="$DATA/venv/bin/python"
echo "-- pre-flight: PyAV venv ($DATA/venv) --"
if [ -x "$VENV_PY" ] && PYAV_VER=$("$VENV_PY" -c 'import av; print(av.__version__)' 2>/dev/null); then
  echo "   PyAV $PYAV_VER via $VENV_PY"
else
  echo ">> REVIEW: this rung needs PyAV and its venv is absent or broken."
  echo "   It NEVER auto-installs (doctor.sh reports the dependency). One line:"
  echo "     python3 -m venv \"$DATA/venv\" && \"$DATA/venv/bin/pip\" install av"
  echo "   What it would do, so it is checkable by hand: pair each complementary"
  echo "   field pair into ONE sample (ISO/IEC 14496-15), then time every frame"
  echo "   from its own pic_order_cnt via k = POC + C, C per (IDR epoch, field"
  echo "   parity). scripts/poc-gate.sh judges any candidate output against the"
  echo "   same lattice without needing this venv."
  exit 10
fi

# --- dry run writes nothing, so it takes no lock ---------------------------
if [ "$DRY" -eq 1 ]; then
  set +e
  "$VENV_PY" "$SELF_DIR/poc-remux.py" "$IN" "$OUT" --audio "$AUDIO" --dry-run \
    ${LIMIT:+--limit "$LIMIT"} ${NOFS:+"$NOFS"}
  prc=$?
  set -e
  case "$prc" in
    0) exit 0;;
    3) echo ">> REFUSED: the evidence does not support a timeline for this stream (above)." >&2
       exit 3;;   # TIER 3 the rung's own evidence bar — nothing written either way
    *) exit "$prc";;
  esac
fi

trap 'rtm_unlock' EXIT   # writer-lock release however this run ends (WO-1.15.6 A2)
rtm_writer_preflight "$OUT" "$IN" || exit 2   # TIER 1 T1.5/T1.6/T1.10/T1.11

# THE CONTAINER'S OWN ANSWER about each audio codec, read once and handed to
# the python. PyAV resolves MP2 through the mp3float DECODER, so asking it
# yields "mp3float" and a template copy then writes a '.mp3' sample entry over
# Layer II payload. Measured on this rung's first real run; gate (i) caught it.
# Blank rows are dropped: an mpegts input lists each stream twice (a bare
# top-level view then the in-program one) and csv=p=0 can emit an empty field
# between them. A blank in the middle would shift every later stream's name
# onto the wrong stream — the mislabel this whole probe exists to prevent,
# reintroduced by an off-by-one.
PC_ACODECS=$(ffp -v error -select_streams a -show_entries stream=index,codec_name -of csv=p=0 "$IN" 2>/dev/null \
  | awk -F, 'NF>=2 && $2!="" { if (!seen[$1]++) printf "%s%s", s, $2; s="," }' || true)
[ -z "${PC_ACODECS:-}" ] || echo "   audio codecs (from the container, not the decoder): $PC_ACODECS"

PART="$(rtm_part "$OUT")"   # extension-keeping (D6) + unique per process (A2)
echo "-- building (video bits copied untouched; frames paired per 14496-15, timed from POC) --"
set +e
"$VENV_PY" "$SELF_DIR/poc-remux.py" "$IN" "$PART" --audio "$AUDIO" \
  ${PC_ACODECS:+--acodecs "$PC_ACODECS"} \
  ${LIMIT:+--limit "$LIMIT"} ${NOFS:+"$NOFS"} 2>&1 | tee "$PART.log" | sed 's/^/   /'
prc=${PIPESTATUS[0]}
set -e
case "$prc" in
  0) ;;
  3) echo ">> REFUSED: the evidence does not support a timeline for this stream (above)." >&2
     echo "   Nothing was blessed. The source is untouched and remains the master." >&2
     rm -f "$PART" "$PART.log"
     exit 3;;   # TIER 3 the rung's own evidence bar
  10) rm -f "$PART" "$PART.log"; exit 10;;
  *) echo ">> FAIL: the rung did not complete (python exit $prc); partial output removed." >&2
     rm -f "$PART" "$PART.log"
     exit 1;;
esac
[ -s "$PART" ] || { echo ">> FAIL: the rung reported success and wrote nothing." >&2; rm -f "$PART.log"; exit 1; }

# --- the muxer's own confession, before anything is blessed ----------------
if grep -iE "$RTM_CONFESSION_RE" "$PART.log" >/dev/null 2>&1; then
  conf=$(grep -icE "$RTM_CONFESSION_RE" "$PART.log" || true)
  echo ">> HARD STOP: the muxer logged $conf timeline confession(s) on a rung whose"
  echo "   whole job is to hand it a complete timeline — that is a contradiction, not"
  echo "   a tolerance."
  echo "   BUILT, and kept as $PART — the artifact exists; what is unproven is its TIMELINE."
  echo "   NOT blessed to $OUT. Run the gates on the kept part: scripts/verify.sh \"$IN\" \"$PART\""
  exit 1
fi

# --- POST-MUX CENSUS (D5): reconcile the plan against the FILE -------------
PC_C=$(ffp -v error -show_entries stream=index,codec_name -of csv=p=0 "$PART" 2>/dev/null | \
       awk -F, 'NF{ if(seen[$1]++) next; printf "%s%s", s, $2; s="," }' || true)
PC_N=$(printf '%s' "$PC_C" | awk -F, '{print ($0=="" ? 0 : NF)}')
census_rc=0
mux_census "$PART" "$PC_N" "$PC_C" poc-remux "$IN" || census_rc=$?
if rtm_census_failed "$census_rc"; then
  echo ">> FAIL: the post-mux census could not confirm the plan (above)."
  echo "   Kept at $PART (log: $PART.log); nothing blessed."
  exit 1
fi

# --- THE OUTPUT GATE: a repair rung does not judge its own timeline --------
echo "-- verify (the full suite, including the container gates (h)/(j)/(k)/(l)) --"
set +e
vo=$(bash "$SELF_DIR/verify.sh" "$IN" "$PART" $FULL 2>&1)
set -e
printf '%s\n' "$vo" | sed 's/^/   /'
case "$vo" in
  *">> OK"*)
    mv -f "$PART" "$OUT"; rm -f "$PART.log"
    echo ">> DONE: $OUT — frames paired per ISO/IEC 14496-15, every display position"
    echo "   evidenced by the bitstream's own pic_order_cnt, verified lossless."
    if rtm_census_review "$census_rc"; then
      echo ">> REVIEW: the census flagged an unexpected surplus stream (see RMX_CENSUS above)."
      exit 10
    fi
    [ -n "$LIMIT" ] && { echo ">> REVIEW: --limit build is a PARTIAL artifact and is never a deliverable."; exit 10; }
    exit 0 ;;
  *">> REVIEW"*)
    mv -f "$PART" "$OUT"; rm -f "$PART.log"
    echo ">> REVIEW: $OUT written; verify wants a closer look (above). The ledger block"
    echo "   names every gate, including any that could not be evaluated."
    exit 10 ;;
  *)
    echo ">> FAIL: the built artifact did not pass its own output gates (above)."
    echo "   BUILT, and kept as $PART — NOT blessed to $OUT. The source is untouched."
    exit 1 ;;
esac
