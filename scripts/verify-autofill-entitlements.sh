#!/bin/bash
# Verifies the completed, signed host and credential-provider products passed to it.
set -euo pipefail

app_path="${1:-}"
extension_path="${2:-}"
app_group="group.codes.petr.quick-access-for-pass"
keychain_group="H23TXL6LPT.codes.petr.quick-access-for-pass"
credential_provider_entitlement="com.apple.developer.authentication-services.autofill-credential-provider"
obsolete_credential_provider_entitlement="com.apple.developer.authentication-services.credential-provider"
source_keychain_group='$(AppIdentifierPrefix)codes.petr.quick-access-for-pass'

fail() {
    echo "AutoFill entitlement verification failed: $1" >&2
    exit 1
}

has_exactly_one_entitlement_array_value() {
    local entitlements_path="$1"
    local entitlement_key="$2"
    local expected_value="$3"

    [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement_key:0" "$entitlements_path")" == "$expected_value" ]] \
        && ! /usr/libexec/PlistBuddy -c "Print :$entitlement_key:1" "$entitlements_path" > /dev/null 2>&1
}

has_entitlement_key() {
    local entitlements_path="$1"
    local entitlement_key="$2"

    /usr/libexec/PlistBuddy -c "Print :$entitlement_key" "$entitlements_path" > /dev/null 2>&1
}

verify_common_entitlements() {
    local entitlements_path="$1"
    local product_name="$2"

    [[ "$(/usr/libexec/PlistBuddy -c "Print :$credential_provider_entitlement" "$entitlements_path")" == "true" ]] \
        || fail "$product_name credential-provider entitlement"
    has_exactly_one_entitlement_array_value "$entitlements_path" "com.apple.security.application-groups" "$app_group" \
        || fail "$product_name App Group"
    ! has_entitlement_key "$entitlements_path" "$obsolete_credential_provider_entitlement" \
        || fail "$product_name obsolete credential-provider entitlement"
}

verify_source_entitlements() {
    local host_entitlements_path="$1"
    local extension_entitlements_path="$2"

    verify_common_entitlements "$host_entitlements_path" "source host"
    has_exactly_one_entitlement_array_value "$host_entitlements_path" "keychain-access-groups" "$source_keychain_group" \
        || fail "source host Keychain group"

    verify_common_entitlements "$extension_entitlements_path" "source extension"
    ! has_entitlement_key "$extension_entitlements_path" "keychain-access-groups" \
        || fail "source extension Keychain group"
}

if [[ "$app_path" == "--check-source-entitlements" ]]; then
    [[ -n "$extension_path" && -n "${3:-}" ]] || fail "source usage"
    verify_source_entitlements "$extension_path" "$3"
    echo "AutoFill source entitlement verification passed"
    exit 0
fi

[[ -n "$app_path" && -n "$extension_path" ]] || fail "usage"
[[ -d "$app_path" ]] || fail "host product missing"
[[ -d "$extension_path" ]] || fail "extension product missing"

expected_extension_path="$app_path/Contents/PlugIns/$(basename "$extension_path")"
[[ "$extension_path" -ef "$expected_extension_path" ]] || fail "extension is not embedded in host"

codesign --verify --strict "$app_path" || fail "host signature"
codesign --verify --strict "$extension_path" || fail "extension signature"

entitlements_file="$(mktemp)"
trap 'rm -f "$entitlements_file"' EXIT

verify_entitlements() {
    local product_path="$1"
    local product_name="$2"
    local requires_keychain_group="$3"

    codesign -d --entitlements :- "$product_path" > "$entitlements_file" 2>/dev/null \
        || fail "$product_name entitlements"

    verify_common_entitlements "$entitlements_file" "$product_name"

    if [[ "$requires_keychain_group" == "yes" ]]; then
        has_exactly_one_entitlement_array_value "$entitlements_file" "keychain-access-groups" "$keychain_group" \
            || fail "$product_name Keychain group"
    else
        ! has_entitlement_key "$entitlements_file" "keychain-access-groups" \
            || fail "$product_name Keychain group"
    fi
}

verify_entitlements "$app_path" "host" "yes"
verify_entitlements "$extension_path" "extension" "no"
echo "AutoFill entitlement verification passed"
