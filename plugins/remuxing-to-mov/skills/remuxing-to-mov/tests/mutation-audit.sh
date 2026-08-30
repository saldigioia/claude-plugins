#!/usr/bin/env bash
# mutation-audit.sh — mutation-test every tree-wide guard, and probe each one
# for false positives. WO-1.15.17 Items 1 and 2, automated.
#
# WHY THIS EXISTS. A guard nobody has seen fail is a guard nobody knows works.
# While writing 1.15.15's standing sweep, TWO of its five guards were vacuous on
# first draft and surfaced only under mutation testing: a pattern that also
# matched the COMMENT describing the idiom (prose satisfied the guard), and a
# `grep -l` counting FILES (a second definition inside one file was invisible).
# Both would have shipped green while guarding nothing. The older tree-wide
# guards had never been mutation-tested at all.
#
# TWO LANES, because a guard fails in two directions:
#   defect  — introduce the EXACT defect the guard claims to catch; the guard's
#             assertion must flip PASS -> FAIL.        CAUGHT / MISSED
#   prose   — introduce a BENIGN mention of the idiom (a comment, a doc line, a
#             quoted string); the guard must stay PASS. CLEAN / FALSE-POSITIVE
#   new     — like `defect`, but the mutation ADDS a row to a DERIVED roster, so
#             the marker cannot exist on the unmutated tree: the baseline check
#             asserts its ABSENCE instead.
#
# VERDICTS ARE DECIDED BY THE PASS LINE, NOT BY MATCHING BOTH. House style gives
# an assertion two different wordings ("defined exactly once" vs "has 2
# definitions"), so a marker that matches the PASS line will never match the FAIL
# line. The rule is: is the marked PASS still there, and did the run go red.
# A prose case whose marked PASS survives while the RUN went red is
# RED-ELSEWHERE, never CLEAN: a sibling assertion in the same test cried wolf
# on the comment (measured 2026-08-28 — P11 kept 92 §4's marker PASS while an
# un-stripped per-consumer pin FAILed, and the harness read CLEAN). A test that
# is red BEFORE any mutation judges nothing: its cases read BASE-RED.
# A guard that cries wolf gets disabled, and then its class is unguarded AND
# believed guarded — so lane 2 is not a nicety.
#
# The real tree is NEVER written to: every run mutates a throwaway copy of the
# plugin. Fixtures (83 MB) are symlinked read-only, not copied.
#
# NOT part of the regression suite — it audits the suite, mutates a tree copy,
# and costs many minutes. It lives in tests/ (not tests/regression.d/) exactly
# so run_subsuites never enrolls it. Run it whenever a tree-wide guard is added
# or changed. (One exception, and it is not an enrollment: 90 §7 invokes this
# script with a SINGLE named case, twice, to prove the verdict channel below
# still has two agreeing ends — about 20 seconds, not a roster run.)
#
# Usage:
#   bash tests/mutation-audit.sh                 # every case
#   bash tests/mutation-audit.sh G04 P04         # named cases only
#   MA_JOBS=4 bash tests/mutation-audit.sh       # parallel sandboxes (default 3)
#   MA_KEEP=1 bash tests/mutation-audit.sh       # keep sandboxes + logs
#   MA_OUTDIR=DIR bash tests/mutation-audit.sh   # logs/verdicts into DIR (never deleted)
#
# Exit 0 = every guard CAUGHT its defect and stayed CLEAN on prose;
#        1 = at least one MISSED or FALSE-POSITIVE; 2 = env/harness failure.
#
# THE VERDICT IS ALSO ON DISK. Every completed run ends with one machine line,
#   MA_SUMMARY total=<N> bad=<N> verdict=pass|fail
# printed after the per-case table AND written to $OUTDIR/VERDICT. The exit
# contract above is unchanged (0 only when bad=0) — the file is a SECOND
# channel, not a replacement, and it exists because an exit status observed
# through a pipe belongs to the last command in the pipe: measured 2026-08-29,
# a red audit (G45 MUTATE-NOOP) was read green off `tail`'s status and the
# per-scope-modulus guard had been audited zero times while reading as
# harmless. A later reader greps the file instead of trusting a remembered rc.
# No VERDICT file = no verdict from this run; a stale one from an earlier run
# in a persisted MA_OUTDIR is removed at start, never left to judge this tree.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"          # skills/remuxing-to-mov
PLUGIN="$(cd "$SKILL/../.." && pwd)"     # plugins/remuxing-to-mov
FIXTURES="$HERE/fixtures"
JOBS="${MA_JOBS:-3}"
# validated: without -e a non-integer here made the pool test error on every
# turn and never wait, forking the whole roster at once
case "$JOBS" in ''|*[!0-9]*|0) echo "MA_JOBS must be a positive integer (got '${MA_JOBS:-}')"; exit 2;; esac
# Cleanup is scoped to what THIS run created. A directory the operator named
# is never rm -rf'd — it may hold their other files, and deleting what you do
# not own is the 1.15.12 class this very harness exists to police.
if [ -n "${MA_OUTDIR:-}" ]; then
  OUTDIR="$MA_OUTDIR"; mkdir -p "$OUTDIR"
else
  OUTDIR="$(mktemp -d)"
  [ "${MA_KEEP:-0}" = 1 ] || trap 'rm -rf "$OUTDIR"' EXIT
fi
# the same reason baseline_one re-takes its baselines: a verdict left in a
# persisted MA_OUTDIR by an earlier tree state must never be read as this
# run's. Absent means "this run reached no verdict", which is the honest
# answer for an env failure (exit 2) that never got to a case.
rm -f "$OUTDIR/VERDICT"
. "$HERE/lib-harness.sh"   # rtm_strip_comments: the SAME stripper the guards read through

command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "need ffmpeg+ffprobe"; exit 2; }
[ -d "$FIXTURES" ] || { echo "fixtures missing — run tests/make-fixtures.sh first"; exit 2; }

