# Proton Pass CLI integration

Quick Access for Pass talks to Proton Pass through Proton's official `pass-cli`. For the simplest setup, install the signed app: it includes the CLI inside the app bundle, so you do not need Homebrew, Terminal setup, or a separate CLI install.

If you manage apps with Homebrew, you can install Quick Access that way and fetch updates through your normal `brew` workflow. Quick Access also supports an already installed Proton Pass CLI for users who want to manage CLI updates themselves.

## Bundled CLI fallback

Signed releases include Proton's official macOS CLI binaries at these paths inside the app bundle:

- `Quick Access for Pass.app/Contents/Helpers/pass-cli-arm64`
- `Quick Access for Pass.app/Contents/Helpers/pass-cli-x86_64`

On first run, if no system CLI is installed, Quick Access uses the bundled helper automatically. You can start login from the notification when it appears, or manually from **Settings → Pass CLI → Log In to Proton Pass CLI…**. With the Quick Access panel open, press `⌘,` to open Settings.

## CLI selection order

Quick Access chooses the CLI executable in this order:

1. A custom path from **Settings → Pass CLI**, if set
2. `/opt/homebrew/bin/pass-cli`
3. `/usr/local/bin/pass-cli`
4. `~/.local/bin/pass-cli`
5. `pass-cli` found on `PATH`
6. The bundled CLI fallback included in signed app releases

A custom path is authoritative. If you enter one, Quick Access uses exactly that executable and does not fall back to a system or bundled CLI if the custom path fails. Clear the field to return to auto-detection and bundled fallback.

## Updating the CLI

The bundled CLI updates only when Quick Access updates. If you want to track Proton Pass CLI releases independently, install `pass-cli` yourself and leave the custom path empty so the system install wins.

## Personal access token support

Quick Access can optionally store a Proton Pass CLI personal access token (PAT) in Keychain from **Settings → Pass CLI**.

When a PAT is saved, Quick Access validates it immediately with `pass-cli login`. Later, if the CLI session is lost, Quick Access uses the saved PAT to recreate the session before asking you to use the normal browser login flow from the notification or **Settings → Pass CLI**.

PAT expiration is managed by Proton Pass. Quick Access cannot discover the expiration date or extend a session created from a PAT. If the token expires or is revoked, replace it in Settings or complete the normal browser login flow from the notification or **Settings → Pass CLI**.

## Provenance

The bundled CLI is not a fork. Quick Access vendors Proton's release binaries under `ThirdParty/ProtonPassCLI/<version>/`, verifies their SHA256 checksums during release preparation, copies them into `Contents/Helpers`, and signs the copied helpers so macOS will run them inside the signed app.

For the current bundled Proton Pass CLI `2.1.4`:

| Architecture | Upstream asset | SHA256 |
| --- | --- | --- |
| Apple Silicon | `pass-cli-macos-aarch64` | `8b579bf452c346da57349a5e72c3839c466e064179b9383f481eefbfa8a65a44` |
| Intel | `pass-cli-macos-x86_64` | `ee0f41d3a1c26022e3f99aff6f2280ec3e0f0e1c443c2c58652c26d3456dc235` |

## Verifying vendored CLI files

You can verify the vendored files match Proton's release assets:

```bash
VERSION=2.1.4
curl -L -o /tmp/pass-cli-macos-aarch64 \
  "https://github.com/protonpass/pass-cli/releases/download/$VERSION/pass-cli-macos-aarch64"
curl -L -o /tmp/pass-cli-macos-x86_64 \
  "https://github.com/protonpass/pass-cli/releases/download/$VERSION/pass-cli-macos-x86_64"

shasum -a 256 /tmp/pass-cli-macos-aarch64 \
  ThirdParty/ProtonPassCLI/$VERSION/pass-cli-arm64
shasum -a 256 /tmp/pass-cli-macos-x86_64 \
  ThirdParty/ProtonPassCLI/$VERSION/pass-cli-x86_64

cmp /tmp/pass-cli-macos-aarch64 ThirdParty/ProtonPassCLI/$VERSION/pass-cli-arm64
cmp /tmp/pass-cli-macos-x86_64 ThirdParty/ProtonPassCLI/$VERSION/pass-cli-x86_64
```

The final app helpers are code-signed during packaging, so their bytes may differ from Proton's raw release downloads because the signature is added for macOS distribution. The verification point is the vendored input plus the packaging scripts: `scripts/prepare-bundled-pass-cli.sh` checksum-verifies the upstream bytes, and `scripts/inject-bundled-pass-cli.sh` only copies those files into the app and code-signs them.

## Related docs

- [README](../README.md)
- [Security policy](../SECURITY.md)
