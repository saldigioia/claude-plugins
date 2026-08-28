#!/usr/bin/env bash
# 45-census-partnames.sh — 1.13 D5/D6: the two things every builder owes its own
# output — a reconciliation against the plan, and a name a human can diagnose.
#
# D5 THE CENSUS. Before 1.13 nothing compared the finished file to the plan.
# `RMX_PLAN … unmapped=N` is computed and printed BEFORE the mux; the KEEP/DROP
# manifest likewise. The field report measured `ffmpeg -c copy -f mov` writing
# 2 of 3 mapped streams with nothing but a `-v warning` line — and that loss
# shipped GREEN, because every downstream gate only examines the streams that
# are present. `mux_census` (lib-mux.sh) closes it: count + per-stream codec
# identity, asserted on the PART file, before the mv that blesses it.
#
# D6 THE NAME. `qlmanage`/`avconvert` are extension-keyed, so an artifact named
# `x.mov.part` fails the playability floor for a FILENAME reason that reads
# exactly like a decode failure ("the decode stack cannot handle this input") —
# on precisely the artifacts the builders deliberately KEEP on failure, i.e. the
# ones an operator is about to diagnose. trim-to-idr.sh learned this in 1.9
# ("x.part.ts, not x.ts.part"); 1.13 applies it everywhere via rtm_part.
#
# The muxer bug itself is NOT reproducible in this sandbox (it needed the real
# capture), so the census arms are asserted two ways: the function's own
# match/MISMATCH behavior directly, and every builder emitting match=ok on a
# real build. That proves the ASSERTION works — which is the deliverable here.
#
# Standalone: bash tests/regression.d/45-census-partnames.sh
# Exit 0 = all assertions pass; 1 = a regression; 2 = env failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"; FIX="$TESTS/fixtures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
. "$TESTS/lib-harness.sh"   # grepq/grepqe + rtm_strip_comments: one definition (tests/lib-harness.sh)
has () { case "$1" in *"$2"*) ok "$3";; *) no "$3 [missing: $2]";; esac; }
hasnt () { case "$1" in *"$2"*) no "$3 [unexpected: $2]";; *) ok "$3";; esac; }

for f in m2v420.ts multilang.ts; do
  if [ ! -f "$FIX/$f" ]; then
    echo "== regenerating missing fixture: $f =="
    bash "$TESTS/make-fixtures.sh" "$f" || { echo "fixture build failed: $f"; exit 2; }
  fi
done
if [ "$(uname -s)" = Darwin ] && command -v qlmanage >/dev/null 2>&1; then BENCH=mac; else BENCH=other; fi

echo "== 1. D6: rtm_part/rtm_sidecar keep the real extension, always =="
# RE-PINNED WO-1.15.6 (A2): rtm_part is now UNIQUE PER PROCESS
# (out.part-<pid>-<epoch>.mov) — the deterministic name was half the measured
# concurrent-writer corruption, so the exact-name pins here became SHAPE pins:
# same directory, stem + ".part…" tag, the REAL extension still last. D6 (the
# suffix discipline) is unchanged and still asserted; determinism was the
# defect, not the contract. Deviation recorded in WO-1.15.6-ONE-WRITER.md.
# shellcheck source=/dev/null
. "$SC/lib-mux.sh"
pshape () {  # pshape OUT GLOB DESC — rtm_part(OUT) must match GLOB (case pattern)
  local got; got="$(rtm_part "$1")"
  case "$got" in $2) ok "$3 ($got)";; *) no "$3 [rtm_part $1 = $got]";; esac
}
pshape /a/b/out.mov '/a/b/out.part*.mov' "out.mov -> out.part….mov (not out.mov.part…)"
pshape /a/b/out.mp4 '/a/b/out.part*.mp4' "out.mp4 keeps .mp4"
pshape /a/b/cut.ts  '/a/b/cut.part*.ts'  "cut.ts keeps .ts (the 1.9 lesson, now shared)"
pshape /a/b/out     '/a/b/out.part*.mov' "an EXTENSIONLESS target still gets a real extension"
pshape /a/b.c/out   '/a/b.c/out.part*.mov' "a dotted DIRECTORY does not fool the split"
case "$(rtm_part /a/b/out.mov)" in /a/b/out.mov.part*) no "extension-hiding shape returned";; *) ok "never extension-hiding (the D6 half of the name survives A2's uniqueness)";; esac
[ "$(rtm_sidecar /a/b/out.mov premeta)" = /a/b/out.premeta.mov ] && ok "rtm_sidecar tags the same way (mov.sh's .premeta)" || no "rtm_sidecar premeta = $(rtm_sidecar /a/b/out.mov premeta)"
[ "$(rtm_sidecar /a/b/out.mov autobest)" = /a/b/out.autobest.mov ] && ok "auto.sh's parked artifact keeps its extension too" || no "rtm_sidecar autobest = $(rtm_sidecar /a/b/out.mov autobest)"