# ---------------------------------------------------------------- sandboxing
# A sandbox is a full copy of the PLUGIN (test 91 reads README.md and
# skills/mov/SKILL.md through $TESTS/../../..), with tests/fixtures symlinked.
new_sandbox () {  # new_sandbox ID -> prints the sandbox's skill dir
  # SEPARATE statements, deliberately: `local a=$1 b=$a` expands b BEFORE a is
  # assigned, so b would read the CALLER's a. Measured here the hard way — every
  # baseline built "sb-" and clobbered the previous one. 94 §9 pins the class.
  local id="$1"
  local sb="$OUTDIR/sb-$id" base
  base="$(basename "$PLUGIN")"
  rm -rf "$sb"; mkdir -p "$sb"
  ( cd "$PLUGIN/.." && tar -cf - --exclude fixtures --exclude __pycache__ "$base" ) \
    | ( cd "$sb" && tar -xf - ) || return 1
  # a REAL directory of per-file links, not a link to the directory: a test
  # that mints a missing fixture (41/92/93 call make-fixtures.sh, which writes
  # into tests/fixtures/) then writes into the sandbox — never through a
  # directory link into the real tree, and never racing a parallel case on
  # one shared .part.
  local fxd="$sb/$base/skills/remuxing-to-mov/tests/fixtures" fx
  mkdir -p "$fxd" || return 1
  for fx in "$FIXTURES"/*; do
    [ -e "$fx" ] || continue
    ln -s "$fx" "$fxd/$(basename "$fx")" || return 1
  done
  printf '%s\n' "$sb/$base/skills/remuxing-to-mov"
}

# ------------------------------------------------------------------ mutations
# DEFECT lane. Each introduces the exact shape its guard claims to catch; a
# mutation the guard catches only by accident proves nothing.
Q="'"

mut_apostrophe () {   # the apostrophe-in-awk trap (1.15.10, 1.15.14)
  printf '\nawk %sBEGIN{print "remux.sh%ss plan"}%s\n' "$Q" "$Q" "$Q" >> "$1/scripts/clock.sh"
}
mut_awk_counter () {  # drop the load-bearing BEGIN{n=0} (the C[""] trap)
  # line-anchored: the FIRST BEGIN{n=0} in the file is the COMMENT explaining
  # why it is load-bearing, and mutating prose proves nothing (measured).
  perl -pi -e 's/^(\s*)BEGIN\{ *n=0 *\}/${1}BEGIN{ }/' "$1/scripts/lib-probe.sh"
}
mut_temp_scan () {    # the 1.15.12 class: scan shared temp ground for foreign files
  printf '\nfind "$TMPDIR" -name "rtm-*"\n' >> "$1/scripts/dim-scan.sh"
}
mut_census_rc () {    # one builder stops asking the writer and re-derives it
  perl -pi -e 's/if rtm_census_failed "\$census_rc"; then/if [ "\$census_rc" -ne 0 ] && [ "\$census_rc" -ne 9 ]; then/' \
    "$1/scripts/resync.sh"
}
mut_dup_aud_manifest () {  # a SECOND definition in the SAME file (grep -l blind spot)
  printf '\nrtm_aud_manifest () { : ; }\n' >> "$1/scripts/lib-probe.sh"
}
mut_dup_disk_preflight () { printf '\nrtm_disk_preflight () { : ; }\n' >> "$1/scripts/lib-mux.sh"; }
mut_dup_lock ()           { printf '\nrtm_lock () { : ; }\n'           >> "$1/scripts/lib-mux.sh"; }
# --- WO-1.15.20 guards -------------------------------------------------------
mut_false_exit3_promise () {   # the sixth defect, put back into the routing prose
  perl -pi -e 's|(REPAIR_WHY="half_ts=\$PF_HALF_TS)|$1 — its own gates refuse (exit 3) if the shape is not the pair class;|' \
    "$1/scripts/diagnose.sh"
}
mut_no_rung_composes () {      # the retired claim, shipped again in a verdict
  perl -pi -e 's|(echo "   Diagnose: scripts/diagnose.sh)|echo "   no rung composes '"'"'fill the few missing PTS'"'"' -> '"'"'derive DTS'"'"'."\n        $1|' \
    "$1/scripts/auto.sh"
}
mut_hardcode_version () {      # the stale-string trap: a script keeps its own copy
  printf '\nRTM_PLUGIN_VERSION="1.15.20"\n' >> "$1/scripts/doctor.sh"
}
mut_dup_sparse_bound () {      # a SECOND definition in the same file
  printf '\nRTM_SPARSE_NOPTS_MAX="${RTM_SPARSE_NOPTS_MAX:-0.05}"\n' >> "$1/scripts/lib-paff.sh"
}
pro_false_exit3_promise () { printf '\n# the 2024-VMA defect: prose claiming its own gates refuse (exit 3) if the shape is wrong\n' >> "$1/scripts/clock.sh"; }
pro_hardcode_version ()    { printf '\n# never hardcode: VERSION=1.15.20 belongs in the manifest, read at runtime\n' >> "$1/scripts/clock.sh"; }
mut_ffp_head () {     # reintroduce the 1.15.2 SIGPIPE shape
  printf '\n_m=$(ffp -v error -show_entries format=duration -of csv=p=0 "$IN" | head -1)\n' >> "$1/scripts/clock.sh"
}
mut_dimscan_pipeline () {
  printf '\nFIRST_CH=$(grep %s^CHANGE %s "$TMP/scan" | head -1 | awk %s{print $2}%s)\n' "$Q" "$Q" "$Q" "$Q" \
    >> "$1/scripts/dim-scan.sh"
}
mut_keepfirst () {    # keep-first dedupe over a stream_tags query (WO 3.4 / 1.15.10)
  printf '\n_m=$(echo | awk %s{ if(idx in seen) next }%s)\n' "$Q" "$Q" >> "$1/scripts/clock.sh"
}
mut_dup_merge_file () {   # the merge pasted into a SECOND file
  printf '\n_m=$(echo | awk %s{ if(G[o]=="und") G[o]=x }%s)\n' "$Q" "$Q" >> "$1/scripts/remux.sh"
}
mut_dup_merge_same () {   # the merge pasted a SECOND TIME into its OWN file
  printf '\n_m=$(echo | awk %s{ if(G[o]=="und") G[o]=x }%s)\n' "$Q" "$Q" >> "$1/scripts/lib-probe.sh"
}
mut_move_merge () { perl -pi -e 's/G\[o\]=="und"/G[o]=="XXX"/' "$1/scripts/lib-probe.sh"; }
mut_qt_undecodable () { printf '\necho "MOV_REFUSED profile=qt-undecodable"\n' >> "$1/scripts/clock.sh"; }
mut_422_refusal () {  # a live yuv422p predicate within 8 lines of an exit 11
  cat >> "$1/scripts/clock.sh" <<'EOF'

case "${_mutpix:-}" in
  yuv422p)
    echo "refusing 4:2:2"
    exit 11
    ;;
esac
EOF
}
mut_stray_entrypoint () {  # a NEW entry point outside the exit-code contract
  printf '#!/usr/bin/env bash\nset -uo pipefail\nexit 234\n' > "$1/scripts/zz-mutant.sh"
  chmod 755 "$1/scripts/zz-mutant.sh"
}
mut_underive_roster () {   # test 14 goes back to a hand-kept roster string
  perl -0pi -e 's/^ENTRY=""\nfor _f.*?\ndone\n/ENTRY="auto batch derive-dts diagnose doctor dual-track gop-probe metadata mov playable-check probe qt-groups rebuild-paff remux resync rung4 seam-check trim-to-idr ts-health verify waiver"\n/ms' \
    "$1/tests/regression.d/14-exit-codes.sh"
}
mut_privatize_vocab () {   # a consumer takes a private copy of the vocabulary back
  perl -pi -e 's/grep -ciE "\$RTM_CONFESSION_RE"/grep -ciE (Q)pts has no value|timestamps are unset(Q)/' \
    "$1/scripts/lib-paff.sh"
  perl -pi -e "s/\\(Q\\)/'/g" "$1/scripts/lib-paff.sh"
}
mut_locale_entrypoint () { # a new entry point with the float gates locale-exposed
  printf '#!/usr/bin/env bash\nset -uo pipefail\nawk %sBEGIN{ if (0.5 > 0.05) print "y" }%s\n' "$Q" "$Q" \
    > "$1/scripts/zz-locale.sh"
  chmod 755 "$1/scripts/zz-locale.sh"
}
mut_locale_mention () {    # the same defect, but the file MENTIONS lib-probe.sh in prose
  printf '#!/usr/bin/env bash\nset -uo pipefail\n# float gates: see lib-probe.sh for the locale rule\nawk %sBEGIN{ if (0.5 > 0.05) print "y" }%s\n' "$Q" "$Q" \
    > "$1/scripts/zz-locale2.sh"
  chmod 755 "$1/scripts/zz-locale2.sh"
}
mut_program_head () {
  printf '\n_m=$(ffp -v error -show_entries program=program_id "$IN" | head -1)\n' >> "$1/scripts/clock.sh"
}
mut_unffp1_program () {    # one of lib-rewrap's two program= sites drops off ffp1
  perl -pi -e 'if (!$d && s/ffp1 (-v error [^|]*program=)/ffp $1/) { $d=1 }' "$1/scripts/lib-rewrap.sh"
}
mut_unask_zerobase () {   # break the CODE only — clean.sh's own comments still say
  # "--preflight-only", which is the point: a detector satisfied by prose is vacuous
  perl -pi -e 's/--preflight-only/--dry-run-only/ if /zero-base\.sh"/' "$1/scripts/clean.sh"
}
mut_nprog_model ()   { printf '\nNPROG=$(pget PR_NPROG)\n' >> "$1/scripts/clean.sh"; }
mut_unrestored_errexit () {  # a set +e region that never re-arms errexit
  printf '\nset +e\n_m=$(false); _rc=$?\necho "verdict $_rc"\n' >> "$1/scripts/clock.sh"
}
mut_exit_while_disarmed () { # errexit disarmed ACROSS an exit
  printf '\nset +e\n_m=$(false)\nexit 0\nset -e\n' >> "$1/scripts/clock.sh"
}
mut_vocab_copy () {          # a literal copy of the vocabulary sprouts again
  printf '\n_m=$(grep -icE %spts has no value|timestamps are unset|non-?monoton(ic|ous) dts|non monotonically increasing dts%s /dev/null)\n' "$Q" "$Q" \
    >> "$1/scripts/clock.sh"
}
mut_dup_vocab_def () {       # a SECOND definition of the shared vocabulary
  printf '\nRTM_CONFESSION_RE=%sdrifted%s\n' "$Q" "$Q" >> "$1/scripts/clock.sh"
}
mut_native_drift () {        # E-AC-3 quietly leaves the native table at ONE site
  perl -pi -e 'if (!$d && s/aac\|alac\|mp3\|pcm_\*\|eac3/aac|alac|mp3|pcm_*/) { $d=1 }' \
    "$1/scripts/pairfill-paff.sh"
}
pro_unrestored_errexit () { printf '\n# the trap: a set +e with no set -e after it\n' >> "$1/scripts/clock.sh"; }
pro_vocab_copy () {
  printf '\n# vocabulary: pts has no value|timestamps are unset|non-?monoton(ic|ous) dts|non monotonically increasing dts\n' \
    >> "$1/scripts/clock.sh"
}
pro_native_drift () { printf '\n# QuickTime-native: aac|alac|mp3|pcm_*|eac3 (eac3 = DD+)\n' >> "$1/scripts/clock.sh"; }

