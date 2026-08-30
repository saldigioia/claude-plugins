#!/usr/bin/env bash
# 116-faststart-policy.sh — faststart is the default on every .mov-writing
# route, the opt-out is manual and announced, and no writer decides on its own.
#
# THE DEFECT (1.16.7, WO-1.16.6 Item 2). Three writers, three policies: the
# shell rungs hardcoded "+faststart", derive-dts.py hardcoded it separately in
# a PyAV options dict, and poc-remux.py set no movflags AT ALL — so the POC
# rung shipped end-moov while every other rung shipped front-moov, and nothing
# said so. The 2024 VMA deliverable is that artifact: front-moov everywhere
# else, moov trailing 24 GB of mdat there, with no line in any log about it.
#
# THE POLICY. Default ON everywhere, POC rung included. The opt-out is
# RTM_FASTSTART=0 or a route's --no-faststart, and it is ANNOUNCED either way.
# Nothing turns faststart off on the file's behalf — not size, not "this looks
# archival". An automatic opt-out would be a new unannounced divergence.
#
# MEASURED 2026-08-29 (ffmpeg 9.0.1 / libavformat 63.1.101, macOS 26.6.2, a
# 3.93 GiB output on an external APFS SSD):
#   - libavformat relocates IN PLACE: it reopens the finished output for
#     reading (lsof showed one 'w' and one 'r' fd on the same path) and shifts
#     the media forward. NO temp file appeared in 50 directory samples.
#   - peak disk 4,224,974,848 B against a 4,224,596,893 B output = 1.000x, so
#     rtm_disk_preflight's one-source-size budget already covers it. UNCHANGED.
#   - the cost is TIME: 8.1 s to mux, 10.9 s more to relocate (19.0 s wall).
#   - PyAV DOES trigger the relocation (the WO's open question): poc-remux.py
#     with options={"movflags":"+faststart"} produced ftyp/moov/wide/mdat on a
#     30 s PAFF cut of feed.ts. No post-pass fallback was needed.
#
# JURISDICTION (III.2). §6's real POC build needs a PAFF source, and true PAFF
# cannot be synthesized here — x264 emits MBAFF frames, not field pictures, so
# the fixture tree has none. §6 therefore runs only when RTM_PAFF_FIXTURE names
# one, and is SKIPPED (announced, not silently passed) otherwise; the measured
# result above stands in the WO. Everything else is unconditional.
#
# Standalone: bash tests/regression.d/116-faststart-policy.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env/fixture failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT INT TERM HUP
pass=0; fail=0; skip=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
sk () { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; skip=$((skip+1)); }

# atom_order FILE -> "ftyp moov wide mdat"
atom_order () {
python3 - "$1" <<'PY'
import struct,os,sys
p=sys.argv[1]; sz=os.path.getsize(p); off=0; o=[]
with open(p,'rb') as f:
    while off<sz:
        f.seek(off); h=f.read(16)
        if len(h)<8: break
        s=struct.unpack('>I',h[0:4])[0]; t=h[4:8].decode('latin1','replace')
        if s==1: s=struct.unpack('>Q',h[8:16])[0]
        elif s==0: s=sz-off
        o.append(t)
        if s<8: break
        off+=s
print(" ".join(o))
PY
}
front_moov () {  # front_moov FILE -> 0 when moov precedes mdat
  local o; o="$(atom_order "$1")"
  case "$o" in *moov*mdat*) return 0;; esac; return 1
}

echo "== 1. the shell policy helper (lib-mux.sh) =="
. "$SC/lib-mux.sh" 2>/dev/null || { echo "cannot source lib-mux.sh"; exit 2; }
[ "$(rtm_movflags)" = "+faststart" ] && ok "default is +faststart" || no "default is '$(rtm_movflags)'"
[ "$(rtm_movflags "+write_colr")" = "+faststart+write_colr" ] \
  && ok "extras concatenate after faststart" || no "extras: '$(rtm_movflags "+write_colr")'"
( RTM_FASTSTART=0; [ -z "$(rtm_movflags)" ] ) \
  && ok "RTM_FASTSTART=0 with no extras yields EMPTY (never -movflags \"\")" \
  || no "opt-out did not yield empty"
( RTM_FASTSTART=0; [ "$(rtm_movflags "+write_colr")" = "+write_colr" ] ) \
  && ok "opt-out keeps the non-faststart extras" || no "opt-out dropped extras"
( RTM_FASTSTART=0; rtm_faststart_announce t | grep -q "RTM_FASTSTART state=off route=t" ) \
  && ok "the opt-out is ANNOUNCED (machine line, state=off)" || no "no off announcement"
rtm_faststart_announce t | grep -q "RTM_FASTSTART state=on route=t" \
  && ok "the default is ANNOUNCED too (state=on)" || no "no on announcement"

