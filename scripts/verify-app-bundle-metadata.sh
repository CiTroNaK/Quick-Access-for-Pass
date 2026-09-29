#!/bin/bash
set -euo pipefail

usage() {
    printf 'Usage: %s APP_BUNDLE [APP_BUNDLE ...]\n' "${0##*/}" >&2
}

(($# >= 1)) || { usage; exit 2; }

for app_bundle in "$@"; do
    plist="$app_bundle/Contents/Info.plist"
    [[ -d "$app_bundle" && -f "$plist" ]] || {
        printf 'App bundle metadata verification failed: missing Info.plist at %s\n' "$plist" >&2
        exit 1
    }

    for key in CFBundleIdentifier CFBundleExecutable; do
        value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
        [[ -n "$value" ]] || {
            printf 'App bundle metadata verification failed: missing %s in %s\n' "$key" "$app_bundle" >&2
            exit 1
        }
    done
done

printf 'App bundle metadata verification passed\n'
