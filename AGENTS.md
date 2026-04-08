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
3. `RunProxyCoordinator` resolves `pass://` URIs through `pass-cli run --env-file ... -- /usr/bin/env`
4. Resolved secrets are cached in memory per profile using the profile `cacheDuration`
5. `RunAuthWindowController` authorizes by app + subcommand + profile
6. Allowed responses return environment variables for client-side injection

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

- **No secrets in the database** — only metadata is persisted locally
- **Secrets are fetched on demand** from `pass-cli` and kept only in memory
- **Database encryption** uses GRDB/SQLCipher with a 256-bit passphrase from Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
- **Socket permissions are strict** (`0600`), and socket directories are owner-only
- **Run proxy peer verification is mandatory** — reject unverified local clients
- **FTS5 queries must remain sanitized** before search execution
- **Clipboard concealment** should be preserved when copying secrets

## Database Schema

`DatabaseManager` currently defines **6 migrations**:

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
└── qa-run/
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

If a change affects agent instructions, contributor workflow, user setup, security posture, or architecture, update the relevant docs in the same change.
