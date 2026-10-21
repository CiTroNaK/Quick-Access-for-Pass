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

- **Ordinary database tables are metadata-only** — the primary GRDB/SQLCipher database persists search metadata, not secret values outside the dedicated snapshot table
- **Offline persistence is opt-in and single-database** — a user may select an individual item or explicitly select a whole vault, including future items after successful sync. Removing an item under a selected vault excludes it from automatic caching until selected again; turning off a vault preserves individually selected items, and **Keep offline individually** promotes a vault-only copy without refetching. Only selected full snapshots are persisted in `offlineSnapshots`, encrypted before SQLite receives them; there is no second offline database, legacy import, or compatibility reader. On v11 upgrade, prior explicit item copies remain selected individually, while old permission-only vault rows do not become whole-vault consent.
- **Offline snapshot keys are device-bound** — the distinct snapshot-cipher key is stored in the data-protection Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; snapshots are additionally authenticated with their vault, item, revision, and key fingerprint. Snapshot cipher/key use is operation-scoped, SQLCipher passphrase use is connection-lifetime, and row purge deliberately retains keys rather than racing Keychain deletion/rotation
- **Authorized usable cache comes first** — selected snapshots are preferred for supported secret actions, without a live request or connectivity probe. Sync refreshes cached values; without a usable cached copy, Quick Access uses Pass CLI. Settings can list and remove selected items, show stale cache state, or purge all offline data. The snapshot can serve ordinary host copy/Large Type or the existing verified host-broker AutoFill password/TOTP request, never SSH or Run proxy resolution
- **Database encryption is mandatory** — the unified database, including encrypted selected snapshots, uses GRDB/SQLCipher with a Keychain-backed passphrase
- **Backup and deletion limits are explicit** — backup exclusion applies to the entire unified file, including local Run profiles and remembered decisions. Device-bound snapshot keys make offline data non-portable; after committed deletion, bounded out-of-transaction WAL maintenance may reduce active-file remnants, but logical deletion does not claim forensic secure erasure, cryptographic shredding, APFS snapshot removal, or deletion from manual/third-party backups
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

Passwords, TOTP seeds, and generated TOTP codes are not persisted in ordinary metadata tables, the system identity store, App Group files, logs, or launch URLs. The sole exception is an explicitly selected encrypted `offlineSnapshots` record in the host-owned unified database. It is never exposed to the extension and is excluded from SSH and Run proxy resolution. For the existing host-only, verified AutoFill broker boundary, a selected snapshot is preferred for only the requested password or TOTP value when authorized and usable. Without a usable cached copy, the host uses Pass CLI; failures remain generic without cache diagnostics. Values returned to the verified extension are returned once and discarded.

## Offline Storage Lifecycle and Limits

Offline Mode uses one host-only SQLCipher database, outside App Group storage.
Migration v11 adds the dedicated `offlineSnapshots` table and request ownership;
migration v12 adds whole-vault policy generations, manual item-selection state, and
per-item exclusions. It clears legacy permission-only vault rows while preserving
existing individually selected rows and ciphertext; v1–v11 remain intact. Its payloads receive an additional
AES-256-GCM layer with authenticated domain, vault/item, schema, revision, and
key-fingerprint identity. Ordinary tables, FTS, presentation models, diagnostics,
UserDefaults, and proxy paths never persist offline plaintext. Clipboard and
Large Type retain only transient requested action values, not decoded snapshots.

The independent snapshot key is host-only, non-synchronizable, and device-bound.
Encryption/decryption loads it per operation; SQLCipher connections retain their
passphrase for their connection lifetime. Offline Mode keeps the existing app
authorization policy: it adds no mandatory Touch ID, user-presence ACL, Secure
Enclave requirement, or authorization-reuse window. A compromised trusted host
process on an unlocked Mac may still read keys or plaintext. Best-effort temporary
buffer clearing is not guaranteed Swift/compiler/OS memory zeroization.

