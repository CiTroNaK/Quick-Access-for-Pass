#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/Quick Access for Pass/Resources/proton-pass-cli.json"
OUT_DIR="${1:-$ROOT_DIR/build/bundled-pass-cli}"

mkdir -p "$OUT_DIR"

python3 - "$MANIFEST" "$OUT_DIR" "$ROOT_DIR" <<'PY'
import hashlib
import json
import pathlib
import shutil
import stat
import sys

manifest_path = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(sys.argv[2])
root_dir = pathlib.Path(sys.argv[3])
manifest = json.loads(manifest_path.read_text())
vendored_relative_dir = pathlib.Path("ThirdParty/ProtonPassCLI")
vendored_dir = root_dir / vendored_relative_dir / manifest["version"]

assets = manifest["assets"]
for key in ("macos-aarch64", "macos-x86_64"):
    asset = assets[key]
    source_path = vendored_dir / asset["outputName"]
    expected_sha = asset["sha256"]
    output_path = out_dir / asset["outputName"]
    tmp_path = output_path.with_suffix(".copy")

    if not source_path.is_file():
        raise SystemExit(f"Missing vendored Proton Pass CLI asset: {source_path}")

    actual_sha = hashlib.sha256(source_path.read_bytes()).hexdigest()
    if actual_sha != expected_sha:
        raise SystemExit(
            f"Checksum mismatch for {source_path}\nexpected: {expected_sha}\nactual:   {actual_sha}"
        )

    print(f"Copying {source_path}")
    shutil.copy2(source_path, tmp_path)
    tmp_path.replace(output_path)
    mode = output_path.stat().st_mode
    output_path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(f"Prepared {output_path} ({actual_sha})")
PY
