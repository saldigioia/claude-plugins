#!/usr/bin/env bash
# 110-park-name-collision.sh — a source whose NAME collides with a name this
# plugin derives for its own scratch must never be touched.
#
# THE MEASURED INCIDENT (2026-08-29). `auto.sh` derives its park file as
# rtm_sidecar(OUT, autobest) — for OUT=x.mov that is x.autobest.mov — and the
# ladder opens with `rm -f "$BEST_SAVE"` to clear a stale park. Handed a SOURCE
# named x.autobest.mov, it DELETED IT, and then printed ">> FAIL … Source
# untouched." A quiet irreversible act and a false statement about it, in one
# run. 1.16.0 closed it with rtm_sibling_guard.
#
# WHY THIS FILE EXISTS ANYWAY. 94-rot-sweep.sh §12 pins that the guard has one
# writer and that every builder reaches it. Neither of those is the same claim
# as "the source survives" — a guard can be present, called, and wrong about
# which names it covers. This test asserts the OUTCOME, over EVERY name the
# tree derives, from the guard's own list rather than a hand-written copy of
# it (Constitution V.1: sweep the class, never the instance). A new sidecar tag
# is covered here the moment it is added to RTM_SIDECAR_TAGS — and if it is
# NOT added, §5 below fails the bench.
#
# Standalone: bash tests/regression.d/110-park-name-collision.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
. "$TESTS/lib-harness.sh"
# the guard's OWN tag list is the table — never a second copy of it here
. "$SC/lib-probe.sh"
. "$SC/lib-mux.sh"

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -y -v error "$@"; }
sumof () { cksum < "$1" | awk '{print $1"-"$2}'; }

mint () {  # mint a valid TS at $1
  ff -f lavfi -i testsrc2=s=160x120:r=25 -t 1 -c:v libx264 -g 25 -bf 0 -pix_fmt yuv420p -f mpegts "$1"
}

echo "== 0. the table: every name the tree derives from OUT =="
[ -n "${RTM_SIDECAR_TAGS:-}" ] && ok "the guard publishes its sidecar tags ($RTM_SIDECAR_TAGS)" \
  || { no "RTM_SIDECAR_TAGS is not defined — there is no table to sweep"; echo "park-name-collision: $pass passed, $fail failed"; exit 1; }

