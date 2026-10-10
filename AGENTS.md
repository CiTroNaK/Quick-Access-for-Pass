# AGENTS.md

This file provides guidance to coding agents and other automated contributors working in this repository.

## Build & Test

```bash
# Build (Release)
make build

# Build + install to /Applications + launch
make install

# Build (Debug, for development)
xcodebuild -scheme "Quick Access for Pass" -configuration Debug build

# Run tests
xcodebuild -scheme "Quick Access for Pass" test

# Run a single test suite (Swift Testing)
xcodebuild -scheme "Quick Access for Pass" test -only-testing:"Quick Access for Pass Tests/SearchServiceTests"
```

Tests use Swift Testing (`@Suite`, `@Test`), not XCTest.

## CI

- `.github/workflows/ci.yml` — runs tests on push to `main` and pull requests targeting `main` (`macos-26`)
- `.github/workflows/release.yml` — triggered by `v*` tag push: build, sign, notarize, package (DMG + ZIP), publish GitHub Release, update Homebrew cask

## Architecture Overview

Quick Access for Pass is a macOS menu-bar app that provides quick access to Proton Pass secrets via `pass-cli`, plus two optional local authorization proxies:

- **SSH Agent Proxy** — gates SSH key signing behind Touch ID
- **Run Proxy** — gates command execution with secret injection behind Touch ID via the bundled `qa-run` helper

`AppDelegate` is intentionally a thin composition root. Cross-cutting orchestration lives in three main `@MainActor` coordinators:

- `SyncCoordinator` — background sync timer, refresh, cache reset
- `SSHProxyCoordinator` — SSH proxy + daemon lifecycle, vault filtering, health recovery
- `RunProxyCoordinator` — Run proxy lifecycle, secret resolution, auth decisions, health recovery

A separate `HealthCheckCoordinator` owns the probe schedule for Pass CLI, SSH, and Run.

## Concurrency Model

Swift 6 strict concurrency is enforced throughout. Preserve actor and `@MainActor` boundaries.

- **Actors** for shared mutable state: `PassCLIService`, `SSHAgentProxy`, `SSHAgentDaemonManager`, `RunProxy`
- **`@MainActor`** for UI and orchestration: `AppDelegate`, `QuickAccessViewModel`, `ClipboardManager`, `HotkeyManager`, `SyncCoordinator`, `SSHProxyCoordinator`, `RunProxyCoordinator`, auth window controllers, health stores/coordinator
- **All models are `Sendable`** and intentionally cross actor boundaries as value types
- **`CheckedContinuation`** bridges blocking process/socket work into async/await in `CLIRunner`, `SSHAgentProxy`, and `RunProxy`
- **CLI startup** remains a structured child joined by its caller, but runs on the operation-owned control executor rather than the caller's cooperative pool. The original absolute deadline still includes queued admission
- **`nonisolated(unsafe)`** is used sparingly and should stay justified with comments

If you add shared mutable state, prefer an actor or isolate it to `@MainActor` instead of weakening the model.

## Main Data Flows

### Quick Access panel

1. Global Carbon hotkey → `AppDelegate.togglePanel()` → floating `NSPanel`
2. Search query → debounced in `QuickAccessViewModel`
3. `SearchService` runs encrypted SQLite FTS5 query + usage ranking
4. Selected action fetches secret on demand through `PassCLIService` + `CLIRunner`
5. `ClipboardManager` copies to pasteboard with `org.nspasteboard.ConcealedType` and auto-clear
6. Detail rows can also be shown in **Large Type** through `LargeTypeWindowController`

### SSH Agent Proxy

`SSHAgentProxy` listens on `~/.ssh/quick-access-agent.sock` and proxies to the Pass CLI daemon at `~/.ssh/proton-pass-agent.sock`.

Key behaviors:

1. `REQUEST_IDENTITIES` is forwarded through transparently
2. `SIGN_REQUEST` is intercepted
3. `ProcessIdentifier` resolves the requesting PID, app, host, and BatchMode metadata
4. BatchMode probes are denied by default and handled through `SSHBatchModeNotifier`, with decisions persisted per fingerprint + host
5. `SSHAuthWindowController` applies:
   - a **session cache** (3 seconds, in memory) keyed by app + fingerprint
   - a **persistent cache** keyed by app + command + fingerprint
6. Failures feed the shared health/auto-heal path

### Run Proxy

`RunProxy` listens on `~/.local/share/quick-access/run.sock` and authorizes command execution through the bundled `qa-run` helper.

Key behaviors:

