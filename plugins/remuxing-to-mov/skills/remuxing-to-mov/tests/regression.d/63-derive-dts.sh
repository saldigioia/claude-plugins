#!/usr/bin/env bash
# 63-derive-dts.sh — WO 1.14 Phase 3: Rung 3-DERIVE (derive-dts.sh/.py), pinned.
#
# The class (2023-VMA incident): reordered H.264 in a container that stores no
# DTS (MKV) — ffmpeg reconstructs DTS from has_b_frames and the MOV mux writes
# the broken reconstruction. The rung derives DTS[i] = (i-D)-th smallest PTS
# from the whole-file PTS column, pre-roll spaced at the modal sorted-PTS delta.
#
# Pinned here (the three-layer strategy, plan §3 Phase 3):
#   1. static: bash -n on the driver, py_compile on the vendored python.
#   2. derivation MATH with no PyAV: importlib the pure derive_dts() on the
#      field-coded pyramid shape from the docs (coded order
#      0,17,133,150,67,83,33,50,100,117 -> depth 4): D=4, strictly monotonic,
#      DTS<=PTS, pre-roll spaced at the modal delta (17, never 1 tick);
#      duplicate PTS raises the refusal.
#   3. driver gates, hermetic (no PyAV needed — a venv SHIM answers the
#      dependency check so the SIGNATURE gates are reachable): venv-absent ->
#      exit 10 + the one-line bootstrap; dup-PTS ticks injection -> exit 3;
#      N/A-PTS injection -> exit 3 naming pairfill; the ADVERSARIAL half:
#      a correct-SPS fixture (PF_DEPTH_CLASS=match-frame) must NOT pass the
#      signature gate without --force (exit 3).
#   4. END-TO-END when PyAV is importable by python3 (announced SKIP when not):
#      minted reordered MKV (libx264 b-pyramid — MKV genuinely stores no DTS)
#      + ffmetadata chapters, --force through the match-frame guard: all four
#      output gates pass, chapters survive, video packet-hash identical,
#      DERIVE_DTS machine line present; --limit bench -> exit 10, never blessed.
#   5. doctor.sh reports the venv (DOC_PYAV, report-only).
# True-PAFF integration remains operator-verified on the next class member
# (house SYNTHESIS LIMIT: libx264 cannot mint PAFF; never faked).
#
# Standalone: bash tests/regression.d/63-derive-dts.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
command -v python3 >/dev/null || { echo "need python3"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }
ff () { ffmpeg -nostdin -y -v error "$@"; }

echo "== 1. static: driver parses, python compiles =="
bash -n "$SC/derive-dts.sh" && ok "bash -n derive-dts.sh" || no "derive-dts.sh does not parse"
# bytecode goes to scratch, never into the repo (no scripts/__pycache__ litter)
if python3 -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
     "$SC/derive-dts.py" "$WORK/derive-dts.pyc" 2>/dev/null
then ok "py_compile derive-dts.py"; else no "derive-dts.py does not compile"; fi