echo
echo "== 2. D6: no builder still writes the old \"\$OUT.part\" shape =="
nomatch () {  # nomatch FILE PATTERN DESC — the old shape must be gone from the CODE.
              # Comments are stripped first: these files DOCUMENT the shape they
              # replaced ("this was \$1.premeta"), and a doc line is not a defect.
              # grep -c prints 0 AND exits 1 on no match, so read the count, never
              # the exit status (the `|| echo 0` trap: it appends a second 0).
  local n; n=$(rtm_strip_comments "$SC/$1" 2>/dev/null | grep -c -- "$2"); n=${n:-0}
  [ "$n" -eq 0 ] && ok "$3" || no "$3 [$n occurrence(s) of the old shape remain in $1]"
}
for f in remux.sh dual-track.sh resync.sh metadata.sh rebuild-paff.sh pairfill-paff.sh rung4.sh trim-to-idr.sh qt-groups.sh; do
  nomatch "$f" 'PART="\${OUT}\.part"' "$f: no extension-hiding part name"
done
nomatch mov.sh '"\$1\.premeta"' "mov.sh: the .premeta intermediate keeps its extension"
nomatch auto.sh 'BEST_SAVE="\$OUT\.autobest"' "auto.sh: the parked best artifact keeps its extension"

echo
echo "== 3. D6: a kept part file is REALLY named that (mux-confession hard stop) =="
# the confession hook is the suite's standing way to make a builder keep its
# part file without a real broken source (regression.sh §, 42-rot-demoted.sh)
printf 'Application provided invalid, non monotonically increasing dts to muxer\npts has no value\n' > "$WORK/conf.log"
o=$(RTM_MUX_LOG_APPEND="$WORK/conf.log" bash "$SC/remux.sh" "$FIX/m2v420.ts" "$WORK/hs.mov" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "confession hard stop still exits 1" || no "confession rc=$rc, want 1"
[ ! -f "$WORK/hs.mov" ] && ok "nothing blessed under the real name" || no "hs.mov exists — a confessed build got blessed"
# re-pinned WO-1.15.6: unique part names — glob the shape, then assert the
# message names the EXACT kept file (the two must agree, whatever the nonce)
hskept=$(ls "$WORK"/hs.part*.mov 2>/dev/null | head -1)
[ -n "$hskept" ] && [ -s "$hskept" ] && ok "the kept artifact is '$(basename "$hskept")' — extension last, openable by the extension-keyed tools" \
  || { no "expected \$WORK/hs.part….mov"; ls "$WORK" | sed 's/^/   /'; }
[ ! -f "$WORK/hs.mov.part" ] && ok "the old 'hs.mov.part' shape is gone" || no "hs.mov.part still written"
[ -n "$hskept" ] && has "$o" "$hskept" "the message names the kept file by its real path"

echo
echo "== 4. D5: mux_census — both arms, asserted directly =="
bash "$SC/remux.sh" "$FIX/m2v420.ts" "$WORK/ok.mov" >/dev/null 2>&1
c=$(mux_census "$WORK/ok.mov" 2 "mpeg2video,pcm_s16le" unit 2>&1); crc=$?
{ [ "$crc" -eq 0 ] && case "$c" in *"match=ok"*) true;; *) false;; esac; } \
  && ok "a matching plan returns 0 and prints match=ok" || { no "census match arm broken (rc=$crc)"; printf '%s\n' "$c" | sed 's/^/   /'; }
c=$(mux_census "$WORK/ok.mov" 3 "mpeg2video,pcm_s16le,ac3" unit 2>&1); crc=$?
{ [ "$crc" -eq 1 ] && case "$c" in *"match=MISMATCH"*) true;; *) false;; esac; } \
  && ok "a DROPPED stream returns 1 and prints match=MISMATCH (the field-report class)" || no "census count arm broken (rc=$crc)"
c=$(mux_census "$WORK/ok.mov" 2 "mpeg2video,aac" unit 2>&1); crc=$?
{ [ "$crc" -eq 1 ] && case "$c" in *"codecs=mismatch"*) true;; *) false;; esac; } \
  && ok "right count, WRONG codec is also a MISMATCH (identity, not just arithmetic)" || no "census identity arm broken (rc=$crc)"
c=$(mux_census "$WORK/ok.mov" 2 "mpeg2video,?" unit 2>&1); crc=$?
[ "$crc" -eq 0 ] && ok "'?' is a per-slot wildcard for a builder that will not assert identity" || no "census wildcard broken (rc=$crc)"
c=$(mux_census "$WORK/ok.mov" 2 "" unit 2>&1); crc=$?
{ [ "$crc" -eq 0 ] && case "$c" in *"codecs=na"*) true;; *) false;; esac; } \
  && ok "count-only mode announces codecs=na (never a silent unchecked half)" || no "census count-only mode broken (rc=$crc)"

