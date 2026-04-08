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
- local socket authentication and peer verification (`PeerVerifier`)
- database encryption and Keychain usage
- health checks, recovery logic, and local service lifecycle handling

## Security Posture Summary

Quick Access for Pass is designed around a few core invariants:

- **No secrets in the database** — only metadata is persisted locally
- **Secrets are fetched on demand** from `pass-cli` and kept in memory only as long as needed
- **Database encryption is mandatory** — the local cache is encrypted using GRDB/SQLCipher with a Keychain-backed passphrase
- **Local proxies are permission constrained** — sockets are created with strict owner-only permissions
- **Run proxy peers are verified** — unverified local clients are rejected; trusted helper handling is explicit
- **Authorization is contextual** — remembered decisions are scoped to app identity and command/profile context rather than globally
- **Clipboard exposure is reduced** — copied secrets are marked with `org.nspasteboard.ConcealedType` and auto-cleared on a timer

## Sensitive Components

The most security-sensitive parts of the codebase are:

- `PassCLIService` and `CLIRunner`
- `DatabaseManager` and Keychain integration
- `Services/SSHAgent/*`
- `Services/RunProxy/*`
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
