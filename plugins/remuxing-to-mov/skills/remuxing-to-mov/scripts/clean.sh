#!/usr/bin/env bash
# clean.sh — the SOURCE CLINIC driver: run the integrity battery on a capture
# in its OWN container and report findings where every route stays there —
# re-wrap corrections (zero-base, surgical cut, IDR trim), never a container
# change, never a re-encode, never a write to the source. The automated form
# of the feed.ts case-file sequence (2026-08-26), cheapest passes first:
#
#   1. probe.sh          identity + timestamp profile        (seconds, demux)
#   2. ts-health.sh      whole-file transport + timeline     (I/O-bound, demux)
#   3. lead-check.sh     black-lead signature at the head    (bounded decode)
#   4. [--deep only]     dim-scan.sh (whole-file decode) + full decode-to-null
#
# REPORT-ONLY: this driver writes nothing and applies nothing. Findings print
# their exact commands — Tier-1 structural corrections (zero-base.sh,
# trim-to-idr.sh) ready to run, Tier-2 content-discarding cuts quoted WITH
# their --discard-content consent flag and loss statement (lead-check's
# words, relayed verbatim). Timeline defects (missing timestamps, DTS rot)
# are NOT clinic business: they route to diagnose.sh and the repair rungs,
# honestly named.
#
# Usage: scripts/clean.sh INPUT [--deep]
# Exit: 0 CLEAN | 10 FINDINGS | 1 DAMAGED (ts-health's verdict) | 2 usage.
# Machine line (stable API — extend only):
#   CLEAN_SUMMARY verdict=clean|findings|damaged findings= routes=<csv|none>
#     deep=yes|no
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/lib-exit.sh"   # exit-code contract trap: no stray code escapes
IN="${1:?usage: clean.sh INPUT [--deep]}"
DEEP=0
[ $# -ge 2 ] && { [ "$2" = --deep ] && DEEP=1 || { echo "unknown opt: $2" >&2; exit 2; }; }
[ $# -le 2 ] || { echo "unknown opt: $3" >&2; exit 2; }
[ -f "$IN" ] || { echo "no such file: $IN" >&2; exit 2; }
. "$SELF_DIR/lib-probe.sh"  # ffp/FF_INPUT_OPTS: raised probe window on every input open
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # only our own scratch; never the source

findings=0; routes=""
route () { routes="$routes${routes:+,}$1"; }

echo "== source clinic: $IN =="
echo "   (report-only: nothing is written; every named route stays in the source container)"

# --- 1. identity + profile (probe) ------------------------------------------------
echo "-- 1. probe (identity + timestamp profile) --"
set +e; PKV=$(bash "$SELF_DIR/probe.sh" "$IN" --kv 2>/dev/null); prc=$?; set -e
# a child rc 2 is its pre-flight "cannot read" — propagate it as OUR 2, never
# relabeled 1 (= this contract's DAMAGED-adjacent FAIL; WO-1.15.4 C4)
[ -n "$PKV" ] || { echo "probe.sh could not read the source (rc=$prc)" >&2; [ "$prc" -eq 2 ] && exit 2; exit 1; }
pget () { printf '%s\n' "$PKV" | sed -n "s/^$1=//p" | head -1; }
CONT=$(ffp1 -v error -show_entries format=format_name -of default=nw=1:nk=1 "$IN" 2>/dev/null)
ST=$(ffp1 -v error -show_entries format=start_time -of default=nw=1:nk=1 "$IN" 2>/dev/null)
case "$ST" in ''|N/A) ST=0;; esac
IS_TS=no; case "$CONT" in *mpegts*) IS_TS=yes;; esac
echo "   container=$CONT video=$(pget PR_VCODEC)/$(pget PR_PIX_FMT) audio_tracks=$(pget PR_AUD_COUNT) paff=$(pget PF_PAFF) start_time=${ST}s"