mut_local_selfref () {   # a local statement reading its own sibling
  printf '\n_mutfn () { local a="$1" b="pre-$a"; echo "$b"; }\n' >> "$1/scripts/clock.sh"
}
pro_local_selfref () { printf '\n# the trap: local a="$1" b="pre-$a" reads the CALLER a\n' >> "$1/scripts/clock.sh"; }

mut_early_exit_reader () {  # a guard reads source through an early-exit grep -q
  printf '\nsed %ss/x//%s "$0" | grep -q rtm_marker\n' "$Q" "$Q" >> "$1/tests/regression.d/11-probe-defaults.sh"
}
pro_early_exit_reader () {
  printf '\n# never: sed ... | grep -q PAT over source (SIGPIPEs the writer)\n' >> "$1/tests/regression.d/11-probe-defaults.sh"
}

mut_uncall_manifest () {  # a consumer stops CALLING the shared writer (its comment still names it)
  # NO $ in the replacement (perl would read it as a perl variable — see below)
  perl -pi -e 's/rtm_aud_manifest "\$IN"/legacy_inline_probe "(IN)"/' "$1/scripts/probe.sh"
}
pro_uncall_manifest () { printf '\n# the call rtm_aud_manifest "IN" is the one above\n' >> "$1/scripts/probe.sh"; }
mut_widen_vocab () {      # one counter appends to the shared vocabulary (A4 drift, the 1.14 shape)
  perl -pi -e 's/grep -ciE "\$RTM_CONFESSION_RE"/grep -ciE "\$RTM_CONFESSION_RE|dts discontinuity"/' "$1/scripts/lib-paff.sh"
}
pro_widen_vocab () {      # a comment INSIDE mux_confessions naming the variable
  perl -pi -e 's/^(mux_confessions \(\) \{)$/$1\n  # note: pattern is "\$RTM_CONFESSION_RE" — never widen it here/' "$1/scripts/lib-paff.sh"
}