echo
echo "== 2. derivation math, no PyAV: the documented field-coded pyramid shape =="
# coded order 0,17,133,150,67,83,33,50,100,117 (docs' field-coded shape): the
# picture at coded index 2 (pts 133) sits at presentation rank 8 — depth 4.
if python3 - "$SC/derive-dts.py" <<'PY'
import importlib.util, sys
sys.dont_write_bytecode = True   # keep scripts/__pycache__ out of the repo
spec = importlib.util.spec_from_file_location("derive_dts_mod", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
coded = [0, 17, 133, 150, 67, 83, 33, 50, 100, 117]
dts, depth, step = m.derive_dts(coded)
assert depth == 4, "depth %r != 4" % depth
assert step == 17, "modal step %r != 17 (pre-roll must be coded-pic duration, never 1 tick)" % step
assert all(dts[i] > dts[i-1] for i in range(1, len(dts))), "DTS not strictly monotonic"
assert all(dts[i] <= coded[i] for i in range(len(dts))), "DTS exceeds PTS"
assert [dts[i+1]-dts[i] for i in range(4)] == [17, 17, 17, 17], "pre-roll not spaced at the modal delta"
assert dts[4] == 0, "DTS[depth] must be the smallest PTS"
# duplicate PTS must raise the refusal, not derive
try:
    m.derive_dts([0, 17, 17, 33]); raise SystemExit("dup PTS not refused")
except m.Refuse: pass
print("math ok")
PY
then ok "D=4, monotonic, DTS<=PTS, pre-roll = modal delta, dup-PTS refused (pure python)"
else no "derivation math pin failed"; fi

echo
echo "== 3. driver gates, hermetic (venv shim; no PyAV required) =="
# venv-absent path: an EMPTY data dir must exit 10 with the one-line bootstrap
ANYIN="$WORK/any.ts"
ff -f lavfi -i testsrc2=s=160x120:r=25 -t 1 -c:v libx264 -g 25 -pix_fmt yuv420p -f mpegts "$ANYIN" || { echo "fixture mint failed"; exit 2; }
mkdir -p "$WORK/nodata"
o=$(CLAUDE_PLUGIN_DATA="$WORK/nodata" bash "$SC/derive-dts.sh" "$ANYIN" "$WORK/nv.mov" 2>&1); rc=$?
[ "$rc" -eq 10 ] && ok "venv absent -> exit 10 REVIEW (advisory-before-automatic)" || no "venv-absent rc=$rc, want 10"
has "$o" "python3 -m venv \"$WORK/nodata/venv\"" "the one-line bootstrap names THIS data dir"
has "$o" "pip\" install av" "the bootstrap installs av (and nothing is auto-installed)"
has "$o" "Manual recipe" "the manual (no-venv) recipe is printed"
[ -f "$WORK/nv.mov" ] && no "venv-absent run wrote an output" || ok "venv-absent run writes nothing"

# a venv SHIM that answers ONLY the 'import av' dependency probe, so the
# signature gates are reachable on a bench with no PyAV at all (the gates
# refuse before the python stage ever runs)
mkdir -p "$WORK/shimdata/venv/bin"
cat > "$WORK/shimdata/venv/bin/python" <<'SH'
#!/bin/sh
case "$*" in *"import av"*) echo 0.0-shim; exit 0;; esac
exec python3 "$@"
SH
chmod +x "$WORK/shimdata/venv/bin/python"

# duplicate-PTS injection (PF_PKT_TICKS_FILE, the pf_reorder_scan hook) -> exit 3
awk 'BEGIN{for(i=0;i<50;i++)printf "%d,%d\n", (i==20?573:i*33), i*33}' > "$WORK/dup.csv"
printf '573,660\n' >> "$WORK/dup.csv"   # a second 573: one duplicated display instant
o=$(CLAUDE_PLUGIN_DATA="$WORK/shimdata" PF_PKT_TICKS_FILE="$WORK/dup.csv" \
    bash "$SC/derive-dts.sh" "$ANYIN" "$WORK/dp.mov" 2>&1); rc=$?
[ "$rc" -eq 3 ] && ok "duplicate PTS -> SIGNATURE REFUSED, exit 3" || no "dup-PTS rc=$rc, want 3"
has "$o" "duplicate PTS" "the refusal names the duplication"

# N/A-PTS injection -> exit 3, routed to pairfill (the half-timestamped class)
awk 'BEGIN{for(i=0;i<50;i++){printf "%d,%d\n", i*33, i*33; if(i%2)print "N/A,N/A"}}' > "$WORK/napts.csv"
o=$(CLAUDE_PLUGIN_DATA="$WORK/shimdata" PF_PKT_TICKS_FILE="$WORK/napts.csv" \
    bash "$SC/derive-dts.sh" "$ANYIN" "$WORK/na.mov" 2>&1); rc=$?
