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

- `.github/workflows/ci.yml` — runs tests on push to `main` and pull requests targeting `main` (`xcode-27` preview runner)
- `.github/workflows/release.yml` — triggered by `v*` tag push: build on `xcode-27`, sign, notarize, package (DMG + ZIP), create a draft GitHub Release
- `.github/workflows/homebrew.yml` — triggered when a draft is published as a full release (not a pre-release): hashes the published ZIP asset and dispatches the Homebrew cask update
- `.github/workflows/codeql.yml` — analyzes Swift and GitHub Actions on `macos-26`; Swift builds pin Xcode 26.6 because CodeQL traced extraction does not support Xcode 27/macOS 27. Keep source compatible with this analysis toolchain.

## Architecture Overview

Quick Access for Pass is a macOS menu-bar app that provides quick access to Proton Pass secrets via `pass-cli`, plus two optional local authorization proxies:

- **SSH Agent Proxy** — gates SSH key signing behind Touch ID
- **Run Proxy** — gates command execution with secret injection behind Touch ID via the bundled `qa-run` helper

`AppDelegate` is intentionally a thin composition root. Cross-cutting orchestration lives in three main `@MainActor` coordinators:

- `SyncCoordinator` — background sync timer, refresh, cache reset
- `SSHProxyCoordinator` — SSH proxy + daemon lifecycle, vault filtering, health recovery
- `RunProxyCoordinator` — Run proxy lifecycle, secret resolution, auth decisions, health recovery

A separate `HealthCheckCoordinator` owns the probe schedule for Pass CLI, SSH, and Run.

AppDelegate composes one `PassCLISessionMutationGate` for browser login/repair, saved-token login/recovery, and explicit logout. Production initializers must share that gate; do not add independent default gates. First owner wins without queuing; leases are metadata-only, role-validated and held through actual unwind, including cancellation. Compound settings save/remove claims ownership before credential changes and passes its lease to the service/logout entrypoint. Automatic contention must not consume recovery attempts or emit competing presentation. Browser reset requires live health plus full-selection/generation/lease revalidation after consent and before queued cleanup; stale consent starts no alternate operation. Sync forwards typed authentication health. Repair retains PAT/offline data; explicit successful logout alone keeps its existing purge policy.

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

### System AutoFill recent-use presentation

`AutoFillBrokerCoordinator` owns one `@MainActor` `AutoFillRecentPasswordSelection`. Only a complete successful password write at `AutoFillCredentialRelease` records its opaque descriptor ID, exact saved domain, release-guard generation, and two-minute monotonic expiry. Keep the record memory-only and secret-free. Protocol v3 candidates carry a presentation-only `isRecentlyUsed` flag; eligible site TOTP results move only within their original service-match tier. Never use this hint as authorization, hide other accounts, infer login success or browser-tab identity, change global/native-app matching, or modify the system identity store/rankings. Clear it with transient-access revocation; expiry, lock, and generation validity are checked again after awaited candidate lookup.

### SSH Agent Proxy

`SSHAgentProxy` listens on `~/.ssh/quick-access-agent.sock` and proxies to the Pass CLI daemon at `~/.ssh/proton-pass-agent.sock`.

Key behaviors:

1. `REQUEST_IDENTITIES` is forwarded through transparently
2. `SIGN_REQUEST` is intercepted
3. `ProcessIdentifier` resolves the requesting PID, app, host, and BatchMode metadata
4. BatchMode probes are denied by default and handled through `SSHBatchModeNotifier`, with decisions persisted per fingerprint + host
5. `SSHAuthWindowController` applies:
   - a **session cache** (3 seconds, in memory) keyed by app + command/host context + fingerprint
   - a **persistent cache** using the same authorization context
6. Failures feed the shared health/auto-heal path

### Run Proxy

`RunProxy` listens on `~/.local/share/quick-access/run.sock` and authorizes command execution through the bundled `qa-run` helper.

Key behaviors:

1. `qa-run` sends a length-prefixed JSON `RunProxyRequest`
2. `PeerVerifier` rejects unverified peers — only signed apps and the trusted `qa-run` helper are accepted
3. `RunProxyCoordinator` resolves `pass://` URIs through `pass-cli run --env-file ... -- qa-env-export ...`
4. The bundled `qa-env-export` helper writes only approved environment variables to a private FIFO channel, avoiding stdout/stderr masking and local secret persistence
5. Resolved secrets are cached in memory per profile using the profile `cacheDuration`
6. `RunAuthWindowController` authorizes by app identity + scope + profile, defaulting to exact ordered received argv (including executable, flags, values, and argument boundaries). Users may select explicit broader prefixes; existing broad decisions are retained. Exact scope binds neither working directory/environment nor executable contents, and version commands are not automatically approved.
7. Exact matching uses the unchanged full versioned SHA256 identity; persistent Run decisions store the natural full command text only in the encrypted authorization table. Caller-supplied arguments may contain tokens or passwords: document this narrowly authorized persistence and never claim redaction or secret-free command metadata. Never persist resolved profile environment variables, fetched Pass secrets, or offline snapshots as command text; never publicly log arbitrary arguments or full command text. Settings shows the stored command text and localized exact/prefix/unknown type; IDs and matching identity remain independent of display labels.
8. Approvals and denials retain existing durations and the 10-second burst cache even for Do Not Remember. Exact-before-prefix lookup spans session and persistent tiers; session wins only within the same scope. An initial cached denial prevents resolution; queued rechecks prevent release, not earlier resolution or already-released values.
9. Allowed responses return environment variables for client-side injection

## Shared requester presentation

`AppDelegate` composes one `TerminalHostStore` and one `HerdrPaneDetailsProviding` provider, shared by General settings and both proxy coordinators. The store owns filesystem-only Herdr discovery and versioned mapping preferences, retains explicit opt-out/edits, and suppresses automatic Herdr activation on generic canonical-path collisions. Resolver inputs must come from `matchingEntries`, never raw preferences. Identified macOS apps take precedence.

Each actually displayed SSH/Run request owns a `RequesterHeaderModel`; `RequesterHeaderView` shows the base header immediately and starts cancellable, once-only enrichment while mounted. Models subscribe to effective configuration changes even after publication and clear/cancel on change, ordinary decision, queue advance, disappearance, and cancelAll. Header context rows are conditional, with no reserved blank metadata slots; controller-owned fitting resizes preserve panel width and top edge when possible, otherwise remain within the visible screen bounds. Cache-covered requests must not create header models or enrich; Run rejects unverified peers before presentation lookup.

Mappings and Herdr labels/directories are untrusted display-only context. Never replace identity-adjacent fallback fields, bundle/team IDs, SSH showCommand/command/host/key cache identities, or Run subcommand/profile scope with presentation values. A detached trusted helper's Run authorization identifier remains `unknown`. Keep metadata request-scoped, out of persistence/audit logs, and never read pane output, transcripts, or agent session files. Enrichment uses only fixed read-only Herdr commands with requester-owned socket/PID correlation and final revalidation, one absolute 750 ms deadline, 512 KiB per-command output cap, 32-pane scan and four concurrent process-info calls. Missing/ambiguous/disabled/cancelled context falls back without blocking decisions/countdowns.

## Health Checks & Recovery

A shared `ProxyHealthStore` and `PassCLIStatusStore` drive the status rows in Settings and the menu-bar health badge.

- `HealthCheckCoordinator` probes Pass CLI, SSH, and Run every 30 seconds
- SSH health uses `SSHProxyProbe.listIdentities(at:)`
- Run health uses `RunProxyProbe.ping(at:)`
- Pass CLI login/version/identity uses `PassCLISanityCheck`
- Recovery uses `AutoHealStateMachine` with a two-strike policy, 120-second cooldown, and wake-aware behavior
- Wake handling is coordinated via `WakeObserver` / `WakeHandler`

Keep the dependency direction one-way: `HealthCheckCoordinator` owns probe scheduling and dispatches to proxy coordinators; proxy coordinators must not own the health coordinator.

Pass CLI's specific `Error decrypting local session` failure retains a typed `localSessionUnreadable` health state. Saved-PAT recovery handles both direct login decryption failure and confirmed unusable Already authenticated sessions with CLI-owned `logout --force` and one retry. Revoke transient secret access before cleanup and check cancellation before cleanup/retry. Do not treat generic decryption, Keychain access, network errors, or timeouts as cleanup authority; never directly remove CLI files/keys or weaken the key provider. Repeated logged-out/unreadable health ticks may recheck unavailable PATs, but completed automatic attempts remain once per unhealthy episode until `.ok`. Credential presence is a throwing query: only confirmed absence may use the generic browser sign-in notifier. Keychain errors defer without consuming an attempt; saved-PAT timeout/failure/unhealthy outcomes use PAT-specific notification and settled PAT settings presentation, never generic logged-out fallback. Preserve the last settings display state when presence is unavailable; it is not authorization authority.

