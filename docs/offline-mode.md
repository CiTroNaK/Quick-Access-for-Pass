# Offline Mode

Offline Mode keeps selected Proton Pass items on this Mac for use without a live CLI request. The app uses its existing authorization policy. Offline selection does not add a mandatory Touch ID, Secure Enclave, or hardware requirement.

## Selection and exclusions

An item becomes selected through **Make available offline**. A vault or recursive folder becomes selected through **Settings → Offline**. A selected vault covers its current items and future items after successful sync; a selected folder covers its subtree, including future descendants after successful complete sync. Folder policies follow stable vault-scoped IDs, not names or paths. Complete authoritative sync reconciles moved-in and moved-out contents.

Removing an item under automatic vault/folder coverage records an exclusion. The exclusion lasts until re-selection; explicit folder re-selection clears only exclusions in that subtree. Turning off a vault or ancestor folder retains independently selected child folders and individual items. Inherited-only checkmarks describe coverage and cannot silently create child intent or disable the covering parent.

**Keep offline individually** changes a vault- or folder-derived usable copy into an individual selection without fetching it again. The v12 migration keeps prior item selections but does not turn old vault permissions into whole-vault consent.

A vault policy does not guarantee that every item has a usable copy. A failed initial individual copy remains selected but unavailable until retry. A failed new vault member stays covered by the vault policy without a provisional item row.

## Supported actions

An authorized, usable selected snapshot serves host copy and Large Type without a live request or connectivity probe. Without a usable copy, Quick Access uses Pass CLI.

The only external integration is a password or TOTP request through the verified System AutoFill host broker. The extension receives the requested value, not cache access, selection state, or fallback diagnostics. TOTP codes are generated from the cached seed and current time, not stored as codes.

SSH and Run proxies never use offline snapshots.

## Refresh behavior

Ordinary sync refreshes selected copies. A failed refresh preserves the previous complete snapshot and its last successful refresh time. An unchanged sync leaves that time unchanged.

Change detection compares the actual payload's modification time and durable metadata generation. Item, share, and AutoFill descriptor changes can require refresh. Usage changes and vault display-name changes do not.

A secret-only upstream change with the same modification time and unchanged metadata can remain undetected. **Retry** forces a refresh of that selected item and bypasses unchanged detection. No persisted hash of the secret body is used.

### Content revisions

`OfflineSnapshotContentPolicy` defines cumulative content requirements separately for each `ItemType`. `offlineSnapshots.contentRevision` records how many consecutive requirements the actual validated payload satisfies.

Aliases currently require revision 1, which means a nonblank top-level `alias_email`. Other types require revision 0. The codec derives the revision from the payload, and publication commits the revision with the ciphertext. A revision is freshness metadata, not authorization or an app-version stamp.

An older selected alias refreshes during ordinary sync once the CLI provides unambiguous usable email evidence, even if the source time is unchanged. Connectivity, login, or CLI support can defer that work. Later syncs resume unfinished items without manual Retry, a separate launch job, or a global completion flag.

A stored revision equal to or greater than its type's requirement adds no content-refresh reason. An insufficient replacement does not complete upgrade-only work.

The v16 migration defaults existing rows to revision 0. It does not decrypt or convert old snapshots, read keys, change AAD or Keychain policy, or change encrypted payload schema 1.

### Folder catalog metadata (v17)

Folder discovery is separate from ordinary item metadata. Additive migration v17 introduces `folders`, self-inclusive `folderAncestors`, `folderItemMemberships`, and `folderCatalogState`, plus explicit policy and pre-fetch policy-evidence tables `offlineFolders` and `offlineSyncCaptureFolders`. These tables contain metadata only, never item bodies, snapshots, or keys. Migration does not convert selections, read existing payloads/keys, modify FTS, or change encrypted payload schema 1, AAD, or Keychain policy.