mut_ungate_route ()  {  # the clinic offers a route its authority refuses
  # NO $ in the replacement: perl reads $ZB_RC there as a PERL variable (empty),
  # which wrote `[ "" -ge 0 ]` and made clean.sh offer nothing at all (measured).
  perl -pi -e 's/if \[ "\$ZB_RC" -eq 0 \]; then/if true; then/' "$1/scripts/clean.sh"
}
mut_raw_census_exit () {  # a builder hands the raw census rc to the operator again (1.15.18)
  perl -0pi -e 's/if rtm_census_review "\$census_rc"; then exit 10; fi\nexit 0\n/exit "\$census_rc"\n/' \
    "$1/scripts/trim-to-idr.sh"
}
pro_raw_census_exit () { printf '\n# never: exit "$census_rc" — ask rtm_census_review, then exit 0 or 10\n' >> "$1/scripts/trim-to-idr.sh"; }
mut_optin_census () {  # an opt-in gate goes back to counting a census with grep -c (1.15.19)
  # the exact WO-1.15.4-leftover shape: `| grep -c . || true` makes a FAILED
  # ffprobe byte-identical to "no audio", and the gate the operator ASKED for
  # then reports a track count nobody measured.
  perl -pi -e 's/^(\s*)nao=\$\(printf .*$/${1}nao=\$(ffp -v error -select_streams a -show_entries stream=index -of csv=p=0 "\$OUT" 2>\/dev\/null | LC_ALL=C sort -u | grep -c . || true)/ if /nao=\$\(printf/' \
    "$1/scripts/verify.sh"
}
pro_optin_census () {  # a comment that merely NAMES the banned shape must stay CLEAN
  printf '\n# never: nao=$(ffp … -select_streams a … stream=index … | grep -c . || true)\n' >> "$1/scripts/verify.sh"
}
mut_phash_swallow () {  # derive-dts swallows its hash-pass rc again (1.15.19)
  perl -pi -e 's/-f streamhash -hash md5 - 2>\/dev\/null; \}/-f streamhash -hash md5 - 2>\/dev\/null || true; }/' \
    "$1/scripts/derive-dts.sh"
}
pro_phash_swallow () { printf '\n# never: phash() { ffmpeg … -f streamhash -hash md5 - 2>/dev/null || true; }\n' >> "$1/scripts/derive-dts.sh"; }
mut_untiered_refusal () {  # a refusal site loses its TIER classification (1.16.0)
  # The exact shape the 2026-08-29 re-aim exists to prevent: a "no" in the tree
  # that nobody has answered the classification test for. TIERS.md is the
  # ledger; this strips one site's pointer into it.
  perl -pi -e 's/   # TIER 3 T3\.11 injected-silence default \(announced --force overrides\)//' \
    "$1/scripts/resync.sh"
}
pro_untiered_refusal () {  # prose that merely NAMES an untiered refusal stays CLEAN
  printf '\n# never: a bare `exit 3` with no # TIER row in TIERS.md — see 94 §11\n' >> "$1/scripts/clock.sh"
}
mut_private_sibling_test () {  # a builder re-grows its own copy of "beside, never onto" (1.16.0)
  # The exact IV.1 shape this class is about: twelve byte-identical copies of
  # one string comparison, none of which looked at the sidecar names, and a
  # source named like the ladder park file was DELETED by it. Appended as CODE,
  # not a comment — the prose lane below proves the guard tells them apart.
  cat >> "$1/scripts/metadata.sh" <<'MUT'
[ "$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")" != "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" ] \
  || { echo "refusing to overwrite the source in place" >&2; exit 2; }
MUT
}
pro_private_sibling_test () {  # prose quoting the banned shape stays CLEAN
  printf '\n# never: [ "$(cd "$(dirname "$IN")" && pwd)" != "$(cd "$(dirname "$OUT")" && pwd)" ] — call rtm_sibling_guard\n' \
    >> "$1/scripts/metadata.sh"
}
mut_output_forecast_gate () {  # a refusal on a forecast about the OUTPUT grows back (1.16.0)
  perl -0pi -e 's/(\necho "== auto: )/\nif [ "\${PF_PAFF:-no}" = yes ]; then echo "the write would be full-length and the refusal is predetermined" >\&2; exit 3; fi\n$1/' \
    "$1/scripts/auto.sh"
}
pro_output_forecast_gate () {  # prose describing the retired reasoning stays CLEAN
  printf '\n# never: refuse because "the write would be full-length" — that is a forecast,\n# not a cached deterministic attempt (TIERS.md Tier 3)\n' >> "$1/scripts/auto.sh"
}
mut_unguard_derived_names () {  # the sibling guard forgets the names derived from OUT
  # THE 2026-08-29 INCIDENT, restored: pre-1.16.0 the guard caught only
  # OUT == IN, so a source named like the ladder's own park file
  # (x.autobest.mov) was deleted by its opening `rm -f` — under a run that then
  # printed "Source untouched."
  perl -0pi -e 's/(  if rtm_same_file "\$in" "\$out"; then what="the output itself"; cand="\$out"; fi\n).*?(  \[ -n "\$what" \] \|\| return 0)/$1$2/s' \
    "$1/scripts/lib-mux.sh"
}
pro_unguard_derived_names () {  # prose naming the derived-name class stays CLEAN
  printf '\n# never: a sibling guard that tests only OUT == IN — the sidecar and .part\n# names derived from OUT are source-deletion shapes too (test 110)\n' >> "$1/scripts/clock.sh"
}
mut_unregistered_inline_scratch () {  # a scratch name built inline, outside the guard's table
  # How the idrtrim.tmp shape stayed deletable through the round that closed
  # the class: a name the guard never hears about cannot be guarded.
  printf '\nSCRATCH_UNREGISTERED="${OUT%%.*}.sneaky.$ext"\n' >> "$1/scripts/mov.sh"
}
pro_unregistered_inline_scratch () {  # prose quoting the shape stays CLEAN
  printf '\n# never: TMP="${OUT%%.*}.sneaky.$ext" without adding the tag to RTM_SIDECAR_TAGS\n' >> "$1/scripts/mov.sh"
}
mut_single_poc_modulus () {  # the lattice checker goes back to ONE modulus for the file
  # §8.2.1.1 is modular arithmetic. Unwrapping a whole capture under one
  # MaxPicOrderCntLsb reads most of a program-change file as off its own
  # declared slot — measured 2026-08-29: 215,949 of 216,631 pictures of a build
  # every other gate proved correct.
  # WRITTEN LOOSELY ON PURPOSE. This pattern named every scope-open clause
  # explicitly, so when 1.16.4 added the provenance clause the mutation stopped
  # matching, reported MUTATE-NOOP, and the guard silently went unaudited for a
  # round. Matching "everything after the IDR clause" keeps the next added
  # clause inside the mutation instead of outside the audit.
  perl -0pi -e 's/if \(\$1 \+ 0 == 1 \|\|.*\) endseq\(\)/if (\$1 + 0 == 1) endseq()/' \
    "$1/scripts/lib-paff.sh"
}
pro_single_poc_modulus () {  # prose naming the retired assumption stays CLEAN
  printf '\n# never: one global MaxPicOrderCntLsb for a whole file — a POC scope opens at\n# an SPS activation that changes the modulus, not only at an IDR (test 111)\n' >> "$1/scripts/clock.sh"
}
mut_hardcoded_frame_num_width () {  # the slice reader goes back to a constant width
  # The ported original carried FRAME_NUM_BITS = 8. It is right for most of a
  # capture and wrong at every program change, where the SPS declares four
  # bits — and the misread returns true*16 plus stray bits rather than
  # failing, so nothing downstream notices (measured 2026-08-29: 17 phantom
  # field pictures and 42 wrong frame_num values on feed.ts).
  perl -0pi -e 's/frame_num = br\.u\(sps\["log2_max_frame_num"\]\)/frame_num = br.u(8)/' \
    "$1/scripts/h264poc.py"
}
pro_hardcoded_frame_num_width () {  # prose naming the retired constant stays CLEAN
  printf '\n# never: FRAME_NUM_BITS = 8 — the width comes from the ACTIVE SPS (test 112)\n' \
    >> "$1/scripts/clock.sh"
}
mut_suppress_t2_row () {  # the extractor goes back to emitting NOTHING for a type-2 picture
  # The III.1 defect one layer down. A pic_order_cnt_type 2 slice carries no
  # pic_order_cnt_lsb, so both extractor arms used to skip it entirely — and
  # the gap was never reported as a gap. Downstream, gate (k) compared row
  # count to timestamped-packet count, found them unequal, and filed UNPROVEN
  # with a "count" symptom: an ABSENCE THE EXTRACTOR CREATED, read back as a
  # fact about the file (measured 2026-08-29 on a mixed capture: POC rows=50,
  # timestamped packets=100). Both arms are mutated together because a defect
  # in only one would be caught by test 78's byte-identity pin instead, which
  # would credit the wrong guard.
  perl -0pi -e 's/if \(pocf != ""\) \{\n(\s+)if \(cur_poc/if (pocf != "" && cur_poc != "") {\n$1if (cur_poc/' \
    "$1/scripts/lib-paff.sh"
  perl -0pi -e 's/if \(!have\) return/if (!have || cur_poc == "") { have = 0; return }/' \
    "$1/scripts/lib-paff.sh"
}
mut_model_the_capability () {  # the shell probe goes back to modelling what h264poc.py knows
  # pf_poc_capability stands in for h264poc.Parser.capability() at pre-flight,
  # where parsing the whole stream is too expensive. A stand-in that answers
  # differently from the authority is not a shortcut, it is a second writer:
  # measured 2026-08-29, shell said PCAP_OK=no why=poc_type on the same x264
  # -bf 0 mint the module called (True, "poc_type=2 ... by spec"), and
  # pairfill refused the build, exit 3, on the shell answer.
  perl -0pi -e 's/else if\(t1seen\)\{ ok="no"; why="poc_type" \}/else if(rows+0==0){ ok="no"; why="poc_type" }/' \
    "$1/scripts/lib-paff.sh"
}
pro_model_the_capability () {  # prose naming the retired model stays CLEAN
  printf '\n# never: "no pic_order_cnt_lsb" == "no display order" — pic_order_cnt_type 2\n# derives its position from decode order, and h264poc.py is the authority (test 114)\n' \
    >> "$1/scripts/clock.sh"
}
pro_suppress_t2_row () {  # prose naming the retired skip stays CLEAN
  printf '\n# never: emit a POC row only when pic_order_cnt_lsb was present — a picture\n# the extractor skips becomes a count disagreement it blames on the file (test 113)\n' \
    >> "$1/scripts/clock.sh"
}
mut_unask_trim () {   # the trim-to-idr CALL stops asking (clean.sh's prose still says --preflight-only)
  perl -pi -e 's/--preflight-only/--dry-run-only/ if /trim-to-idr\.sh"/' "$1/scripts/clean.sh"
}
pro_unask_trim () { printf '\n# clean.sh asks trim-to-idr.sh --preflight-only too; it holds no window model\n' >> "$1/scripts/clean.sh"; }

