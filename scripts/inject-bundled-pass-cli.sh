#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
	echo "usage: $0 /path/to/App.app /path/to/prepared-cli-dir" >&2
	exit 64
fi

select_signing_identity() {
	if [[ -n "${SIGN_IDENTITY:-}" ]]; then
		printf '%s\n' "$SIGN_IDENTITY"
		return 0
	fi

	# Keep the signer selected by Xcode so the embedded provisioning profiles
	# still authorize the app. Matching certificate names/team IDs is not enough.
	local certificate_prefix="$SIGNING_TEMP_DIR/certificate"
	if ! codesign -d --extract-certificates="$certificate_prefix" "$APP_PATH" 2>/dev/null \
		|| [[ ! -s "${certificate_prefix}0" ]]; then
		cat >&2 <<'ERROR'
Cannot read the built app's signing certificate.

Build with a certificate-backed signing identity, or explicitly override with:
  SIGN_IDENTITY="<certificate fingerprint or signing identity>" make install

The signing identity must match the app's embedded provisioning profile.
ERROR
		return 1
	fi

	# Use the leaf certificate's ASCII fingerprint to avoid accented-name issues.
	shasum -a 1 "${certificate_prefix}0" | awk '{print toupper($1)}'
}

APP_PATH="$1"
PREPARED_DIR="$2"
SIGNING_TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$SIGNING_TEMP_DIR"' EXIT
SIGN_IDENTITY="$(select_signing_identity)"
HELPERS_DIR="$APP_PATH/Contents/Helpers"
RESOURCES_DIR="$APP_PATH/Contents/Resources"
CLI_RESOURCES_DIR="$RESOURCES_DIR/ProtonPassCLI"
APP_ENTITLEMENTS_PATH="$SIGNING_TEMP_DIR/entitlements.plist"

codesign -d --entitlements :- "$APP_PATH" >"$APP_ENTITLEMENTS_PATH" 2>/dev/null

mkdir -p "$HELPERS_DIR" "$CLI_RESOURCES_DIR"
rm -rf "$HELPERS_DIR/ProtonPassCLI" "$CLI_RESOURCES_DIR"
mkdir -p "$CLI_RESOURCES_DIR"

while IFS= read -r -d '' source_file; do
	version="$(basename "$(dirname "$source_file")")"
	name="$(basename "$source_file")"
	target_dir="$CLI_RESOURCES_DIR/$version"
	mkdir -p "$target_dir"
	install -m 755 "$source_file" "$target_dir/$name"

	case "$name" in
	pass-cli-arm64) file "$target_dir/$name" | grep -q "arm64" ;;
	pass-cli-x86_64) file "$target_dir/$name" | grep -q "x86_64" ;;
	*)
		echo "Unexpected helper name: $name" >&2
		exit 65
		;;
	esac

	codesign --force --options runtime --timestamp --generate-entitlement-der --sign "$SIGN_IDENTITY" "$target_dir/$name"
done < <(find "$PREPARED_DIR" -mindepth 2 -maxdepth 2 -type f \( -name 'pass-cli-arm64' -o -name 'pass-cli-x86_64' \) -print0 | sort -z)

codesign \
	--force \
	--options runtime \
	--timestamp \
	--generate-entitlement-der \
	--entitlements "$APP_ENTITLEMENTS_PATH" \
	--sign "$SIGN_IDENTITY" \
	"$APP_PATH"

while IFS= read -r -d '' helper; do
	codesign --verify --strict --verbose=4 "$helper"
done < <(find "$CLI_RESOURCES_DIR" -type f \( -name 'pass-cli-arm64' -o -name 'pass-cli-x86_64' \) -print0 | sort -z)
codesign --verify --deep --strict --verbose=4 "$APP_PATH"

LATEST_VERSION="$(find "$CLI_RESOURCES_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort -V | tail -n 1)"
if [[ "$(uname -m)" == "arm64" ]]; then
	"$CLI_RESOURCES_DIR/$LATEST_VERSION/pass-cli-arm64" --version
else
	"$CLI_RESOURCES_DIR/$LATEST_VERSION/pass-cli-x86_64" --version
fi