# --- 2. whole-file health (ts-health) ---------------------------------------------
echo "-- 2. ts-health (whole-file transport + timeline, demux only) --"
set +e; bash "$SELF_DIR/ts-health.sh" "$IN" --kv > "$TMP/tsh" 2>/dev/null; thrc=$?; set -e
# ts-health's 2 is its announced "cannot read" pre-flight (WO-1.15.4 C4) —
# propagate as 2; only a real scan failure stays this driver's 1
[ -s "$TMP/tsh" ] || { echo "ts-health could not scan the source (rc=$thrc)" >&2; [ "$thrc" -eq 2 ] && exit 2; exit 1; }
tget () { sed -n "s/^$1=//p" "$TMP/tsh" | head -1; }
echo "   transport: CC=$(tget TSH_CC) corrupt=$(tget TSH_CORRUPT) PES=$(tget TSH_PES) scrambled=$(tget TSH_SCRAMBLED)"
echo "   timeline:  napts=$(tget TSH_NAPTS) nadts=$(tget TSH_NADTS) back=$(tget TSH_BACK) dup=$(tget TSH_DUP) gaps=$(tget TSH_GAPS) wrap=$(tget TSH_WRAP) prekey=$(tget TSH_PREKEY)"
DAMAGED=0; [ "$(tget TSH_VERDICT)" = DAMAGED ] && DAMAGED=1

# --- 3. head lead (bounded decode) ------------------------------------------------
echo "-- 3. lead-check (head luma + splice census, bounded decode) --"
set +e; LC=$(bash "$SELF_DIR/lead-check.sh" "$IN" 2>&1); lcrc=$?; set -e
LCLINE=$(printf '%s\n' "$LC" | grep '^LEADCHECK_SUMMARY ' || true)
lget () { printf '%s\n' "$LCLINE" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
case "$lcrc" in
  0)  echo "   head clean (first frame is program-bright)";;
  10) echo "   BLACK LEAD detected: $(lget black_secs)s (splice packet $(lget splice_idx), audio_hot=$(lget audio_hot))";;
  *)  echo "   lead-check could not measure (rc=$lcrc) — not fatal for the report";;
esac

# --- 4. deep passes (opt-in: whole-file decode) -----------------------------------
DIMS_CH=na
if [ "$DEEP" -eq 1 ]; then
  echo "-- 4. deep: dim-scan (whole-file decode) --"
  set +e; DS=$(bash "$SELF_DIR/dim-scan.sh" "$IN" 2>&1); dsrc=$?; set -e
  DIMS_CH=$(printf '%s\n' "$DS" | grep '^DIMSCAN_SUMMARY ' | tr ' ' '\n' | sed -n 's/^changes=//p' | head -1)
  echo "   dimension changes: ${DIMS_CH:-?}"
  echo "-- 4b. deep: full decode-to-null (bitstream proof) --"
  ffmpeg -nostdin -v error "${FF_INPUT_OPTS[@]}" -i "$IN" -map 0 -f null - 2>"$TMP/dec.log" || true
  NDEC=$(grep -c . "$TMP/dec.log" || true)
  echo "   decode log lines: ${NDEC:-0} (transport counters above decide damage, never this tally alone)"
else
  echo "-- 4. deep passes skipped (--deep runs dim-scan + a full decode) --"
fi

# --- findings + routes (source-domain only) ---------------------------------------
echo "-- findings --"
finding () { findings=$((findings+1)); echo "   [$1] $2"; echo "        -> $3"; }
if [ "$DAMAGED" -eq 1 ]; then
  finding transport "ts-health verdict: DAMAGED (scrambled or heavy loss — counters above)" \
    "PERMANENT: re-capture is the only true fix (ts-health.sh for the detail)"
fi
# jurisdiction gates (WO-1.15.7): the Tier-1 zero-base route must never be
# printed "ready to run" for a file zero-base refuses at pre-flight — B1
# (no video: verify-source cannot bless the re-wrap) and F12 (multi-program:
# the mpegts muxer cannot reconstruct the layout; measured refusal exit 2).
# ASK, DON'T MODEL (1.15.13). This driver used to RE-DERIVE zero-base's
# refusal conditions — container, program count, video presence, timeline rot,
# and (1.15.11) both PAFF arms. Every axis added to zero-base had to be
# mirrored here by hand, and twice it was not: F12 shipped the multi-program
# mirror a round late, and the PAFF mirror was two rounds late and found in
# the field. Enumeration cannot close: the sources supply axes faster than a
# guard can list them.
# zero-base now answers for itself. --preflight-only runs ITS OWN refusal
# logic, writes nothing, and exits 0 eligible / 2 refused (anything else: it
# could not RUN, which is UNPROVEN, not a refusal); --src-tsh hands it the
# whole-file scan already taken in step 2, so asking costs no re-scan.
# Offering a route that refuses on the SOURCE's shape is now structurally
# impossible — on every axis, including ones nobody has met yet; 1.15.18 asks
# the other Tier-1 authority (trim-to-idr) the same way. Build-time conditions
# — the writer lock, disk headroom — belong to the run and are judged then;
# the verdict line says so.
if [ "$(tget TSH_VIDEO)" = none ]; then
  finding scope "no video stream — the clinic's video-domain routes do not apply (ts-health scoped its scan the same way)" \
    "audio-only capture: extract/remux the audio directly (ffmpeg -map 0:a -c copy); zero-base/verify-source require video by design"