# PROSE lane. Each adds a BENIGN mention — a comment, or a quoted string in a
# message — of exactly the idiom the guard hunts. The guard must stay PASS.
pro_awk_counter ()  { printf '\n# the trap: C[n]= with n++ and no BEGIN{n=0}\n' >> "$1/scripts/clock.sh"; }
pro_temp_scan ()    { printf '\n# never do this: find $TMPDIR -name "rtm-*"\n' >> "$1/scripts/dim-scan.sh"; }
pro_census_rc ()    { printf '\n# see the census_rc contract in the builders\n' >> "$1/scripts/probe.sh"; }
pro_dup_lock ()     { printf '\n# rtm_lock () { ... } lives in lib-mux.sh\n' >> "$1/scripts/probe.sh"; }
pro_ffp_head ()     { printf '\n# doctrine: never ffp -v error -show_entries x | head -1 — use ffp1\n' >> "$1/scripts/clock.sh"; }
pro_keepfirst ()    { printf '\n# the WO 3.4 bug was awk if(idx in seen) next over a tags query\n' >> "$1/scripts/clock.sh"; }
pro_dup_merge ()    { printf '\n# the merge lives in lib-probe.sh: if(G[o]=="und") take the tagged view\n' >> "$1/scripts/remux.sh"; }
pro_qt_undecodable (){ printf '\n# 1.11 removed the MOV_REFUSED profile=qt-undecodable line\n' >> "$1/scripts/clock.sh"; }
pro_422_refusal ()  { printf '\n# the old gate: yuv422p -> exit 11, falsified 2026-08-13\n' >> "$1/scripts/clock.sh"; }
pro_program_head () { printf '\n# never: ffp -show_entries program=program_id | head -1\n' >> "$1/scripts/clock.sh"; }
pro_nprog_model ()  { printf '\n# F12 note: NPROG is asked of zero-base now, not modelled here\n' >> "$1/scripts/clean.sh"; }
# appended to clean.sh — the file 93 §5 READS. It went to probe.sh once, and
# a prose case the guard never reads cannot FALSE-POSITIVE by construction.
pro_unask_zerobase () { printf '\n# clean.sh asks zero-base --preflight-only; it holds no model\n' >> "$1/scripts/clean.sh"; }

mut_suppress_ma_verdict () {  # the audit stops writing its verdict where it can be re-read
  # 1.16.4's misreading in one edit: with only stdout and an exit status left,
  # the verdict is whatever the observer remembers — and `| tail` remembers
  # tail's. The exit contract is untouched by this mutation on purpose; what
  # goes away is the SECOND channel, and test 90 §7 must notice.
  perl -pi -e 's{> "\$OUTDIR/VERDICT"}{> /dev/null}' "$1/tests/mutation-audit.sh"
}
pro_suppress_ma_verdict () {  # prose naming the write stays CLEAN
  printf '\n# never: drop the > "$OUTDIR/VERDICT" write — an exit status seen through a\n# pipe is the pipe\x27s, and a remembered one is not evidence at all (test 90 §7)\n' \
    >> "$1/tests/mutation-audit.sh"
}
mut_alias_ffp_head () {  # the 1.15.2 SIGPIPE class, hidden one alias deep
  # THREE lines, deliberately: on ONE line the literal `ffp … | head -1` also
  # trips 91 §5's first arm, and the alias arm would be credited for a catch
  # that was not its own. Split, only the alias arm can see it.
  printf '\n_alias_probe () {\n  local _q="ffp -v error -select_streams"\n  $_q v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" | head -1\n}\n' \
    >> "$1/scripts/clock.sh"
}
pro_alias_ffp_head () {  # prose naming the aliased shape stays CLEAN
  printf '\n# never: q="ffp -v error -select_streams" and then $q … | head -1 — behind an\n# alias or not, a two-line ffprobe write into an early-exit reader is the\n# 1.15.2 SIGPIPE class; use ffp1 (test 115)\n' >> "$1/scripts/clock.sh"
}

mut_unmeasured_version_reader () {  # a new tool joins the -version exemption unmeasured
  # 115 §3 exempts `<tool> -version | head` on a MEASURED premise: the block
  # fits the pipe buffer, so the writer finishes. An unmeasured tool inherits
  # the exemption by resemblance, which is how a size argument turns into a
  # habit. Never called — the shape is what is under test, not the run.
  printf '\n_zz_ver () {\n  _v=$(zzprobe -version 2>/dev/null | head -1)\n}\n' >> "$1/scripts/clock.sh"
}
pro_unmeasured_version_reader () {  # prose naming the exemption stays CLEAN
  printf '\n# never: add a new tool -version | head -1 without measuring its block against\n# the pipe buffer — the exemption is size, and size is re-taken (115 §3)\n' \
    >> "$1/scripts/clock.sh"
}


mut_suppress_faststart_announce () {  # the choice stops being announced
  # 1.16.7's contract is that faststart is announced EITHER WAY. A build that
  # silently front-moovs is still a divergence — just one nobody can read in
  # the log, which is exactly how the POC rung's end-moov survived four rounds.
  perl -pi -e 's{^rtm_faststart_announce remux\.sh$}{}' "$1/scripts/remux.sh"
}
pro_suppress_faststart_announce () {  # prose naming the announcement stays CLEAN
  printf '\n# never: drop rtm_faststart_announce from a .mov-writing route — the atom\n# order a build chose is only a fact if the run log says which one (test 116)\n' \
    >> "$1/scripts/remux.sh"
}