Browser-only session repair is user-initiated, never a background reset. Route Settings, menu, panel and notification login actions through `requestPassCLILogin()` and `PassCLILoginCoordinator.requestLogin(health:confirmSessionReset:)`. Confirm shared-session impact before bounded CLI-owned cleanup and one browser login; preserve the saved PAT and offline snapshots. Recognize chunked local-session decryption failures with typed login state/result, not a missing-URL message. Do not let a historical login failure override changed health to authorize cleanup. Keep cancellation ownership until the operation unwinds, block duplicate confirmations/resets, and use `isLoggingIn` (not a historical result state) to gate automatic PAT recovery.

## Localization Rules

Use `Quick Access for Pass/Resources/Localizable.xcstrings` as the single English/Czech catalog, compiled separately into both the host and AutoFill extension. Keep both resource memberships; do not duplicate the catalog or read translations from an installed containing app. New generated-resource keys are manual and include translator context and both languages.

Localize interface text at its presentation boundary, including native placeholders, errors, help, accessibility, and announcements. Preserve user-provided titles, usernames, domains, commands, and identity values verbatim; never run arbitrary runtime text through `LocalizedStringKey`. Pass view locale into dynamic formatters and native-control updates. Use catalog plural forms, not English suffix concatenation; test English and Czech counts 0/1/2/5 and exact interpolation-value preservation.

After building, run `scripts/verify-localizations.py` with `--catalog`, `--stringsdata-root`, and `--app` paths from that build, plus its standard-library fixture tests. See `CONTRIBUTING.md` for the full command. The CI gate checks Czech translation readiness, printf identities/types, compiler-extracted key coverage, and compiled `.strings`/`.stringsdict` values in both bundles. Extraction alone misses raw runtime strings, so preserve actual locale/control/formatter and independent-bundle tests. Do not mutate global locale preferences in tests.

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

- **Ordinary database tables do not store fetched Pass item content** — sync may temporarily load full item content from `pass-cli` to derive metadata, and live ordinary actions fetch current values on demand; authorized Offline Mode actions prefer selected usable snapshots without a live probe. The narrow separate exception is caller-supplied Run command text in the encrypted authorization table for readable remembered decisions; such arguments may contain credentials, as documented in `SECURITY.md`.
- **Offline Mode is the only approved persisted-secret exception for fetched Pass item content** — users may explicitly select an individual item or a whole vault (including future items after successful sync); item exclusions and manual selections are retained according to policy. Full snapshots may be stored only in the unified database's encrypted `offlineSnapshots` table, after operation-scoped encryption. Do not write offline secrets to ordinary tables, UserDefaults, logs, diagnostics, UI state, FTS, App Group files, or proxy paths; do not create a second offline database or legacy reader
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

Offline catalog presentation uses a set-based item-metadata projection and an
explicit constant observation region so production `DatabasePool` refreshes can
run off the writer queue. Keep all eleven catalog dependencies covered (items,
vaults, offline selections, whole-vault policies, exclusions, snapshot usability
metadata, folders, ancestor closure, folder memberships, folder policies, and
folder discovery state), including when observation starts empty. Never reintroduce
per-item reads, fetch snapshot payload bytes into presentation, or use displayed
state as release authority. Test pool scheduling with a temporary encrypted pool;
in-memory queue tests cannot verify that optimization. Folder paths/counts/policy
badges and fresh/deferred discovery status are metadata-only presentation, never
admission or release proofs. Preserve the fixed three-read catalog projection and
one set-based metadata read per search batch. Search keeps its existing vault
label and a separate subordinate folder pill; folder names never enter FTS,
ranking, filtering, or SSH scope. Reject stale asynchronous label results after
query/probe/executable changes, and check the shared gate plus the exact load
stamp again when rendering. Omit root/unresolved paths, keep literal names and
full accessible/help paths, and truncate the folder pill before primary text.