echo
echo "== 1. a source named like ANY derived sidecar is refused, and survives =="
# ONE driver for the whole table: the guard is shared, so whichever script
# derives a given name, every builder must refuse a source that collides with
# it. remux.sh is the cheapest builder that reaches the shared pre-flight.
for tag in $RTM_SIDECAR_TAGS; do
  d="$WORK/$tag"; mkdir -p "$d"
  # the collision is constructed by the SAME function the tree derives with
  src="$(rtm_sidecar "$d/x.mov" "$tag")"
  mint "$src" 2>/dev/null || { no "$tag: could not mint the colliding fixture"; continue; }
  before=$(sumof "$src")
  o=$(bash "$SC/remux.sh" "$src" "$d/x.mov" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && ok "$tag: a source named $(basename "$src") refuses (exit 2)" \
    || no "$tag: rc=$rc, want 2 — the guard does not cover this derived name"
  if [ -f "$src" ] && [ "$(sumof "$src")" = "$before" ]; then
    ok "$tag: the source is byte-identical afterwards"
  else
    no "$tag: THE SOURCE WAS DESTROYED (or altered) BY ITS OWN DERIVED NAME"
  fi
done

echo
echo "== 2. the atomic .part shape and the lock name =="
d="$WORK/part"; mkdir -p "$d"
src="$d/y.part-999-1.mov"; mint "$src" 2>/dev/null
before=$(sumof "$src")
o=$(bash "$SC/remux.sh" "$src" "$d/y.mov" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "a source matching the .part name shape refuses" || no "part-shape rc=$rc, want 2"
[ "$(sumof "$src")" = "$before" ] && ok "…and survives byte-identical" || no "THE .part-SHAPED SOURCE WAS DESTROYED"
d="$WORK/lock"; mkdir -p "$d"
src="$d/z.mov.lock"; mint "$src" 2>/dev/null
before=$(sumof "$src")
o=$(bash "$SC/remux.sh" "$src" "$d/z.mov" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "a source occupying the writer-lock name does not build (rc=$rc)" \
  || no "a source named like the lock dir let the build proceed (rc=0)"
[ -f "$src" ] && [ "$(sumof "$src")" = "$before" ] && ok "…and the lock-named source survives byte-identical" \
  || no "THE LOCK-NAMED SOURCE WAS DESTROYED"

echo
echo "== 3. the measured incident, end to end through auto.sh =="
# The exact shape of the 2026-08-29 defect: the ladder's own park file.
d="$WORK/incident"; mkdir -p "$d"
src="$(rtm_sidecar "$d/x.mov" autobest)"
mint "$src" 2>/dev/null
before=$(sumof "$src")
o=$(bash "$SC/auto.sh" "$src" "$d/x.mov" 2>&1); rc=$?
if [ -f "$src" ] && [ "$(sumof "$src")" = "$before" ]; then
  ok "the source survives auto.sh's park-file cleanup"
else
  no "THE SOURCE WAS DELETED BY THE PARK-FILE COLLISION (the 2026-08-29 incident)"
fi
[ "$rc" -eq 2 ] && ok "the collision refuses at pre-flight, before any rung runs" || no "auto rc=$rc, want 2"
hasnt "$o" "-- attempting" "no rung is attempted"
hasnt "$o" "AUTO_SUMMARY" "no ladder verdict is reached"
has "$o" "RTM_SIBLING verdict=refused" "the refusal emits its machine row"

echo
echo "== 4. no false refusal: an ordinary sibling still builds =="
d="$WORK/ok"; mkdir -p "$d"
mint "$d/plain.ts" 2>/dev/null
o=$(bash "$SC/remux.sh" "$d/plain.ts" "$d/plain.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$d/plain.mov" ]; } && ok "an ordinary source builds normally (rc=0)" \
  || { no "false refusal on an ordinary source (rc=$rc)"; printf '%s\n' "$o" | tail -3; }

echo
echo "== 5. every INLINE derived name is registered in the guard's table =="
# The table above only sweeps what the guard knows. A name built by hand —
# `${OUT%.*}.something.$ext` rather than rtm_sidecar — is invisible to it, and
# invisible is exactly how the autobest defect survived. MEASURED 2026-08-29:
# mov.sh derived `${OUT%.*}.idrtrim.tmp.$ext` inline and `rm -f`s it on
# success, so a source with that name was still deletable after the round that
# closed the class. Comments stripped: lib-mux.sh's header describes the idiom.
inline_bad=""
for f in "$SC"/*.sh; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in lib-mux.sh) continue;; esac   # the one writer
  while IFS= read -r tagname; do
    [ -n "$tagname" ] || continue
    case " $RTM_SIDECAR_TAGS " in
      *" $tagname "*) : ;;
      *) inline_bad="$inline_bad $(basename "$f"):$tagname" ;;
    esac
  done <<EOF
$(rtm_strip_comments "$f" | sed -n 's/.*\${OUT%\.\*}\.\([A-Za-z0-9._-]*\)\.\$.*/\1/p' | sort -u)
EOF
done
[ -z "$inline_bad" ] && ok "every inline-derived scratch name is in RTM_SIDECAR_TAGS" \
  || no "inline scratch names the sibling guard cannot see:$inline_bad"

echo
echo "== 6. RTM_OWN_SCRATCH: this run's own intermediate is allowed, and has a floor =="
# mov.sh's IDR trim writes an intermediate and then ADOPTS it as the input for
# the build that follows, so that file matches the derived-name shape by
# construction. Refusing it would refuse the plugin's own two-stage build —
# measured 2026-08-29, when registering the idrtrim.tmp tag broke tests
# 11/12/22. The escape hatch is DECLARED by the caller, never inferred, and it
# does NOT extend to writing onto the file being read.
d="$WORK/own"; mkdir -p "$d"
src="$d/w.idrtrim.tmp.ts"; mint "$src" 2>/dev/null
before=$(sumof "$src")
o=$(bash "$SC/remux.sh" "$src" "$d/w.mov" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "undeclared: a source with the intermediate's shape still refuses" || no "undeclared rc=$rc, want 2"
o=$(RTM_OWN_SCRATCH="$(rtm_canon "$src")" bash "$SC/remux.sh" "$src" "$d/w.mov" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$d/w.mov" ]; } \
  && ok "declared: the run's own intermediate builds (the two-stage path works)" \
  || { no "declared own-scratch still refused (rc=$rc)"; printf '%s\n' "$o" | tail -3; }
[ "$(sumof "$src")" = "$before" ] && ok "…and the intermediate itself is untouched" || no "the declared intermediate was modified"
# THE FLOOR: declaring a path never licenses writing onto the file being read
o=$(RTM_OWN_SCRATCH="$(rtm_canon "$src")" bash "$SC/remux.sh" "$src" "$src" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "IN == OUT is refused even for a declared own-scratch path" \
  || no "the escape hatch let a run write onto the file it was reading (rc=$rc)"
has "$o" "the output itself" "…and the refusal names why"

echo
echo "park-name-collision: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
