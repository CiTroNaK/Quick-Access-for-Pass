# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Quick Access for Pass, **please do not open a public issue**.

Instead, report it privately via [GitHub Security Advisories](https://github.com/CiTroNaK/Quick-Access-for-Pass/security/advisories/new).

Please include:
- a clear description of the issue
- steps to reproduce
- affected component or subsystem
- expected vs. actual behavior
- potential impact
- any proof-of-concept details or logs that help reproduce the problem

You should receive an acknowledgment within 48 hours. We will investigate the report, work with you to validate it, and coordinate a fix before public disclosure when appropriate.

## Scope

This policy covers the Quick Access for Pass application, including:

- the main menu-bar app and its handling of secrets, credentials, and biometric authorization
- the Quick Access search panel, detail views, and clipboard flows
- the SSH agent proxy (`SSHAgentProxy`) and Pass CLI daemon integration
- SSH BatchMode notification handling and remembered decisions
- the Run Proxy (`RunProxy`) and the bundled `qa-run` helper
- the macOS 27 System AutoFill credential-provider extension and host broker
- local socket authentication and peer verification (`PeerVerifier` and `AutoFillPeerVerifier`)
- database encryption and Keychain usage
- health checks, recovery logic, and local service lifecycle handling

## Security Posture Summary

Quick Access for Pass is designed around a few core invariants:

- **No secrets in the database** — only metadata is persisted locally
- **Secrets are never persisted locally**; sync may temporarily load full item content from `pass-cli` to derive metadata, and selected actions fetch current values on demand
- **Database encryption is mandatory** — the local cache is encrypted using GRDB/SQLCipher with a Keychain-backed passphrase
- **Optional Proton Pass CLI personal access tokens stay in Keychain** — PATs use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and are never written to UserDefaults, SQLite, logs, notifications, or captured CLI output
- **Local proxies are permission constrained** — sockets are created with strict owner-only permissions
- **Run proxy peers are verified** — unverified local clients are rejected; trusted helper handling is explicit
- **AutoFill IPC is mutually authenticated** — both endpoints bind the connected socket's audit token to a signed-code check that pins the Apple anchor, exact bundle identifier, and certificate Team ID; socket permissions alone are not trusted
- **Authorization is contextual** — remembered decisions are scoped to app identity and command/profile context rather than globally
- **Clipboard exposure is reduced** — copied secrets are marked with `org.nspasteboard.ConcealedType` and auto-cleared on a timer

## System AutoFill Boundary

System AutoFill is available only on macOS 27 and later. The credential-provider extension advertises passwords and one-time codes only; it does not register, retrieve, or sign passkeys. Proton Pass can remain enabled as the passkey provider while Quick Access supplies passwords and current TOTP codes in Safari and compatible native apps.

The main app is the only component that invokes Pass CLI. The extension sends an opaque descriptor ID and a fixed value kind over a dedicated local broker connection. Both endpoints verify the connected peer using the socket audit token and signed-code requirements before processing a request. A `quickaccesspass://autofill` URL contains only a random, expiring wake handle: it can launch the host without activating it, but it never identifies a credential or authorizes a fill. The first verified cold-host candidate-list or direct credential-resolution request must atomically claim the matching handle. Handle-free requests are allowed only to an already-warm host or after that initial bootstrap claim succeeds.

The provisioned `group.codes.petr.quick-access-for-pass` App Group contains only the AutoFill broker socket directory and socket. The directory is owner-only (`0700`) and the socket is owner-only (`0600`). The extension has no database or Keychain Sharing entitlement: it sends only the system identity's opaque descriptor ID and fixed value kind over the verified broker. The host alone opens the local SQLCipher metadata database and accesses its `H23TXL6LPT.codes.petr.quick-access-for-pass` Keychain Sharing group with the data-protection Keychain and `WhenUnlockedThisDeviceOnly` accessibility.

Passwords, TOTP seeds, and generated TOTP codes are not persisted by Quick Access in the database, system identity store, App Group files, logs, or launch URLs. Values are resolved on demand by the host, returned once to the verified extension, and discarded.

## Sensitive Components

The most security-sensitive parts of the codebase are:

- `PassCLIService` and `CLIRunner`
- `DatabaseManager` and Keychain integration
- `Services/SSHAgent/*`
- `Services/RunProxy/*`
- `Services/AutoFill/*`
- `Services/Security/PeerVerifier.swift`
- authorization dialogs and remembered-decision flows

## Out of Scope

The following are generally out of scope unless they directly enable a meaningful security impact in this project:

- issues in Proton Pass itself or `pass-cli`
- problems requiring physical access to an already-unlocked machine without a project-specific exploit path
- local-only denial of service with no data exposure or privilege consequence
- missing best-practice hardening that does not currently create an exploitable condition
- social engineering, phishing, or third-party account compromise unrelated to this codebase

## Disclosure Expectations

Please give us a reasonable opportunity to investigate and fix the issue before public disclosure. Coordinated disclosure is appreciated.

## Additional Documentation

- [README.md](README.md#security) — user-facing security design summary
- [AGENTS.md](AGENTS.md) — repository constraints contributors and coding agents should preserve
