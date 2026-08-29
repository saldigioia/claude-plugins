#!/usr/bin/env bash
# 115-probe-head-race.sh — probe.sh must survive the head/ffprobe race under
# contention. The 1.15.2 SIGPIPE class, found alive behind a variable alias.
#
# THE DEFECT (measured 2026-08-29, chasing 12-probe-retry's contention red).
# probe_struct held its query in a local:
#     local q="ffp -v error -select_streams"
#     vcodec=$($q v:0 -show_entries stream=codec_name … | head -1)   x9
# On a program-bearing transport stream ffprobe lists every stream TWICE — the
# bare top-level view, then the in-program view — so each of those queries
# writes TWO lines. `head -1` takes the first and closes the pipe; when
# ffprobe loses that race it dies of SIGPIPE (141), `pipefail` promotes it,
# `set -e` fires, and lib-exit.sh's guard maps the stray to a bare exit 1 with
# no diagnostic. mov.sh then reads a failed --kv and refuses at the front door:
#     >> REFUSED (pre-flight): probe.sh --kv failed (rc=1) or returned no audio
# — a clean source declined, on a machine that was merely busy.
#
# WHY IT HID FOR FOUR MINOR VERSIONS. ffp1 (the SIGPIPE-safe first-line helper,
# awk reads to EOF so the writer always completes) has existed since 1.15.2 and
# 91 §5 guards the class — by matching the literal token `ffp`. Behind `$q` the
# nine armed sites were invisible to it. 91 §5 now sweeps one alias deep.
#
# MEASURED, this bench (M-series, macOS, ffmpeg 9.0.1), on the pre-fix tree:
#   24 concurrent probe.sh --kv + 4 CPU spinners …… 3/24 and 4/24 red
#   10 concurrent mov.sh at the default window …… 2/10 refused pre-flight
#   12 concurrent probe.sh, no spinners ………………… 0/12 (the race is winnable)
#   1 run, quiet machine …………………………………………… 0/1, always
# The race is scheduling-dependent, so like test 73 this file cannot pin
# "red before" on every bench. What it pins: the property, under load the
# plugin actually meets, plus the shape that made the property possible.
#
# Standalone: bash tests/regression.d/115-probe-head-race.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env/fixture failure.
# Scratch is mktemp (auto-cleaned); the spinners are this test's own children
# and are killed on exit, including on interrupt.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"
SPIN=""
# the trap owns BOTH: a killed run must not leave spinners eating the bench
cleanup () { for _p in $SPIN; do kill "$_p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
. "$TESTS/lib-harness.sh"   # rtm_strip_comments: the SAME stripper 91 §5 reads through

# fixture: a program-bearing TS is the whole point — the double stream view is
# what makes these queries multi-line and the race real. late-sps.ts is one.
if [ ! -f "$FIX/late-sps.ts" ]; then
  echo "== regenerating missing fixture: late-sps.ts =="
  bash "$TESTS/make-fixtures.sh" late-sps.ts || { echo "fixture build failed"; exit 2; }
fi

echo "== 0. precondition: the queries under test really do write two lines =="
nl=$(ffprobe -v error -probesize 200M -analyzeduration 200M -select_streams v:0 \
       -show_entries stream=codec_name -of default=nw=1:nk=1 "$FIX/late-sps.ts" 2>/dev/null | wc -l | tr -d ' ')
[ "${nl:-0}" -ge 2 ] && ok "select_streams v:0 emits $nl lines (the PMT double view — head -1 closes early)" \
  || no "v:0 codec_name emits ${nl:-0} line(s); this fixture cannot arm the race"

echo
echo "== 1. $((24)) concurrent probe.sh --kv under induced load: every run clean =="
N=24
for _ in 1 2 3 4; do dd if=/dev/zero of=/dev/null bs=1m >/dev/null 2>&1 & SPIN="$SPIN $!"; done
PP=""
for i in $(seq 1 "$N"); do
  ( bash "$SC/probe.sh" "$FIX/late-sps.ts" --kv > "$WORK/o-$i" 2>"$WORK/e-$i"; echo $? > "$WORK/rc-$i" ) &
  PP="$PP $!"
done
for p in $PP; do wait "$p"; done
for p in $SPIN; do kill "$p" 2>/dev/null; done; SPIN=""
nz=0; nz_rcs=""; empty=0
for i in $(seq 1 "$N"); do
  r=$(cat "$WORK/rc-$i" 2>/dev/null || echo missing)
  [ "$r" = 0 ] || { nz=$((nz+1)); nz_rcs="$nz_rcs $r"; continue; }
  # exit 0 is not enough: a query that silently returned EMPTY would also exit
  # 0 and quietly hand the router a source with no codec — the same bug in a
  # different hat (73 §1's lesson).
  o=$(cat "$WORK/o-$i")
  case "$o" in
    *"PR_VCODEC=h264"*) case "$o" in *"PR_ACODEC=mp2"*) case "$o" in *"PR_AUD_COUNT=1"*) continue;; esac;; esac;;
  esac
  empty=$((empty+1))
done
[ "$nz" -eq 0 ] && ok "$N/$N concurrent --kv runs exit 0 (no SIGPIPE promoted to a silent abort)" \
  || no "$nz/$N runs died under contention (rc:$nz_rcs) — the head race is live"
[ "$empty" -eq 0 ] && ok "…and every one recovered the real values (h264 / mp2 / 1 audio track)" \
  || no "$empty/$N runs exited 0 with a hollowed-out manifest"

echo
echo "== 2. the shape: probe_struct's scalar queries ride ffp1, never a bare head =="
psrc=$(rtm_strip_comments "$SC/probe.sh")
nq=$(printf '%s\n' "$psrc" | grep -cE '^\s*local .*q="ffp1 ' || true)
[ "${nq:-0}" -eq 1 ] && ok "probe_struct's query alias is ffp1 (the SIGPIPE-safe first-line helper)" \
  || no "probe_struct's alias is not ffp1 (matched $nq); the 1.15.2 class is re-armed"
nhead=$(printf '%s\n' "$psrc" | grep -cE '\$q [^|]*\|[[:space:]]*head' || true)
[ "${nhead:-0}" -eq 0 ] && ok "no \$q query pipes into head (was 9 sites, invisible to 91 §5's literal match)" \
  || no "$nhead aliased \$q|head sites remain in probe.sh"
# the positive count: the nine converted sites are still THERE, doing the work.
# A "fix" that deleted them would satisfy both checks above and probe nothing.
nsites=$(printf '%s\n' "$psrc" | grep -cE '^\s*[a-z]+=\$\(\$q [va]:0 ' || true)
[ "${nsites:-0}" -ge 9 ] && ok "all $nsites structured scalar queries survive the conversion (none silently dropped)" \
  || no "only ${nsites:-0} \$q query sites left in probe_struct, want >= 9"

echo
echo "probe-head-race: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
