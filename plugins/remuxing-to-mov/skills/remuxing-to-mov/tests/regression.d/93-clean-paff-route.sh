#!/usr/bin/env bash
# 93-clean-paff-route.sh — the clinic must never hand the operator a command
# that refuses. 1.15.7 F12 established the rule ("clean.sh printed a
# ready-to-run zero-base command that refuses exit 2 on a 2-program TS,
# measured") and closed the multi-program axis; B1 closed the no-video axis.
# The PAFF axis was left open — and PAFF is the refusal 1.15.2 Defect C added,
# for the 2022-08-28 field capture, which is exactly the file that walked into
# it again on 2026-08-27:
#
#   -- 1. probe --  container=mpegts ... paff=yes             <- the clinic KNOWS
#   [timeline] timeline starts at 0.200000s, not zero
#        -> TIER 1 (structural): scripts/zero-base.sh "feed.ts" OUT.ts
#   $ zero-base.sh feed.ts OUT.ts
#   pair-timestamped PAFF source (paff=yes half_ts=yes): refusing at pre-flight.
#
# The guard tested IS_TS / TSH_BACK / TSH_DUP / TSH_VIDEO / NPROG, and its own
# comment named its coverage as "B1 ... and F12" — PF_PAFF/PF_HALF_TS are in
# the same --kv block it already parses. BOTH of zero-base's PAFF arms refuse
# (1.15.2 pair-timestamped; 1.15.7 F1 full-TS as POLICY), so both must be
# gated.
#
# §4 is the point of the test: rather than enumerate refusals forever, it pins
# the INVARIANT — if clean.sh printed the ready-to-run zero-base command, then
# zero-base must not refuse that same file at pre-flight. That assertion would
# have caught B1, F12 and this one before any of them shipped.
#
# Standalone: bash tests/regression.d/93-clean-paff-route.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

# grepq / grepqe PATTERN — read stdin to EOF, THEN answer. `x | grep -q PAT`
# closes the pipe on the first match and SIGPIPEs its writer: the same early-exit
# shape as the 1.15.2 `ffp … | head -1` field defect. Measured 2026-08-28 on
# verify.sh (95 KB): "printf: write error: Broken pipe", and under pipefail the
# non-zero pipeline flipped a PASS into a FALSE FAIL. Never `| grep -q` over
# source in this suite (94 §10 sweeps for it).
# A leading `--` is SWALLOWED, not searched for: converting a `grep -q -- PAT`
# call site left the `--` in place, so the pattern became "--" and the guard
# matched every long option in the file — PASS, guarding nothing. Measured
# 2026-08-28 (mutation-audit case G21, the third self-inflicted vacuity this
# round). The `--` below is what protects a pattern that starts with a dash.
grepq  () { [ "${1:-}" = -- ] && shift; [ "$(grep -c  -- "$1")" -gt 0 ]; }
grepqe () { [ "${1:-}" = -- ] && shift; [ "$(grep -cE -- "$1")" -gt 0 ]; }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }

READY='TIER 1 (structural): scripts/zero-base.sh'
routes_of () { printf '%s\n' "$1" | sed -n 's/.*CLEAN_SUMMARY .*routes=\([^ ]*\).*/\1/p'; }

echo "== fixtures: clean single-program TS (non-PAFF) + the two PAFF profiles =="
# 29.97 like test 88 §6 — the house injection tables are calibrated to that
# nominal rate (a 25 fps source + the 0.033367 pair table reads paff=no, since
# the ratio lands at 1.6, not 2.0; measured while writing this test).
S="$WORK/src.ts"
ff -f lavfi -i "testsrc2=s=320x240:r=30000/1001" -f lavfi -i "sine=1000" -t 3 \
   -c:v libx264 -g 30 -pix_fmt yuv420p -c:a mp2 -f mpegts "$S" || { echo "fixture mint failed"; exit 2; }
# house injections (test 75 / test 88 §6): alternating N/A -> half_ts=yes;
# a complete column at 2x nominal -> paff=yes half_ts=no.
awk 'BEGIN{for(i=0;i<120;i++){printf "%.6f,%.6f\nN/A,N/A\n", i*0.033367, i*0.033367}}' > "$WORK/pair.csv"
awk 'BEGIN{for(i=0;i<180;i++){t=i*0.016683; printf "%.6f,%.6f\n", t, t}}'               > "$WORK/full2x.csv"

