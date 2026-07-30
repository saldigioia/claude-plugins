# Rare Data Club — Claude Code Plugins

A marketplace of Claude Code plugins maintained by [Rare Data Club](mailto:salthecowboy@proton.me).

## Install

```bash
# Add the marketplace (one time)
claude plugin marketplace add saldigioia/claude-plugins

# Install the plugins you want
claude plugin install every-layout@rare-data-club
claude plugin install wayback-archive@rare-data-club
claude plugin install stems-to-mixdown@rare-data-club
claude plugin install stems-from-mix@rare-data-club
```

Or from inside an interactive Claude Code session:

```
/plugin marketplace add saldigioia/claude-plugins
/plugin install every-layout@rare-data-club
/plugin install wayback-archive@rare-data-club
/plugin install stems-to-mixdown@rare-data-club
/plugin install stems-from-mix@rare-data-club
```

To install everything in one shot:

```bash
curl -fsSL https://raw.githubusercontent.com/saldigioia/claude-plugins/main/install.sh | bash
```

## Plugins

| Plugin | Version | What it does |
| --- | --- | --- |
| [`every-layout`](plugins/every-layout/README.md) | 4.11.0 | Axiom-enforced CSS layout primitives, Astro 6 site architecture, archival data patterns, and design system tokens. 13 composable primitives, 33 numbered principles, 6 axioms enforced by CI-grade strict-check and JS-budget gates. Zero-JS-by-default, media-query-free, modular-scale spacing. |
| [`wayback-archive`](plugins/wayback-archive/README.md) | 1.3.0 | Recover product databases from defunct e-commerce sites via Wayback Machine, CommonCrawl, and Shopify CDN archaeology. Self-contained 9-stage pipeline supporting Shopify, Swell Commerce, Fourthwall, and custom platforms. |
| [`stems-to-mixdown`](plugins/stems-to-mixdown/README.md) | 1.3.0 | Sum a folder of multitrack stems into stereo mixdowns at the highest fidelity the source supports. Six-pass pipeline with SHA-anchored idempotency, sidecar provenance per output, declared pan law, true-peak headroom, dither when reducing depth. Optional master-reference produces a three-synced-versions reference-bundle and runs a recombine-null verification battery. Eighteen commandments, every refusal cites its rule. |
| [`remuxing-to-mov`](plugins/remuxing-to-mov/README.md) | 1.7.0 | Losslessly remux broadcast and web video (`.ts`, `.mpg`/`.vob`, `.mkv`, broken `.mov`) into a QuickTime-ready `.mov` without re-encoding. Five-rung escalation ladder with probe/diagnose/verify scripts, dual-track PCM-access + bit-exact-original audio, field-coded (PAFF) H.264 repair, and decoded-pixel-identity verification of every output. The source file is never touched. |
| [`hunt`](plugins/hunt/README.md) | 1.0.0 | Recover the byte-exact master behind any CDN/CMS transform, and recover assets from dead, parked, redirected, or archive-only sites. A 48-resolver engine, a six-probe recon script that classifies a dead front door and routes the recovery, 41 per-host registry entries, and a trap catalog for every way a candidate wins on bytes or format while carrying fewer real pixels. |
| [`catalog-forge`](plugins/catalog-forge/README.md) | 0.2.0 | Verify, enrich, finalize, and promote canonical-3.1 product catalogs against a truth-root archive. One-command 4-axis verify, CDN master-rendition resolver, flag-only liveness sweep, propose-only enrichment queue, gated promotion. Mechanical steps auto-apply; identity/naming/merge/inclusion stay curator-gated. |

## Update

Pull the latest marketplace catalog and refresh installed plugins:

```bash
claude plugin marketplace update rare-data-club
```

## Repository layout

```
claude-plugins/
├── .claude-plugin/
│   └── marketplace.json        # Marketplace catalog
├── plugins/
│   ├── every-layout/           # Self-contained plugin with its own plugin.json
│   ├── wayback-archive/        # Self-contained plugin with its own plugin.json
│   ├── stems-to-mixdown/       # Self-contained plugin with its own plugin.json
│   └── stems-from-mix/         # Self-contained plugin with its own plugin.json
├── install.sh                  # One-command bootstrap
├── LICENSE
└── README.md
```

Each plugin is self-contained and versioned independently via its own `.claude-plugin/plugin.json`. Adding a new plugin is one commit: drop the plugin directory under `plugins/` and append an entry to `marketplace.json`.

## License

MIT — see [LICENSE](LICENSE).
