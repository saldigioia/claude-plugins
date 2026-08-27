#!/usr/bin/env bash
# 85-c8-py-probe-floor.sh — CHECKUP-2026-08-27 C8 / WO-1.15.4: derive-dts.py
# must inherit the probe-window floor. Its av.open(src) calls ran at libav's
# stock 5 MB probesize against lib-probe.sh's explicit doctrine ("no call
# site can fall back to stock defaults") — measured on the repo's own
# late-sps.ts: PyAV saw 0x0 where the plugin floor reads the real dimensions,
# in the exact 200M-floor class the rung exists for (the 32.4 Mbit/s late-SPS
# field case).
#
# Unit lane (test-76/63 pattern — no PyAV, no media): importlib the module
# and pin rtm_open_options()' parsing of the same env knobs the shell side
# honors; a lockstep guard pins that BOTH read-side av.open call sites carry
# the options (the confession-regex lockstep discipline: a comment cannot
# hold two sites together, a test can).
#
# Pins (relationships): defaults == the lib-probe.sh floor (200M both axes);
# RTM_PROBESIZE/RTM_ANALYZEDURATION parse K/M/G decimal suffixes and plain
# integers; garbage falls back to the FLOOR, never to stock.
#
# Standalone: bash tests/regression.d/85-c8-py-probe-floor.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v python3 >/dev/null || { echo "need python3"; exit 2; }

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

echo "== 1. rtm_open_options(): env parsing pins (importlib, no PyAV) =="
if python3 - "$SC/derive-dts.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("derive_dts_mod", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def opts(**env):
    saved = {}
    for k in ("RTM_PROBESIZE", "RTM_ANALYZEDURATION"):
        saved[k] = os.environ.pop(k, None)
    os.environ.update(env)
    try:
        return m.rtm_open_options()
    finally:
        for k in ("RTM_PROBESIZE", "RTM_ANALYZEDURATION"):
            os.environ.pop(k, None)
            if saved[k] is not None:
                os.environ[k] = saved[k]

fails = []
def pin(name, got, want):
    if got != want:
        fails.append("%s: got %r want %r" % (name, got, want))

o = opts()
pin("default probesize == the 200M floor", o["probesize"], "200000000")
pin("default analyzeduration == the 200M floor", o["analyzeduration"], "200000000")
o = opts(RTM_PROBESIZE="5M")
pin("RTM_PROBESIZE=5M (the suite's stock-failure repro knob)", o["probesize"], "5000000")
o = opts(RTM_PROBESIZE="1G", RTM_ANALYZEDURATION="1G")
pin("1G retry window, probesize", o["probesize"], "1000000000")
pin("1G retry window, analyzeduration", o["analyzeduration"], "1000000000")
o = opts(RTM_PROBESIZE="123456")
pin("plain integer passes through", o["probesize"], "123456")
o = opts(RTM_PROBESIZE="64k")
pin("lowercase k suffix", o["probesize"], "64000")
o = opts(RTM_PROBESIZE="garbage")
pin("garbage falls back to the FLOOR (never to stock 5M)", o["probesize"], "200000000")

if fails:
    print("\n".join("  " + f for f in fails))
    sys.exit(1)
PY
then ok "all env-parsing pins hold (floor defaults, K/M/G, integer, garbage->floor)"
else no "rtm_open_options parsing pins failed (or the helper is missing — the pre-fix shape)"
fi

echo
echo "== 2. lockstep: BOTH read-side av.open call sites carry the options =="
n_opt=$(grep -c 'av\.open(src, options=rtm_open_options())' "$SC/derive-dts.py" || true)
[ "${n_opt:-0}" -eq 2 ] && ok "both read-side av.open(src) calls ride rtm_open_options ($n_opt/2)" \
  || no "expected 2 optioned av.open(src) sites, found ${n_opt:-0}"
bare=$(grep -c 'av\.open(src)' "$SC/derive-dts.py" || true)
[ "${bare:-0}" -eq 0 ] && ok "no bare av.open(src) remains (the stock-5M shape)" \
  || no "$bare bare av.open(src) call(s) still at stock defaults"

echo
echo "c8-py-probe-floor: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
