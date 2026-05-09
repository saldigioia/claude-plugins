#!/usr/bin/env bash
# Audio MD5 drift detector — ADVISORY, not a gate.
#
# Compares each fixture's mixed audio MD5 against the values in
# tests/baselines/expected-audio-md5s.txt. The MD5s were captured against
# a specific ffmpeg build; resampler / dither / encoder changes between
# ffmpeg versions produce slightly different bytes for the same input,
# which trips this script even though the perceptual content is identical.
#
# Use this script to detect that something has drifted — a useful signal
# when you've intentionally changed the pipeline. Do NOT use it as a CI
# gate; the gate is `pytest tests/test_perceptual_outputs.py`, which
# asserts what Cmd 1, Cmd 7, and Cmd 19 actually care about (format,
# true peak, recombine null) and is robust to ffmpeg version drift.
#
# Exits 0 always. Drift is reported on stderr as a "drift" line.
set -uo pipefail
cd "$(dirname "$0")/.."

EXPECTED=tests/baselines/expected-audio-md5s.txt
test -f $EXPECTED || { echo "FAIL: no $EXPECTED"; exit 2; }

any_drift=0
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
        || { echo "  [drift] analyze exited non-zero"; any_drift=1; continue; }
    # v1.3: the canonical default is now normalized to -14 LUFS-I, which
    # changes the audio bytes. The committed baselines were generated at
    # unity sum (the v1.2 default, now `--archival`), so this script
    # exercises the --archival path. A separate v1.3 default-normalized
    # baseline lives in tests/baselines/v1.3-default-md5s.txt and is
    # asserted by assert-normalized-shas.sh.
    python3 stems_to_mixdown/plan.py --analysis "$tmp_root/a.json" --output-dir "$tmp_root/mixdowns" \
        --archival \
        > "$tmp_root/p.json" 2>/dev/null \
        || { echo "  [drift] plan exited non-zero"; any_drift=1; continue; }
    python3 stems_to_mixdown/mix.py --plan "$tmp_root/p.json" --yes \
        > /dev/null 2>&1 || { echo "  [drift] mix exited non-zero"; any_drift=1; continue; }
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
            echo "  [drift] $rel — output missing at $actual_path"
            any_drift=1
            continue
        fi
        actual=$(ffmpeg -nostdin -hide_banner -loglevel error -i "$actual_path" -map 0:a -f md5 - 2>&1 | sed 's/MD5=//')
        if [ "$actual" = "$expected" ]; then
            echo "  [ok] $rel"
        else
            echo "  [drift] $rel"
            echo "         expected: $expected"
            echo "         actual:   $actual"
            any_drift=1
        fi
    done < $EXPECTED
done

if [ "$any_drift" -ne 0 ]; then
    echo ""
    echo "Drift detected. This is advisory — perceptual invariants are the gate."
    echo "Run \`python3 -m pytest tests/test_perceptual_outputs.py\` for the real test."
fi
exit 0