mut_auto_faststart_optout () {  # the opt-out becomes automatic, on size
  # The policy resolution is explicit: never automatic. A size threshold is the
  # tempting version (it even looks like a kindness on a 24 GB master) and it is
  # invisible to every assertion that runs on a small fixture — only 116 §8,
  # which reads the DECISION rather than an output, can see it.
  # every $ in the REPLACEMENT is escaped: perl interpolates ${...} and $(...)
  # there, so the unescaped form compiled to nothing and the case reported
  # MUTATE-FAIL — a guard that mutates nothing audits nothing.
  perl -0pi -e 's{rtm_faststart_on \(\) \{ \[ "\$\{RTM_FASTSTART:-1\}" != 0 \]; \}}{rtm_faststart_on () { [ "\$\{RTM_FASTSTART:-1\}" != 0 ] && [ "\$(stat -f%z "\$\{1:-/dev/null\}" 2>/dev/null || echo 0)" -lt 4294967296 ]; }}' \
    "$1/scripts/lib-mux.sh"
}
pro_auto_faststart_optout () {  # prose naming the automatic shape stays CLEAN
  printf '\n# never: make rtm_faststart_on consult the file (size, name, "looks archival")\n# — the opt-out is an operator decision, announced, or it is not one (116 SS8)\n' \
    >> "$1/scripts/lib-mux.sh"
}

mut_recategorize_mp2 () {  # the categorical silence claim comes back
  # Item 1 demoted C102 to a per-OS empirical pair. The regression is not a
  # deleted date — it is one confident sentence re-added beside them, which
  # reads as a summary and silently restores the categorical the bench falsified.
  perl -0pi -e 's{(    echo "   >> MP2 audio with NO PCM access track[^\n]*\n)}{$1    echo "      AVFoundation has no MPEG Layer II path for mp4a/.mp2 tracks."\n}' \
    "$1/scripts/verify.sh"
}
pro_recategorize_mp2 () {  # prose naming the categorical stays CLEAN
  printf '\n# never: restate "AVFoundation has no MPEG Layer II path" as a categorical —\n# it was measured playing here 2026-08-29 and silent on the D3 bench\n# 2026-08-15; both dates stand, neither summarises the other (test 117)\n' \
    >> "$1/scripts/verify.sh"
}