Offline Settings uses the same active-CLI 2.5.0+ gate plus committed discovery
stamps for new folder actions. Keep the coordinator async-throwing and localize
fixed errors/announcements at the view locale boundary. Keep main Settings compact:
folder trees live in a bounded native manager sheet, with its footer outside the
scrolling list. Its local folder-name/path filter and Selected only projection
are presentation-only exceptions to the search restrictions above; neither may
alter Quick Access or item-manager matching, row policy fields, or action targets.
Retain ancestor context by stable IDs/depth, not parsed path separators. Checkboxes
apply immediately; closing detaches feedback, not service-owned work. Tree row
bodies consume metadata and callbacks only; inherited-only controls must not write
child intent or revoke ancestors. On unsupported/checking state, keep the manager
available for existing explicit policies, reset filters, hide unselected discovery
rows and expose every explicit selected policy regardless of collapsed branches.
Preserve independent child/manual intent,
ordinary item-manager matching (no folder matching), and removal/purge while
new folder work is unavailable. Paths and policy descriptions remain literal
presentation context, never authority or secret-bearing payloads.

Incremental ordinary sync obtains optional metadata-only capture authority before
fetching full list content; absent/not-ready admission must not fail metadata sync
or be acquired retroactively. Invocation-bound exact 2.1.4, 2.2.3, 2.3.3, 2.4.2,
2.5.1 or 2.7.0 complete JSON is verified for bulk reuse. Other 2.5.0+ releases are
unverified: reuse needs per-vault, per-item-type, per-sync agreement between the
first needed copy's `item view` and its list body (one type never vouches for
another), never a version comparison alone, and
`blockedContentReuseVersions` excludes known-bad releases. Pre-2.5 unlisted,
disagreeing, incomplete or ambiguous content uses sequential needed-copy item reads. See docs/pass-cli.md for
published-release evidence and source-to-binary attestation limits. A vault whose
CLI listing is refused by the share's sensitive-content policy (CLI 2.7.0+) is
isolated: it retains existing items like an unidentified skip, never fails other
vaults' sync, never blocks their membership expansion, and is never deletion
authority. Keep fetched
items in the caller-owned awaited frame, never in service lifecycle registrations
or queued work. Capture registries retain metadata only.
Close admission/revoke persisted captures before joining shutdown frames; reset
purges before that join and clears ordinary metadata only after it. Removal/purge
must not wait for fetch/preparation, subject to existing writer contention.

Writer admission owns sync commit freshness and ordered awaited AutoFill side
effects. Preserve original committed metadata/share proofs, selection/policy and
durable request generations, including completed newer Retry ownership. Publish
sequentially prepared output in batches of at most 32 items / 8 MiB ciphertext,
with one batch plus at most one in-flight prepared result; these limits do not
bound the full fetched list. Earlier commits survive later failure/cancellation.
A usable equal-source snapshot with matching metadata generation skips crypto,
key access and added item views; short-lived capture records still have writes.
Never manufacture a source baseline from catalog dates or secret-body hashes.
Durable item/share/descriptor metadata changes force refresh even at equal source
time, while usage/vault display renames do not. A secret-only same-time change
with unchanged metadata can remain undetected until explicit Retry, which bypasses
unchanged detection. Unchanged copies retain their last successful refresh time;
live fallback stores the actual fetched time. Additive v15 changes no Keychain
policy and performs no offline-content conversion or ordinary-data wipe.

## Database Schema

`DatabaseManager` currently defines **17 migrations**:

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
- **v13**
  - adds `allowed` to SSH and Run remembered decisions so both allow and deny actions can be persisted
  - existing remembered decisions retain allow behavior
- **v14**
  - replaces Run's legacy text key with typed match identity, natural command text, and stable autoincrement row IDs
  - removes only strictly valid old exact-v1 fingerprint-only Run entries; retains broad and malformed literal entries as command-prefix rules
  - persists full received command text in the encrypted decision table; this caller-controlled text may itself contain credentials
- **v15**
  - adds non-secret metadata and durable request generations to `offlineItems`; every explicit reservation advances the request generation, which remains after completion
  - adds nullable actual-payload source time and matching metadata generation to `offlineSnapshots`; publication commits these with ciphertext/status/timestamp, never using a catalog fallback date as the payload baseline
  - adds metadata-only `offlineSyncCaptures`, `offlineSyncCaptureVaults`, and `offlineSyncCaptureItems`; child rows cascade with their capture, not catalog rows, so removal cannot erase prior-admission evidence
  - changes no ordinary metadata/profile/decision rows and does not read snapshot payloads or keys; performs no offline-content conversion