echo
echo "== 0. precondition: the injections actually reach clean.sh's probe =="
p_pair=$(PF_PKT_FILE="$WORK/pair.csv"   bash "$SC/probe.sh" "$S" --kv 2>/dev/null | grep -E '^PF_(PAFF|HALF_TS)=' | paste -sd' ' -)
p_full=$(PF_PKT_FILE="$WORK/full2x.csv" bash "$SC/probe.sh" "$S" --kv 2>/dev/null | grep -E '^PF_(PAFF|HALF_TS)=' | paste -sd' ' -)
case "$p_pair" in *PF_PAFF=yes*PF_HALF_TS=yes*) ok "pair injection reads paff=yes half_ts=yes";; *) no "pair injection did not take [$p_pair]";; esac
case "$p_full" in *PF_PAFF=yes*PF_HALF_TS=no*)  ok "full-2x injection reads paff=yes half_ts=no";;  *) no "full-2x injection did not take [$p_full]";; esac

echo
echo "== 1. CONTROL: a non-PAFF clean TS still gets the Tier-1 route (no over-correction) =="
c0=$(bash "$SC/clean.sh" "$S" 2>&1)
has "$c0" "$READY" "non-PAFF source still gets the ready-to-run zero-base command"
case "$(routes_of "$c0")" in *zero-base*) ok "routes= names zero-base";; *) no "routes= lost zero-base on a legit file [$(routes_of "$c0")]";; esac

echo
echo "== 2. pair-timestamped PAFF: no ready-to-run command, refusal named =="
c1=$(PF_PKT_FILE="$WORK/pair.csv" bash "$SC/clean.sh" "$S" 2>&1)
hasnt "$c1" "$READY" "pair-timestamped PAFF gets NO ready-to-run zero-base command"
case "$(routes_of "$c1")" in *zero-base*) no "routes= still advertises zero-base [$(routes_of "$c1")]";; *) ok "routes= does not advertise zero-base";; esac
has "$c1" "paff" "the finding names the PAFF profile it measured"
has "$c1" "pairfill-paff.sh" "…and names the route that actually accepts this file"

echo
echo "== 3. full-timestamp PAFF (the F1 policy arm) is gated too =="
c2=$(PF_PKT_FILE="$WORK/full2x.csv" bash "$SC/clean.sh" "$S" 2>&1)
hasnt "$c2" "$READY" "full-TS PAFF gets NO ready-to-run zero-base command"
case "$(routes_of "$c2")" in *zero-base*) no "routes= still advertises zero-base [$(routes_of "$c2")]";; *) ok "routes= does not advertise zero-base";; esac

echo
echo "== 4. THE INVARIANT: EVERY printed Tier-1 command must not refuse at pre-flight =="
# Generalizes B1 / F12 / the PAFF defect. 1.15.17 widens it from the ZERO-BASE
# instance to the CLASS: the clinic's own verdict line promises "Tier-1 commands
# are ready to run", and it prints THREE of them (zero-base, trim-to-idr, and
# lead-check's surgical-cut at Tier 2). Only the zero-base route was asked of its
# authority (1.15.13's --preflight-only); the invariant below is what closes the
# others without the clinic learning about them one axis at a time. The routes
# are read out of the clinic's OWN output, so a Tier-1 route added later joins
# this invariant the day it lands.
# midgop rides late-sps.ts, the house mid-GOP fixture: without it the trim-to-idr
# arm is never offered on any profile and this section would judge one tool.
[ -f "$FIX/late-sps.ts" ] || bash "$TESTS/make-fixtures.sh" late-sps.ts >/dev/null 2>&1
i=0; offered=0
for spec in "none:$S:" "pair:$S:$WORK/pair.csv" "full2x:$S:$WORK/full2x.csv" "midgop:$FIX/late-sps.ts:"; do
  prof="${spec%%:*}"; rest="${spec#*:}"; src="${rest%%:*}"; env_file="${rest#*:}"
  [ -f "$src" ] || { ok "profile=$prof: source not available on this bench, skipped"; continue; }
  i=$((i+1))
  if [ -n "$env_file" ]; then c=$(PF_PKT_FILE="$env_file" bash "$SC/clean.sh" "$src" 2>&1)
  else c=$(bash "$SC/clean.sh" "$src" 2>&1); fi
  tools=$(printf '%s\n' "$c" | sed -n 's|.*TIER 1 (structural): scripts/\([a-z0-9-]*\)\.sh.*|\1|p' | sort -u)
  if [ -z "$tools" ]; then ok "profile=$prof: clinic offered no Tier-1 route (nothing to contradict)"; continue; fi
  for tool in $tools; do
    offered=$((offered+1))
    if [ -n "$env_file" ]; then
      PF_PKT_FILE="$env_file" bash "$SC/$tool.sh" "$src" "$WORK/inv$i-$tool.ts" >/dev/null 2>&1; zrc=$?
    else
      bash "$SC/$tool.sh" "$src" "$WORK/inv$i-$tool.ts" >/dev/null 2>&1; zrc=$?
    fi
    [ "$zrc" -ne 2 ] \
      && ok "profile=$prof: clinic offered $tool.sh and it did not refuse at pre-flight (rc=$zrc)" \
      || no "profile=$prof: clinic offered $tool.sh, which refuses at pre-flight (rc=2) — the F12 class"
  done
