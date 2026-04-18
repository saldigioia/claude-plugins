# Rare Data Club — Claude Code Plugins

A marketplace of Claude Code plugins maintained by [Rare Data Club](mailto:salthecowboy@proton.me).

## Install

```bash
# Add the marketplace (one time)
claude plugin marketplace add saldigioia/claude-plugins

# Install the plugins you want
claude plugin install every-layout@rare-data-club
claude plugin install wayback-archive@rare-data-club
```

Or from inside an interactive Claude Code session:

```
/plugin marketplace add saldigioia/claude-plugins
/plugin install every-layout@rare-data-club
/plugin install wayback-archive@rare-data-club
```

To install everything in one shot:

```bash
curl -fsSL https://raw.githubusercontent.com/saldigioia/claude-plugins/main/install.sh | bash
```

## Plugins

| Plugin | Version | What it does |
| --- | --- | --- |
| [`every-layout`](plugins/every-layout/README.md) | 4.2.0 | Axiom-enforced CSS layout primitives, Astro 5 site architecture, archival data patterns, and design system tokens. 13 composable primitives, 32 numbered principles, 6 axioms enforced by CI-grade strict-check and JS-budget gates. Zero-JS-by-default, media-query-free, modular-scale spacing. |
| [`wayback-archive`](plugins/wayback-archive/README.md) | 1.2.0 | Recover product databases from defunct e-commerce sites via Wayback Machine, CommonCrawl, and Shopify CDN archaeology. Self-contained 9-stage pipeline supporting Shopify, Swell Commerce, Fourthwall, and custom platforms. |

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
│   └── wayback-archive/        # Self-contained plugin with its own plugin.json
├── install.sh                  # One-command bootstrap
├── LICENSE
└── README.md
```

Each plugin is self-contained and versioned independently via its own `.claude-plugin/plugin.json`. Adding a new plugin is one commit: drop the plugin directory under `plugins/` and append an entry to `marketplace.json`.

## License

MIT — see [LICENSE](LICENSE).
