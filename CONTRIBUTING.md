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

Tests run automatically on every PR via GitHub Actions (`macos-26`). CI must pass before merging.

## Code Guidelines

- **Swift 6 strict concurrency** — use `actor` for shared mutable state, `@MainActor` for UI and orchestration, and `Sendable` models for cross-actor data.
- **Thin composition root** — keep `AppDelegate` focused on wiring; orchestration belongs in `SyncCoordinator`, `SSHProxyCoordinator`, `RunProxyCoordinator`, and `HealthCheckCoordinator`.
- **No secrets on disk** — the database stores metadata only. Sync may temporarily load full item content from `pass-cli` to derive metadata; selected actions fetch current values on demand.
- **Run proxy clients must be verified** — maintain `PeerVerifier` protections; unverified local peers must stay rejected.
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

## Documentation

- [README.md](README.md) — user-facing overview and setup
- [SECURITY.md](SECURITY.md) — security reporting and posture
- [AGENTS.md](AGENTS.md) — coding-agent instructions for this repository