done
[ "$offered" -ge 2 ] && ok "the invariant judged $offered offered route(s) across the profiles (not vacuous)" \
  || no "only $offered Tier-1 route(s) were offered at all — the invariant proves almost nothing"

echo
echo "== 5. structure: the clinic ASKS zero-base, it does not model it =="
# 1.15.11 gated the PAFF axis by adding a term to a guard that enumerated
# zero-base's conditions. That closed one axis and left the NEXT one open —
# the same trap F12 and B1 fell into. 1.15.13 removes the model: zero-base is
# asked. These pins are about that structure, because the structure is what
# keeps the next axis from needing a round of its own.
# EVERY pin here reads comment-stripped source. clean.sh's own comments explain
# the ask by name, so the un-stripped versions of these greps passed with the
# CODE broken — measured MISSED 2026-08-28 (tests/mutation-audit.sh case G21,
# which replaces the flag on the zero-base CALL only and leaves the prose) and
# FALSE-POSITIVE (case P22, a comment naming NPROG).
CL=$(sed 's/#.*//' "$SC/clean.sh")
printf '%s\n' "$CL" | grepq '--preflight-only' \
  && ok "clean.sh asks zero-base for its own verdict (--preflight-only)" \
  || no "clean.sh does not ask zero-base — it is modelling the conditions again"
printf '%s\n' "$CL" | grepq '--src-tsh' \
  && ok "…and hands over the scan it already took (no duplicate whole-file pass)" \
  || no "clean.sh re-scans instead of passing --src-tsh"
printf '%s\n' "$CL" | grepq 'ZB_PAFF_OK' \
  && no "clean.sh still carries a hand-mirrored PAFF term (the model is back)" \
  || ok "no hand-mirrored refusal term left in clean.sh"

echo
echo "== 6. the ask GENERALIZES: an axis clean.sh has no code for at all =="
# Multi-program is F12's axis. clean.sh no longer mentions programs anywhere;
# if the ask works, the route is withheld anyway — which is the whole point:
# axes close without the clinic learning about them.
P2="$WORK/prog2.ts"
ff -f lavfi -i testsrc2=s=160x120:r=25 -f lavfi -i sine=1000 \
   -f lavfi -i testsrc2=s=160x120:r=25 -f lavfi -i sine=500 -t 2 \
   -map 0:v -map 1:a -map 2:v -map 3:a -c:v mpeg2video -pix_fmt yuv420p -c:a mp2 \
   -program title=P1:program_num=1:st=0:st=1 -program title=P2:program_num=2:st=2:st=3 \
   -f mpegts "$P2" 2>/dev/null || { echo "   (2-program mint failed)"; }
if [ -f "$P2" ]; then
  c3=$(bash "$SC/clean.sh" "$P2" 2>&1)
  hasnt "$c3" "$READY" "multi-program TS gets NO ready-to-run zero-base command"
  bash "$SC/zero-base.sh" "$P2" "$WORK/mp.ts" >/dev/null 2>&1; zrc=$?
  [ "$zrc" -eq 2 ] && ok "…and zero-base does refuse it (rc=2) — the ask matched the authority" \
    || no "zero-base rc=$zrc on the 2-program source (want 2)"
  printf '%s\n' "$CL" | grepq 'NPROG' \
    && no "clean.sh still hand-models the program count" \
    || ok "clean.sh holds NO multi-program code — the axis closed without it"
else
  no "could not mint the 2-program fixture"
fi

echo
echo "clean-paff-route: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
