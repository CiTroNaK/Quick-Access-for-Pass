# Offline Mode: cache-first secret resolution

Status: Approved by the user's explicit plan-review/update and execution request. No policy implementation has started.

## Intent and approved direction

When a user enables Offline Mode for an item or vault, an available offline copy should be the preferred source for secret actions—even when Pass CLI and the network are working. Copying an already cached value should not depend on a live request succeeding, timing out, or producing an error that qualifies for fallback.

The user approved cache-first behavior for ordinary host copy, Large Type, and the existing verified System AutoFill password/TOTP integration, with a clear note that sync refreshes cached values. SSH and Run proxies remain live-only.

This intentionally replaces the current live-first policy. It is not a connectivity-detection feature or an expansion of the set of generic CLI failures that permit fallback.

## Current behavior and observed failure

The manual report shows an item marked **Cached**, but both password and TOTP copy fail. The precise runtime cause has not been confirmed.

The current source has a relevant gap: `CLIRunner` returns `commandFailed` for non-authentication CLI exits, `PassCLIService` sanitizes secret-command errors to `secretFetchFailed`, and `OfflineSecretResolver.eligibleFallback` permits only missing CLI, logged-out CLI, and timeout. A prompt network failure can therefore prevent use of an otherwise available snapshot.

Cache-first removes that dependency for authorized, usable snapshots. It does not by itself repair a corrupt snapshot, unavailable key, initialization failure, or a final release-authorization failure. Automated and manual acceptance must distinguish those cases rather than assume that the Cached label proves success.

## Source-selection contract

For ordinary item resolution, TOTP resolution, and verified AutoFill resolution:

1. Honor cancellation and the original request deadline before starting secret-facing work.
2. Consult existing readiness and repository-owned snapshot eligibility. Never use the UI's Cached label, settings counts, or stale display state as permission.
3. If a current authorized snapshot exists, attempt cache resolution first using the existing snapshot decoder, selection proofs, release authority, and final release guard.
4. If cache resolution succeeds, return the cached value with its existing offline release capability. Do not call Pass CLI or perform a connectivity probe.
5. If no usable authorized snapshot is available, use the existing live resolution path. An offline selection with a pending or failed initial copy is not a guarantee that cached content exists.
6. Cancellation, deadline expiry, identity mismatch, or selection/release-authorization failure during an admitted cache operation remains terminal. Do not catch these failures and retry live merely to make the action succeed.

**Cache admission boundary:** the operation is admitted to the cache path when readiness is available and `repository.hasAuthorizedSnapshot(for:)` returns `true` for the requested snapshot key. This is a source-selection decision using existing repository authority, not a new persisted request, transaction, or admission framework. A negative eligibility result before admission is a cache miss and may use live access.

After positive eligibility, an `authorizedSnapshot` result of `nil`, a missing initial/current release proof, or selection/release-authority invalidation is an authorization race—not a cache miss that permits live access. Preserve the existing bounded cache-only retry for a valid replacement, with fresh capture and proofs. If no authorized replacement can be resolved within that retry, return the fixed offline-unavailable error with zero live calls. Cancellation, identity mismatch, and deadline expiry remain terminal without a live retry.

A snapshot missing before admission, failed optional eligibility lookup, or unavailable offline initialization can leave the ordinary live path usable, as today. Explicit storage/key/decode unavailability may make a snapshot unusable and select the live path, but must be distinguished from terminal security/lifecycle failures before errors are flattened into a generic presentation message. In particular, do not treat every existing `Error.unavailable` as permission to try live: that error also represents proof/authorization failures. Unknown failures must not be broadly reclassified as a cache miss. Preserve existing corrupt-snapshot discard rules; never delete keys or purge user selections as a recovery shortcut.

A cache miss followed by a live failure reports the existing fixed, non-secret error. No new network reachability checks, background live probes, implicit refresh-on-copy, or live-to-cache retry loop is needed.

## Values, refresh, and selection semantics

