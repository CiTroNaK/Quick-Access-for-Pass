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

	local identities
	identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

	local developer_id
	developer_id="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)"
	if [[ -n "$developer_id" ]]; then
		printf '%s\n' "$developer_id"
		return 0
	fi

	local apple_development
	apple_development="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)"
	if [[ -n "$apple_development" ]]; then
		printf '%s\n' "$apple_development"
		return 0
	fi

	cat >&2 <<'ERROR'
No suitable code signing identity found.

Install a Developer ID Application or Apple Development certificate, or run:
  SIGN_IDENTITY="Your Signing Identity" make install

Release CI signs with SIGN_IDENTITY="Developer ID Application".
ERROR
	return 1
}

APP_PATH="$1"
PREPARED_DIR="$2"
SIGN_IDENTITY="$(select_signing_identity)"
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