# --------------------------------------------------------------------- roster
# ID|LANE|TEST|MARKER|MUTATION[|FAILMARK]        LANE: defect | prose | new
# MARKER is a substring UNIQUE to the guard's own PASS line.
# FAILMARK is optional: when a guard emits ONE PASS LINE PER ITEM (93 §4 judges
# every offered route), the items that legitimately keep passing would read as
# MISSED — so name the FAIL text the mutation must produce, and judge that.
ROSTER='
G01|defect|94-rot-sweep.sh|every script and test parses under bash -n|mut_apostrophe
G02|defect|94-rot-sweep.sh|every counter-subscripted awk initializes its counter|mut_awk_counter
G03|defect|94-rot-sweep.sh|nothing scans shared temp ground|mut_temp_scan
G04|defect|94-rot-sweep.sh|ask the one writer|mut_census_rc
G05|defect|94-rot-sweep.sh|the audio manifest is defined exactly once|mut_dup_aud_manifest
G06|defect|94-rot-sweep.sh|the disk pre-flight is defined exactly once|mut_dup_disk_preflight
G07|defect|94-rot-sweep.sh|the writer lock is defined exactly once|mut_dup_lock
G08|defect|91-flags-parsers-docs.sh|converted to ffp1|mut_ffp_head
G09|defect|91-flags-parsers-docs.sh|assignment-position pipeline|mut_dimscan_pipeline
G10|defect|92-probe-lang-merge.sh|survives nowhere in scripts|mut_keepfirst
G11|defect|92-probe-lang-merge.sh|exists exactly once in scripts|mut_dup_merge_file
G11b|defect|92-probe-lang-merge.sh|exists exactly once in scripts|mut_dup_merge_same
G12|defect|92-probe-lang-merge.sh|that file is lib-probe.sh|mut_move_merge
G13|defect|41-422-empirical.sh|no script emits MOV_REFUSED profile=qt-undecodable|mut_qt_undecodable
G14|defect|41-422-empirical.sh|within reach of a live yuv422p predicate|mut_422_refusal
G15|new|14-exit-codes.sh|zz-mutant: no args|mut_stray_entrypoint
G16|defect|90-harness-honesty.sh|the roster is derived|mut_underive_roster
G17|defect|84-d1-d2-evidence-loss.sh|mux_confessions reads the shared vocabulary|mut_privatize_vocab
G18|defect|88-jurisdiction.sh|locale-exposed|mut_locale_entrypoint
G18b|defect|88-jurisdiction.sh|locale-exposed|mut_locale_mention
G19|defect|73-rewrap-sigpipe.sh|pipes into head|mut_program_head
G20|defect|73-rewrap-sigpipe.sh|program= sites ride ffp1|mut_unffp1_program
G21|defect|93-clean-paff-route.sh|asks zero-base for its own verdict|mut_unask_zerobase
G22|defect|93-clean-paff-route.sh|the axis closed without it|mut_nprog_model
G23|defect|93-clean-paff-route.sh|and it did not refuse at pre-flight|mut_ungate_route|which refuses at pre-flight (rc=2)
P02|prose|94-rot-sweep.sh|every counter-subscripted awk initializes its counter|pro_awk_counter
P03|prose|94-rot-sweep.sh|nothing scans shared temp ground|pro_temp_scan
P04|prose|94-rot-sweep.sh|ask the one writer|pro_census_rc
P07|prose|94-rot-sweep.sh|the writer lock is defined exactly once|pro_dup_lock
P08|prose|91-flags-parsers-docs.sh|converted to ffp1|pro_ffp_head
P10|prose|92-probe-lang-merge.sh|survives nowhere in scripts|pro_keepfirst
P11|prose|92-probe-lang-merge.sh|exists exactly once in scripts|pro_dup_merge
P13|prose|41-422-empirical.sh|no script emits MOV_REFUSED profile=qt-undecodable|pro_qt_undecodable
P14|prose|41-422-empirical.sh|within reach of a live yuv422p predicate|pro_422_refusal
P19|prose|73-rewrap-sigpipe.sh|pipes into head|pro_program_head
P21|prose|93-clean-paff-route.sh|asks zero-base for its own verdict|pro_unask_zerobase
P22|prose|93-clean-paff-route.sh|the axis closed without it|pro_nprog_model
G36|defect|99-route-prose-and-identity.sh|no script promises pairfill refuses on shape|mut_false_exit3_promise
G37|defect|99-route-prose-and-identity.sh|the retired claim survives in no script|mut_no_rung_composes
G38|defect|99-route-prose-and-identity.sh|no script assigns a hardcoded plugin version|mut_hardcode_version
G39|defect|99-route-prose-and-identity.sh|the shell half defines the sparse bound exactly once|mut_dup_sparse_bound
P36|prose|99-route-prose-and-identity.sh|no script promises pairfill refuses on shape|pro_false_exit3_promise
P38|prose|99-route-prose-and-identity.sh|no script assigns a hardcoded plugin version|pro_hardcode_version
G24|defect|94-rot-sweep.sh|every set +e region restores set -e|mut_unrestored_errexit
G24b|defect|94-rot-sweep.sh|every set +e region restores set -e|mut_exit_while_disarmed
G25|defect|94-rot-sweep.sh|no literal copy of the vocabulary survives|mut_vocab_copy
G26|defect|94-rot-sweep.sh|RTM_CONFESSION_RE is defined exactly once|mut_dup_vocab_def
G27|defect|94-rot-sweep.sh|QuickTime-native audio arms are identical|mut_native_drift
P24|prose|94-rot-sweep.sh|every set +e region restores set -e|pro_unrestored_errexit
P25|prose|94-rot-sweep.sh|no literal copy of the vocabulary survives|pro_vocab_copy
P27|prose|94-rot-sweep.sh|QuickTime-native audio arms are identical|pro_native_drift
G28|defect|94-rot-sweep.sh|reads a name it declares in the same statement|mut_local_selfref
P28|prose|94-rot-sweep.sh|reads a name it declares in the same statement|pro_local_selfref
G29|defect|94-rot-sweep.sh|ends in an early-exit grep -q|mut_early_exit_reader
P29|prose|94-rot-sweep.sh|ends in an early-exit grep -q|pro_early_exit_reader
G30|defect|92-probe-lang-merge.sh|calls rtm_aud_manifest|mut_uncall_manifest|does not call the shared writer
P30|prose|92-probe-lang-merge.sh|calls rtm_aud_manifest|pro_uncall_manifest
G31|defect|84-d1-d2-evidence-loss.sh|reads the shared vocabulary, and nothing else|mut_widen_vocab|carries a private copy or a widened pattern
P31|prose|84-d1-d2-evidence-loss.sh|reads the shared vocabulary, and nothing else|pro_widen_vocab
G32|defect|94-rot-sweep.sh|no builder exits with the raw census rc|mut_raw_census_exit
P32|prose|94-rot-sweep.sh|no builder exits with the raw census rc|pro_raw_census_exit
G33|defect|93-clean-paff-route.sh|asks trim-to-idr for its own verdict|mut_unask_trim
P33|prose|93-clean-paff-route.sh|asks trim-to-idr for its own verdict|pro_unask_trim
G34|defect|95-empty-ne-absent-optin-gates.sh|-counted audio census left in verify.sh|mut_optin_census
P34|prose|95-empty-ne-absent-optin-gates.sh|-counted audio census left in verify.sh|pro_optin_census
G35|defect|95-empty-ne-absent-optin-gates.sh|no longer swallows its rc|mut_phash_swallow
P35|prose|95-empty-ne-absent-optin-gates.sh|no longer swallows its rc|pro_phash_swallow
G40|defect|94-rot-sweep.sh|refusal sites carry a # TIER classification|mut_untiered_refusal|refusal sites with no # TIER classification
P40|prose|94-rot-sweep.sh|refusal sites carry a # TIER classification|pro_untiered_refusal
G41|defect|94-rot-sweep.sh|no builder carries a private copy of the source-vs-output identity test|mut_private_sibling_test|private copies of the sibling test
P41|prose|94-rot-sweep.sh|no builder carries a private copy of the source-vs-output identity test|pro_private_sibling_test
G42|defect|109-attempt-not-predicted.sh|no script refuses on a forecast about its own output|mut_output_forecast_gate|output-quality forecasts still gate an attempt
P42|prose|109-attempt-not-predicted.sh|no script refuses on a forecast about its own output|pro_output_forecast_gate
G43|defect|110-park-name-collision.sh|the source survives auto.sh|mut_unguard_derived_names|THE SOURCE WAS DELETED BY THE PARK-FILE COLLISION
P43|prose|110-park-name-collision.sh|the source survives auto.sh|pro_unguard_derived_names
G44|defect|110-park-name-collision.sh|every inline-derived scratch name is in RTM_SIDECAR_TAGS|mut_unregistered_inline_scratch|inline scratch names the sibling guard cannot see
P44|prose|110-park-name-collision.sh|every inline-derived scratch name is in RTM_SIDECAR_TAGS|pro_unregistered_inline_scratch
G45|defect|111-poc-scopes.sh|both scopes on-slot under their OWN modulus|mut_single_poc_modulus|the l2 change did not open a new scope
P45|prose|111-poc-scopes.sh|both scopes on-slot under their OWN modulus|pro_single_poc_modulus
G46|defect|112-sps-aware-slice-reader.sh|the true value|mut_hardcoded_frame_num_width|want 3
P46|prose|112-sps-aware-slice-reader.sh|the true value|pro_hardcoded_frame_num_width
G47|defect|113-poc-type2-scopes.sh|no picture emits nothing|mut_suppress_t2_row|VERIFY_LEDGER gate=k verdict=unproven
P47|prose|113-poc-type2-scopes.sh|no picture emits nothing|pro_suppress_t2_row
G48|defect|114-capability-one-authority.sh|the shell probe agrees|mut_model_the_capability|two writers, one fact
P48|prose|114-capability-one-authority.sh|the shell probe agrees|pro_model_the_capability
G49|defect|90-harness-honesty.sh|the durable channel|mut_suppress_ma_verdict
P49|prose|90-harness-honesty.sh|the durable channel|pro_suppress_ma_verdict
G50|defect|91-flags-parsers-docs.sh|the class swept one alias deep|mut_alias_ffp_head
P50|prose|91-flags-parsers-docs.sh|the class swept one alias deep|pro_alias_ffp_head
G51|defect|115-probe-head-race.sh|one this section measures|mut_unmeasured_version_reader
P51|prose|115-probe-head-race.sh|one this section measures|pro_unmeasured_version_reader
G52|defect|116-faststart-policy.sh|remux.sh announced state=on|mut_suppress_faststart_announce
P52|prose|116-faststart-policy.sh|remux.sh announced state=on|pro_suppress_faststart_announce
G53|defect|116-faststart-policy.sh|consults nothing but the knob|mut_auto_faststart_optout
P53|prose|116-faststart-policy.sh|consults nothing but the knob|pro_auto_faststart_optout
G54|defect|117-mp2-per-os-claim.sh|AVFoundation has no MPEG Layer II path|mut_recategorize_mp2
P54|prose|117-mp2-per-os-claim.sh|AVFoundation has no MPEG Layer II path|pro_recategorize_mp2
'

