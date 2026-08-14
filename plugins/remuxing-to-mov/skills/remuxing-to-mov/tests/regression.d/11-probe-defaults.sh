#!/usr/bin/env bash
# 11-probe-defaults.sh — work-order 1.1: raised probe defaults, centrally.
#
# Pins the lib-probe.sh contract born from the misprobe incident: a 32.4 Mbit/s
# BBC TS with its first SPS ~6.4 MB in defeated ffmpeg's stock 5 MB probe —
# mov.sh died with "[mov] dimensions not set", plain ffprobe saw no streams,
# and the misprobe fed paff=no into routing a working probe later contradicted.
# Every input open now rides ffp/FF_INPUT_OPTS with a 200M floor on both axes,
# overridable via RTM_PROBESIZE / RTM_ANALYZEDURATION.
#
# Asserted here, on the synthetic late-sps.ts (first SPS ~8 MB in):
#   1. the env knob plumbs through: FF_INPUT_OPTS honors RTM_* overrides and
#      carries the 200M defaults otherwise;
#   2. mov.sh proceeds past the probe on late-sps.ts (no "dimensions not set");
#      REVIEW (10) is legitimate — the mid-GOP head slice has fixture-inherent
#      A/V duration skew — but the probe failure classes (1/2/11) are not;
#   3. RTM_PROBESIZE=5M still fails on the FIRST attempt (knob provably wired,
#      fixture still earns its keep) — and the WO 1.2 probe-shaped retry then
#      heals it at 1G (the one behavior 1.2 deliberately changed here);
#   4. controls: m2v420.ts and aac.ts still convert to verified OK (the raised
#      window changes no healthy-file verdict).
#
# Standalone: bash tests/regression.d/11-probe-defaults.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env/fixture failure.
# Regenerates its fixtures via make-fixtures.sh when missing. Scratch goes to
# mktemp (auto-cleaned); the repo tree is never written to.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }

# fixtures: regenerate any that are missing (media never ships in git)
need=""
for f in late-sps.ts m2v420.ts aac.ts; do [ -f "$FIX/$f" ] || need="$need $f"; done
if [ -n "$need" ]; then
  echo "== regenerating missing fixtures:$need =="
  # shellcheck disable=SC2086  # word splitting is the point
  bash "$TESTS/make-fixtures.sh" $need || { echo "fixture build failed"; exit 2; }
fi

echo "== 1. env knob plumbing: FF_INPUT_OPTS honors RTM_* and defaults to 200M =="
opts_def=$(bash -c ". '$SC/lib-probe.sh'; echo \"\${FF_INPUT_OPTS[*]}\"")
has "$opts_def" "-probesize 200M" "default -probesize 200M"
has "$opts_def" "-analyzeduration 200M" "default -analyzeduration 200M"
opts_env=$(RTM_PROBESIZE=7M RTM_ANALYZEDURATION=123M \
  bash -c ". '$SC/lib-probe.sh'; echo \"\${FF_INPUT_OPTS[*]}\"")
has "$opts_env" "-probesize 7M" "RTM_PROBESIZE=7M overrides the default"
has "$opts_env" "-analyzeduration 123M" "RTM_ANALYZEDURATION=123M overrides the default"

echo
echo "== 2. late-sps.ts: mov.sh proceeds past the probe on the raised default =="
out=$(bash "$SC/mov.sh" "$FIX/late-sps.ts" "$WORK/late.mov" 2>&1); rc=$?
hasnt "$out" "dimensions not set" "no '[mov] dimensions not set' on the default window"
case "$rc" in 0|10) ok "mov.sh built the file (rc=$rc; REVIEW is fixture-inherent A/V skew)";;
  *) no "mov.sh rc=$rc — probe-class failure (want 0 or 10)";; esac
[ -f "$WORK/late.mov" ] && ok "output written" || no "no output file written"
wd=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$WORK/late.mov" 2>/dev/null | head -1)
[ "${wd:-}" = 1280 ] && ok "output carries the real dimensions (width=1280)" \
  || no "output width='$wd', want 1280 (probe still blind?)"

echo
echo "== 3. RTM_PROBESIZE=5M: attempt 1 fails at the knobbed window; the WO 1.2 retry heals it at 1G =="
# ORIGIN UPDATE (WO 1.4 wiring): when this suite was written (WO 1.1) a 5M
# window was a terminal FAIL — that pinned the knob. WO 1.2 then added the
# probe-shaped-failure retry: attempt 1 still runs at the 5M the knob set and
# still misses (the retry notices below are the proof the knob was honored and
# the miss was real), and the single 1G retry converts the fixture. Both
# original properties stay pinned; only the "stays failed" ending moved — that
# is exactly the behavior WO 1.2 shipped.
out=$(RTM_PROBESIZE=5M bash "$SC/mov.sh" "$FIX/late-sps.ts" "$WORK/late5m.mov" 2>&1); rc=$?
has "$out" "re-probing wide (1G)" "5M probe window misses -> pf_detect re-probes wide (knob honored)"
has "$out" "retrying with 1G" "5M mux attempt fails probe-shaped -> the WO 1.2 retry notice fires"
case "$rc" in 0|10) ok "1G retry heals the 5M window (rc=$rc; REVIEW is fixture-inherent A/V skew)";;
  *) no "retry did not heal the 5M window (rc=$rc)";; esac

echo
echo "== 4. controls: healthy fixtures still convert to verified OK =="
out=$(bash "$SC/mov.sh" "$FIX/m2v420.ts" "$WORK/m2v420.mov" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "m2v420.ts -> OK (rc=0)" || no "m2v420.ts rc=$rc (want 0)"
has "$out" ">> DONE" "m2v420.ts reports DONE"
out=$(bash "$SC/mov.sh" "$FIX/aac.ts" "$WORK/aac.mov" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "aac.ts -> OK (rc=0)" || no "aac.ts rc=$rc (want 0)"
has "$out" ">> DONE" "aac.ts reports DONE"

echo
echo "probe-defaults: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