- Passwords and other copy/Large Type fields come from the selected snapshot, even if live values have changed.
- TOTP uses the cached seed and the current time to generate a fresh code locally. Do not store or reuse a generated code. A valid snapshot whose requested TOTP field is missing or malformed reports a fixed error; do not silently switch that field to a different live version.
- Only existing successful snapshot capture/publication updates cached content: sync, explicit item Retry, or creation of an offline copy through the existing selection workflow.
- Failed refresh retains the previous complete snapshot, which remains preferred while authorized and usable. Its existing stale status/last-successful-refresh information remains truthful.
- Whole-vault selection still covers future items after successful sync; exclusions persist until re-selection; turning off a vault retains individually selected items.
- Removing a copy or purging offline selections prevents subsequent cache use. Do not release a value already invalidated by removal, metadata change, logout, lock, or another existing release-guard event.
- Item/vault selection is not a promise that every snapshot has been created successfully. Without a usable copy, the normal live path remains available subject to existing authorization.

## Deadlines and security boundaries

No database migration, cache transfer, new key, new authorization prompt, or permission expansion is required.

Preserve:

- Full snapshots only in the host-only unified database's encrypted `offlineSnapshots` table, with operation-scoped encryption and the existing device-bound snapshot key.
- Current repository selection proofs, database-owned invalidation ordering, one-shot offline release capabilities, and the final `SecretReleaseGuard` check.
- Original AutoFill deadlines and native CLI cancellation/output/termination limits. Cache access must not refresh or extend the deadline.
- Verified host-broker AutoFill only: the extension gets only the requested final password/TOTP value, never cache access, ciphertext, seed, or fallback diagnostics.
- Cached AutoFill username/item-kind validation and final broker registry/release checks.
- Concealed clipboard writes and existing Large Type release checks.
- No secret-bearing error payloads, diagnostics, logs, UI state, FTS, UserDefaults, App Group files, or proxy paths.
- SSH and Run proxies do not resolve from offline snapshots.

The live-phase fallback reserve is not needed for a successfully resolved cached request: no live phase runs. For a live/no-cache request, pass the original deadline through without inventing a new cache-fallback reserve. Simplify directly superseded budget/branch code only; do not start a separate executor, transport, fixture, or observation refactor.

## User-facing note and documentation

Add visible explanatory text in **Settings → Offline**, near the existing selection explanation:

> Items and vaults enabled for Offline Mode use cached values when a usable copy is available. Sync is needed to refresh them. Without a usable cached copy, Quick Access uses Pass CLI.
>
> Offline copies are used for copy actions, Large Type, and System AutoFill. SSH Agent and Run proxies do not use offline copies.

The note applies equally to individual items and whole vaults. Keep it readable and accessible with existing caption/text styling; no new toggle, badge, dialog, or UI navigation is required. Do not claim that either proxy always requires a network connection: the precise guarantee is that it does not use this app's offline snapshots.

The scope/exclusion statement must appear in all three user-facing locations explicitly requested by the user:

- **Settings → Offline:** visible text alongside the cache preference/refresh explanation.
- **README:** the Offline Mode overview, naming both SSH Agent and Run proxies.
- **Published release notes:** an Offline Mode paragraph in the existing `.github/workflows/release.yml` **Build release body** step, so the policy and exclusions reach the GitHub Release body. Preserve generated release notes and installation guidance; do not create a separate changelog or release-automation framework.

Update README, SECURITY, AGENTS, CLAUDE, and current source comments/tests that promise live-first or unavailable-only cache use. Security documentation must retain all other Offline Mode guarantees, including encrypted host-only storage, selection/exclusion policy, proxy exclusion, removal/purge, and the bounded maintenance checkpoint's non-secure-erasure limitations. The agent documentation checklist must describe the new cache-first policy rather than demand the old live-first wording.

## Implementation boundary

Use the existing shared `OfflineSecretResolver` and current repository/codec/release APIs. Existing callers should not implement their own cache preference or duplicate authorization logic. Keep public resolver signatures and actor boundaries unless a concrete test demonstrates a necessary change.

Reuse existing test fixtures. Update tests whose live-first expectations are intentionally superseded; preserve meaningful security, native deadline, cancellation, overflow, ownership, and release coverage. Retarget live/native tests to a no-usable-cache setup when their previous selected snapshot would now correctly prevent any CLI invocation. No test splitting or new diagnostic framework is part of this change.

