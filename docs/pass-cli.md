# Proton Pass CLI integration

Quick Access uses Proton's official `pass-cli` for live access. Signed releases include the CLI. An installed CLI or a custom executable can take precedence.

The [setup guide](get-started.md) covers installation and first login. This reference describes executable selection, authentication, content contracts, and release provenance.

## Bundled CLI fallback

Bundled executables live at `Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/<version>/pass-cli-arm64` and `pass-cli-x86_64`. The [provenance table](#provenance) lists the bundled versions and architectures. The manifest is `Quick Access for Pass/Resources/proton-pass-cli.json`.

The newest bundled version is both the recommended version and the Auto fallback. Older versions remain selectable for temporary rollback. With no installed CLI, Auto selects the bundled fallback.

A missing login session produces **Login** in the panel's sync-status area. Other sync failures and skipped items produce **Show sync errors**, which opens a separate diagnostics window. Search remains available.

## CLI selection order

The selected **Pass CLI source** determines the executable:

| Source | Selection and fallback |
| --- | --- |
| **Auto (recommended)** | Installed candidates first, then `bundled:latest`. |
| **Installed path** | The selected discovered path. If missing, selection falls back through Auto. |
| **Bundled latest** | The newest bundled CLI. |
| **Bundled version** | The pinned version. If missing after an update, selection falls back to bundled latest. |
| **Custom path** | The exact entered path, with no fallback. |

Installed candidates are discovered from `/opt/homebrew/bin/pass-cli`, `/usr/local/bin/pass-cli`, `~/.local/bin/pass-cli`, and `pass-cli` found on `PATH`.

A failing custom executable does not trigger fallback. Auto-detection resumes when the source returns to Auto.

Quick Access checks authenticated Pass CLI health with `pass-cli info --output json`. This command works in all bundled versions and replaces `pass-cli test`, which Proton removed in version 2.2.4. A separate `pass-cli --version` probe supplies version and compatibility metadata.

## Alias email copying

**Copy Alias** copies the optional top-level `alias_email` from `item view --output json`, with surrounding whitespace removed. It requires Pass CLI 2.4.0 or later, with no upper-version cutoff, as long as that release retains the field.

Missing, null, or blank email produces **Alias email is unavailable.** The action leaves the clipboard and panel unchanged. Nested `Alias.email`, item titles, and other items' addresses are never fallbacks.

The field is present in the published [2.4.0 item model](https://github.com/protonpass/pass-cli/blob/c479bd41a2b3ffc0126eb9c5f304eddd59a3e412/pass-domain/src/models/item/mod.rs) and [2.5.0 item model](https://github.com/protonpass/pass-cli/blob/b4a7ebea6c1d97c729ea69b9aeca01165215e597/pass/src/domain/models/item/mod.rs), and their item-opening paths populate it. This capability check is separate from the exact-release full-list bulk-reuse contract below.

Alias addresses are secret-facing content. They never enter ordinary metadata, search indexes, or list subtitles. Opt-in Offline Mode can retain them only inside encrypted snapshots under the existing authorization and release rules.

Older selected aliases refresh during ordinary sync once unambiguous usable email evidence is available. Login, connectivity, or CLI support can defer that work. Later syncs resume unfinished items without manual Retry or global forced sync.

Migration v16 stores non-secret `contentRevision`, defaulting existing rows to 0. `OfflineSnapshotContentPolicy` defines cumulative requirements per type. Aliases require revision 1, and other types currently require 0. The codec certifies the actual validated payload, and publication commits that revision with ciphertext.

Equal or newer revisions add no content-refresh reason. Revision metadata never grants authorization. Migration does not convert payloads, access keys, change Keychain policy, or change encrypted payload schema 1. No separate launch job or global completion switch exists. Clipboard concealment and auto-clear behavior are unchanged.

The [Offline Mode reference](offline-mode.md#content-revisions) describes refresh and failure behavior.

## CLI updates

Bundled versions change with app updates. A separately installed CLI follows its own update schedule and takes precedence under **Auto (recommended)**.

## Recommended version warning

Quick Access treats the newest bundled CLI as the recommended version. If the active installed, custom, or pinned bundled CLI reports a version older than the newest bundled version, Quick Access shows a warning in Settings, marks the menu-bar icon with a warning badge, and sends one startup notification.

The warning is advisory. Quick Access does not switch CLIs automatically because doing so could hide version-specific bugs or change the session unexpectedly.

Older bundled versions are available in **Settings → Pass CLI**. The [troubleshooting guide](troubleshooting.md) covers diagnosis and safe reports.

## Personal access token support

Quick Access can optionally store a Proton Pass CLI personal access token (PAT) in Keychain from **Settings → Pass CLI**.

Saving a PAT immediately validates it with `pass-cli login`. If the session is later lost, Quick Access attempts recovery with the saved token. Authentication failure during sync, including **⌘R**, requests recovery without waiting for the next health check.

A failed or timed-out token attempt offers **Update PAT** and clears the progress indicator. It does not also post **Proton Pass CLI is logged out** or request browser login. Browser login remains an explicit option in Settings. A failure does not by itself mean the token expired.

Only confirmed token absence permits the generic sign-in notification. Unavailable Keychain access, including while locked, leaves token presence unknown and consumes no automatic attempt. Logged-out or unreadable-session health checks recheck availability, normally every 30 seconds. A completed automatic attempt is not repeated until a healthy session has been observed.

The specific **Error decrypting local session** failure appears as **Local CLI session could not be decrypted**, including when detected during sync. It can authorize CLI-owned cleanup and one saved-token retry. **Already authenticated** can also lead to cleanup if an authenticated probe confirms a missing remote session or that specific decryption failure.

Cleanup uses `pass-cli logout --force`. It never follows a healthy probe, timeout, network error, generic decryption error, or Keychain-access failure. Quick Access revokes transient secret access first and checks cancellation before cleanup and retry.

The PAT remains in Keychain and reaches login only through the child-process environment, never command-line arguments. Quick Access does not directly delete CLI files or keys or weaken the key provider.

Local session cleanup can affect other clients sharing the configuration. It does not revoke the old remote session, which can remain listed in Proton account settings. Proton documents [logout behavior](https://protonpass.github.io/pass-cli/commands/logout/) and [session configuration](https://protonpass.github.io/pass-cli/get-started/configuration/). Recovery does not guarantee that a session or key mismatch cannot recur.

Proton Pass controls PAT expiry. Quick Access cannot read that expiry or extend the session. An expired or revoked token needs replacement or explicit browser login.

## Browser-only session repair

Without a saved PAT, background checks never silently reset the session. For **Error decrypting local session**, Settings and the menu offer **Reset CLI Session and Log In…**. Panel and notification login actions use the same confirmation flow.

The prompt explains the impact on other clients and the retained remote session. **Cancel** does no cleanup. After confirmation, Quick Access revokes transient access, runs bounded `pass-cli logout --force`, and starts browser login once with the same executable.

Cleanup failure or cancellation prevents login. A failed restarted login does not trigger another reset. Saved credentials and offline snapshots remain intact. Quick Access never directly deletes CLI files or keys. An unreadable-session failure before a browser URL appears is reported as that failure, not a missing-URL error.

### Authentication ownership and fresh consent

`PassCLISessionMutationGate` gives browser login and repair, saved-token login and recovery, and explicit logout one owner without queuing. A competing manual request reports **Sign-in already in progress.** It starts no extra confirmation, login, or logout, and Settings cannot replace or remove the token.

Automatic contention defers without consuming the completed-attempt allowance or showing another prompt. Recovery rechecks health after looking up token availability. Cancellation retains ownership until actual unwind.

Reset consent belongs to the full diagnosed CLI selection. Health, selection, generation, lease identity, and cancellation ownership are revalidated after consent and before queued cleanup. Changed authority abandons the request without revocation, cleanup, or alternate login.

Admitted cleanup and subsequent login stay bound to the same executable. These observed-state checks do not lock out external CLI clients.

Explicit logout is separate from repair. Only successful CLI logout triggers its offline purge. A busy logout neither revokes access nor purges data.

## Incremental offline sync contract

Ordinary sync fetches full CLI items to derive search and AutoFill metadata. Optional metadata-only offline admission must precede that fetch. Missing admission does not fail metadata sync, and readiness recovered during a fetch cannot authorize already-fetched plaintext.

The current writer transaction produces original metadata and share proofs. Publication rechecks captured selection, exclusions, durable request generations, and current metadata evidence. UI state never authorizes publication.

Bulk reuse is **verified** for exact releases **2.1.4, 2.2.3, 2.3.3, 2.4.2, 2.5.1, and 2.7.0**. It requires invocation-bound executable and version evidence plus raw complete-JSON validation through `completeJSONV1`.

Other releases **2.5.0 or newer** are **unverified** (`unverifiedCompleteJSON`), so a new CLI release works without an app update. Their list bodies pass the same raw shape validation, but a version comparison alone never permits reuse. In each sync, the first selected copy that needs content in a vault is read with authoritative `item view` and compared with its list body (canonical encoding of every field the snapshot codec persists). Only on agreement does the rest of that vault reuse list bodies for that sync; disagreement, a failed view, or a missing body keeps that vault on sequential `item view` reads. The checked copy publishes the `item view` result, so the check adds no extra read. Evidence never outlives the sync. A release found to return well-formed but wrong list content can be excluded in `PassCLICapabilities.blockedContentReuseVersions`. This check cannot detect a release that alters `item view` and the list identically; ordinary copy would show the same values.

Incomplete or ambiguous bodies and identity mismatches fall back to sequential `item view` reads for needed selected copies. Unselected bodies contribute to ordinary metadata derivation but are not encrypted or persisted as snapshots. The full fetched list remains in the owning sync's awaited frame.

The contract uses published release evidence, not reproducible-build or exact source-to-binary attestation. For 2.4.2, checksum-matching binaries report embedded commit `ef5f645`, while the public tag resolves to `7ae51e5`. Exact source correspondence is unproven. The checksums establish release association only.

### Pass CLI 2.7.0 contract validation

The 2.7.0 allowlist entry uses the same published-release contract standard, not a source-to-binary attestation. Both checksum-matching macOS binaries are signed by Proton AG (team `2SB5Z68H26`) and report `Proton Pass CLI 2.7.0 (ba80a19)`. The embedded commit was not resolvable through the public commit API during validation. Exact source correspondence is unproven. No authenticated vault content was fetched for this validation.

Published-source evidence, compared against 2.5.1:

- The [JSON list branch](https://github.com/protonpass/pass-cli/blob/2.7.0/pass-cli/src/commands/item/list.rs) still serializes full `ItemsList { items }` under `--show-secrets`. The previously internal-only top-level `folders` enrichment (`folder_id`, `folder_name`, `parent_id`) is now public. Quick Access ignores it; it is **not** the folder discovery contract below.
- The item model crate pin and the [item envelope](https://github.com/protonpass/pass-cli/blob/2.7.0/pass/src/domain/models/item/mod.rs) are unchanged apart from a new extra-field module used by item creation. The item-opening path changed only in tests.
- The [pagination rewrite](https://github.com/protonpass/pass-cli/blob/2.7.0/pass/src/item/list.rs) adds an incremental per-process page cache. `list_items` starts each CLI process with an empty cache, visits every page until a short page, de-duplicates by item ID and propagates page-fetch errors. Undecryptable items can still be omitted, as before.
- New share policy: when a shared vault has Proton's **hide sensitive content** flag, `item list --show-secrets` and `item view` fail with `Viewing the contents of this item is not allowed by policy`. The CLI does not enforce it for `item totp`, `run`/`inject` references or `ssh-agent`.

Sync isolates such a vault: other vaults sync normally, the restricted vault's existing items and offline copies are retained like an unidentified skipped item, and the sync status names the vault. Password copy shows **The owner of this vault doesn't allow viewing its passwords.** The restriction is never deletion or authorization evidence.

### Pass CLI 2.5.1 contract validation

The 2.5.1 allowlist entry uses the same published-release contract standard, not a source-to-binary attestation. Both checksum-matching macOS binaries report `Proton Pass CLI 2.5.1 (84186e7)`, while the public release tag resolves to [`5d0cfbf8b7875550ce2494dd322032c34a3a6a72`](https://github.com/protonpass/pass-cli/commit/5d0cfbf8b7875550ce2494dd322032c34a3a6a72). The embedded commit was unavailable through the public source URL during validation. Exact source correspondence is unproven. No authenticated vault content was fetched for this validation.

Published-source evidence:

- The [JSON list branch](https://github.com/protonpass/pass-cli/blob/5d0cfbf8b7875550ce2494dd322032c34a3a6a72/pass-cli/src/commands/item/list.rs) serializes `ItemsList { items }` directly when `--show-secrets` is set, rather than `ItemSummary`. The bundled binaries' `item list --help` also advertise full JSON content with that flag. Agent sessions reject it rather than silently returning a redacted success.
- The [item envelope](https://github.com/protonpass/pass-cli/blob/5d0cfbf8b7875550ce2494dd322032c34a3a6a72/pass/src/domain/models/item/mod.rs) and [decryption path](https://github.com/protonpass/pass-cli/blob/5d0cfbf8b7875550ce2494dd322032c34a3a6a72/pass/src/item/open.rs) match the published 2.4.2 source. Both release lockfiles pin `proton-pass-types` 2.1.1 at commit `25b673b98ed84982e74a1fbcdf036ebd7957950f`. Serialization adds no summary or masking layer.
- The [pagination refactor](https://github.com/protonpass/pass-cli/blob/5d0cfbf8b7875550ce2494dd322032c34a3a6a72/pass/src/item/list.rs) calls `scan_items` with an always-continue visitor for `list_items`, accumulates opened items across pages and propagates page-fetch failures. Early-exit search is a separate caller. This does not establish that every remote item can be decrypted: the existing opening path can omit failed items, unchanged from 2.4.2. Completeness here is evidence for returned item bodies, not a remote-vault enumeration guarantee.
- Version 2.5.1 additionally [marks listed secrets as read](https://github.com/protonpass/pass-cli/blob/5d0cfbf8b7875550ce2494dd322032c34a3a6a72/pass-cli/src/commands/item/list.rs) before JSON serialization. Ordinary full-list sync already uses this flag independently of offline selection. Reuse adds no list invocation and does not suppress that upstream effect.

### Older bundled release validation

The same published-release contract review covers the older bundled releases. Both architectures' vendored inputs match their manifest checksums and GitHub release asset digests. Their `--version` output and published tag commits differ, so this remains release association and contract evidence, not reproducible-build or exact source-to-binary attestation. The embedded commits were not resolvable through the public commit API during this review. No authenticated vault content was fetched.

| Version | Embedded commit (both macOS binaries) | Published tag commit |
| --- | --- | --- |
| 2.3.3 | `0d7235d` | [`0e8f993421f387a969f8888f60c82bacf265d73b`](https://github.com/protonpass/pass-cli/commit/0e8f993421f387a969f8888f60c82bacf265d73b) |
| 2.2.3 | `38ff599` | [`2407e8d0a24760f53c38072bb104518c708f3e54`](https://github.com/protonpass/pass-cli/commit/2407e8d0a24760f53c38072bb104518c708f3e54) |
| 2.1.4 | `d13561a` | [`eb1408242292aa25a3cdc95808ceba3ffa668ba4`](https://github.com/protonpass/pass-cli/commit/eb1408242292aa25a3cdc95808ceba3ffa668ba4) |

- The full-JSON list branches in [2.3.3](https://github.com/protonpass/pass-cli/blob/0e8f993421f387a969f8888f60c82bacf265d73b/pass-cli/src/commands/item/list.rs), [2.2.3](https://github.com/protonpass/pass-cli/blob/2407e8d0a24760f53c38072bb104518c708f3e54/pass-cli/src/commands/item/list.rs) and [2.1.4](https://github.com/protonpass/pass-cli/blob/eb1408242292aa25a3cdc95808ceba3ffa668ba4/pass-cli/src/commands/item/list.rs) serialize the full `ItemsList { items }` directly under `--show-secrets`, with the same JSON-only and agent-session restrictions as 2.4.2. Both bundled architectures advertise this behavior in `item list --help`.
- Their `pass-domain/src/models/item/mod.rs` models use derived Serde serialization for the item envelope, `ItemData`, and supported content variants. They include modeled login passwords, TOTP, notes, extra fields, and custom sections. They lack the newer unmodeled `custom_icon` and `autofill_urls` fields and optional `alias_email`. Those omissions do not relax shape validation or permit invented alias addresses. The 2.2.3 and 2.3.3 models are identical. The 2.1.4 differences affect timestamp mutation and tests, not serialized fields.
- Their `pass/src/item/list.rs` paths fetch every page before returning opened items, with the same pagination termination/error behavior as 2.4.2. Their vault-opening paths differ only in the absent newer `alias_email` envelope field. Undecryptable items can still be omitted. Complete remote-vault enumeration is not guaranteed.

Regression coverage checks exact-version admission for every allowlisted release, unverified classification of neighbouring 2.5.0+ releases, agreement-gated reuse after one item view, and full fallback on disagreement. It also checks per-vault incomplete-body fallback, selected-copy publication without extra views, and unchanged sync after explicit Retry. A synthetic older-login fixture checks full modeled password/TOTP and Unicode-value preservation without newer optional fields. Raw shape validation, invocation binding, capture authority and final publication guards remain mandatory.

### Snapshot freshness and lifecycle

Unchanged detection needs a usable snapshot with an actual successful payload time equal to the incoming valid time and a matching metadata generation. Unknown, invalid, older, or different times and changed item, share, or descriptor metadata require conservative refresh. Dirty metadata survives failed publication and service recreation. Usage and vault display-name changes do not dirty snapshots.

Live fallback records the actual fetched time. An unchanged sync adds no item view, key lookup, encoding, encryption, ciphertext write, or refresh-time update. Short-lived capture rows still require writes. **Retry** bypasses unchanged detection. Without a persisted secret-body hash, same-time secret-only changes with unchanged metadata can remain undetected.

Preparation is sequential. A writer batch holds at most 32 items and 8 MiB of ciphertext, plus at most one prepared result outside the batch. Earlier commits survive later failure or cancellation. These limits do not bound the full list or guarantee hard real-time writes.

The caller awaits consumption and metadata-only cleanup. Shutdown closes admission, attempts persisted capture revocation, and joins active frames. Startup recovers unavailable-store metadata cleanup. Reset purges, joins frames, then clears ordinary metadata. Removal and purge do not wait for fetch or crypto preparation, though writer contention still applies.

Offline access is opt-in by item, whole vault, or recursive folder, including future descendants after successful complete sync. Exclusions persist until re-selection; turning off a vault or ancestor folder retains independent child-folder and manual selections. Full secrets persist only in encrypted `offlineSnapshots` in the host-only database, protected by a separate device-bound key.

Authorized usable copies serve host copy and Large Type without live requests or connectivity probes. Otherwise, Quick Access uses Pass CLI. Verified host-broker password and TOTP requests are the only external offline integration. The extension receives no cache access or fallback diagnostics. SSH and Run never use snapshots.

**Settings → Offline** lists copies and supports individual Retry, removal, and full purge. Bounded post-deletion WAL checkpoints run outside the transaction. They do not guarantee secure erase, cryptographic shredding, APFS snapshot removal, manual-backup removal, or forced-termination cleanup. The [offline security reference](../SECURITY.md#offline-storage-lifecycle-and-limits) defines those limits.

## Folder metadata contract (CLI 2.5.0+)

Folder discovery requires invocation-bound version evidence for the **actively selected executable at 2.5.0 or newer**. A pending, unrecognized or older version does not permit folder commands. The capability probe precedes optional offline capture; discovering support later does not retroactively authorize a fetch. Sync reprobes `--version` (30-second limit) only when the selection changes or the selected file's identity (resolved path, inode, size, modification date) changes or cannot be read; an unchanged executable keeps its confirmed stamp, so routine syncs do not interrupt folder admission. Selection changes and superseding probes invalidate the earlier stamp, including replacement at the same path. A failed or timed-out probe reports folders as unavailable without caching a negative version, so the next command probes again.

The same gate controls separate search-result folder labels and new recursive Offline settings. No folder-name matching, ranking, filtering, or SSH scope is added. Downgrade or unknown/checking support disables discovery and new/expanded folder-only work, not existing authorized cached release, explicit deselection/removal, or purge. Settings discovery readiness also requires the committed catalog stamp; a verified version alone cannot revive stale discovery.

Published [2.5.0 folder-list source](https://github.com/protonpass/pass-cli/blob/2.5.0/pass-cli/src/commands/folder/list.rs) and [2.5.1 folder-list source](https://github.com/protonpass/pass-cli/blob/2.5.1/pass-cli/src/commands/folder/list.rs) serialize a top-level array. `folder list --share-id=… --output json`, **without `--parent-id`**, provides the separate folder catalog. The [folder model](https://github.com/protonpass/pass-cli/blob/2.5.1/pass/src/domain/models/folder.rs) has this synthetic shape:

```json
[{"id":"folder-id","share_id":"share-id","parent_folder_id":null,"content":{"name":"Example folder"}}]
```

Both tags use the same fields; the root parent is explicitly null. The [2.5.0 item model](https://github.com/protonpass/pass-cli/blob/2.5.0/pass/src/domain/models/item/mod.rs) and [2.5.1 item model](https://github.com/protonpass/pass-cli/blob/2.5.1/pass/src/domain/models/item/mod.rs) declare `folder_id` with Serde `default` and omission when `None`. Omission/null therefore denotes root in this proven active-item response. Missing response/identity/state evidence, malformed IDs, duplicate identities, skipped items, cross-share references, dangling membership, orphan parents and cycles are not authoritative empty/root results. Folder membership is projected separately from the already fetched item list; no extra full-secret item-list request is made and the encrypted snapshot payload/AAD is unchanged. Internally gated embedded folder enrichment in item-list source is **not** the discovery contract.

Defensive **app limits**, not claimed upstream restrictions, are 10,000 folders per vault, 64 levels (root folder level 1), 640,000 self-inclusive ancestry rows, and 8 MiB per folder-command output. Iterative validation checks count, depth and checked ancestry arithmetic before closure-row construction or writer admission. Folder commands add no unbounded vault fan-out. Failed, incomplete, over-budget or stale discovery is unavailable evidence: ordinary item synchronization still proceeds; it is not deletion authority for retained folder data or cached access.

The checksum-matching bundled Apple Silicon 2.5.1 and 2.7.0 binaries advertise this command and flags in `folder list --help`; the 2.7.0 folder-list command and folder model are unchanged from 2.5.1. Validation used only public source, help and synthetic fixtures, never authenticated vault contents. As above, public release contracts and matching checksums do not establish exact source-to-binary attestation or prove complete remote enumeration. This metadata contract does not expand the exact-version full-secret reuse allowlist.

## Provenance

The bundled CLI is not a fork. Quick Access vendors Proton's release binaries under `ThirdParty/ProtonPassCLI/<version>/`, verifies their SHA256 checksums during release preparation, copies them into `Contents/Resources/ProtonPassCLI/<version>/`, and signs the copied helpers so macOS will run them inside the signed app.

Current bundled Proton Pass CLI assets:

| Version | Architecture | Upstream asset | SHA256 |
| --- | --- | --- | --- |
| 2.7.0 | Apple Silicon | `pass-cli-macos-aarch64` | `f17222619b4c4c4112eccc3796edea4bc0e4a341dc8960f7bb4023782adcc4a1` |
| 2.7.0 | Intel | `pass-cli-macos-x86_64` | `1829f7ecef108df5e14f92081cf4a4412c0fdc5be2034f9ee85d1e6745a62322` |
| 2.5.1 | Apple Silicon | `pass-cli-macos-aarch64` | `2c5834dd21bef341db70c39eaa0a353d4b9e49a8a0d4e5579c02f62ed70db3d9` |
| 2.5.1 | Intel | `pass-cli-macos-x86_64` | `fed0d6a919b8b05921c508cdd4cfe8c05a0b0cf4ccc55ed036e3b51ace6f7373` |
| 2.4.2 | Apple Silicon | `pass-cli-macos-aarch64` | `99e862094fd2a4f82788c9000ba5a92246e7739f86c35a84655b9d7e2adf7227` |
| 2.4.2 | Intel | `pass-cli-macos-x86_64` | `44f7cd45bdfabe34079e6d6ba2ff54e3a3e9e3150046b6cbee326cad52edff18` |
| 2.3.3 | Apple Silicon | `pass-cli-macos-aarch64` | `3281587ac9c50ae2f1604ba75e9d1d39b6debb221b65a6cc56f64d626ede3dbc` |
| 2.3.3 | Intel | `pass-cli-macos-x86_64` | `275f6159f63d152ecdd9d4e2969ef515291619005e0d30ab762daee26081621c` |
| 2.2.3 | Apple Silicon | `pass-cli-macos-aarch64` | `8318e5af39d899780214ec62c6d1c2cfdc7628bb2036dba8f72af74c9a63c732` |
| 2.2.3 | Intel | `pass-cli-macos-x86_64` | `2babdfaf4badf1c428d66acd784377e5a9312c8a35b1fb6dea19e7eb051ae839` |
| 2.1.4 | Apple Silicon | `pass-cli-macos-aarch64` | `8b579bf452c346da57349a5e72c3839c466e064179b9383f481eefbfa8a65a44` |
| 2.1.4 | Intel | `pass-cli-macos-x86_64` | `ee0f41d3a1c26022e3f99aff6f2280ec3e0f0e1c443c2c58652c26d3456dc235` |

## Verifying vendored CLI files

The [verification guide](verify-pass-cli.md) compares upstream downloads with vendored inputs and regenerates this table from the manifest.

Final app helpers can differ from raw release downloads because packaging adds code signatures. `scripts/prepare-bundled-pass-cli.sh` verifies upstream input checksums. `scripts/inject-bundled-pass-cli.sh` copies and signs those files. Matching checksums establish release association, not exact source-to-binary correspondence.

## Related docs

- [README](../README.md)
- [Troubleshooting](troubleshooting.md)
- [Security policy](../SECURITY.md)