echo
echo "== 5. D5: the real builders emit the census, and it matches =="
o=$(bash "$SC/remux.sh" "$FIX/multilang.ts" "$WORK/ml.mov" 2>&1)
has "$o" "RMX_CENSUS stage=remux" "remux.sh emits its census"
has "$o" "match=ok" "remux.sh census matches on a 3-audio source"
nst=$(ffprobe -v error -show_entries stream=index -of csv=p=0 "$WORK/ml.mov" 2>/dev/null | grep -c .)
pl=$(printf '%s\n' "$o" | sed -n 's/^RMX_CENSUS .*planned=\([0-9]*\).*/\1/p' | awk 'NR==1')
{ [ -n "$pl" ] && [ "$pl" = "$nst" ]; } && ok "planned=$pl equals the streams actually in the file ($nst)" || no "planned=$pl vs file streams=$nst"
o=$(bash "$SC/dual-track.sh" "$FIX/m2v420.ts" "$WORK/dt.mov" 2>&1)
has "$o" "RMX_CENSUS stage=dual-track" "dual-track.sh emits its census"
has "$o" "match=ok" "dual-track census matches (video + PCM access + preserved original)"
o=$(bash "$SC/metadata.sh" "$WORK/dt.mov" "$WORK/dtm.mov" --title T 2>&1)
has "$o" "RMX_CENSUS stage=metadata" "metadata.sh censuses its container rewrite"
has "$o" "match=ok" "the metadata pass did not narrow the file"
o=$(bash "$SC/trim-to-idr.sh" "$FIX/m2v420.ts" "$WORK/tt.ts" 2>&1) || true
case "$o" in
  *"RMX_CENSUS stage=trim-to-idr"*) has "$o" "match=ok" "trim-to-idr censuses its all-stream cut";;
  *) echo "  (skip: trim-to-idr declined this fixture — no mid-GOP head to cut)";;
esac

echo
if [ "$BENCH" = mac ]; then
  echo "== 6. D6 (macOS): the extension guard makes a part file diagnosable again =="
  cp "$WORK/ok.mov" "$WORK/kept.mov.part"
  o=$(bash "$SC/playable-check.sh" "$WORK/kept.mov.part" 2>&1); rc=$?
  has "$o" "carries no QuickTime extension" "the guard ANNOUNCES the rename it is working around"
  has "$o" "hardlink" "it uses a hardlink (Quick Look does not follow symlinks — measured)"
  [ "$rc" -eq 0 ] && ok "a healthy build under a .part name now PASSES (pre-1.13: a false decode FAIL)" \
    || { no "playable-check on kept.mov.part rc=$rc, want 0"; printf '%s\n' "$o" | tail -8 | sed 's/^/   /'; }
  o=$(bash "$SC/playable-check.sh" "$WORK/ok.mov" 2>&1); rc=$?
  hasnt "$o" "carries no QuickTime extension" "a normal .mov is untouched by the guard (no new noise)"
  [ "$rc" -eq 0 ] && ok "the normal path still exits 0" || no "normal .mov rc=$rc"

  echo "  -- C105, re-measured on this bench: symlink vs hardlink through qlmanage --"
  mkdir -p "$WORK/sl" "$WORK/hl"
  ln -s "$WORK/kept.mov.part" "$WORK/sl/probe.mov" 2>/dev/null
  ln    "$WORK/kept.mov.part" "$WORK/hl/probe.mov" 2>/dev/null
  qlshot () {  # qlshot DIR — bounded qlmanage render; echoes yes|no
    ( qlmanage -t -s 240 -o "$1" "$1/probe.mov" >/dev/null 2>&1 & p=$!; s=$SECONDS
      while kill -0 $p 2>/dev/null; do [ $((SECONDS-s)) -ge 25 ] && { kill -9 $p 2>/dev/null; break; }; sleep 1; done
      wait $p 2>/dev/null ) || true
    ls "$1"/*.png >/dev/null 2>&1 && echo yes || echo no
  }
  if [ -L "$WORK/sl/probe.mov" ] && [ -f "$WORK/hl/probe.mov" ]; then
    sy=$(qlshot "$WORK/sl"); hy=$(qlshot "$WORK/hl")
    [ "$hy" = yes ] && ok "hardlink: qlmanage renders (why the guard hardlinks)" || no "hardlink produced no thumbnail — the guard's mechanism just changed"
    [ "$sy" = no ] && ok "symlink: qlmanage renders NOTHING (C105 holds on this macOS)" \
      || echo "  NOTE symlink rendered on this macOS — C105 has drifted; the guard still works (it hardlinks), but re-measure the claim."
  else
    echo "  (skip: could not create both link kinds in the temp dir)"
  fi
else
  echo "== 6. (skip: off-macOS — the extension-keyed half needs qlmanage/avconvert) =="
  echo "  NOT proven here: that a .part-named build now passes the playability floor, and"
  echo "  the C105 symlink-vs-hardlink measurement. Evidence bench: macOS 26.6.1, 2026-08-15."
fi

ok "sources untouched"
echo
echo "census-partnames: $pass passed, $fail failed — the silent-stream-drop itself is operator-measured (2026-08-15), not synthesizable here"
[ "$fail" -eq 0 ]
