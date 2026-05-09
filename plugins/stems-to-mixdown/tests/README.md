# Tests

Two kinds of tests live here. Know which is which before you debug a failure.

## Perceptual invariants — the gate

These assert what the doctrine actually cares about (format, true peak, recombine null). They're environment-independent: the same source stems produce passing tests on any reasonably modern ffmpeg / mediainfo / wavinfo combination.

```bash
python3 -m pytest tests/                     # all unit + perceptual tests
python3 -m pytest tests/test_perceptual_outputs.py  # just the perceptual baselines
bash tests/run-all-passes.sh                 # smoke: every fixture end-to-end
bash tests/test_master_reference.sh          # Cmd 19 end-to-end (recombine-null + refusals)
```

The perceptual surface lives in:

- `tests/_invariants.py` — helpers (`assert_format`, `assert_true_peak_below`, `assert_lufs_within`, `assert_recombine_null`)
- `tests/test_perceptual_outputs.py` — for every fixture, run the `--archival` pipeline, assert outputs probe to the planned format and don't clip; for `with-master`, assert recombine null within Cmd-19 bounds.
- `tests/test_master_reference.sh` — Cmd-19 end-to-end including the strict `≤ -90 dBTP` recombine-null reference battery.
- `tests/test_format_decision.py`, `tests/test_codec_detection.py`, `tests/test_pan_distribution.py` — pure-function unit tests on the plan-time decision logic.

If these fail, the pipeline is broken. Fix the code.

## Drift detectors — advisory only

These compare current outputs against committed byte-level baselines. Useful for spotting that *something* changed during a refactor, but the baselines were captured at a specific environment and false-positive drift is normal (ffmpeg resampler revisions, mediainfo version differences, wavinfo presence/absence, fixture content edits).

```bash
bash tests/assert-audio-shas.sh   # audio-MD5 drift detector
bash tests/diff-baseline.sh        # JSON-baseline drift detector
```

Both scripts always exit 0. Drift is reported on stderr with `[drift]` prefix. **Do not wire these into CI as gates** — wire the perceptual tests instead.

If they show drift after a refactor, that's a hint, not a failure. Confirm via the perceptual tests, then either:

- Accept the drift if the perceptual tests still pass (it's an environment-driven byte-level change with no doctrinal consequence), or
- Investigate if the perceptual tests also fail (the refactor genuinely changed behavior — fix the code or update the doctrine).

## Fixtures

`tests/fixtures/` has five hand-built directories exercising different code paths:

| Fixture | Exercises |
|---|---|
| `mono-stems` | All-mono → stereo upmix with default pan law (Cmd 16, Cmd 20) |
| `mixed-rates` | Different sample rates across stems → highest-common resample (Cmd 4) |
| `dirty-inputs` | DC offset + silent stem → sanity warns surface, mix continues |
| `24-in-32` | 24-in-32 detection (when wavinfo is installed) |
| `with-master` | Master reference + reference-bundle deliverable + Cmd-19 refusals |

Pre-rendered output FLACs live alongside under `<fixture>-mixdowns/` and are committed for reference comparison; perceptual tests run a fresh pipeline into a `tmp_path` rather than checking the committed outputs.
