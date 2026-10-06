# Contributing to Quick Access for Pass

Thanks for your interest in contributing.

This guide covers contribution workflow and expectations. For agent-specific repository instructions, see [AGENTS.md](AGENTS.md).

## Getting Started

1. Fork the repository and clone your fork
2. Open `Quick Access for Pass.xcodeproj` in Xcode 26+
3. Build and run (`⌘R`) — the app appears as a menu-bar icon

```bash
# Build (Release)
make build

# Build (Debug)
xcodebuild -scheme "Quick Access for Pass" -configuration Debug build

# Run tests
xcodebuild -scheme "Quick Access for Pass" test
```

You do not need `pass-cli` installed to build or run tests. It is only required for runtime functionality.

`make install` bundles the CLI and reuses the built app's signing certificate for both the bundled CLI and the host app. This preserves Xcode's certificate selection and keeps the host signer consistent with its embedded provisioning profile, even when Keychain contains multiple certificates with the same name. Automatic selection uses the certificate fingerprint to avoid encoding issues with accented names. An unsigned or ad-hoc-signed build requires an explicit override. To override selection, use `SIGN_IDENTITY="<certificate fingerprint or signing identity>" make install`; the override must match the host's provisioning profile and remain consistent with the embedded AutoFill extension's signing setup.

## Submitting Changes

1. Create a branch from `main`
2. Make your changes and add or update tests where applicable
3. Update docs when behavior, architecture, setup, or security expectations change
4. Ensure tests pass: `xcodebuild -scheme "Quick Access for Pass" test`
5. Open a pull request against `main`

### PR Title Conventions

We use [Conventional Commits](https://www.conventionalcommits.org/) for PR titles:

| Prefix | Use for |
|---|---|
| `feat:` | New feature |
| `fix:` | Bug fix |
| `docs:` | Documentation only |
| `refactor:` | Code change that neither fixes a bug nor adds a feature |
| `test:` | Adding or updating tests |
| `chore:` | Build process, CI, or tooling changes |
| `perf:` | Performance improvements |
| `security:` | Security hardening |

Example: `feat: add Large Type display for selected values`

## Continuous Integration

Tests run automatically on every PR via GitHub Actions (`macos-26`). CI must pass before merging. It builds and tests without Apple signing secrets.

### Release signing secrets

The tag-triggered release workflow requires these repository secrets:

- `APPLE_CERTIFICATE_P12` and `APPLE_CERTIFICATE_PASSWORD` — the Developer ID Application certificate and its password.
- `APPLE_PROVISIONING_PROFILE` — base64 of the regenerated host Developer ID profile named `Quick Access for Pass - Developer ID`.
- `APPLE_AUTOFILL_PROVISIONING_PROFILE` — base64 of the extension Developer ID profile named `Quick Access AutoFill - Developer ID`.
- `APPLE_TEAM_ID`, `APPLE_ID`, and `APPLE_APP_SPECIFIC_PASSWORD` — existing notarization credentials.
- `HOMEBREW_TAP_TOKEN` — existing Homebrew update token.

Encode each provisioning profile without line wrapping before adding it as a GitHub repository secret:

```bash
base64 < profile.provisionprofile | tr -d '\n'
```

The workflow reads profile names from the installed profiles, maps both bundle IDs during export, and verifies the signed host and embedded AutoFill extension before notarization. `APPLE_PROFILE_NAME` is no longer used.

## Code Guidelines

- **Swift 6 strict concurrency** — use `actor` for shared mutable state, `@MainActor` for UI and orchestration, and `Sendable` models for cross-actor data.
- **Thin composition root** — keep `AppDelegate` focused on wiring; orchestration belongs in `SyncCoordinator`, `SSHProxyCoordinator`, `RunProxyCoordinator`, and `HealthCheckCoordinator`.
- **No secrets on disk** — ordinary database tables store metadata only. Sync may temporarily load full item content from `pass-cli` to derive metadata; selected actions fetch current values on demand. Offline snapshots are the sole persisted-secret exception: users explicitly select individual items or whole vaults; fixtures must cover manual-only authorization without requiring a whole-vault selection, and must keep offline data out of SSH/Run proxies and the extension.
- **Run proxy clients must be verified** — maintain `PeerVerifier` protections; unverified local peers must stay rejected.
- **AutoFill remains IPC-only** — protocol v2 may expose at most 20 in-memory, non-secret candidates to the extension. The host alone owns descriptor and app-association storage, the database, Keychain, Pass CLI, unlock UI, and secret resolution; never add those capabilities to the extension.
- **Tests use Swift Testing** — use `@Suite`, `@Test`, `#expect`, and `#require`, not XCTest.
- **Single external dependency** — [GRDB.swift](https://github.com/groue/GRDB.swift) via Swift Package Manager.
- **Accessibility first** — icon-only buttons need `.accessibilityLabel`, decorative images need `.accessibilityHidden(true)`, selection uses `.accessibilityAddTraits(.isSelected)`, and state changes should announce via `AccessibilityNotification.Announcement`.
- **Keep docs current** — update `README.md`, `SECURITY.md`, and `AGENTS.md` when relevant.

## Project Layout

```text
Quick Access for Pass/
├── Quick Access for Pass/           # Main app target
│   ├── Environment/                # SwiftUI environment plumbing
│   ├── Extensions/                 # Utility extensions and defaults keys
│   ├── Models/                     # Sendable data models
│   ├── Services/                   # Business logic
│   │   ├── Concurrency/            # Small concurrency helpers
│   │   ├── Health/                 # Health probing + auto-heal
│   │   ├── Logging/                # AppLogger
│   │   ├── RunProxy/               # Run proxy subsystem
│   │   ├── SSHAgent/               # SSH agent proxy subsystem
│   │   └── Security/               # Peer verification and related security code
│   ├── ViewModels/                 # UI state and actions
│   └── Views/                      # SwiftUI + AppKit UI
├── qa-run/                         # Bundled CLI helper for Run Proxy
└── Quick Access for Pass Tests/    # Swift Testing suite
```

## Testing Notes

- Use in-memory `DatabaseManager` instances for persistence tests
- Prefer real implementations with controlled inputs over broad mocking
- Add regression tests for migration changes, concurrency fixes, health/recovery logic, and security-sensitive behavior
- If you change SSH or Run proxy behavior, update or add probe/lifecycle tests as needed
- AutoFill tests must use injected fakes or temporary/in-memory fixtures only; never access real credentials, Keychain items, or the real database. Candidate metadata stays capped at 20 and memory-only; test typed global search only after non-empty input and explicit host-local native-app association behavior. Offline AutoFill fallback is host-broker-only; the extension must never receive selection/source/cache diagnostics.
- For an AutoFill release change, complete owner-operated validation on an isolated account with non-production fixtures. Cover Safari and a native app, exact subdomain-before-parent ranking, typed global search, explicit association opt-in and repeat ranking, host unlock, Cancel, unavailable host, and a passkey request that shows password/TOTP picker content rather than a blank panel. Do not inspect or record credential values.

## Documentation

- [README.md](README.md) — user-facing overview and setup
- [SECURITY.md](SECURITY.md) — security reporting and posture
- [AGENTS.md](AGENTS.md) — coding-agent instructions for this repository
