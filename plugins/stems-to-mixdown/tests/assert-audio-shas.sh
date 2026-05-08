#!/usr/bin/env bash
# Assert audio-stream MD5 of every fixture's mixed output against the
# expected values in tests/baselines/expected-audio-md5s.txt.
#
# Audio MD5 (via `ffmpeg -map 0:a -f md5`) is the right primitive for
# cross-day SHA assertions: it hashes the decoded PCM, not the file bytes,
# so it's stable even though the embedded COMMENT tag carries the
# per-day date and the file SHA changes daily.
#
# Tests by basename, not by full path, so this script works regardless of
# whether mix.py wrote into the canonical sibling layout
# (tests/fixtures/<fix>-mixdowns/) or a tmp dir.
#
# Exits 0 if every expected output exists and its audio MD5 matches.
set -uo pipefail
cd "$(dirname "$0")/.."

EXPECTED=tests/baselines/expected-audio-md5s.txt
test -f $EXPECTED || { echo "FAIL: no $EXPECTED"; exit 2; }

any_fail=0
for fix in mono-stems mixed-rates dirty-inputs 24-in-32; do
    echo "=== $fix ==="
    # Generate plan FRESH from the fixture rather than reading the committed
    # baseline. The committed baselines have TESTROOT placeholder paths for
    # portability across clones (see tests/diff-baseline.sh) — they're meant
    # for shape-comparison, not for live execution. The live plan needs real
    # absolute paths so mix.py can find the inputs.
    tmp_root="/tmp/_s2m_audio_${fix}"
    rm -rf "$tmp_root"
    mkdir -p "$tmp_root"
    python3 stems_to_mixdown/analyze.py --dir "tests/fixtures/$fix" --force \
        > "$tmp_root/a.json" 2>/dev/null \
        || { echo "  [fail] analyze exited non-zero"; any_fail=1; continue; }
    # v1.3: the canonical default is now normalized to -14 LUFS-I, which
    # changes the audio bytes. The committed baselines were generated at
    # unity sum (the v1.2 default, now `--archival`), so this script
    # exercises the --archival path. A separate v1.3 default-normalized
    # baseline lives in tests/baselines/v1.3-default-md5s.txt and is
    # asserted by assert-normalized-shas.sh.
    python3 stems_to_mixdown/plan.py --analysis "$tmp_root/a.json" --output-dir "$tmp_root/mixdowns" \
        --archival \
        > "$tmp_root/p.json" 2>/dev/null \
        || { echo "  [fail] plan exited non-zero"; any_fail=1; continue; }
    python3 stems_to_mixdown/mix.py --plan "$tmp_root/p.json" --yes \
        > /dev/null 2>&1 || { echo "  [fail] mix exited non-zero"; any_fail=1; continue; }
    out_dir="$tmp_root/mixdowns"

    # Walk every line in the expected file whose path starts with this fixture's mixdown dir.
    while IFS= read -r line; do
        expected=$(echo "$line" | awk '{print $1}')
        rel=$(echo "$line" | awk '{$1=""; sub(/^ +/,""); print}')
        case "$rel" in
            ${fix}-mixdowns/*) ;;
            *) continue ;;
        esac
        # rel looks like "<fix>-mixdowns/<name>.flac"; strip the prefix and find under tmp_root.
        bn="${rel#${fix}-mixdowns/}"
        actual_path="$out_dir/$bn"
        if [ ! -f "$actual_path" ]; then
            echo "  [fail] $rel — output missing at $actual_path"
            any_fail=1
            continue
        fi
        actual=$(ffmpeg -nostdin -hide_banner -loglevel error -i "$actual_path" -map 0:a -f md5 - 2>&1 | sed 's/MD5=//')
        if [ "$actual" = "$expected" ]; then
            echo "  [ok] $rel"
        else
            echo "  [fail] $rel"
            echo "         expected: $expected"
            echo "         actual:   $actual"
            any_fail=1
        fi
    done < $EXPECTED
done

exit $any_fail
