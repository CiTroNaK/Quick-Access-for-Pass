# Security policy

## Reporting a vulnerability

Private reports go through [GitHub Security Advisories](https://github.com/CiTroNaK/Quick-Access-for-Pass/security/advisories/new), not public issues. A useful report includes the affected component, reproduction steps, expected and actual behavior, impact, and a proof of concept or redacted logs.

The acknowledgment target is 48 hours. Reports are investigated and validated with the reporter, with a fix coordinated before public disclosure where appropriate. Coordinated disclosure gives maintainers time to investigate and fix the issue.

## Scope

This policy covers the menu-bar app, search panel, clipboard, Large Type, SSH Agent Proxy, Run Proxy, and bundled helpers. It also covers System AutoFill, peer verification, authorization decisions, database and Keychain access, health checks, recovery, and service lifecycle handling.

The following reports are generally outside scope unless they demonstrate a project-specific security impact:

- Vulnerabilities in Proton Pass or `pass-cli` itself.
- Physical access to an unlocked Mac without a project-specific exploit path.
- Local denial of service without data exposure or a privilege consequence.
- Missing hardening without an exploitable condition.
- Unrelated social engineering, phishing, or third-party account compromise.

## Stored data and local protection

Ordinary database tables contain metadata, not fetched Pass item content. Sync can temporarily hold full CLI items to derive metadata. Live actions fetch current values on demand.

Fetched full secrets can persist only in explicitly selected, encrypted `offlineSnapshots` records in the host-only unified database. Remembered Run command text is a separate exception for caller-supplied arguments, which can themselves contain credentials.

The database uses GRDB and SQLCipher with a 256-bit Keychain-backed passphrase. The passphrase uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and remains available for the connection lifetime.

The owned directory is `0700`. The database, known sidecars, and private preflight copies are `0600`. Expected owned paths are validated before permission changes. SQLCipher memory sanitization, secure deletion, in-memory temporary storage, and foreign keys are enabled and checked.

Local proxy sockets are owner-only. Run rejects unverified clients. AutoFill verifies both connected peers rather than trusting socket permissions alone.

Copied secrets use `org.nspasteboard.ConcealedType` and an automatic-clear timer. These controls reduce clipboard exposure but cannot recall values another process has already read.

## CLI credentials and session recovery

Saved personal access tokens use the data-protection Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. They never enter UserDefaults, SQLite, logs, notifications, or captured CLI output. Login receives the token through the child-process environment, not command-line arguments.

### Saved-token recovery

A confirmed unusable CLI session can trigger `pass-cli logout --force` followed by one saved-token retry. Cleanup is allowed for a confirmed missing remote session or the specific `Error decrypting local session` failure. Generic decryption errors, network errors, timeouts, and Keychain-access errors do not authorize cleanup.

Recovery revokes transient host secret access before cleanup and checks cancellation before cleanup and retry. The saved token remains in Keychain. Quick Access never directly deletes CLI files or keys or weakens the key provider.

Only `errSecItemNotFound` confirms that no token exists. A Keychain error leaves availability unknown, defers recovery without consuming an automatic attempt, and does not trigger browser sign-in notification. Saved-token failures remain token-specific. A completed automatic attempt is not repeated until a healthy CLI session has been observed.

CLI cleanup can affect other clients that share its session configuration. Forced local logout does not revoke the old remote session.

### Browser repair and consent

Background checks do not reset a browser-only session. User-initiated repair for the specific unreadable-session failure explains the shared-client impact and requires confirmation.

After consent, Quick Access revokes transient access, runs bounded CLI-owned cleanup, and starts browser login once. Cleanup failure or cancellation prevents the login. Repair retains the saved token and selected offline snapshots.

Consent is bound to the full diagnosed CLI selection. Health, configuration, generation, lease identity, and cancellation ownership are rechecked after confirmation and before queued cleanup. Stale consent starts neither cleanup nor an alternate login. These checks are not an atomic lock against external CLI clients.

### Authentication ownership

Browser login and repair, saved-token login and recovery, and explicit logout share one `PassCLISessionMutationGate`. The first owner keeps its metadata-only, role-validated lease until actual unwind, including cancellation. Competing operations do not queue.

A busy request does not change credentials or sessions, revoke delivery, or purge offline data. Automatic contention does not consume a recovery attempt or produce competing presentation. Sync forwards typed authentication health, not raw diagnostics.

Only explicit successful logout applies the existing offline-data purge policy. Session repair does not purge snapshots.

## Run Proxy authorization boundary

Run authorization defaults to the complete ordered argument vector received from `qa-run`. Exact scope includes the executable string, flags, values, empty arguments, and argument boundaries. A changed value, order, or grouping does not match that decision.

App identity and profile are separate checks. Exact scope does not bind the working directory, environment, or executable contents. Version commands are not automatically approved.

Users can select broader command-prefix scopes. Existing broad approvals and denials remain valid and can match changed commands. Lookup checks exact scope before prefixes, from narrowest to broadest, across session and persistent decisions. Session takes precedence only within the same scope.

Both approval and denial support the existing durations, including Forever. **Do Not Remember** writes no persistent decision but retains the 10-second in-memory burst cache.

### Stored command text

Exact identity uses `exact-argv-v1` and the full SHA256 digest of the literal ordered arguments. A fingerprint is not encryption or a confidentiality guarantee.

The encrypted authorization table also stores full command text for readable remembered decisions. Caller arguments can contain tokens or passwords. That text is not guaranteed redacted or secret-free.

Resolved profile environment values, fetched Pass secrets, and offline snapshots never become stored command text. Full command text never enters public logs, FTS, UserDefaults, App Group storage, or an unencrypted sidecar. Explicit prefixes retain their literal matching value.

Settings displays the stored text and a localized **Exact command**, **Command prefix**, or **Unknown matching type** label. Typed identity controls matching and uniqueness. Stable row IDs control selection and removal. Display labels do not authorize.

The v14 migration removes strictly valid old exact-v1 fingerprint-only entries because their text cannot be recovered. It retains broad rules and malformed literal entries as prefix decisions. Removing a row does not guarantee a prompt while another broad decision or a live burst-cache entry applies.

### Resolution and release

An initial matching denial prevents secret resolution. A queued request is rechecked before its prompt. A new queued denial prevents environment release but cannot undo earlier resolution or recall released values.

The profile's in-memory resolved-secret cache is separate from authorization decisions. Offline snapshots never serve Run resolution. `qa-env-export` sends only approved environment variables over a private FIFO rather than stdout or stderr. Resolved values are not persisted by that flow.

The [Run Proxy guide](docs/run-proxy.md) covers setup and decision management.

## Terminal-host presentation boundary

**Settings → Integrations** contains shared SSH and Run terminal settings. Filesystem-only discovery does not execute candidates. Generic mappings never launch executables. Identified macOS apps take precedence over mappings.

Herdr is enabled on first detection. Explicit opt-out and edits survive rediscovery and restart. Terminal labels, workspace or tab names, pane titles, and directories are untrusted display context. They never change peer verification, bundle or team identifiers, SSH command, host, or key identity, or Run command and profile scope.

A detached trusted `qa-run` helper keeps authorization identifier `unknown`. Request metadata remains in memory and stays out of persistence and audit logs.

Only matched, enabled Herdr details invoke fixed read-only commands. Routing hints are limited to `HERDR_SOCKET_PATH` and `HERDR_PANE_ID`. Lookup requires a local user-owned socket, bounded requester-side shell-PID correlation, coherent ancestry and start times, and final process, socket, and association revalidation.

Those checks establish point-in-time consistency, not atomic ownership or permission. Inherited application routing is neutralized. Lookup never reads pane output, transcripts, agent session files, or unrelated environment values.

Each displayed eligible request gets one lookup with one absolute 750 ms deadline, a 512 KiB per-command cap, a 32-pane limit, and four concurrent process-info calls. Incomplete, excessive, ambiguous, stale, malformed, cancelled, or slow results produce no details.

Authorization and countdowns do not wait for metadata. Configuration changes and dialog lifecycle events cancel lookup and invalidate late results without changing permission scopes or cache keys.

## System AutoFill boundary

System AutoFill requires macOS 27 or later. The extension advertises passwords and one-time codes, not passkeys. Quick Access never creates, retrieves, stores, signs, or completes passkeys. Proton Pass can remain the passkey provider.

Only the host invokes Pass CLI. The extension sends an opaque descriptor ID and fixed value kind through the broker. Each endpoint verifies the connected socket's audit token and signed identity, pinning the Apple anchor, exact bundle identifier, and certificate Team ID.

A `quickaccesspass://autofill` URL contains only a random expiring wake handle. It can launch the host without activating it but cannot identify a credential or authorize release. The first verified cold-host candidate or resolution request atomically claims the matching handle. Handle-free requests require a warm host or a successful initial bootstrap claim.

The provisioned `group.codes.petr.quick-access-for-pass` App Group contains only the broker socket directory and socket, with `0700` and `0600` permissions. The extension has no database or Keychain Sharing entitlement.

The host alone opens the database and accesses `H23TXL6LPT.codes.petr.quick-access-for-pass` through the data-protection Keychain with `WhenUnlockedThisDeviceOnly` accessibility.

Retrieved passwords, TOTP seeds, and generated codes never persist in ordinary tables, the system identity store, App Group files, logs, or launch URLs. Explicitly selected encrypted offline snapshots are the only persisted exception for fetched AutoFill values.

An authorized, usable snapshot can provide the requested password or TOTP value through the verified broker. Without a usable copy, the host uses Pass CLI. Failures remain generic, without cache diagnostics. The extension receives the requested value once and discards it, never storage access.

### Recent password presentation

Only a complete successful password IPC write records a recent selection. The host retains one record for two minutes in memory, with an opaque descriptor ID, exact saved domain, lifecycle generation, and monotonic expiry.

The record has no password, seed, code, username, or title. Resolution alone and failed or partial writes do not record it. It is neither persisted nor logged.

Protocol v3 uses the record only to flag **Recently used** and reorder matching website TOTP candidates within their existing service tier. Other accounts, global search, native-app matching, identity rankings, resolution, and authorization stay unchanged. The hint proves neither login success nor browser-tab identity.

Transient-access revocation clears the record. Expired, revoked, or locked state cannot produce a preference. The extension holds candidate metadata only for its active picker, with at most 20 non-secret candidates.

## Offline storage lifecycle and limits

Offline Mode uses the host-only unified SQLCipher database outside App Group storage. Full selected snapshots persist only in `offlineSnapshots`, encrypted before SQLite receives them. Ordinary tables, FTS, presentation models, diagnostics, UserDefaults, and proxy paths never persist offline plaintext.

### Consent and storage format

Selection is opt-in by item, whole vault, or recursive folder. Vault and folder policies cover future descendants only after successful authoritative sync. Folder identities are stable and vault-scoped, never paths or display names. Item removal creates an exclusion until re-selection; explicit folder re-selection clears applicable subtree exclusions only. Turning off a vault or parent folder preserves independent child-folder and individual selections. **Keep offline individually** promotes a vault- or folder-derived usable copy without refetching.

Folder discovery, new/expanded folder selection, and folder-only secret refresh require the actively selected Pass CLI at **2.5.0 or newer**, current capability evidence, and fresh invocation-bound committed catalog evidence. Unknown/checking/older executables and incomplete, stale, or failed discovery grant no new folder authority. They do not revoke already authorized cached access, explicit removal, or purge; independent manual/vault consent remains separate. Before-fetch capture generations, membership evidence, original selection/request ownership, bounded publication, and final release guards are revalidated below the UI. Displayed paths, counts, status, and badges never authorize work.

Additive migration v17 adds six metadata-only folder/catalog/policy/capture tables. It does not convert existing selections or secrets, read payloads/keys, modify FTS, or change payload schema, AAD, ciphertext, or Keychain policy. Folder names are literal presentation metadata, not search matching/ranking/filtering or SSH scope.

Migration v11 adds snapshots and request ownership. Migration v12 adds whole-vault generations, manual selection state, and exclusions. It preserves existing item selections and ciphertext without turning prior permission-only vault rows into whole-vault consent.

Migration v15 adds metadata and durable request generations, actual-payload source time, snapshot metadata generation, and metadata-only sync captures. It does not convert content, read payloads or keys, wipe ordinary data, or change Keychain policy.

Migration v16 adds non-secret `contentRevision`, defaulting existing rows to 0. `OfflineSnapshotContentPolicy` defines ordered cumulative requirements per item type. The codec certifies the leading requirements satisfied by the actual identity-validated payload. Publication commits the revision atomically with ciphertext.

Aliases currently require revision 1, a nonblank top-level `alias_email`. Other types require 0. Equal or newer revisions add no refresh reason. Revisions describe freshness, not authorization or application version.

Existing selected aliases refresh during ordinary sync after unambiguous usable email evidence. Connectivity, login, or CLI support can defer work without manual Retry or a global completion switch. Migration performs no conversion or key access and leaves payload schema 1, AAD, ciphertext, and Keychain policy unchanged. It starts no global forced sync.

Snapshots use an additional AES-256-GCM layer authenticated with domain, vault, item, schema, snapshot revision, and key fingerprint. The distinct host-only key is non-synchronizable and device-bound, with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

Key loading and snapshot encryption or decryption are operation-scoped. The SQLCipher passphrase remains connection-scoped. Purge retains snapshot keys.

Offline Mode adds no mandatory Touch ID, user-presence ACL, Secure Enclave requirement, or authorization-reuse window. A compromised trusted process on an unlocked Mac can still read keys or plaintext. Temporary-buffer clearing is best effort, not guaranteed Swift, compiler, or OS zeroization.

### Request ownership and publication

Explicit selection and Retry reserve metadata-only ownership before secret fetches. Ordinary sync instead acquires optional metadata-only capture authority before its list fetch.

Publication rechecks current ownership and identity, then atomically commits ciphertext, status, and the last successful refresh time. Failure preserves the previous complete snapshot and time, marked stale. Cancellation before commit can prevent publication. Late cancellation cannot reverse a committed transaction.

Removal, vault/folder deselection, and purge invalidate applicable selections and requests. Vault and ancestor deselection keep independent child-folder and manual selections. Corruption cleanup is conditional on the captured snapshot revision and cannot delete a newer replacement.

Missing, locked, invalid, or mismatched keys and unsupported formats fail without resetting storage or rekeying.

### Incremental sync admission and freshness

Ordinary sync can acquire capture authority only while Offline Mode is ready with fresh observation, before the list fetch. Missing admission does not fail ordinary metadata sync. Readiness recovered during a fetch cannot retroactively authorize that plaintext.

Terminal observation failure blocks new admission but does not revoke an admitted operation. Publication still rechecks persisted original identity and share, selection, policy, request, and metadata evidence. Display state is never authority.

Writer admission accepts only the current sync. Its committed metadata transaction produces publication proofs and advances each affected selected item's metadata generation once for item, share, or descriptor changes. Usage and vault display-name changes do not dirty snapshots.

Explicit Retry advances a request generation that remains after completion. An older capture cannot regain ownership when a pending token disappears. Metadata reconciliation and AutoFill effects remain ordered through awaited native work. Writer admission decides commit order.

A usable snapshot is unchanged only when its actual successful payload time equals a valid incoming time and its metadata generation matches the selection. Unknown, invalid, older, or different times and dirty metadata require conservative refresh.

Unchanged copies cause no item-view fetch, key lookup, decryption, encoding, encryption, ciphertext write, or successful-refresh-time update. Short-lived capture records still require database writes.

No secret-body hash is persisted. A secret-only change with the same time and unchanged ordinary metadata can remain undetected until explicit **Retry**. Dirty metadata survives failed publication and service recreation. A live fallback records the fetched payload's time, never the catalog time.

Bulk reuse requires invocation-bound recognized complete JSON. Unknown versions, incomplete or ambiguous bodies, and identity mismatches use sequential reads for needed selected copies. The [CLI contract](docs/pass-cli.md#incremental-offline-sync-contract) defines exact-release eligibility.

Preparation is sequential. Each writer batch holds at most 32 items and 8 MiB of ciphertext, plus at most one additional prepared result. These limits do not bound the owning sync's full fetched list or guarantee a hard real-time write limit. Full results remain in the caller-owned awaited frame, not service lifecycle registrations.

Earlier committed batches survive later failure. Still-owned failures retain old ciphertext, source time, and successful refresh time. Failed new vault members create no provisional row and cannot resurrect removed selections.

Removal and purge do not wait for fetch or crypto preparation, though active transactions and writer contention still apply. Stop closes admission and attempts persisted capture revocation before joining active frames.

Unavailable-store metadata cleanup is best effort. Startup abandons orphan captures. Lifecycle checks block new submissions while stop joins frames. Reset purges first, joins frames, then clears ordinary metadata. Scoped removal keeps unrelated admitted work.

Cleanup is awaited and metadata-only. Older cleanup cannot consume a newer owner. Final release guards remain in force, and SSH and Run never use snapshots.

### Readiness and final release

Startup recovers abandoned provisional requests before readiness. Recovery failure disables offline fallback and new selections until explicit retry succeeds. Live access, removal, and purge remain available.

**Settings → Offline** lists copies, supports individual Retry and removal, and can purge all offline data. Committed projections show selected and usable counts, available, stale, or unavailable status, and refresh times. These are metadata indicators, not decryption guarantees.

Observation failure marks retained display state stale and blocks new selections until fresh observation succeeds. Removal and purge remain available.

Final release checks authorization, snapshot revision, lifecycle generation, lock state, and broker deadline. Invalidation ordered before synchronized release blocks the value. An already-released value cannot be recalled.

### Backup and deletion

Backup exclusion is reapplied after database creation or replacement. It covers the entire file, including local Run profiles and remembered decisions. It guides supported backup tools but cannot control manual copies, third-party backups, APFS snapshots, or storage-controller copies. Device-bound keys are not portable restore credentials.

After committed offline deletion, a metadata-only owner requests a WAL TRUNCATE checkpoint outside the transaction. Requests coalesce into bounded follow-up batches, with at most one pending batch while another runs. A request received during a batch remains scheduled for that follow-up.

All three checkpoint result columns are checked. Busy handling allows at most three attempts with two cooperative 250 ms delays. An error ends the batch without reversing deletion or misreporting deletion or sync.

Startup checkpoints after recovery. Normal termination cancels and awaits owned maintenance after setup joins. Forced termination can bypass cleanup. Writer queues, disk I/O, and SQLite busy handling add latency, so this is not a hard wall-clock erasure bound.

Keys remain after deletion. An older ciphertext copy can remain decryptable on the original host. No secure erase, cryptographic shredding, legacy import, compatibility reader, transfer, or automatic legacy file or Keychain cleanup is provided.

### Offline AutoFill and native CLI limits

Authorized host copy and Large Type can use snapshots. Verified host-broker AutoFill is the only external offline integration. The extension receives only the requested password or TOTP value, never storage access, selection state, or fallback diagnostics.

The original AutoFill deadline includes queue time and spans every native CLI command in the request. A usable authorized snapshot resolves without a live request or connectivity probe. Live requests keep the remaining deadline without a separate cache-fallback reserve.

Cancellation, expiry, identity mismatch, and admitted cache-authorization or release failure are terminal. They do not authorize live retry. Explicit key or decode availability failures can select live access only after current authority checks.

TOTP is generated from the cached seed and current time, never a stored code. Native cleanup allows up to 250 ms of SIGTERM grace before SIGKILL, with bounded nonblocking pipe draining and exactly-once completion. This is a monotonic policy limit, not a hard real-time OS guarantee.

Secret-facing stdout is capped at 4 MiB plus 4 KiB framing. Stderr is capped at 256 KiB. Overflow and errors expose no captured output. Ordinary host actions use the same cache-first resolver and final release guards.

## Security-sensitive components

The main components are `PassCLIService`, `CLIRunner`, `DatabaseManager`, Keychain integration, authorization dialogs, and remembered-decision handling. Proxy, AutoFill, and verification code lives under `Quick Access for Pass/Services/SSHAgent/`, `RunProxy/`, `AutoFill/`, and `Security/`.

The [README](README.md#security) gives the user-facing summary. [AGENTS.md](AGENTS.md) records repository rules for contributors and coding agents.