fi
if awk "BEGIN{exit !(($ST) > 0.05)}"; then
  # asked HERE, not unconditionally: this branch is the verdict's only reader,
  # and the pre-flight re-runs pf_detect plus three header opens (~3 s on a
  # field master) that a zero-based or non-TS source would pay for nothing.
  set +e
  # stderr only: zero-base speaks its refusals there; its stdout is progress
  # (stage banners, the --src-tsh reuse line naming THIS clinic's private temp
  # dir) and relaying that put a soon-deleted path in the operator's report.
  ZB_PF=$(bash "$SELF_DIR/zero-base.sh" "$IN" --preflight-only --src-tsh "$TMP/tsh" 2>&1 >/dev/null); ZB_RC=$?
  set -e
  if [ "$ZB_RC" -eq 0 ]; then
    # ASK, DON'T MODEL, still — and since 1.16.0 zero-base can answer
    # "eligible, WITH a warning" (TIERS.md T3.3: its field-coded arms warn and
    # build rather than refusing on a prediction about the output). A route
    # relayed without its warning is the 1.15.11 defect in the other direction:
    # the operator gets a ready-to-run command and none of the caveat the tool
    # attached to it. So the warning is relayed here, in zero-base's own words.
    ZB_WARN=$(printf '%s\n' "$ZB_PF" | sed -n 's/^ZB_PREFLIGHT_WARN //p' | head -1 || true)
    if [ -n "${ZB_WARN:-}" ]; then
      finding timeline "timeline starts at ${ST}s, not zero (players rebase it; tools and clocks read it)" \
        "TIER 1 (structural), WITH A WARNING zero-base attached to it — $ZB_WARN: scripts/zero-base.sh \"$IN\" OUT.ts. It will BUILD and let its own gates judge the result (it no longer refuses this shape on a prediction); --preflight-only gives the verdict without the build. For a QuickTime deliverable from a field-coded source the route is scripts/mov.sh, and scripts/diagnose.sh picks the repair rung by measured profile."
    else
      finding timeline "timeline starts at ${ST}s, not zero (players rebase it; tools and clocks read it)" \
        "TIER 1 (structural): scripts/zero-base.sh \"$IN\" OUT.ts — lossless re-wrap to the floor, PID layout kept, prediction-gated"
    fi
    route zero-base
  elif [ "$ZB_RC" -eq 2 ]; then
    # Relay, do not paraphrase: the refusal text is zero-base's, so this
    # driver holds no copy of the reasoning that can drift out of date. The
    # routes named below are the ones zero-base itself named.
    finding timeline "timeline starts at ${ST}s, not zero" \
      "NOT a zero-base job — zero-base.sh refuses this source at pre-flight, in its own words:"
    # display only, so `|| true`: a display pipeline that fails under pipefail
    # killed the clinic here with exit 1 (= DAMAGED) and no CLEAN_SUMMARY row.
    printf '%s\n' "$ZB_PF" | sed 's/^/             /' || true
  else
    # rc 1 or a stray: the pre-flight could not RUN (a broken meter, a probe
    # that died). That is UNPROVEN, never a refusal to put in zero-base's mouth
    # — EMPTY != ABSENT. Say so, and relay whatever it managed to print.
    finding timeline "timeline starts at ${ST}s, not zero" \
      "UNPROVEN whether zero-base applies — its pre-flight could not run (rc=$ZB_RC); scripts/zero-base.sh \"$IN\" --preflight-only shows why:"
    printf '%s\n' "$ZB_PF" | sed 's/^/             /' || true
  fi
elif awk "BEGIN{exit !(($ST) < -0.05)}"; then
  # B4 (WO-1.15.7): the positive direction alone missed the unwrapped-wrap
  # symptom this ffmpeg's demuxer actually hands back.
  finding timeline "negative start_time (${ST}s) — an already-unwrapped mid-capture 33-bit crossing or PCR epoch reset (ts-health names the representation)" \
    "remux normally — the muxer rebases and verify.sh gate (d) proves the OUTPUT; for a stay-in-TS deliverable, scripts/zero-base.sh floors the timeline (prediction-gated)"