1. `qa-run` sends a length-prefixed JSON `RunProxyRequest`
2. `PeerVerifier` rejects unverified peers — only signed apps and the trusted `qa-run` helper are accepted
3. `RunProxyCoordinator` resolves `pass://` URIs through `pass-cli run --env-file ... -- qa-env-export ...`
4. The bundled `qa-env-export` helper writes only approved environment variables to a private FIFO channel, avoiding stdout/stderr masking and local secret persistence
5. Resolved secrets are cached in memory per profile using the profile `cacheDuration`
6. `RunAuthWindowController` authorizes by app + subcommand + profile
7. Allowed responses return environment variables for client-side injection

## Health Checks & Recovery

A shared `ProxyHealthStore` and `PassCLIStatusStore` drive the status rows in Settings and the menu-bar health badge.

- `HealthCheckCoordinator` probes Pass CLI, SSH, and Run every 30 seconds
- SSH health uses `SSHProxyProbe.listIdentities(at:)`
- Run health uses `RunProxyProbe.ping(at:)`
- Pass CLI login/version/identity uses `PassCLISanityCheck`
- Recovery uses `AutoHealStateMachine` with a two-strike policy, 120-second cooldown, and wake-aware behavior
- Wake handling is coordinated via `WakeObserver` / `WakeHandler`

Keep the dependency direction one-way: `HealthCheckCoordinator` owns probe scheduling and dispatches to proxy coordinators; proxy coordinators must not own the health coordinator.

## Accessibility Rules

Views follow VoiceOver and Voice Control patterns throughout:

- **Icon-only buttons** must have `.accessibilityLabel`
- **Decorative images** next to text must use `.accessibilityHidden(true)`
- **Selection state** uses `.accessibilityAddTraits(.isSelected)`, not label text
- **Async state changes** should post `AccessibilityNotification.Announcement`
- **Focus recovery after auth failure** uses `@AccessibilityFocusState`
- Buttons with visible text should generally not override `.accessibilityLabel`
- Status indicators must not rely on color alone

## Security Invariants

These are core constraints, not implementation details:

- **Ordinary database tables are metadata-only** — sync may temporarily load full item content from `pass-cli` to derive metadata, and ordinary selected actions fetch current values on demand
- **The only approved persisted-secret exception is Offline Mode** — users may explicitly select an individual item or a whole vault (including future items after successful sync); item exclusions and manual selections are retained according to policy. Full snapshots may be stored only in the unified database's encrypted `offlineSnapshots` table, after operation-scoped encryption. Do not write offline secrets to ordinary tables, UserDefaults, logs, diagnostics, UI state, FTS, App Group files, or proxy paths; do not create a second offline database or legacy reader
- **Offline snapshot key material is device-bound** — its distinct snapshot cipher key uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; the cipher/key is operation-scoped while the SQLCipher connection passphrase is connection-lifetime. Purge/removal retains keys; maintenance never reads or deletes them. Offline snapshots must stay excluded from SSH and Run proxies and may serve only ordinary host copy/Large Type actions or the existing verified host-broker System AutoFill password/TOTP request
- **Database encryption** uses GRDB/SQLCipher with a 256-bit passphrase from Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). The unified file and known sidecars are owner-only and backup-excluded, including local Run profiles and remembered decisions; backup exclusion is guidance, not a portable backup/restore or secure-erasure guarantee
- **Socket permissions are strict** (`0600`), and socket directories are owner-only
- **Run proxy peer verification is mandatory** — reject unverified local clients
- **FTS5 queries must remain sanitized** before search execution
- **Clipboard concealment** should be preserved when copying secrets

Offline Mode preserves existing app authorization; do not add mandatory Touch ID,
user-presence ACLs, Secure Enclave gates, or authorization-reuse windows. Reserve
metadata-only request ownership before fetch, publish ciphertext/status/timestamps
atomically, and never reverse an actual commit because of late cancellation.
Startup recovery/readiness and terminal observation failure must leave live
operations and explicit removal/purge usable while new offline selections wait
for explicit retry. The repository owns persisted authority and current selection
proofs; the database-owned release authority owns non-secret invalidation ordering,
and `SecretReleaseGuard` owns the lifecycle check at final release. Test fixtures
may provide catalog mutation setup helpers only in the test target; production
writers must use the repository/database mutation paths. Display only non-secret
committed counts/status/timestamps;
never use stale display state as authorization. Secret-facing native CLI work
must honor the original AutoFill deadline, bounded termination/output, external
cancellation, and final release guards. See `SECURITY.md` for exact limits and
accepted host-compromise, backup, memory-clearing, and already-released-value
risks. No legacy cache import, compatibility reader, transfer, or automatic
file/Keychain cleanup is permitted.

