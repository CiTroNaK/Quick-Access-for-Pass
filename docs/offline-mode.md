# Offline Mode

Offline Mode keeps selected Proton Pass items on this Mac for use without a live CLI request. The app uses its existing authorization policy. Offline selection does not add a mandatory Touch ID, Secure Enclave, or hardware requirement.

## Selection and exclusions

An item becomes selected through **Make available offline**. A vault becomes selected through **Settings → Offline**. A selected vault covers its current items and future items after successful sync.

Removing an item from a selected vault records an exclusion. The exclusion lasts until the item is selected again. Turning off a vault retains items selected individually.

**Keep offline individually** changes a vault-only copy into an individual selection without fetching it again. The v12 migration keeps prior item selections but does not turn old vault permissions into whole-vault consent.

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

## Settings and status

**Settings → Offline** shows selected and usable counts. **Manage offline items…** opens a scrollable list grouped by vault, with metadata-only search and individual Keep, Retry, and Remove actions. Search includes ordinary usernames and email metadata, not fetched alias addresses or snapshot contents.

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
