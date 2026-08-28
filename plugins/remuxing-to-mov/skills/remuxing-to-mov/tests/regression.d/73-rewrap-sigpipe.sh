#!/usr/bin/env bash
# 73-rewrap-sigpipe.sh — 1.15.2 Defect A: rewrap_layout must survive
# multi-stream program= probes under `set -euo pipefail`.
#
# The bug: `ffp ... -show_entries program= ... | head -1` — program= emits one
# program line plus one blank line per program_stream, and head's early close
# SIGPIPEs ffprobe (exit 141) when it loses the write/exit race; pipefail +
# set -e then abort the caller with ZERO diagnostic. The race is stable
# per-bench (the field bench lost 5/5 at the 200M window while winning 5/5 at
# stock 5M), so this test cannot pin "red before" everywhere — what it pins:
#   1. rewrap_layout exits 0 on a multi-stream program, repeatedly (>=5 runs,
#      strict mode), AND recovers the real values — a helper that silently
#      returned empty would exit 0 and quietly drop layout preservation,
#      which is the same bug wearing a different hat;
#   2. the class guard: the two program= sites in lib-rewrap.sh go through
#      ffp1 (the SIGPIPE-safe first-line helper), and no `program=` query
#      anywhere in scripts/ rides a bare `| head` again.
#
# Standalone: bash tests/regression.d/73-rewrap-sigpipe.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

. "$TESTS/lib-harness.sh"   # grepq/grepqe + rtm_strip_comments: one definition (tests/lib-harness.sh)
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }

echo "== fixture: 3-stream single-program TS (v + 2a, custom PIDs + PMT) =="
S="$WORK/multi.ts"
ff -f lavfi -i "testsrc2=s=320x240:r=25" -f lavfi -i "sine=1000" -f lavfi -i "sine=500" \
   -t 3 -map 0:v -map 1:a -map 2:a -c:v libx264 -g 25 -pix_fmt yuv420p -c:a mp2 \
   -streamid 0:3050 -streamid 1:3051 -streamid 2:3052 \
   -mpegts_pmt_start_pid 305 -f mpegts "$S" || { echo "fixture mint failed"; exit 2; }

echo
echo "== 1. rewrap_layout under set -euo pipefail: 5 runs, values recovered =="
runs_ok=0
for i in 1 2 3 4 5; do
  out=$(bash -c '
    set -euo pipefail
    . "$1/lib-probe.sh"; . "$1/lib-rewrap.sh"
    rewrap_layout "$2"
    printf "MUX:%s\nSID:%s\n" "${RW_MUX_OPTS[*]:-none}" "${RW_STREAMID_OPTS[*]:-none}"
  ' _ "$SC" "$S" 2>&1); rc=$?
  case "$rc:$out" in
    0:*"-mpegts_pmt_start_pid 305"*"-mpegts_service_id 1"*) : ;;
    *) echo "   run $i: rc=$rc out=[$out]"; continue;;
  esac
  case "$out" in *"0:3050"*"1:3051"*"2:3052"*) runs_ok=$((runs_ok+1));; *) echo "   run $i: streamids missing [$out]";; esac
done
[ "$runs_ok" -eq 5 ] && ok "5/5 strict-mode runs: exit 0, PMT 305 + service 1 + all 3 PIDs recovered" \
  || no "only $runs_ok/5 strict-mode runs recovered the full layout"

echo
echo "== 2. class guard: program= queries are ffp1, never bare | head =="
n_ffp1=$(rtm_strip_comments "$SC/lib-rewrap.sh" | grep -c 'ffp1 .*program=' || true)
[ "${n_ffp1:-0}" -eq 2 ] && ok "both lib-rewrap program= sites ride ffp1 ($n_ffp1)" \
  || no "expected 2 ffp1 program= sites in lib-rewrap.sh, found ${n_ffp1:-0}"
# comment-stripped + basenames: an un-stripped grep is satisfied by a comment
# saying "never do this" (measured FALSE-POSITIVE 2026-08-28, case P19).
offenders=""
for _f in "$SC"/*.sh; do
  rtm_strip_comments "$_f" | grepqe 'program=[a-z_]+.*\|[[:space:]]*head' && offenders="$offenders $(basename "$_f")"
done
[ -z "$offenders" ] && ok "no program= query in scripts/ pipes into head (the armed shape)" \
  || no "program= | head reintroduced in: $offenders"

echo
echo "rewrap-sigpipe: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