Earlier green-baseline fixes and scope cleanup are prior work. Record and preserve the actual HEAD, working tree, and staging state at implementation start rather than restoring an outdated staging snapshot; HEAD was `cbaddb6` when the scope was finalized. Keep a recoverable checkpoint before implementation. Do not commit, rewrite history, install a build, or mutate the user's actual offline database without separate permission.

## Acceptance criteria

1. With a usable authorized snapshot and a live adapter that returns a different value, password/item resolution returns the cached value with an offline release capability and makes zero live calls.
2. Cached ordinary TOTP and cached verified AutoFill password/TOTP make zero live calls. TOTP matches a known seed/time vector rather than a saved code.
3. Cached resolution also works when the live adapter would fail with a generic sanitized secret-fetch error; no failure classification or network request is needed.
4. Unselected items and selected items without a usable copy use the live path. Failed optional eligibility lookup or unavailable initialization does not unnecessarily block live access.
5. Missing/corrupt/key-unavailable cache behavior follows the source-selection contract. An absent snapshot before admission permits live access; positive eligibility followed by `authorizedSnapshot == nil` or failed proof must exhaust only the existing bounded cache retry and then fail with zero live calls. A valid replacement remains resolvable with fresh capture/proofs. Cancellation, expired deadlines, identity mismatch, and admitted cache authorization/release failures cannot be converted into successful live retries.
6. Cache removal, replacement, metadata changes, and lock/logout races retain their current final-release protections. No already invalidated cached value reaches clipboard, Large Type, or AutoFill.
7. Failed refresh retains the old usable snapshot; successful refresh changes the cached value used by subsequent actions. Existing whole-vault/exclusion/manual-selection policy remains unchanged.
8. No usable-cache action launches native CLI work. Live/no-cache native tests continue to enforce the original deadline, cancellation, output bounds, and terminal completion contracts.
9. Settings, README, and the published release-note body explicitly explain cached-value preference, sync freshness, and exclusion of both SSH Agent and Run proxies. The other required documentation has no contradictory current-policy text.
10. Run focused affected suites and the full native Debug test suite. Record failures by name and disclose signed-Keychain/PAT or other environment-dependent skips. Full Debug does not replace manual installed-build acceptance.
11. With a separately approved rebuilt/installed app and the user's selected item, manually verify password and current TOTP copy plus Large Type. Verify the cached path with network available and unavailable, and verify refresh changes subsequent cached reads. Do not expose real values in logs, reports, screenshots, or agent context.

12. `swiftlint lint --strict` must exit successfully with zero violations under the current repository configuration. Do not weaken rules/thresholds, exclude affected files, or add suppressions/baselines merely to hide findings.

## Strict SwiftLint work

The exact command was run while drafting this specification: exit 2, with **96 violations in 236 files**, all reported as serious under strict mode. The captured baseline is `/tmp/qa-cache-first-swiftlint-baseline.log`. These are configured application findings, not the generic hook's out-of-scope test-file warnings.

The implementation plan must explicitly account for this existing lint debt, rather than claim the cache-first resolver alone makes the repository lint-clean. Apply straightforward formatting corrections and the smallest behavior-preserving structural changes needed for actual complexity, nesting, size, tuple, and parameter-count findings. Preserve concurrency/security behavior and regression tests. This authorizes necessary lint cleanup, not an unrelated architecture or test-infrastructure redesign.

## Explicit non-goals: SSH and Run

The user considered extending cache-first behavior to SSH and Run, then explicitly chose to skip both for now. Neither proxy is part of this feature. Preserve their current Pass CLI resolution/signing behavior, authentication, peer verification, and existing in-memory caches. Do not route them through offline snapshot resolution, import cached private keys, or add an offline signing backend.

Behavior-preserving changes in these files may still be necessary to satisfy the separately requested strict SwiftLint gate, but that does not authorize any proxy functionality change. Make the exclusion visible in Settings, README, and published release notes as specified above.

## Next step

The bounded builder check identified one important ambiguity: the cache-admission boundary when a snapshot disappears between eligibility and loading. It is resolved explicitly above as a terminal authorization race after positive repository eligibility, preserving bounded cache-only replacement retry and forbidding a silent switch to live.

User approval is recorded above. Execute the reviewed implementation plan with exact files, RED/GREEN regression steps, documentation/lint changes, and full-suite/manual verification; preserve this approved policy.
