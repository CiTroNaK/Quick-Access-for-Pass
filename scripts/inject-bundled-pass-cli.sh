#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
	echo "usage: $0 /path/to/App.app /path/to/prepared-cli-dir" >&2
	exit 64
fi

APP_PATH="$1"
PREPARED_DIR="$2"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
HELPERS_DIR="$APP_PATH/Contents/Helpers"
APP_ENTITLEMENTS_PATH="$(mktemp)"
trap 'rm -f "$APP_ENTITLEMENTS_PATH"' EXIT

codesign -d --entitlements :- "$APP_PATH" >"$APP_ENTITLEMENTS_PATH" 2>/dev/null

mkdir -p "$HELPERS_DIR"

install -m 755 "$PREPARED_DIR/pass-cli-arm64" "$HELPERS_DIR/pass-cli-arm64"
install -m 755 "$PREPARED_DIR/pass-cli-x86_64" "$HELPERS_DIR/pass-cli-x86_64"

file "$HELPERS_DIR/pass-cli-arm64" | grep -q "arm64"
file "$HELPERS_DIR/pass-cli-x86_64" | grep -q "x86_64"

codesign --force --options runtime --timestamp --generate-entitlement-der --sign "$SIGN_IDENTITY" "$HELPERS_DIR/pass-cli-arm64"
codesign --force --options runtime --timestamp --generate-entitlement-der --sign "$SIGN_IDENTITY" "$HELPERS_DIR/pass-cli-x86_64"

codesign \
	--force \
	--options runtime \
	--timestamp \
	--generate-entitlement-der \
	--entitlements "$APP_ENTITLEMENTS_PATH" \
	--sign "$SIGN_IDENTITY" \
	"$APP_PATH"

codesign --verify --strict --verbose=4 "$HELPERS_DIR/pass-cli-arm64"
codesign --verify --strict --verbose=4 "$HELPERS_DIR/pass-cli-x86_64"
codesign --verify --deep --strict --verbose=4 "$APP_PATH"

if [[ "$(uname -m)" == "arm64" ]]; then
	"$HELPERS_DIR/pass-cli-arm64" --version
else
	"$HELPERS_DIR/pass-cli-x86_64" --version
fi