A complete validated catalog commits with item/AutoFill metadata in the same writer transaction. Stable IDs survive display renames; renames do not change membership generation. Parent/membership changes do. Graph expansion is validated against the [CLI contract and defensive app limits](pass-cli.md#folder-metadata-contract-cli-250) before writer admission; closure rows are produced set-wise, not per search result.

Retained catalog data and admission freshness are separate. Missing, failed, unsupported or stale discovery marks expansion deferred while preserving prior membership and existing authorized cached access. A new folder expansion or folder-only refresh needs a fresh committed observation matching the shared active-CLI 2.5.0+ selection/probe stamp; stored names, status rows, and old version strings cannot grant it. Independent manual/whole-vault work, existing cached release/removal/purge, and ordinary metadata sync remain available. The connection-local folder-tracking flag only avoids extra SQL before any catalog exists; it is restored from persisted catalog state when opening a database and is never authorization.

Before full-content fetch, sync captures the existing supported folder policy generations. New folder members require an originally captured, still-current policy and the actual invocation's fresh committed observation/membership generation. Reader planning and writer publication recheck that evidence. Selecting a folder or restoring readiness after fetch cannot retroactively authorize reuse. Already-selected copies retain their exact selection/request generations instead of weaker folder-member ownership, so a completed newer explicit Retry wins.

Explicit folder selection, materialization, and Retry use the same distinction at their own publication boundary: reservation retains only the original catalog observation, membership generation, active selection/probe stamp, and covering policy generations. The publication writer revalidates that provenance rather than treating retained cached coverage or a newer discovery as permission to write. Originally independent manual/vault requests remain independent. This adds no persisted content, payload format, or Keychain change.

The current effective selection is individual consent or non-excluded whole-vault/selected-folder ancestry. Recursive policies follow stable IDs and cover future descendants only after authoritative sync. Removing a parent or vault preserves independently selected children, folders, and individual items; explicit folder re-selection clears only applicable subtree exclusions. Names and displayed counts never authorize a fetch or release.

Capture policy evidence cascades only with its capture, not a removed live policy. Authoritative folder/vault deletion removes the corresponding live policies; purge clears folder policies too. Committed deletion feeds the same bounded, out-of-transaction maintenance path described below. Full content remains in the caller-owned awaited sync frame and uses the existing sequential preparation and bounded publisher, not a folder queue or lifecycle registry.

## Settings and status

**Settings → Offline** shows compact vault summaries, independent folder-selection counts, selected/usable item counts, and whole-vault controls. **Manage folders…** opens a bounded native sheet for the chosen vault, with a vault picker, scrollable hierarchy, local folder-name/path filter, and **Selected only** (including inherited coverage). The launcher and the manager’s vault picker include only vaults with committed folder rows; folders containing no items still count. Vaults without folders remain listed for whole-vault selection. If the chosen vault loses its last folder while the manager is open, an empty-state placeholder preserves its identity rather than silently selecting another vault. Retained folder metadata remains available under the existing capability/removal rules; this presentation filter never authorizes new work. Matching rows retain their ancestor context; filtering never creates selection intent. **Done** or Escape closes the sheet; checkbox changes apply immediately, and closing does not cancel an already-submitted operation. Longer guidance is available under **How offline access works**.

The folder manager retains expansion controls, independent versus inherited coverage, selected/usable counts, and last-refresh metadata. Empty folders can be selected for future contents. Explicit child-folder policies survive ancestor removal. Item counts are unique within each subtree; overlaps do not double-count an item, and unfinished provisional copies are not reported as committed selections. Folder-policy counts describe independent selections, not numbers of distinct items.

Folder functionality requires the **actively selected Pass CLI 2.5.0 or newer**, verified capability, and a fresh committed discovery for new selections. Failed/incomplete discovery defers expansion instead of pretending the tree is empty. An older, unknown, or checking CLI hides unselected discovery rows and disables new folder work. The manager stays available when explicit policies exist; capability loss clears local filters and exposes all explicit selected rows for removal regardless of previously collapsed branches. Existing authorized copies and purge remain usable. Ordinary manual and whole-vault selection are unchanged.

**Manage offline items…** opens a scrollable list grouped by vault, with literal folder paths when supported, independent/inherited coverage, and individual Keep, Retry, and Remove actions. Its metadata-only search includes ordinary titles, types, vault names, usernames and email metadata, not folder names, fetched alias addresses, or snapshot contents. Ordinary search likewise adds a separate subordinate folder-path label without folder matching, ranking, or filtering; root/unresolved paths are omitted. Item detail shows the same supported metadata as a read-only folder-icon/path line beneath its existing subtitle, without replacing vault context or adding a copy action. Long paths truncate in the middle on one line, with the full literal path available through help and accessibility. Rendering rechecks the current CLI/load stamp and makes no additional CLI request; missing or obsolete paths are omitted. SSH filtering remains vault-only.

Settings also provides **Remove all offline data** to purge all offline selections and cached copies.

The list shows available, stale, or unavailable status and the last successful refresh time. Those values describe committed metadata. They do not authorize release or guarantee that later key access and decryption will succeed.

Startup recovery failure keeps live operations, removal, and purge available but disables offline fallback and new selections until an explicit retry succeeds. Observation failure marks retained display state stale and blocks new selections until fresh observation succeeds. An already admitted sync still revalidates persisted authority before publication.

## Cancellation and removal

Removal and purge invalidate selections and pending requests. Obsolete work cannot recreate a removed selection or replace a newer explicit Retry.

Cancellation before publication can prevent a write. Once the native transaction commits, late cancellation does not undo its ciphertext or revision. Earlier committed batches survive a later failure.

Release checks selection, revision, lifecycle generation, lock state, and any broker deadline. Invalidation ordered before final release blocks the value. Removal cannot recall a value already released.

## Storage and deletion limits

Selected full secrets persist only in the encrypted `offlineSnapshots` table in the host-only SQLCipher database. An additional AES-256-GCM layer uses a separate device-bound Keychain key. The extension cannot open that database or access the key.

The database file also contains local Run profiles and remembered decisions. Backup exclusion applies to the whole file, not just offline data. Device-bound keys do not provide portable backup and restore.

Deletion retains snapshot keys. After committed offline deletion, maintenance requests a bounded WAL checkpoint outside the deletion transaction. That checkpoint can reduce active-file remnants but does not guarantee secure erase, cryptographic shredding, APFS snapshot removal, or removal from manual and third-party backups. Forced termination can bypass cleanup.

The [security policy](../SECURITY.md#offline-storage-lifecycle-and-limits) defines the authority, key, deadline, and maintenance limits. The [CLI reference](pass-cli.md#incremental-offline-sync-contract) describes complete-list reuse and individual-fetch fallback.
