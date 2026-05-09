# `stems-to-mixdown`

A conservative mixdown engineer in script form, packaged as a Claude Code plugin. Reads a directory of stems, refuses to invent fidelity that wasn't captured, produces stereo sums with full provenance.

The full operational doctrine lives in [`skills/mixdown/SKILL.md`](skills/mixdown/SKILL.md) — that's what the LLM reads when the skill triggers. The eighteen commandments are in [`skills/mixdown/references/commandments.md`](skills/mixdown/references/commandments.md). Architectural decisions per phase live in [`docs/decisions/`](docs/decisions/).

## Install

```bash
claude plugin marketplace add saldigioia/claude-plugins
claude plugin install stems-to-mixdown@rare-data-club
```

For local development:

```bash
claude --plugin-dir ./plugins/stems-to-mixdown
```

## Dependencies

**Required:** `ffmpeg` ≥ 5.0, `ffprobe` (ships with ffmpeg), Python 3.10+.

**Optional** (the plugin works correctly when these are absent):

| Tool | Install | What it adds |
|---|---|---|
| `PyYAML` | `pip install pyyaml` | Required if you use `stems.manifest.yaml` |
| `wavinfo` | `pip install wavinfo` | Honest 24-in-32 bit-depth, BWF `bext`, iXML metadata |
| `mediainfo` (CLI) | `brew install mediainfo` | Cross-check probe; fires `probe_disagreement` warns |
| `bwfmetaedit` (CLI) | `brew install bwfmetaedit` | FADGI-conformant XML/CSV reports (opt-in via `--bwf-report`) |

## One-shot mode

```bash
python3 stems_to_mixdown/run.py --dir /path/to/some-track-stems --yes
```

Default output is normalized to -14 LUFS-I / -1 dBTP. `--archival` for the v1.2 unity-sum behavior; `--target-lufs -16` for Apple-first; `--target-lufs -23` for EBU R128. `--master <path>` (or auto-detection of files named `master`, `final`, `released`, `reference`, `bounce_final`) opts into the three-synced-versions reference bundle and the recombine-null verification battery (Cmd 19).

The package supports both `python3 stems_to_mixdown/<pass>.py` and `python3 -m stems_to_mixdown.<pass>` invocation. The per-pass entry points (`identify`, `analyze`, `plan`, `mix`, `verify`) remain available for power users who want intermediate JSON or to re-run a single step.

## Quick test

```bash
cd plugins/stems-to-mixdown
bash tests/run-all-passes.sh         # smoke: every fixture end-to-end
bash tests/test_master_reference.sh  # Cmd 19 end-to-end (recombine-null + refusals)
python3 -m pytest tests/             # unit tests (codec, format-decision, pan)
```

## Layout

```
stems-to-mixdown/
├── .claude-plugin/plugin.json    plugin manifest
├── skills/mixdown/               SKILL.md (operational doctrine) + references/
├── stems_to_mixdown/             Python package; pipeline passes + private modules
├── tests/                        fixtures, baselines, smoke + correctness tests
├── docs/                         decisions/, why.md, research/, archive/
├── CHANGELOG.md
└── LICENSE
```

## License

MIT — see [LICENSE](LICENSE).
