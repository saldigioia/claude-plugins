#!/usr/bin/env bash
# 94-rot-sweep.sh — the standing sweep. Every defect class this plugin has
# actually shipped, enumerated MECHANICALLY over the whole tree, every run.
#
# Why it exists: 1.15.10/.11/.12 were each found by tripping over them, and
# 1.15.12 in particular was found only because a suite run happened to share a
# machine with a 24 GB build. Finding a CLASS and then waiting to meet its next
# INSTANCE is not a method. Once a class is named, enumerating it is mechanical
# — so it belongs here, not in the next field run's luck.
#
# Ground rules for anything added below:
#   * PRECISE, not broad. A tree-wide guard that cries wolf gets disabled, and
#     then the class is unguarded AND believed guarded. Every detector here was
#     tuned until it reported zero false positives on the tree as it stands.
#   * classes already pinned elsewhere are NOT re-pinned (that would be this
#     file committing the very duplication it audits): `ffp … | head -1` is
#     test 91 §5; the audio-manifest single-writer is test 92 §4; the
#     entry-point roster is test 14; pix_fmt refusals are test 41.
#   * MUTATION-VERIFIED, both directions. Every guard below has been seen to
#     FAIL against the exact defect it claims to catch, and to stay PASS against
#     a benign COMMENT quoting the same idiom — `bash tests/mutation-audit.sh`
#     runs both lanes. Add a case there whenever you add a section here. 1.15.17
#     audited the guards that predated the harness: three were vacuous and six
#     tripped on prose.
#
# Standalone: bash tests/regression.d/94-rot-sweep.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TESTS="$HERE/.."; SC="$TESTS/../scripts"
pass=0; fail=0
ok () { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no () { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

. "$TESTS/lib-harness.sh"   # grepq/grepqe + rtm_strip_comments: one definition (tests/lib-harness.sh)

echo "== 1. quoting: every script parses (catches the apostrophe-in-awk trap) =="
# A ' inside a single-quoted awk program silently ends the shell string and the
# rest of the program is parsed as shell. Hit TWICE in one session (1.15.10
# `remux.sh's`, 1.15.14 `rtm_aud_manifest's`). `bash -n` is the exact,
# zero-false-positive detector for it, so the guard is simply: everything parses.
qbad=""
for f in "$SC"/*.sh "$TESTS"/regression.d/*.sh "$TESTS"/*.sh; do
  [ -f "$f" ] || continue
  bash -n "$f" 2>/dev/null || qbad="$qbad $(basename "$f")"
done
[ -z "$qbad" ] && ok "every script and test parses under bash -n" || no "syntax errors (apostrophe-in-awk class?):$qbad"

echo
echo "== 2. the awk bare-counter-subscript trap (1.15.10) =="
# An UNINITIALIZED awk variable used as an array subscript is the empty string,
# not 0 — record 0 lands at C[""] while n++ still counts it. Any awk that both
# subscripts by a counter and increments it must initialize it.
sub_bad=""
for f in "$SC"/*.sh; do
  # comments stripped FIRST: the pattern is also how the idiom is DESCRIBED in
  # prose, so an un-stripped grep is satisfied by a comment mentioning it —
  # measured vacuous, caught by mutation test.
  code=$(rtm_strip_comments "$f")
  printf '%s\n' "$code" | grepq '[A-Za-z_]\[n\]=' || continue
  printf '%s\n' "$code" | grepq 'n++' || continue
  printf '%s\n' "$code" | grepq 'BEGIN{ *n=0' || sub_bad="$sub_bad $(basename "$f")"
done
[ -z "$sub_bad" ] && ok "every counter-subscripted awk initializes its counter" \
  || no "uninitialized counter used as array subscript in:$sub_bad"

echo
echo "== 3. scanner jurisdiction over shared ground (1.15.12) =="
# The 1.15.12 defect precisely: a watcher SCANNED the shared per-user temp dir
# for anything matching a pattern, then rm -rf'd what it found — and deleted
# the live scratch of a running 24 GB build. The detectable, zero-false-positive
# form of the rule is the scan itself: nothing in this tree may take
# jurisdiction over shared temp ground. A process may only look where it wrote.
# (Deliberately NOT "audit every rm -rf": that guard false-positived on .lock
# paths, on a string assertion, and on this file — and a tree-wide guard that
# cries wolf gets disabled, which is worse than no guard. Narrow and true beats
# broad and ignored.)
# The sanctioned way to watch a child's scratch is the mktemp PATH shim in
# test 84: force the code under test to write where the test can see.
scan_bad=""
for f in "$SC"/*.sh "$TESTS"/regression.d/*.sh; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in 94-rot-sweep.sh) continue;; esac
  rtm_strip_comments "$f" | grepqe 'find +"?\$(TD|TMPDIR)|find +"?\$\{?(TD|TMPDIR)|DARWIN_USER_TEMP_DIR[^)]*\)?"?[^=]*$|find +/tmp|find +"?\$HOME' \
    && scan_bad="$scan_bad $(basename "$f")"
done
[ -z "$scan_bad" ] && ok "nothing scans shared temp ground for files it did not write" \
  || no "scanner with no jurisdiction (the 1.15.12 class) in:$scan_bad"

echo
echo "== 4. the census verdict has ONE writer (1.15.17) =="
# Was: "10 builders, 9 genuinely different forms — hold the SEMANTIC in
# lockstep." 1.15.17 gave the contract a single definition (rtm_census_failed /
# rtm_census_review, lib-mux.sh), so the assertion that scales is no longer "do
# all ten copies still agree" but "is there still only one copy". The
# per-builder wrapping — stage name, message, retention pointer, exit contract,
# machine rows — stays private to each builder on purpose: share the FACT, not
# the presentation (1.15.14).
cen_bad=""; n_cen=0
for f in "$SC"/*.sh; do
  case "$(basename "$f")" in lib-mux.sh) continue;; esac   # the writer itself
  # comment-stripped: a builder may legitimately DESCRIBE the contract in prose,
  # and a detector satisfied (or tripped) by prose guards nothing.
  code=$(rtm_strip_comments "$f")
  printf '%s\n' "$code" | grepq 'census_rc' || continue
  n_cen=$((n_cen+1))
  printf '%s\n' "$code" | grepq 'rtm_census_failed' || cen_bad="$cen_bad $(basename "$f")"
  printf '%s\n' "$code" | grepq 'census_rc" -ne 10' && cen_bad="$cen_bad $(basename "$f"):inline"
done
[ -z "$cen_bad" ] && ok "all $n_cen census_rc consumers ask the one writer (rtm_census_failed)" \
  || no "census_rc consumers off the shared writer:$cen_bad"
# …and the verdict is a PREDICATE, never the exit itself. A builder that ends in
# `exit "$census_rc"` hands the raw census rc to the operator — and the day
# rtm_census_failed widens (the one-site edit the writer exists for), that
# builder exits an unmapped code AFTER it mv'd the blessed output, while the
# builders that ask (exit 10 on review, else 0) stay in contract. Three did
# (trim-to-idr, rung4, rebuild-paff — 1.15.18); the loop above could not see
# it, because each still called rtm_census_failed on the way.
raw_exit=""
for f in "$SC"/*.sh; do
  rtm_strip_comments "$f" | grepqe '^[[:space:]]*exit "?\$\{?census_rc' && raw_exit="$raw_exit $(basename "$f")"
done
[ -z "$raw_exit" ] && ok "no builder exits with the raw census rc (the verdict is asked, then mapped to 0/10)" \
  || no "builders exiting the raw census rc (unmapped the day the writer widens):$raw_exit"
# (the two predicates' single-definition pins live in §5's roster below — one
# definition-count loop, not three)

echo
echo "== 5. no NEW duplicate of a shared-writer fact =="
# Facts that have been given a single home must not sprout a second copy. Add
# a line here whenever a fact is centralized; that is the cost of centralizing.
for pair in "rtm_aud_manifest:lib-probe.sh:the audio manifest" \
            "rtm_census_failed:lib-mux.sh:the census failed-verdict" \
            "rtm_census_review:lib-mux.sh:the census review-verdict" \
            "rtm_disk_preflight:lib-mux.sh:the disk pre-flight" \
            "rtm_lock:lib-mux.sh:the writer lock"; do
  fn="${pair%%:*}"; rest="${pair#*:}"; home="${rest%%:*}"; what="${rest#*:}"
  # count DEFINITIONS, not files: grep -l would miss a second copy pasted into
  # the same file (measured vacuous, caught by mutation test).
  defs=$(cat "$SC"/*.sh 2>/dev/null | rtm_strip_comments | grep -c "^$fn *() *{")
  [ "$defs" = 1 ] && ok "$what is defined exactly once ($fn)" \
    || no "$what has $defs definitions — a shared writer has been copied"
  # …and in its HOME: one definition relocated to another lib is still "one",
  # while every builder that sources only the home dies on command-not-found
  rtm_strip_comments "$SC/$home" | grepq "^$fn *() *{" \
    && ok "…and it lives in $home" \
    || no "$fn is not defined in $home — relocated; the builders that source only $home lose it"
done

echo
echo "== 6. errexit is never left disarmed (1.15.17) =="
# A `set +e` region exists to CAPTURE a child's exit code. If its `set -e` is
# missing, errexit stays off for everything AFTER it — including the verdict
# that blesses an artifact and the mv that publishes it. Two properties, both
# mechanical: every region closes, and none exits while disarmed.
# Detector notes (both measured while writing this):
#   * pairing must be TOKEN-wise, not line-wise: 29 of the tree's 42 regions are
#     written `set +e; cmd; rc=$?; set -e` on ONE line, and a line-wise reader
#     calls every one of them unbalanced.
#   * comments stripped FIRST: lib-probe.sh and lib-exit.sh both discuss `set +e`
#     in prose, and an un-stripped reader opens a region on a comment.
ee_bad=""
for f in "$SC"/*.sh; do
  hit=$(rtm_strip_comments "$f" | awk '
    { line=$0
      while (match(line, /set [+-]e/)) {
        tok=substr(line, RSTART, RLENGTH); line=substr(line, RSTART+RLENGTH)
        if (tok=="set +e") { if (pend) printf "reopened@%d ", NR; pend=1; pline=NR }
        else pend=0
      }
      if (pend && NR>pline && $0 ~ /(^|[^A-Za-z_])exit[[:space:]]+[0-9"$]/) printf "exit-while-disarmed@%d ", NR
    }
    END{ if (pend) printf "unrestored@%d ", pline }')
  [ -n "$hit" ] && ee_bad="$ee_bad $(basename "$f"):[$hit]"
done
[ -z "$ee_bad" ] && ok "every set +e region restores set -e, and none exits while disarmed" \
  || no "errexit left disarmed:$ee_bad"

echo
echo "== 7. one vocabulary for the muxer's confessions (1.15.17) =="
# The alternation that decides whether a mux CONFESSED to inventing timing had
# FIVE byte-identical copies — lib-paff's two counters plus the display greps in
# derive-dts.sh, remux.sh and pairfill-paff.sh — and test 84's A4 lockstep
# pinned only the first two. 1.14 had already broadened one copy and left the
# other narrow (CHECKUP-2026-08-27 A4); the three unpinned ones could drift the
# same way unseen. One definition now; this pins that there is still only one.
vdefs=$(cat "$SC"/*.sh 2>/dev/null | rtm_strip_comments | grep -c '^RTM_CONFESSION_RE=')
[ "$vdefs" = 1 ] && ok "RTM_CONFESSION_RE is defined exactly once" \
  || no "RTM_CONFESSION_RE has $vdefs definitions"
lits=$(cat "$SC"/*.sh 2>/dev/null | rtm_strip_comments | grep -c 'non monotonically increasing dts')
[ "$lits" = 1 ] && ok "no literal copy of the vocabulary survives outside the definition" \
  || no "$lits literal copies of the confession vocabulary in scripts/ (want 1: the definition)"
users=$(cat "$SC"/*.sh 2>/dev/null | rtm_strip_comments | grep -c 'RTM_CONFESSION_RE')
[ "${users:-0}" -ge 6 ] && ok "…and $users sites reference it (the definition + the five former copies)" \
  || no "only $users references to RTM_CONFESSION_RE — a consumer stopped asking"

echo
echo "== 8. one QuickTime-native audio table, held in lockstep (1.15.17) =="
# `aac|alac|mp3|pcm_*|eac3` is the partition that decides copy-vs-dual-track. It
# is a case ARM at the point of decision in mov.sh (twice), remux.sh and
# pairfill-paff.sh, and is deliberately NOT centralized: mov.sh's classifiers are
# sourced by the RTM_TEST harness and each site reads where it decides. So it is
# held in step instead. E-AC-3's membership has drifted before — 1.15.9 F7 found
# the dual-track REFERENCE PAGE still calling it a dual-track class rounds after
# the code classified it native.
# one pass: `hits` is every arm as MATCHED (-o), so the site count and the
# distinct-arm set come from the same list (a -c count read LINES, which
# undercounts a line carrying two arms)
hits=$(cat "$SC"/*.sh 2>/dev/null | rtm_strip_comments | grep -oE '[A-Za-z0-9_*|]*aac\|alac[A-Za-z0-9_*|]*')
arms=$(printf '%s\n' "$hits" | sort -u)
n_arms=$(printf '%s\n' "$hits" | grep -c .)
{ [ "$(printf '%s\n' "$arms" | grep -c .)" = 1 ] && [ "${n_arms:-0}" -ge 4 ]; } \
  && ok "all $n_arms QuickTime-native audio arms are identical [$arms]" \
  || no "the native-audio table has drifted across $n_arms site(s): $(printf '%s' "$arms" | tr '\n' ' ')"

echo
echo "== 9. no local statement reads a name it declares in the SAME statement (1.15.17) =="
# `local a="$1" b="pre-$a"` does NOT work. `local` is a BUILTIN: every one of its
# arguments is word-expanded BEFORE any assignment happens, so $a there is the
# CALLER's a (dynamic scope) or empty. Measured on this bench, bash 3.2.57:
#   f(){ local a="$1" b="pre-$a"; echo "$b"; }; f XYZ   ->  "pre-"
# Found the hard way in this round's own mutation harness, where new_sandbox's
# `local id="$1" sb="$OUTDIR/sb-$id"` took the sandbox name from whatever `id`
# the CALLER happened to have in scope — unique per case by luck, EMPTY for
# every baseline, so ten baselines silently overwrote one directory.
# The detector is deliberately narrow: simple `local NAME=VALUE` words only, and
# a plain string search so a value can never inject a regex. A false negative on
# an exotic shape beats a tree-wide guard that cries wolf (CONSTITUTION V.3).
loc_bad=""
for f in "$SC"/*.sh "$TESTS"/regression.d/*.sh "$TESTS"/*.sh; do
  [ -f "$f" ] || continue
  hit=$(rtm_strip_comments "$f" | awk '
    function refs(val, name,   p, c) {
      p = index(val, "$" name)
      if (p > 0) { c = substr(val, p + length(name) + 1, 1); if (c !~ /[A-Za-z0-9_]/) return 1 }
      p = index(val, "${" name)
      if (p > 0) { c = substr(val, p + length(name) + 2, 1); if (c !~ /[A-Za-z0-9_]/) return 1 }
      return 0
    }
    {
      # a `local` can also open a one-line function body, so strip a leading
      # `name () {` and treat each `;`-separated fragment as its own statement.
      # NOT split on `{`: values legitimately contain ${...} and chopping there
      # would blind the ${name} half of the check.
      line=$0; sub(/^[[:space:]]*/,"",line)
      sub(/^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([[:space:]]*\)[[:space:]]*\{[[:space:]]*/, "", line)
      nf=split(line, frag, /;/)
      for (fi=1; fi<=nf; fi++) {
        t=frag[fi]; sub(/^[[:space:]]*/,"",t)
        if (t !~ /^local[[:space:]]/) continue
        sub(/^local[[:space:]]+/,"",t)
        n=split(t, w, /[[:space:]]+/)
        for (x in names) delete names[x]
        k=0
        for (i=1; i<=n; i++) {
          eq=index(w[i], "=")
          if (eq == 0) { names[++k]=w[i]; continue }
          nm=substr(w[i],1,eq-1); vl=substr(w[i],eq+1)
          for (j=1; j<=k; j++) if (refs(vl, names[j])) printf "%d:%s<-$%s ", NR, nm, names[j]
          names[++k]=nm
        }
      }
    }')
  [ -n "$hit" ] && loc_bad="$loc_bad $(basename "$f"):[$hit]"
done
[ -z "$loc_bad" ] && ok "no local statement reads a name it declares in the same statement" \
  || no "local self-reference (expanded before assignment, so it reads the CALLER's value):$loc_bad"

echo
echo "== 10. no early-exit reader over source in the suite (the SIGPIPE class) =="
# `sed … | grep -q` and `printf … | grep -q` close the pipe on the FIRST match and
# SIGPIPE the writer — the same shape as the 1.15.2 `ffp … | head -1` field
# defect. Test 91 §5 pins it for scripts/; nothing pinned it for the suite's OWN
# guards, and 1.15.17 put it there: the freshly-hardened 88 §8 locale sweep
# printed "printf: write error: Broken pipe" on verify.sh (95 KB) and, under
# pipefail, the non-zero pipeline flipped a PASS into a FALSE FAIL — found by
# tests/mutation-audit.sh, not by the bench, because the race needs a big file.
# Use grepq/grepqe (grep -c, reads to EOF).
# Scoped to SOURCE-scanning writers: `ffmpeg -encoders | grep -q` is a different
# class — a short capability listing, no source, and it pre-dates this rule.
# Two exclusions, both because the file's JOB is to hold the shape: this section
# quotes what it forbids, and tests/mutation-audit.sh AUTHORS the defect for every
# guard here — scanning it would false-positive on this rule and on every rule
# added after it (CONSTITUTION V.3: a quoted string inside an assertion is not a
# defect).
sig_bad=""
for f in "$TESTS"/regression.d/*.sh "$TESTS"/*.sh; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in 94-rot-sweep.sh|mutation-audit.sh) continue;; esac
  n=$(rtm_strip_comments "$f" | grep -cE '(sed|printf|cat)[^|]*\| *grep -q')
  [ "${n:-0}" -eq 0 ] || sig_bad="$sig_bad $(basename "$f"):$n"
done
[ -z "$sig_bad" ] && ok "no source-scanning pipeline in the suite ends in an early-exit grep -q" \
  || no "early-exit readers over source (the 1.15.2 SIGPIPE class):$sig_bad"

echo
echo "rot-sweep: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