[ "$rc" -eq 3 ] && ok "N/A-PTS packets -> SIGNATURE REFUSED, exit 3" || no "N/A-PTS rc=$rc, want 3"
has "$o" "pairfill-paff.sh" "the refusal routes to pairfill (the class that owns missing PTS)"

echo
echo "== 4. the minted reordered MKV + chapters (fixture for guard + end-to-end) =="
# libx264 B-pyramid in MKV: MKV stores no DTS, so the fixture is genuinely
# PTS-only (every dts ffprobe shows is the demuxer's reconstruction). Two audio
# tracks exercise the multi-stream carry; ffmetadata chapters exercise the
# re-attach pass. has_b_frames is CORRECT on this fixture (match-frame) — which
# is exactly what makes it the adversarial guard pin.
MKV="$WORK/reord.mkv"; MKVCH="$WORK/reordch.mkv"
ff -f lavfi -i testsrc2=s=320x240:r=30000/1001 -f lavfi -i sine=frequency=440:sample_rate=48000 \
   -f lavfi -i sine=frequency=880:sample_rate=48000 -t 4 -map 0:v -map 1:a -map 2:a \
   -c:v libx264 -g 30 -bf 8 -x264opts b-pyramid=normal:b-adapt=0 -pix_fmt yuv420p -c:a aac \
   -metadata:s:a:0 language=eng -metadata:s:a:1 language=spa "$MKV" || { echo "MKV mint failed"; exit 2; }
printf ';FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=2000\ntitle=One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=2000\nEND=4000\ntitle=Two\n' > "$WORK/ch.txt"
ff -i "$MKV" -i "$WORK/ch.txt" -map 0 -map_metadata 1 -map_chapters 1 -c copy "$MKVCH" || { echo "chapter attach failed"; exit 2; }
nch=$(ffprobe -v error -show_chapters -of csv "$MKVCH" 2>/dev/null | grep -c '^chapter' || true)
[ "${nch:-0}" -eq 2 ] && ok "fixture carries 2 chapters" || no "fixture chapters wrong ($nch)"

# ADVERSARIAL GUARD: correct SPS (match-frame) must NOT auto-route through the
# rung — the reconstruction is NOT provably short, so blind restamping refuses.
o=$(CLAUDE_PLUGIN_DATA="$WORK/shimdata" bash "$SC/derive-dts.sh" "$MKVCH" "$WORK/g.mov" 2>&1); rc=$?
[ "$rc" -eq 3 ] && ok "match-frame class WITHOUT --force -> exit 3 (no blind restamp)" || no "guard rc=$rc, want 3"
has "$o" "match-frame" "the refusal names the measured class"
has "$o" "--force" "the refusal names the operator override"
[ -f "$WORK/g.mov" ] && no "guard refusal wrote an output" || ok "guard refusal writes nothing"

echo
echo "== 5. end-to-end (PyAV) — announced SKIP when python3 lacks av =="
if python3 -c 'import av' 2>/dev/null; then
  # a REAL venv shape whose python is the system python3 (which has av) — the
  # driver only requires $DATA/venv/bin/python to import av, which this does.
  mkdir -p "$WORK/realdata/venv/bin"
  cat > "$WORK/realdata/venv/bin/python" <<SH
