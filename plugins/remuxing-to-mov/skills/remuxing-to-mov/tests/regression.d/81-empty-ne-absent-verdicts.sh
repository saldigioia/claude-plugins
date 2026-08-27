#!/usr/bin/env bash
# 81-empty-ne-absent-verdicts.sh — CHECKUP-2026-08-27 C2/C3/C4 / WO-1.15.4:
# EMPTY probe output must never become a VERDICT.
#
#   C4  ts-health on an unreadable input used to die at its first probe with
#       ZERO output and exit 1 — which is the contract's DAMAGED ("could not
#       read" shipped as "proven damaged", silently). Now: an announced
#       pre-flight, exit 2.
#   C2  verify-source with an empty/invalid SOURCE baseline read every
#       ${s_*:-0} as 0 and accused "backward DTS INTRODUCED (0 -> N)" on a
#       byte-identical copy. Now: "no source baseline" REVIEW; the accusation
#       arms need a real baseline.
#   C3  verify.sh gate (b): a tool failure produced empty hashes on both
#       sides and empty==empty fell into "decoded frames differ / VCL
#       MISMATCH — NOT a lossless copy" — a positive claim of difference from
#       zero evidence. Now: "could not decode" INCONCLUSIVE REVIEW; the
#       accusation needs two NON-EMPTY differing hashes. Fault injection is
#       the house PATH-shim pattern (ffmpeg shims keyed on the one query
#       shape each gate owns).
#
# Standalone: bash tests/regression.d/81-empty-ne-absent-verdicts.sh
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
ff () { ffmpeg -nostdin -hide_banner -loglevel error "$@"; }

# fixture corpus self-heal (standalone runs; the harness heals once up front)
[ -f "$FIX/rot.ts" ] || bash "$TESTS/make-fixtures.sh" rot.ts >/dev/null 2>&1 || true
[ -f "$FIX/m2v420.ts" ] || bash "$TESTS/make-fixtures.sh" m2v420.ts >/dev/null 2>&1 || true

echo "== C4: ts-health on an unreadable input — announced pre-flight, exit 2 =="
head -c 4096 /dev/urandom > "$WORK/garbage.ts"
o=$(bash "$SC/ts-health.sh" "$WORK/garbage.ts" 2>&1 >/dev/null); rc_probe=0
so=$(bash "$SC/ts-health.sh" "$WORK/garbage.ts" >/dev/null 2>&1; echo $?)
[ "$so" -eq 2 ] && ok "unreadable input -> exit 2 (pre-fix: silent exit 1 = DAMAGED)" \
  || no "ts-health rc=$so (want 2)"
has "$o" "cannot read" "the pre-flight says so on stderr"
has "$o" "NOT a damage verdict" "the message separates 'unreadable' from 'damaged'"
kv=$(bash "$SC/ts-health.sh" "$WORK/garbage.ts" --kv 2>/dev/null); kvrc=$?
{ [ "$kvrc" -eq 2 ] && [ -z "$kv" ]; } && ok "--kv consumers get rc 2 + empty stdout (no fake counters)" \
  || no "--kv on unreadable input wrong (rc=$kvrc out=[$kv])"

echo
echo "== C2: no source baseline -> 'no baseline' REVIEW, never INTRODUCED =="
cp "$FIX/rot.ts" "$WORK/rot_copy.ts"
: > "$WORK/empty.kv"
o=$(bash "$SC/verify-source.sh" "$FIX/rot.ts" "$WORK/rot_copy.ts" --src-tsh "$WORK/empty.kv" 2>&1); rc=$?
hasnt "$o" "INTRODUCED" "byte-identical copy is never accused of INTRODUCING defects"
has "$o" "no source ts-health baseline" "the missing baseline is announced"
has "$o" "UNPROVEN" "attribution is called UNPROVEN, not decided"
{ [ "$rc" -eq 10 ] && case "$o" in *">> REVIEW"*) true;; *) false;; esac; } \
  && ok "verdict REVIEW exit 10 (pre-fix: FAIL exit 1 on the identical file)" \
  || no "verdict wrong (rc=$rc)"
# control: with a REAL baseline the same copy reads inherited and stays green
o=$(bash "$SC/verify-source.sh" "$FIX/rot.ts" "$WORK/rot_copy.ts" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && case "$o" in *">> OK"*) true;; *) false;; esac; } \
  && ok "control: real baseline -> inherited counters, >> OK exit 0" \
  || no "control regressed (rc=$rc)"