## Database Schema

`DatabaseManager` currently defines **12 migrations**:

- **v1**
  - `vaults`
  - `items`
  - `items_ft` (FTS5)
  - `sshAuthDecisions`
  - `sshBatchModeDecisions` with fingerprint + host keying
- **v2**
  - `runProfiles`
  - `runProfileEnvMappings`
  - `runAuthDecisions`
- **v3**
  - adds `cacheDuration` to `runProfiles`
- **v4**
  - adds `fieldKeysJSON` to `items`
- **v5**
  - clears remembered decisions and adds app identity metadata (`appIdentifier`, `appTeamID`) to remembered decision tables
- **v6**
  - makes `expiresAt` nullable on `sshAuthDecisions` and `runAuthDecisions` (table-rewrite migration) to represent permanent (`Forever`) decisions
- **v7**
  - adds `shareId` to `vaults` so stable `vault_id` can be used as the local identity while current session-specific `share_id` is still available for Pass CLI commands
- **v8**
  - adds non-secret `autoFillDescriptors` with stable opaque IDs and a unique vault/item/service/username identity key
- **v9**
  - adds non-secret `autoFillAppAssociations` for explicit native-app AutoFill associations
- **v10**
  - adds non-secret `offlineVaults` and `offlineItems` catalog tables for explicit Offline Mode selection and cache state
- **v11**
  - adds pending request ownership to `offlineItems` and encrypted `offlineSnapshots` with composite selection identity, strict ciphertext metadata constraints, and cascading selection deletion
- **v12**
  - adds whole-vault policy generations, manual item selection flags and generations, and cascading per-item vault exclusions
  - clears legacy permission-only vault rows without changing existing item selections or encrypted snapshot bytes
  - existing selected items remain individually selected; prior vault permission does not become whole-vault consent

### Offline Mode Documentation Verification Checklist

Before changing Offline Mode documentation, confirm it states all of the following:

- Offline access is opt-in by individual item or whole vault; whole-vault selection covers future items after successful sync, exclusions persist until re-selection, and turning off a vault retains manual selections.
- Full secrets are stored only in the dedicated encrypted `offlineSnapshots` table in the host-only unified database, protected by a device-bound key.
- Cached content is used only when live Pass CLI access is unavailable.
- Settings lists and removes selected items and can purge all offline data.
- Offline cache data is excluded from SSH and Run proxies.
- Ordinary host copy and Large Type may use a selected snapshot only after live access is unavailable; the only external integration is the existing verified host-broker System AutoFill password/TOTP request. The extension never receives cache access or fallback diagnostics.
- Maintenance requests a bounded out-of-transaction WAL checkpoint after committed offline deletion. It reduces active-file remnants but does not promise secure erase, cryptographic shredding, APFS/manual-backup removal, or forced-termination cleanup.

When changing schema:

- add a new migration block
- preserve existing migration history
- update docs/tests that describe the schema
- prefer additive migrations over destructive changes unless explicitly intended

## Project Layout

```text
Quick Access for Pass/
├── AGENTS.md
├── CLAUDE.md
├── CONTRIBUTING.md
├── README.md
├── SECURITY.md
├── docs/
├── Quick Access for Pass/
│   ├── App.swift
│   ├── Environment/
│   ├── Extensions/
│   ├── Models/
│   ├── Resources/
│   ├── Services/
│   │   ├── Concurrency/
│   │   ├── Health/
│   │   ├── Logging/
│   │   ├── RunProxy/
│   │   ├── SSHAgent/
│   │   └── Security/
│   ├── ViewModels/
│   └── Views/
├── Quick Access for Pass Tests/
├── qa-run/
└── qa-env-export/
```

## Development Guidelines

- Keep `AppDelegate` thin; put lifecycle logic into coordinators/services
- Prefer small focused files over expanding mixed-responsibility types
- Match existing naming and file organization patterns
- Use Swift Testing for new tests
- Favor in-memory DB tests for persistence logic
- Preserve strict concurrency correctness; do not paper over isolation errors
- Keep docs in sync when architecture, schema, settings, or security guarantees change

## Documentation Map

- `README.md` — user-facing overview and setup
- `CONTRIBUTING.md` — contribution workflow and contributor expectations
- `SECURITY.md` — vulnerability reporting + security posture summary

If a change affects agent instructions, contributor workflow, user setup, security
posture, or architecture, update the relevant docs in the same change.