echo "== 2. WHY the array idiom exists: ffmpeg rejects an empty movflags VALUE =="
ffmpeg -nostdin -v error -f lavfi -i testsrc2=size=64x48:rate=5 -t 1 -c:v libx264 \
  -movflags "" -f mov "$WORK/empty.mov" -y 2>"$WORK/empty.err"
if grep -qi "Unable to parse .movflags. option value" "$WORK/empty.err"; then
  ok "-movflags \"\" is a hard parse error (so 'no flags' must mean 'no option')"
else
  no "expected the movflags parse error; got: $(head -1 "$WORK/empty.err")"
fi

echo "== 3. a real shell-rung build is front-moov by default, and says so =="
SRC="$FIX/aac.ts"
[ -f "$SRC" ] || bash "$TESTS/make-fixtures.sh" aac.ts >/dev/null 2>&1
if [ -f "$SRC" ]; then
  if bash "$SC/remux.sh" "$SRC" "$WORK/on.mov" >"$WORK/on.log" 2>&1; then
    front_moov "$WORK/on.mov" && ok "remux.sh default: front-moov ($(atom_order "$WORK/on.mov"))" \
      || no "remux.sh default is NOT front-moov: $(atom_order "$WORK/on.mov")"
    grep -q "RTM_FASTSTART state=on route=remux.sh" "$WORK/on.log" \
      && ok "remux.sh announced state=on" || no "remux.sh did not announce"
  else
    no "remux.sh failed: $(tail -3 "$WORK/on.log" | tr '\n' ' ')"
  fi

  echo "== 4. the same rung under the opt-out is end-moov, announced, same essence =="
  if RTM_FASTSTART=0 bash "$SC/remux.sh" "$SRC" "$WORK/off.mov" >"$WORK/off.log" 2>&1; then
    front_moov "$WORK/off.mov" && no "opt-out still produced front-moov" \
      || ok "RTM_FASTSTART=0: end-moov ($(atom_order "$WORK/off.mov"))"
    grep -q "RTM_FASTSTART state=off route=remux.sh" "$WORK/off.log" \
      && ok "the opt-out is announced in the run log" || no "opt-out not announced"
    a=$(ffmpeg -v error -i "$WORK/on.mov"  -map 0:v -c copy -f streamhash -hash md5 - 2>/dev/null)
    b=$(ffmpeg -v error -i "$WORK/off.mov" -map 0:v -c copy -f streamhash -hash md5 - 2>/dev/null)
    [ -n "$a" ] && [ "$a" = "$b" ] && ok "atom placement changed nothing in the essence" \
      || no "essence differs across the knob ($a vs $b)"
  else
    no "remux.sh --opt-out failed: $(tail -3 "$WORK/off.log" | tr '\n' ' ')"
  fi
else
  sk "aac.ts fixture unavailable — §3/§4 need a real source"
fi

echo "== 5. the Python half is ONE writer too (lib_faststart) =="
py=$(python3 - "$SC" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
import lib_faststart as L, os
r=[]
r.append(L.resolve() is True)
r.append(L.resolve(True) is False)
os.environ["RTM_FASTSTART"]="0"; r.append(L.resolve() is False); del os.environ["RTM_FASTSTART"]
r.append(L.options(True)=={"movflags":"+faststart"})
r.append(L.options(False)=={})                       # never {"movflags": ""}
r.append(L.options(True,["+use_metadata_tags"])=={"movflags":"+faststart+use_metadata_tags"})
print("OK" if all(r) else "BAD "+repr(r))
PY
)
[ "$py" = OK ] && ok "lib_faststart: defaults, both opt-outs, empty-dict on off" || no "lib_faststart: $py"

echo "== 6. the POC rung really relocates under PyAV (opt-in: RTM_PAFF_FIXTURE) =="
if [ -n "${RTM_PAFF_FIXTURE:-}" ] && [ -f "${RTM_PAFF_FIXTURE:-}" ]; then
  if bash "$SC/poc-remux.sh" "$RTM_PAFF_FIXTURE" "$WORK/poc.mov" >"$WORK/poc.log" 2>&1 \
     || [ -f "$WORK/poc.mov" ]; then
    front_moov "$WORK/poc.mov" && ok "POC rung default: front-moov (PyAV DOES relocate)" \
      || no "POC rung is NOT front-moov: $(atom_order "$WORK/poc.mov")"
    grep -q "RTM_FASTSTART state=on route=poc-remux.py" "$WORK/poc.log" \
      && ok "POC rung announced state=on" || no "POC rung did not announce"
    if bash "$SC/poc-remux.sh" "$RTM_PAFF_FIXTURE" "$WORK/pocoff.mov" --no-faststart \
         >"$WORK/pocoff.log" 2>&1 || [ -f "$WORK/pocoff.mov" ]; then
      front_moov "$WORK/pocoff.mov" && no "--no-faststart still front-moov" \
        || ok "POC rung --no-faststart: end-moov, announced"
    fi
  else
    no "POC rung failed on $RTM_PAFF_FIXTURE"
  fi