hasnt "$o" "no source ts-health baseline" "control: baseline present is not flagged"

echo
echo "== C3: gate (b) empty-vs-empty is 'could not decode', never an accusation =="
REAL_FFMPEG="$(command -v ffmpeg)"
# shim A: fail only the decoded-head framemd5 pass (the non-H.264 branch)
mkdir "$WORK/shimA"
cat > "$WORK/shimA/ffmpeg" <<EOF
#!/bin/bash
case "\$*" in *"-f framemd5"*) exit 1;; esac
exec "$REAL_FFMPEG" "\$@"
EOF
chmod +x "$WORK/shimA/ffmpeg"
M2="$FIX/m2v420.ts"
if [ -f "$M2" ]; then
  # OUT must MISS gate (a) (else (b) never runs): a same-codec re-encode —
  # with the framemd5 shim the decoded evidence is EMPTY on both sides, and
  # the pre-fix arm called that "frames differ; NOT a lossless copy".
  M2RE="$WORK/m2re.mov"
  ff -i "$M2" -map 0:v:0 -c:v mpeg2video -pix_fmt yuv420p -f mov "$M2RE"
  o=$(PATH="$WORK/shimA:$PATH" bash "$SC/verify.sh" "$M2" "$M2RE" 2>&1); rc=$?
  has "$o" "could not decode" "empty head hashes read 'could not decode' (INCONCLUSIVE)"
  hasnt "$o" "decoded frames differ" "no 'frames differ' accusation from zero evidence"
  has "$o" ">> " "a verdict line is reached (no silent mid-print death)"
  hasnt "$o" "NOT a lossless copy" "the lossless-copy accusation needs real evidence"
  # discrimination intact: unshimmed, the same re-encode is caught red-handed
  o=$(bash "$SC/verify.sh" "$M2" "$M2RE" 2>&1); rc=$?
  { [ "$rc" -eq 1 ] && case "$o" in *"decoded frames differ"*) true;; *) false;; esac; } \
    && ok "negative control: the real re-encode still FAILs 'frames differ' unshimmed" \
    || no "fhead discrimination lost (rc=$rc)"
else
  echo "  (skip: m2v420.ts fixture unavailable)"
fi
# shim B: fail only the VCL filter_units pass (the H.264 branch)
mkdir "$WORK/shimB"
cat > "$WORK/shimB/ffmpeg" <<EOF
#!/bin/bash
case "\$*" in *"filter_units"*) exit 1;; esac
exec "$REAL_FFMPEG" "\$@"
EOF
chmod +x "$WORK/shimB/ffmpeg"
H="$WORK/h.ts"; HCP="$WORK/hcp.mov"
ff -f lavfi -i testsrc2=s=320x240:r=25 -t 3 -c:v libx264 -g 25 -bf 2 -pix_fmt yuv420p -f mpegts "$H"
# a TS->MOV plain copy: gate (a) mismatches (SPS/PPS re-placed), so (b) VCL runs
ff -i "$H" -map 0:v:0 -c:v copy -movflags +faststart -f mov "$HCP"
o=$(PATH="$WORK/shimB:$PATH" bash "$SC/verify.sh" "$H" "$HCP" 2>&1); rc=$?
has "$o" "VCL hash could not be computed" "empty VCL hashes read 'could not be computed'"
hasnt "$o" "VCL MISMATCH" "no 'VCL MISMATCH' accusation from zero evidence"
[ "$rc" -eq 0 ] && ok "inconclusive gate (b) lands REVIEW-side (exit 0), not FAIL(1)" \
  || no "rc=$rc (pre-fix: FAIL 1 on 'slice data differs')"
# discrimination intact: a REAL re-encode must still FAIL VCL MISMATCH unshimmed
RE="$WORK/re.mov"
ff -i "$H" -map 0:v:0 -c:v libx264 -crf 30 -pix_fmt yuv420p "$RE"
o=$(bash "$SC/verify.sh" "$H" "$RE" 2>&1); rc=$?
{ [ "$rc" -eq 1 ] && case "$o" in *"VCL MISMATCH"*) true;; *) false;; esac; } \
  && ok "negative control: a real re-encode still FAILs VCL MISMATCH" \
  || no "discrimination lost (rc=$rc)"

echo
echo "empty-ne-absent-verdicts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