#!/bin/sh
exec "$(command -v python3)" "\$@"
SH
  chmod +x "$WORK/realdata/venv/bin/python"
  o=$(CLAUDE_PLUGIN_DATA="$WORK/realdata" bash "$SC/derive-dts.sh" "$MKVCH" "$WORK/d.mov" --force 2>&1); rc=$?
  { [ "$rc" -eq 0 ] && [ -f "$WORK/d.mov" ]; } && ok "derive-dts --force on the minted MKV -> blessed, exit 0" \
    || { no "end-to-end rc=$rc"; printf '%s\n' "$o" | tail -12 | sed 's/^/   /'; }
  has "$o" "FORCED past the depth-class gate" "--force announces itself"
  has "$o" "re-attaching 2 chapter(s)" "the chapter re-attach pass is announced"
  has "$o" "PTS multiset" "the PTS identity gate is announced"
  has "$o" "bit-identical" "the packet-hash gate passed"
  has "$o" "census:" "mux_census ran on the finished part"
  dline=$(printf '%s\n' "$o" | grep '^DERIVE_DTS ' | head -1)
  case "$dline" in
    "DERIVE_DTS depth="*" shift_ms="*" packets="*" census=ok verdict=ok")
      ok "DERIVE_DTS machine line present with the additive schema";;
    *) no "DERIVE_DTS machine line wrong: '$dline'";;
  esac
  # chapters survived into the deliverable, and the chapter track is the LAST stream
  nch=$(ffprobe -v error -show_chapters -of csv "$WORK/d.mov" 2>/dev/null | grep -c '^chapter' || true)
  [ "${nch:-0}" -eq 2 ] && ok "both chapters survive into the .mov" || no "chapters lost ($nch)"
  na=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$WORK/d.mov" 2>/dev/null | grep -c . || true)
  [ "${na:-0}" -eq 2 ] && ok "both audio tracks carried" || no "audio tracks: $na, want 2"
  # independent packet-hash identity (the same claim the gate made, re-measured)
  vh () { ffmpeg -nostdin -v error -i "$1" -map 0:v:0 -c copy -f streamhash -hash md5 - 2>/dev/null; }
  { [ -n "$(vh "$MKVCH")" ] && [ "$(vh "$MKVCH")" = "$(vh "$WORK/d.mov")" ]; } \
    && ok "video packets bit-identical source vs deliverable (independent re-hash)" \
    || no "packet hash differs src vs out"
  # output timeline: 0 N/A, strictly monotonic DTS, DTS<=PTS (independent scan)
  tl=$(ffprobe -v error -select_streams v:0 -show_entries packet=pts,dts -of csv=p=0 "$WORK/d.mov" 2>/dev/null | \
       awk -F, 'NF{ n++
           if($1=="N/A"||$1==""||$2=="N/A"||$2==""){bad++; next}
           d=$2+0; if(hav && d<=pd) mono++; pd=d; hav=1
           if(d>$1+0) viol++ }
         END{ printf "n=%d bad=%d mono=%d viol=%d", n+0, bad+0, mono+0, viol+0 }')
  case "$tl" in *" bad=0 mono=0 viol=0") ok "output timeline clean ($tl)";; *) no "output timeline dirty ($tl)";; esac
  # --limit bench mode: partial artifact, exit 10, never blessed
  o=$(CLAUDE_PLUGIN_DATA="$WORK/realdata" bash "$SC/derive-dts.sh" "$MKVCH" "$WORK/b.mov" --force --limit 30 2>&1); rc=$?
  [ "$rc" -eq 10 ] && ok "--limit bench -> exit 10 REVIEW" || no "--limit rc=$rc, want 10"
  has "$o" "verdict=bench" "bench machine line says so (census=skipped verdict=bench)"
  [ -f "$WORK/b.mov" ] && no "--limit blessed a partial artifact" || ok "--limit never blesses (part kept only)"
else
  echo "  (SKIP: python3 cannot import av on this bench — end-to-end unpinned here."
  echo "   The derivation math, guards and refusal paths above still ran; install PyAV"
  echo "   [pip install av] or the plugin venv to arm this half.)"
fi

echo
echo "== 6. doctor.sh reports the venv (report-only) =="
d=$(bash "$SC/doctor.sh" --kv 2>&1) || true
has "$d" "DOC_PYAV=" "doctor --kv carries DOC_PYAV (additive)"
d=$(bash "$SC/doctor.sh" 2>&1) || true
has "$d" "PyAV venv" "doctor human report names the PyAV venv line"

echo
echo "derive-dts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