else
  sk "no RTM_PAFF_FIXTURE — real PAFF cannot be synthesized (x264 emits MBAFF, not"
  sk "  field pictures). Measured in WO-1.16.7: front-moov on a 30 s cut of feed.ts."
fi

echo "== 7. SHAPE: no writer decides faststart on its own (V.1, the class swept) =="
. "$TESTS/lib-harness.sh" 2>/dev/null || true
rogue=0
for f in "$SC"/*.sh; do
  case "$(basename "$f")" in lib-mux.sh) continue;; esac
  # A literal movflags value in a real COMMAND LINE. Advice strings are not
  # writers: gop-probe.sh/playable-check.sh/probe.sh print `-movflags +faststart`
  # as a recommendation to the operator, which is still exactly right — the
  # defect this guards is a writer choosing the policy, not a doc quoting it.
  if rtm_strip_comments "$f" 2>/dev/null \
       | grep -vE '^[[:space:]]*(echo|printf)[[:space:]]' \
       | grep -E '^[^#]*-movflags[[:space:]]+[+a-z]' | grep -qv '\$'; then
    echo "     rogue: $(basename "$f")"; rogue=$((rogue+1))
  fi
done
[ "$rogue" -eq 0 ] && ok "no shell rung hardcodes a movflags value" || no "$rogue shell rung(s) still hardcode movflags"

# The sweep ITSELF (V.1): outside the two policy writers, nothing may name the
# literal value "+faststart" in live code. This is the assertion that would
# have gone red before 1.16.7 — five rungs each carried MOVFLAGS="+faststart",
# which the command-line check above cannot see (it is an assignment, not an
# option). Knob plumbing like --no-faststart does not contain the value.
lit=0
for f in "$SC"/*.sh "$SC"/*.py; do
  case "$(basename "$f")" in lib-mux.sh|lib_faststart.py) continue;; esac
  if rtm_strip_comments "$f" 2>/dev/null | grep -vE '^[[:space:]]*(echo|printf)[[:space:]]' \
       | grep -q -- '+faststart'; then
    echo "     names the literal +faststart: $(basename "$f")"; lit=$((lit+1))
  fi
done
[ "$lit" -eq 0 ] && ok "only the policy writers name +faststart (the sweep holds)" \
  || no "$lit file(s) still name the literal +faststart"
if grep -q 'options=lib_faststart.options(' "$SC/poc-remux.py" \
   && grep -q 'options=lib_faststart.options(' "$SC/derive-dts.py"; then
  ok "both PyAV writers take their options from lib_faststart"
else
  no "a PyAV writer still builds its own movflags"
fi
grep -q '"movflags": "+faststart"' "$SC/derive-dts.py" \
  && no "derive-dts.py still carries the hardcoded dict" \
  || ok "the hardcoded PyAV dict is gone"

echo "== 8. the opt-out is MANUAL: the decision reads one input, never the file =="
# The policy resolution is explicit that nothing turns faststart off on the
# file's behalf — not size, not "this looks archival". So the predicate must
# consult RTM_FASTSTART and NOTHING ELSE. A size test here would be exactly the
# automatic, unannounced divergence 1.16.7 exists to remove; it would also be
# invisible to every other assertion in this file, which all run on small
# fixtures and would simply never trip the threshold.
body=$(sed -n '/^rtm_faststart_on ()/,/}$/p' "$SC/lib-mux.sh")
if [ -z "$body" ]; then
  no "rtm_faststart_on not found in lib-mux.sh"
else
  # via a FILE, not `printf … | grep -q`: 94 §10 forbids that shape suite-wide
  # (the 1.15.2 SIGPIPE class — an early-exit reader can kill its own writer),
  # and this file tripped it twice on the first bench. A file has no writer to
  # signal, so grep -q against one is outside the class.
  printf '%s\n' "$body" > "$WORK/decision.txt"
  grep -q 'RTM_FASTSTART' "$WORK/decision.txt" \
    && ok "the decision reads RTM_FASTSTART" || no "the decision does not read RTM_FASTSTART"
  if grep -qE '\bstat\b|\bwc\b|\bdu\b|\bdf\b|-lt|-gt|-ge|-le|size|bytes' "$WORK/decision.txt"; then
    no "rtm_faststart_on consults the FILE — the opt-out has become automatic"
  else
    ok "rtm_faststart_on consults nothing but the knob (never automatic)"
  fi
fi

echo
echo "== 116 summary: $pass passed, $fail failed, $skip skipped =="
[ "$fail" -eq 0 ] || exit 1
exit 0
