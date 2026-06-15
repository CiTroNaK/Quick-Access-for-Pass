# Proton Pass CLI 2.1.4

This directory vendors macOS Proton Pass CLI release binaries used as the signed-release bundled fallback for Quick Access for Pass.

- Upstream project: https://github.com/protonpass/pass-cli
- Release: https://github.com/protonpass/pass-cli/releases/tag/2.1.4
- Corresponding source: https://github.com/protonpass/pass-cli/tree/2.1.4
- License: GPL-3.0

## Vendored assets

| File | Upstream asset | SHA256 |
| --- | --- | --- |
| `pass-cli-arm64` | https://github.com/protonpass/pass-cli/releases/download/2.1.4/pass-cli-macos-aarch64 | `8b579bf452c346da57349a5e72c3839c466e064179b9383f481eefbfa8a65a44` |
| `pass-cli-x86_64` | https://github.com/protonpass/pass-cli/releases/download/2.1.4/pass-cli-macos-x86_64 | `ee0f41d3a1c26022e3f99aff6f2280ec3e0f0e1c443c2c58652c26d3456dc235` |

The release preparation script copies these local files, verifies them against `Quick Access for Pass/Resources/proton-pass-cli.json`, and never downloads binaries during release CI.

Quick Access for Pass is not affiliated with or endorsed by Proton AG.