Manual item selection, whole-vault selection, and refresh reserve metadata-only request tokens. Publication checks
current ownership and identity and atomically commits ciphertext, status, and the
last successful refresh time. Ordinary refresh failure preserves the previous
complete snapshot and timestamp, marked stale. Cancellation before commit can
prevent publication; cancellation after commit cannot undo it. Item removal, whole-vault deselection, and global purge atomically invalidate
applicable selections and pending requests. Whole-vault deselection preserves
manual item selections; item removal under a selected vault records an exclusion.
Corruption cleanup is conditional on the captured revision, so it cannot remove
a newer replacement. Missing, locked, invalid, or mismatched keys and unsupported
formats are non-destructive failures, not permission to reset storage or rekey.

Startup recovers abandoned provisional requests before offline readiness. Recovery
failure disables fallback and new selections until explicit retry succeeds;
live operations, removal, and purge remain usable. Settings/detail state observes
non-secret committed projections, showing selected/usable counts, available,
stale, or unavailable status and last successful refresh timestamps. These are
metadata eligibility indicators, not promises that later key access/decryption
will succeed. Observation failure marks retained display state stale and disables
new selections until a fresh observation succeeds; explicit removal/purge remain
available. Final authorization/revision, lock, generation, and broker-deadline
checks reject obsolete release. Removal cannot retract a value already released. Cached capabilities remain valid only until synchronized final release; invalidation ordered before that release blocks it, while an already-released value cannot be recalled.

The owned database directory is `0700`; the database, known sidecars, and private
preflight copies are `0600`. Owned expected paths are validated before permission
changes. SQLCipher memory sanitization, secure deletion, in-memory temporary
storage, and foreign keys are enabled and checked. Backup exclusion is reapplied
after creation/replacement, including local Run profiles and remembered decisions
in the unified file. These flags guide supported backup software; they cannot
control manual copies, third-party backups, APFS snapshots, or storage-controller
copies. Device-bound keys are not portable backup/restore credentials.

After committed offline deletion, a metadata-only owner requests an
out-of-transaction WAL TRUNCATE checkpoint. Concurrent requests coalesce into
bounded follow-up batches (at most one pending batch while a batch is active); a
request arriving during an active batch is retained for that follow-up. All three
result columns are checked; busy retries at most three total attempts, with two
cooperative 250 ms inter-attempt delays. Errors end that batch without reversing or misreporting deletion or sync.
Startup also checkpoints after recovery. Normal termination cancels and awaits
owned maintenance after joining setup; forced termination may bypass cleanup.
Writer queues, disk I/O, and SQLite busy handling add latency: this is not a hard
wall-clock erasure bound. Keys are retained, so an older copied ciphertext may
remain decryptable on the original host. No secure erase or cryptographic
shredding is promised. No legacy database import, compatibility reader, transfer,
or automatic legacy file/Keychain cleanup was implemented.

Verified host-broker System AutoFill is the only external offline integration;
ordinary authorized host copy and Large Type are also supported. The extension
receives only the requested final password/TOTP value, never storage access,
selection state, or fallback diagnostics. SSH and Run never use snapshots.
AutoFill preserves its original broker deadline and peer verification. The absolute
deadline includes queue time and applies across every native CLI command in one
AutoFill request. An authorized usable selected snapshot resolves without native
CLI work; live/no-cache requests keep the original remaining budget, with no
cache-fallback reserve. Invalidation cannot recall a value
already released to the verified caller. Cancellation, deadline expiry, identity mismatch, and admitted cache authorization
or release failure remain terminal; they do not authorize a live retry. Explicit
key/decode availability failures may select live access only after current
authority checks. TOTP is generated locally from the cached seed and current time,
never from a stored code. Native cleanup uses up to 250 ms SIGTERM grace, then SIGKILL,
nonblocking bounded pipe draining, and exactly-once completion; it is a monotonic
policy bound, not a hard real-time OS guarantee. Secret-facing stdout is capped at
4 MiB plus 4 KiB framing and stderr at 256 KiB; overflow/errors expose no captured
output. Ordinary host actions use the same cache-first resolver and final release guards.

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
