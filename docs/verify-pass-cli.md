# Verify bundled Pass CLI inputs

Use this guide to compare vendored binaries with Proton's release assets. Run the commands from the repository root. The commands download public release files but do not log in or read a vault.

## Compare upstream and vendored files

1. Set `VERSION` to the release you want to check.
2. Download both macOS assets into a new temporary directory.
3. Compare their checksums and bytes with the vendored inputs.

```bash
VERSION=2.7.0
VERIFY_DIR="$(mktemp -d)"

curl -fL -o "$VERIFY_DIR/pass-cli-macos-aarch64" \
	"https://github.com/protonpass/pass-cli/releases/download/$VERSION/pass-cli-macos-aarch64"
curl -fL -o "$VERIFY_DIR/pass-cli-macos-x86_64" \
	"https://github.com/protonpass/pass-cli/releases/download/$VERSION/pass-cli-macos-x86_64"

shasum -a 256 "$VERIFY_DIR/pass-cli-macos-aarch64" \
	"ThirdParty/ProtonPassCLI/$VERSION/pass-cli-arm64"
shasum -a 256 "$VERIFY_DIR/pass-cli-macos-x86_64" \
	"ThirdParty/ProtonPassCLI/$VERSION/pass-cli-x86_64"

cmp "$VERIFY_DIR/pass-cli-macos-aarch64" \
	"ThirdParty/ProtonPassCLI/$VERSION/pass-cli-arm64"
cmp "$VERIFY_DIR/pass-cli-macos-x86_64" \
	"ThirdParty/ProtonPassCLI/$VERSION/pass-cli-x86_64"
```

Each `shasum` pair must match. Each `cmp` must exit with code 0 and no output. Compare the digest with the [manifest and provenance reference](pass-cli.md#provenance) as well.

Do not compare these raw bytes with a signed helper extracted from the final app. Packaging adds a macOS code signature, which can change the bytes.

`scripts/prepare-bundled-pass-cli.sh` verifies the upstream inputs. `scripts/inject-bundled-pass-cli.sh` copies and signs them during packaging. A matching download establishes release association, not exact correspondence between the public source tag and the binary's embedded commit.

## Regenerate the checksum table

Read the version and checksum entries from the manifest instead of copying a previous release's values:

```bash
python3 - <<'PY'
import json
from pathlib import Path

manifest = json.loads(Path("Quick Access for Pass/Resources/proton-pass-cli.json").read_text())
print("| Version | Architecture | Upstream asset | SHA256 |")
print("| --- | --- | --- | --- |")
for release in reversed(manifest["versions"]):
	for key, architecture, asset in (
		("macos-aarch64", "Apple Silicon", "pass-cli-macos-aarch64"),
		("macos-x86_64", "Intel", "pass-cli-macos-x86_64"),
	):
		digest = release["assets"][key]["sha256"]
		print(f'| {release["version"]} | {architecture} | `{asset}` | `{digest}` |')
PY
```

Update the [CLI reference](pass-cli.md#provenance) with that output after a manifest change. Keep the source-contract evidence separate from binary checksum evidence.