# --------------------------------------------------------------------- runner
# MEASURED 2026-08-29: this scanned *.sh ONLY, so a mutation that edited a .py
# file changed nothing it could see and every such case reported MUTATE-NOOP —
# i.e. no guard over the plugin's five Python scripts could ever be audited,
# and the harness said so in a word that reads like the mutator's fault.
# `#` starts a comment in both languages, so rtm_strip_comments serves both.
code_digest () {  # cksum of every *.sh and *.py under $1, comments and blanks removed
  find "$1" \( -name "*.sh" -o -name "*.py" \) -type f | sort | while IFS= read -r _f; do rtm_strip_comments "$_f"; done \
    | sed '/^[[:space:]]*$/d' | cksum
}
run_one () {  # run_one ID LANE TEST MARKER MUTATION [FAILMARK]
  local id="$1" lane="$2" test="$3" marker="$4" mutfn="$5" failmark="${6:-}"
  local sk out rc verdict
  sk="$(new_sandbox "$id")" || { echo "SANDBOX-FAIL" > "$OUTDIR/$id.verdict"; return; }
  local before after cbefore cafter
  before=$(find "$sk" \( -name "*.sh" -o -name "*.py" \) -type f -exec cksum {} + | cksum)
  cbefore=$(code_digest "$sk")
  if ! "$mutfn" "$sk"; then echo "MUTATE-FAIL" > "$OUTDIR/$id.verdict"; return; fi
  after=$(find "$sk" \( -name "*.sh" -o -name "*.py" \) -type f -exec cksum {} + | cksum)
  cafter=$(code_digest "$sk")
  # measured: the BEGIN{n=0} regex matched nothing, perl exited 0, and the guard
  # read MISSED — a harness bug dressed as a finding. Never again.
  [ "$before" != "$after" ] || { echo "MUTATE-NOOP" > "$OUTDIR/$id.verdict"; return; }
  # WHERE it landed is checked, not hoped: a defect must change CODE (a defect
  # written into a comment proves nothing and reads as MISSED against an
  # innocent guard); a prose mutation must change NOTHING but comments (else
  # its CLEAN was earned by luck).
  case "$lane" in
    prose) [ "$cbefore" = "$cafter" ] || { echo "MUTATE-IN-CODE" > "$OUTDIR/$id.verdict"; return; };;
    *)     [ "$cbefore" != "$cafter" ] || { echo "MUTATE-IN-PROSE" > "$OUTDIR/$id.verdict"; return; };;
  esac
  out="$OUTDIR/$id.log"
  ( cd "$sk" && bash "tests/regression.d/$test" ) > "$out" 2>&1; rc=$?
  if [ -n "$failmark" ] && [ "$lane" != prose ]; then
    # a per-item guard: judge the FAIL text the mutation must produce, because
    # the other items legitimately keep passing
    # count, never `| grep -q`: the early-exit reader SIGPIPEs its writer past
    # ~16 KiB of matches (measured: CAUGHT flips to MISSED at 300 FAIL lines)
    if [ "$(grep 'FAIL' "$out" | grep -cF -- "$failmark")" -gt 0 ]; then verdict=CAUGHT; else verdict=MISSED; fi
  elif [ "$(grep -F -- "$marker" "$out" | grep -c 'PASS')" -gt 0 ]; then
    # the marked guard stayed PASS. Prose: CLEAN only if the whole run stayed
    # green — a red run means a SIBLING assertion in the same test cried wolf
    # on this comment (measured 2026-08-28: P11 kept 92 §4's marker PASS while
    # its un-stripped per-consumer pin FAILed, and this read CLEAN). Defect:
    # MISSED regardless — something else going red is not this guard's catch.
    if [ "$lane" = prose ]; then
      [ "$rc" -eq 0 ] && verdict=CLEAN || verdict=RED-ELSEWHERE
    else verdict=MISSED; fi
  elif [ "$rc" -ne 0 ]; then
    [ "$lane" = prose ] && verdict=FALSE-POSITIVE || verdict=CAUGHT
  else
    # the assertion stopped running and nothing failed: say so, never credit it
    verdict=GUARD-VANISHED
  fi
  # keep the run's FAIL lines so a human can confirm the catch was for the right
  # reason and not a side effect elsewhere in the same file
  grep 'FAIL' "$out" 2>/dev/null | sed 's/^ *//' > "$OUTDIR/$id.why" || true
  printf '%s\n' "$verdict" > "$OUTDIR/$id.verdict"
  [ "${MA_KEEP:-0}" = 1 ] || rm -rf "$OUTDIR/sb-$id"
}

baseline_one () {  # the marker must be a PASS on an UNMUTATED sandbox, or a
  local test="$1" sk    # "CAUGHT" means nothing (the line may never appear)
  # always re-taken: the caller runs this once per distinct test, and a
  # baseline left in a persisted MA_OUTDIR by an earlier tree state must never
  # judge this one (a stale PASS line is a fake baseline)
  sk="$(new_sandbox "base-$test")" || return 1
  local brc=0
  ( cd "$sk" && bash "tests/regression.d/$test" ) > "$OUTDIR/base-$test.log" 2>&1 || brc=$?
  # kept: a test that is red BEFORE any mutation cannot judge one (its prose
  # cases would all read RED-ELSEWHERE for a reason that is not theirs)
  printf '%s\n' "$brc" > "$OUTDIR/base-$test.rc"
  [ "${MA_KEEP:-0}" = 1 ] || rm -rf "$OUTDIR/sb-base-$test"
  return 0
}

WANT="$*"
rows=""
while IFS='|' read -r id lane test marker mutfn failmark; do
  [ -n "${id:-}" ] || continue
  case "$id" in \#*) continue;; esac
  if [ -n "$WANT" ]; then case " $WANT " in *" $id "*) ;; *) continue;; esac; fi
  rows="$rows$id|$lane|$test|$marker|$mutfn|${failmark:-}
"
done <<< "$ROSTER"
[ -n "$rows" ] || { echo "no cases selected"; exit 2; }

echo "== baselines (unmutated sandboxes) =="
for t in $(printf '%s' "$rows" | cut -d'|' -f3 | sort -u); do
  printf '   %-32s ' "$t"
  baseline_one "$t" && echo done || { echo FAILED; exit 2; }
done

echo
echo "== cases (JOBS=$JOBS) =="
running=0
while IFS='|' read -r id lane test marker mutfn failmark; do
  [ -n "${id:-}" ] || continue
  printf '   %-5s %-7s %s\n' "$id" "$lane" "$test"
  run_one "$id" "$lane" "$test" "$marker" "$mutfn" "$failmark" &
  running=$((running+1))
  if [ "$running" -ge "$JOBS" ]; then wait; running=0; fi
done <<< "$rows"
wait

echo
printf '%-5s %-7s %-30s %-15s %s\n' ID LANE TEST VERDICT GUARD
bad=0; total=0
while IFS='|' read -r id lane test marker mutfn failmark; do
  [ -n "${id:-}" ] || continue
  total=$((total+1))
  v=$(cat "$OUTDIR/$id.verdict" 2>/dev/null || echo NO-VERDICT)
  [ "$(cat "$OUTDIR/base-$test.rc" 2>/dev/null)" = 0 ] || v="BASE-RED"
  if [ "$lane" = new ]; then
    grep -F "$marker" "$OUTDIR/base-$test.log" >/dev/null 2>&1 && v="MARKER-PREEXISTS"
  elif [ -n "$failmark" ]; then
    grep -F "$failmark" "$OUTDIR/base-$test.log" >/dev/null 2>&1 && v="FAILMARK-PREEXISTS"
  else
    [ "$(grep -F -- "$marker" "$OUTDIR/base-$test.log" 2>/dev/null | grep -c 'PASS')" -gt 0 ] || v="NO-BASELINE"
  fi
  case "$v" in CAUGHT|CLEAN) ;; *) bad=$((bad+1));; esac
  printf '%-5s %-7s %-30s %-15s %s\n' "$id" "$lane" "$test" "$v" "$marker"
  case "$v" in CAUGHT|FALSE-POSITIVE|RED-ELSEWHERE)
    head -2 "$OUTDIR/$id.why" 2>/dev/null | sed 's/^/      -> /';;
  esac
done <<< "$rows"

echo
echo "mutation-audit: $((total-bad))/$total cases in contract (CAUGHT for defect, CLEAN for prose)"
# the verdict, in one line a machine can read, on two channels that must agree.
# $OUTDIR is this run's OWN scratch (III.3) — the file goes nowhere else.
ma_verdict=fail; [ "$bad" -eq 0 ] && ma_verdict=pass
ma_summary="MA_SUMMARY total=$total bad=$bad verdict=$ma_verdict"
printf '%s\n' "$ma_summary"
printf '%s\n' "$ma_summary" > "$OUTDIR/VERDICT"
[ "$bad" -eq 0 ]