- **v16**
  - adds non-secret `contentRevision` to `offlineSnapshots`, defaulting existing rows to 0; `OfflineSnapshotContentPolicy` defines ordered cumulative content requirements independently per item type, not by app version
  - the codec certifies only the leading requirements satisfied by the actual validated payload; aliases currently require revision 1 (nonblank top-level `alias_email`), all other types require 0
  - already-selected snapshots below their type's requirement can refresh during ordinary sync after unambiguous sufficient-content evidence; equal or newer revisions add no refresh reason. Missing connectivity/login/supporting CLI defers work without manual Retry, a launch job or an app-wide completion flag; revision metadata is not authorization
  - leaves encrypted payload schema 1, AAD, existing ciphertext and Keychain policy unchanged; reads no old payloads/keys and performs no conversion, key access during migration, global forced sync or ordinary-data wipe

- **v17**
  - adds metadata-only `folders`, bounded self-inclusive `folderAncestors`, `folderItemMemberships`, and `folderCatalogState`, keyed by stable vault/folder identity
  - adds explicit recursive policy rows in `offlineFolders` and metadata-only pre-fetch evidence in `offlineSyncCaptureFolders`; capture children cascade only with their capture, not live policies/catalog rows
  - commits validated folder catalog and original item/share proofs in the ordinary metadata transaction. Display renames retain membership generation; structural/membership changes advance it. Failed/unsupported/stale evidence marks expansion deferred without deleting retained folder authority
  - folder additions require a fresh committed observation matching the shared active-CLI 2.5.0+ selection/probe stamp at writer admission; cached release/removal is independent. Sync reprobes only on selection or executable-file identity change (or unreadable identity); an unchanged fresh catalog under the same stamp keeps its observation ID. A failed probe is never cached as a negative version. The connection-local monotonic folder-tracking flag only avoids extra SQL before any catalog exists; it is never authorization and is restored from persisted state on reopen
  - runtime coverage is manual selection, or non-excluded whole-vault/selected-folder ancestry. Removing a parent/vault retains independent child/manual/folder coverage; explicit folder re-selection clears only subtree exclusions. Reconcile moves/deletion in the metadata writer, not presentation
  - bound and pre-bind release constraints accumulate metadata-only coverage removals and hierarchy changes. Permission gains are commit-confirmed and selection-generation-bound; never revive invalid captures or erase other pending revocations. Key gains outside the authority lock and visit only active captures inside it
  - retained folder authority permits cached release/removal, not new folder-only content fetches/publication when discovery is deferred or the gate is unsupported/checking. Independent manual/whole-vault fetch authority remains unchanged
  - explicit selection/materialization/Retry tokens retain metadata-only folder admission captured with reservation: exact catalog observation/membership/stamp plus original covering policy generations. Revalidate this inside the publication writer; never substitute a later discovery or policy promotion. Originally independent manual/vault requests require no folder proof. This is in-memory provenance, not a schema or encrypted-content change
  - sync captures folder policy generations before full-content fetch. New folder members need an originally captured/current policy and the actual invocation's fresh committed observation/membership generation, rechecked at reader planning and writer publication; no retroactive readiness/selection or replacement proof. Existing selected rows retain exact selection/request ownership, including completed newer Retry. Full content remains in the caller-owned awaited frame and the existing bounded publisher
  - the capture item's legacy-named `wasEligibleForVaultSelection` metadata flag covers active/non-excluded eligibility under originally captured vault or folder policies; captured-policy joins still distinguish their ownership. Small fallback/writer rechecks bound both folder and outer item projections, never per-item payload reads or expanded argument logs
  - changes no existing rows, FTS definitions, encrypted payload schema/AAD or Keychain policy during migration; reads no snapshot payloads or keys and performs no conversion, forced sync or ordinary-data wipe

### Offline Mode Documentation Verification Checklist

Before changing Offline Mode documentation, confirm it states all of the following:

- Offline access is opt-in by individual item or whole vault; whole-vault selection covers future items after successful sync, exclusions persist until re-selection, and turning off a vault retains manual selections.
- Full secrets are stored only in the dedicated encrypted `offlineSnapshots` table in the host-only unified database, protected by a device-bound key.
- Authorized usable cached content is preferred without a live request or connectivity probe. Sync refreshes cached values; without a usable cached copy, Quick Access uses Pass CLI.
- Settings lists and removes selected items and can purge all offline data.
- Offline cache data is excluded from SSH and Run proxies.
- Ordinary host copy and Large Type prefer an authorized usable selected snapshot; the only external integration is the existing verified host-broker System AutoFill password/TOTP request. The extension never receives cache access or fallback diagnostics.
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