fi
if [ "$(tget TSH_PREKEY)" != 0 ]; then
  # the same ask, of the other Tier-1 authority. The scan window, the
  # missing-timestamp class and gop-probe's open-GOP verdict are trim-to-idr's
  # refusals, and this driver used to print the route off the ts-health
  # counter alone — a ready-to-run command that FAILed on such a head (rc=1,
  # nothing written). Asked here, not unconditionally: only a pre-key count
  # reaches it, and the boundary proof (gop-probe) is the decode step.
  set +e
  TT_PF=$(bash "$SELF_DIR/trim-to-idr.sh" "$IN" --preflight-only 2>&1 >/dev/null); TT_RC=$?
  set -e
  MIDGOP="capture starts mid-GOP: $(tget TSH_PREKEY) pre-keyframe packet(s) — undecodable pre-roll"
  if [ "$TT_RC" -eq 0 ]; then
    finding timeline "$MIDGOP" \
      "TIER 1 (structural): scripts/trim-to-idr.sh \"$IN\" OUT.ts — removes only what no player could show"
    route trim-to-idr
  elif [ "$TT_RC" -eq 2 ]; then
    finding timeline "$MIDGOP" \
      "NOT a trim-to-idr job — trim-to-idr.sh refuses this source at pre-flight, in its own words:"
    printf '%s\n' "$TT_PF" | sed 's/^/             /' || true
  else
    finding timeline "$MIDGOP" \
      "UNPROVEN whether trim-to-idr applies — its pre-flight could not run (rc=$TT_RC); scripts/trim-to-idr.sh \"$IN\" --preflight-only shows why:"
    printf '%s\n' "$TT_PF" | sed 's/^/             /' || true
  fi
fi
if [ "$lcrc" -eq 10 ]; then
  finding head "black lead-in: $(lget black_secs)s of black before program picture (audio_hot=$(lget audio_hot))" \
    "TIER 2 (content-discarding — operator's call): the exact command below, from lead-check's census"
  printf '%s\n' "$LC" | sed -n '/surgical-cut.sh/p' | sed 's/^/        /'
  route surgical-cut
fi
if [ "$(tget TSH_NAPTS)" != 0 ] || [ "$(tget TSH_NADTS)" != 0 ] || [ "$(tget TSH_BACK)" != 0 ] || [ "$(tget TSH_DUP)" != 0 ]; then
  finding timeline "timestamp defects (napts=$(tget TSH_NAPTS) nadts=$(tget TSH_NADTS) back=$(tget TSH_BACK) dup=$(tget TSH_DUP))" \
    "NOT clinic business — timeline repair has its own rungs: scripts/diagnose.sh routes by measured profile"
  route diagnose
fi
if [ "$(tget TSH_GAPS)" != 0 ]; then
  finding timeline "$(tget TSH_GAPS) forward gap(s) (~$(tget TSH_GAP_SECS)s dropped) — permanent capture loss" \
    "no re-wrap restores dropped frames; ts-health names the downstream (remux-side) precautions"
fi
if [ "$DEEP" -eq 1 ] && [ "${DIMS_CH:-0}" != na ] && [ "${DIMS_CH:-0}" != 0 ] 2>/dev/null; then
  finding video "mid-stream resolution change(s): $DIMS_CH (dim-scan)" \
    "cut at the splice (dim-scan's report has the address) or do NOT remux across the junction"
  route dim-scan
fi

# --- verdict ----------------------------------------------------------------------
if [ "$DAMAGED" -eq 1 ]; then V=damaged; rc=1
elif [ "$findings" -gt 0 ]; then V=findings; rc=10
else V=clean; rc=0; echo "   none — the capture needs no clinic work (remux ladder territory when a .mov is wanted)"; fi
case "$V" in
  clean)    echo ">> CLEAN: nothing to correct in the source container.";;
  findings) echo ">> FINDINGS: $findings item(s) above. Tier-1 commands are ready to run (each tool judged the source itself; the writer lock and disk headroom are its run-time checks); Tier-2 needs the operator's --discard-content. Nothing was written.";;
  damaged)  echo ">> DAMAGED: transport-level loss (permanent). The other findings still route what survives.";;
esac
echo "CLEAN_SUMMARY verdict=$V findings=$findings routes=${routes:-none} deep=$([ "$DEEP" -eq 1 ] && echo yes || echo no)"
exit "$rc"
