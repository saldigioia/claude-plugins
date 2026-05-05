# `stems-to-mixdown`

A conservative mixdown engineer in script form, packaged as a Claude Code plugin. Reads a directory of stems, refuses to invent fidelity that wasn't captured, produces stereo sums with full provenance.

## What it does

Given a folder of multitrack stems:

```
~/sessions/some-track/
├── vox_lead.wav
├── vox_bg_l.wav
├── vox_bg_r.wav
├── kick.wav
├── snare.wav
├── bass.wav
├── gtr_l.wav
├── gtr_r.wav
└── keys.wav
```

…the skill produces:

```
~/sessions/some-track-mixdowns/
├── some-track_acapella.flac
├── some-track_acapella.flac.log.md
├── some-track_instrumental.flac
└── some-track_instrumental.flac.log.md
```

Each `.log.md` is a sidecar with input SHA-256s, the exact ffmpeg command, the filter graph, before/after measurements (LUFS-I, LRA, dBTP), tool versions, and the SHA-anchored idempotency key.

## With a master reference (optional)

Declare `source.master_reference.path` in `stems.manifest.yaml` (or pass `--master <path>` to analyze) and the skill produces a `reference-bundle/` containing three perfectly synchronized files (master + instrumental + acapella) at identical rate / depth / channels. Pass 5 runs the reference battery: recombine null `(instrumental + acapella) - master`, two diagnostic inverse-stems nulls, and per-deliverable LUFS-I / dBTP deltas vs the master. The master is the witness, not the source — the skill refuses to resample, requantize, or trim it. (Cmd 19.)

## Install

From the marketplace:

```bash
claude plugin marketplace add saldigioia/claude-plugins
claude plugin install stems-to-mixdown@rare-data-club
```

Or from inside Claude Code:

```
/plugin marketplace add saldigioia/claude-plugins
/plugin install stems-to-mixdown@rare-data-club
```

For local development, point `--plugin-dir` at this folder:

```bash
claude --plugin-dir ./plugins/stems-to-mixdown
```

## Dependencies

Required:

- `ffmpeg` ≥ 5.0 (for stable `ebur128 peak=true` summary format and `aresample` dither methods)
- `ffprobe` (ships with ffmpeg)
- Python 3.10+

Optional (the plugin works correctly when these are absent):

| Tool | Install | What it adds |
|---|---|---|
| `PyYAML` | `pip install pyyaml` | Required if you use `stems.manifest.yaml` (most non-trivial setups) |
| `wavinfo` | `pip install wavinfo` | Honest 24-in-32 bit-depth, BWF `bext`, iXML `scene`/`take`/`project`, UMID |
| `mediainfo` (CLI) | `brew install mediainfo` / `apt install mediainfo` | Cross-check probe, fires `probe_disagreement` warns on matrix-affecting disagreements |
| `bwfmetaedit` (CLI) | `brew install bwfmetaedit` / `apt install bwfmetaedit` | FADGI-conformant XML/CSV reports under `<dir>/.s2m/metadata/` (opt-in via `--bwf-report`) |

## Six-pass workflow

| Pass | Script | Purpose |
|---|---|---|
| 0a | `identify.py` | Triage. Cheap. Decides whether Pro Tools intake is needed. Always run first. |
| 0b | `import_pt_track_names.py` | Borrow track names from a Pro Tools "Session Info as Text" export to classify badly-named files. Does **not** reconstruct session timing. Run only when 0a recommends it. |
| 1+2 | `analyze.py` | Discovery (probe + classify) + Sanity (red flags, including pan-law disclosure, master-reference parity, length drift, lossy presence, DC offset, dead channels, silent files). |
| 3 | `plan.py` | Format-decision matrix + measured pre-attenuation + filter-graph construction. Plans the reference bundle when a master is declared. |
| 4 | `mix.py` | Executes the plan. Writes canonical mixdowns + sidecar logs. With `--preview`: also writes `*.preview.flac` (Cmd 17, listening only). With `--solo`: per-stem QC bounces. With a planned bundle: writes `reference-bundle/`. |
| 5 | `verify.py` | Re-probes outputs against the plan (rate, channels, codec, bit depth). Optional null-test against a reference bounce. With a master: runs the reference battery. Reports per-platform loudness deltas (Spotify / Apple Music / EBU R128) informationally — no normalization. |

## Doctrine

Eighteen commandments live in `skills/stems-to-mixdown/references/commandments.md`. The load-bearing ones, in plain English:

1. **The source is the ceiling.** Output rate/depth follows the inputs. Lossy in chain → 16/44.1 FLAC out.
2. **Sum at unity.** `amix=normalize=0`. Headroom comes from measured pre-attenuation, never post-sum normalization.
3. **Headroom is not wasted space.** Pre-attenuate to land at -3 dBTP when the measured peak crosses -1.
5. **Dither when reducing depth.** Triangular high-pass at every 16-bit reduction. No exceptions.
7. **True peak is not sample peak.** ITU-R BS.1770 dBTP for every measurement.
9. **Loudness normalization is not mastering.** The skill measures LUFS; it doesn't target it.
13. **Reversibility is a feature.** Sidecar `.log.md` per output, with SHA-anchored idempotency key.
16. **Pan law is a choice. Declare it.** Default -3.0 dB (Logic / Cubase); Pro Tools is -2.5 dB.
17. **The preview is not the deliverable.** `--preview` makes a listening copy; the canonical FLAC is the truth.
18. **Inputs are read-only.** Default output dir is `<source>/../<source-name>-mixdowns/`.
19. **The master is the witness, not the source.** Refuses to resample/requantize/trim the master to fit.

Each commandment is cited (`Cmd N`) by the error messages and plan rationales that depend on it. To change behavior, start there.

## Out of scope

- Multichannel inputs (5.1, 7.1, ambisonic). Different problem, different tooling.
- Mastering. The skill bounces a clean sum; loudness targets are a separate decision.
- Lossy → same-codec lossy at higher bitrate. That's a fidelity claim the source doesn't support.
- Pro Tools `.ptx` parsing. Format is undocumented and version-fragile; consolidate stems first.
- Source separation from a finished mix. Use the sibling [`stems-from-mix`](../stems-from-mix/) plugin.

## Quick test

```bash
cd plugins/stems-to-mixdown
bash tests/run-all-passes.sh        # smoke: every fixture end-to-end
bash tests/diff-baseline.sh         # byte-equivalence against committed baselines
bash tests/test_master_reference.sh # Cmd 19 end-to-end (recombine-null + refusals)
bash tests/assert-audio-shas.sh     # output-MD5 assertions
python3 -m pytest tests/test_format_decision.py  # 17 matrix cases
```

## Layout

```
stems-to-mixdown/
├── .claude-plugin/
│   └── plugin.json                 plugin manifest (name, version, keywords)
├── skills/
│   └── stems-to-mixdown/
│       ├── SKILL.md                skill entry point + frontmatter
│       └── references/             commandments, format-decisions, manifest schema, etc.
├── scripts/                         the six pipeline scripts + shared _*.py modules
├── tests/                           fixtures, baselines, smoke + correctness tests
├── docs/
│   ├── why.md                      one-page ethos
│   ├── research/                   Phase 2 research outputs
│   ├── decisions/                  decision records per phase
│   ├── REVIEW-2026-05.md           original technical review
│   └── IMPROVEMENT-PLAN.md         seven-phase plan that produced v1.0
├── CHANGELOG.md
├── LICENSE
└── README.md
```

## License

MIT — see [LICENSE](LICENSE).
