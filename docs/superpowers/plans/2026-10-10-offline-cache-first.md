# Offline Cache-First Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prefer authorized offline snapshots for ordinary copy, Large Type, and verified AutoFill, explain sync freshness and proxy exclusions, and achieve a clean strict SwiftLint run.

**Architecture:** Change source selection once in the existing `OfflineSecretResolver`; retain repository proofs, offline capabilities, final release guards, and original deadlines. Resolve cache availability separately from terminal authorization failures. Strict lint work is behavior-preserving and separated into runtime, persistence, and presentation owners.

**Tech Stack:** Swift 6 strict concurrency, Swift Testing, SwiftUI/AppKit, GRDB/SQLCipher, existing CryptoKit snapshot/TOTP services, native Xcode tests, SwiftLint.

**Spec:** `docs/superpowers/specs/2026-10-10-offline-cache-first-design.md`

## Global Constraints

- User approved plan review/update followed by execution with subagents **in the current checkout, with no worktrees**. Exactly one writer at a time; fresh read-only reviewers run only against settled checkpoints.
- Current starting HEAD: `cbaddb6`. Preserve the actual current index and user changes. Do not restore old staged-baseline patches.
- No commits, staging, push, installation, real-user database/Keychain/clipboard inspection, purge, new dependency, or history rewrite. Keep changes reviewable and recoverable.
- Cache-first covers ordinary copy, Large Type, and existing verified System AutoFill password/TOTP only. SSH and Run retain current behavior and do not read offline snapshots.
- Zero live calls/connectivity probes when authorized usable cache resolution succeeds. Missing cache before admission uses live access; positive `hasAuthorizedSnapshot` admits the cache path.
- After admission, missing snapshot/proof or invalidated authority permits only the existing bounded cache-only replacement retry; terminal failure must not switch to live.
- Cancellation, original deadline expiry, expected-username/item-kind mismatch, and final release failure remain terminal. Do not broadly catch `Error.unavailable` as a cache miss.
- Explicit storage/key/decode unavailability can use live access only when distinguished from authorization failures. Unknown failures and oversized payloads remain fixed non-secret failures; no widening output limits or compatibility readers.
- TOTP uses the cached seed and current time, never a stored code. Existing invalid/missing TOTP-field errors do not silently switch to live values.
- Keep encryption, device-bound key accessibility, operation-scoped cipher use, native bounded I/O/cancellation, concealed clipboard, verified peers, and one-shot release behavior unchanged. General skill recommendations do not authorize new biometrics/ACLs or Secure Enclave gates.
- Exact gate: `swiftlint lint --strict` exits 0, zero violations, current repository configuration. No new suppressions, weakened thresholds/rules, baselines, or exclusions.
- Existing baseline: 96 strict findings in 27 application files (236 files linted); full Debug previously passed 1,401 functions/1,658 executions with seven declared signed-Keychain/PAT skips. Do not treat that previous pass as verification of new work.
- Evidence/ledger namespace: `.superpowers/sdd/2026-10-10-offline-cache-first/`. Save per-task before/after diffs, actual commands/results, and rulings there; do not erase it or sibling workspaces.

## Review Focus

1. Eligibility returns true but loading/proof returns nil: cache-only retry, then fixed failure and zero live calls; an authorized replacement must still work.
2. Cache key/decode failure versus identity/revocation failure: only explicitly recoverable availability can choose live, and no associated error payload may leak.
3. Selected snapshot with changed live password/TOTP: cached value wins with retained release capability; local TOTP matches a fixed seed/time vector.
4. Live/native deadline tests formerly used a selected snapshot: retarget genuinely live paths without dropping termination/overflow/deadline assertions or adding fixture infrastructure.
5. Structural lint extractions around actors, callbacks, transactions, or SwiftUI identity: preserve isolation, callback execution placement, publication/release ordering, and stable selected-row identity.

## File Ownership and Verification

Task 1 owns the resolver/policy tests. Task 2 owns CLI/proxy/AutoFill runtime lint and necessary sync-return-type consumers. Task 3 owns persistence/offline-service/sync lint. Task 4 owns UI/orchestration lint and user documentation/release copy. Task 5 performs final integrated verification without introducing features.

New production files are allowed only as focused extractions needed by the existing lint limits. Preserve existing public-facing/test-facing names with aliases where appropriate. Use existing synchronization/fixtures; no new transport, executor framework, broad diagnostic machinery, or test-file splitting.

Common native command (use a fresh result path for every run):

```bash
xcodebuild -scheme "Quick Access for Pass" -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/qa-offline-cache-first-derived \
  -resultBundlePath <fresh-path>/result.xcresult test
```

Use `-only-testing:"Quick Access for Pass Tests/<Suite>"` for focused runs. Capture logs/result summaries outside tracked source; use the process tool for long runs, and do not finish a task while its required test run is unobserved. Fresh build evidence, not standalone SourceKit module-search failures, determines compilation correctness.

## Task 1: Cache-first resolver and policy regression tests

**Files:**
- Modify: `Quick Access for Pass/Services/Offline/OfflineSecretResolver.swift`.
- Modify or remove directly superseded branches: `Quick Access for Pass/Services/Offline/OfflineAutoFillLiveBudget.swift`.
- Tests: `OfflineSecretResolverTests.swift`, `OfflineSecretResolverDeadlineQueueTests.swift`, `OfflineAutoFillSecretResolverTests.swift`, `QuickAccessViewModelOfflineActionTests.swift`, `AutoFillBrokerCoordinatorTests.swift`, `AutoFillBrokerOfflineSnapshotIPCTests.swift`, `OfflineModeServiceTests.swift` under `Quick Access for Pass Tests/`.
- Read unchanged: `Models/ResolvedSecret.swift`, `Services/Offline/OfflineReleaseAuthority.swift`, snapshot repository/codec and existing fixture helpers.

**Interfaces:** Retain `SecretItemResolving.resolveItem`, `resolveTOTP`, and `resolveAutoFillValue` signatures with `SecretResolutionContext` and `ResolvedSecret` results. Later tasks rely on retained offline capabilities and unchanged final release APIs.

- [ ] Write RED tests `authorizedSnapshotWinsWithoutLiveCalls`, `cachedTOTPUsesCurrentTimeWithoutLiveCalls`, and `cachedAutoFillValuesSkipLiveResolution`. Reuse selected fixtures and recording live adapters: cached password `"cached"` differs from `"live"`; assert cached result, `offlineCapability != nil`, and live call count 0. Use the existing RFC seed with 8 digits at Unix time 59 and expect `"94287082"`; verify via the real final release effect, not just a fake's output.
- [ ] Run those tests against the current live-first implementation and save evidence that they fail for source preference/call count, not compilation or setup.
- [ ] Add source-boundary tests: false eligibility uses live; true eligibility followed by missing snapshot/proof never uses live; valid replacement uses fresh cache capture/proofs; cancellation/expiry/identity/release failure stays terminal. Use existing gates and repository mutation paths, not arbitrary sleeps or production fixture writers.
- [ ] Implement cache-first selection in the existing actor. Preserve the existing cached-item authorization/retry sequence and mapping/release capability. Classify recoverable cache availability before generic error flattening; keep public UI errors fixed. Use an explicit small internal outcome/error distinction if required, not a new policy framework.
- [ ] Keep `.keyUnavailable` and authenticated decode/storage unavailability distinct from `.invalidIdentity`, current proof failures, invalid username/type, output/payload overflow, cancellation, and deadline expiry. Apply only existing authorized corrupt-snapshot discard behavior; no key/selection cleanup. Document any precise classification ruling in the ledger against the spec.
- [ ] Add positive availability regressions with a successful recording live adapter: missing/wrong key (`.keyUnavailable`) and authenticated corrupt/decode failure (`.corruptSnapshot`) select live once, return live source without an offline capability, and expose no cache/error payload. Assert retained key and selection; key unavailability retains the snapshot, while corruption follows existing revision-conditional discard rules and cannot delete a valid replacement. Preserve negative marker-leakage coverage with a failing live adapter. Any explicitly typed storage availability chosen after inspecting actual APIs also requires successful-live regression coverage; unknown storage errors are terminal, not an availability catch-all. Run changed behavior tests in RED/GREEN and record the exact typed classification before flattening. Contrast each recoverable outcome with proof/identity/cancellation/deadline terminal-zero-live tests.
- [ ] Generate cached ordinary/broker TOTP locally with the existing generator/date injection. For no-cache broker requests, forward the original absolute deadline to native live resolution; no cached-request live-phase reserve is needed.
- [ ] Update intentionally superseded live-first assertions and retarget selected live-stall/overflow/deadline fixture tests to no usable snapshot where their subject is native behavior. Preserve the real assertions, ownership/settlement observation, and cancellation forwarding. A test blocked on a CLI gate must not retain a now-preferred usable snapshot.
- [ ] Update `AutoFillBrokerOfflineSnapshotIPCTests.manualOnlySnapshotFallbackReturnsOnlyRequestedValues` (rename to cache-first policy if appropriate): cached password/TOTP requests now make zero live item and TOTP calls. Preserve real verified broker delivery, requested-value-only JSON keys/no diagnostics, authenticated malformed-payload leakage checks, mutation denial, and final-release protections. Run this suite in the focused GREEN checkpoint, not only final full Debug.
- [ ] Read the captured strict baseline; Task 1 owns all configured `OfflineSecretResolver.swift` findings (including retained signature width and cached-item complexity). Perform only minimal behavior-preserving wrapping/focused extraction, retaining signatures, executor placement, proofs and release order. Run owned-file strict lint on the resolver, budget file if retained, and any new extraction before this checkpoint; do not lint excluded tests or weaken configuration.
- [ ] Run the affected suites listed above and existing TOTP/release-authority tests. Any old test changed or removed requires an explanation of its replaced policy coverage; no deletion of still-relevant security/native guarantees.
- [ ] Save the task diff, RED/GREEN command/results, changed-test rationale, and a concise report. Gate with fresh spec/concurrency/security/testing review before Task 2.

## Task 2: Strict lint — CLI, proxy, and AutoFill runtime

**Files with actual baseline findings:**
- `Services/CLIRunner.swift`, `Services/PassCLIService.swift`.
- `Services/SSHAgent/SSHAgentProxy.swift`, `Services/SSHAgent/SSHAgentProtocol.swift`.
- `Services/RunProxy/RunSecretResolver.swift`.
- `Services/AutoFill/AutoFillSecretResolver.swift`, `AutoFillBrokerCoordinator.swift`, `AutoFillBrokerConnectionProcessor.swift`.

All service paths are under `Quick Access for Pass/`. Candidate focused extractions: `Services/CLIExecution.swift`, `Services/CLIPipeReader.swift`, `Services/CLIRunnerTesting.swift`, `Services/PassCLIService+Sync.swift`; introduce only those actually required. Name a four-property return value `Models/CLISyncFetchResult.swift` if replacing `fetchAllItems`'s oversized tuple; update actual consumers and test fakes in the same task.

**Interfaces:** Preserve CLIRunning/CLIEnvironmentRunning and existing `CLIRunner.run` overloads. Preserve `CLIRunner.LifecycleTesting`/event/suspension names through type aliases when moving nested declarations. If `fetchAllItems` returns `CLISyncFetchResult`, retain property names/types `vaults: [CLIVault]`, `items: [(item: CLIItem, vaultId: String)]`, `skippedItems: [SkippedSyncItem]`, `presenceUncertainties: [SyncItemPresenceUncertainty]` and update all protocol/tuple destructuring consumers coherently.

- [ ] Read the persisted strict baseline and run lint on this group's current files. Identify mechanical versus structural violations before changing behavior.
- [ ] Correct formatting/documentation/line-width findings without changing statement ordering or secrets handling.
- [ ] Move nested execution/reader/test-observation types into focused source files as needed for nesting/file/type limits. Keep actor state private in its owning file and task executor retention/placement intact; use same-file extensions/helpers where sufficient. Group private launch inputs coherently to satisfy parameter limits without recapturing deadlines.
- [ ] Preserve FIFO descriptor ownership, bounded native execution and reader callbacks; SSH identity/sign forwarding and authorization remain unchanged; no proxy cache use. Named configuration/input values are allowed for genuine parameter-count fixes, not a new request pipeline.
- [ ] Extract oversized/complex AutoFill methods by existing phases without changing original deadline, registry completion, peer verification, or release order. Update sync tuple interface consumers only if that natural named result is needed.
- [ ] Run focused `CLIRunnerTimeoutTests`, `CLIRunnerEnvironmentTests`, `CLIRunnerAuthClassificationTests`, `RunSecretResolverTests`, `SSHAgentProxyTests`, `AutoFillBrokerTests`, `AutoFillBrokerCoordinatorTests`, `AutoFillRequestRegistryTests`, and affected sync/parser suites (confirm exact existing suite names before execution).
- [ ] Run strict lint on owned files plus each new extraction; save diff/tests/interface changes and receive fresh concurrency/API/security review. Do not demand a globally green lint run until Tasks 3–4 finish remaining owners.

## Task 3: Strict lint — persistence, offline services, and sync

**Files with baseline findings (under `Quick Access for Pass/`):**
- `Services/DatabaseManager.swift`, `Services/DatabaseManager+Vaults.swift`, `Services/SyncCoordinator.swift`.
- `Services/Offline/OfflineStorageMaintenance.swift`, `OfflineCatalogObservation.swift`, `OfflineReleaseMutationPlan.swift`, `OfflineReleaseAuthority.swift`.
- `Services/Offline/OfflineSnapshotRepository.swift`, `OfflineSnapshotRepository+Selection.swift`, `OfflineModeService+Work.swift`, `OfflineSnapshotCipher.swift`, `TOTPGenerator.swift`.

Candidate focused extractions only if necessary: `Services/Offline/OfflineModeService+Completion.swift`, `Services/DatabaseManager+Migrations.swift`. Retain existing migration history and production mutation paths.

**Interfaces:** Consume Task 1's cache-first/error contract and Task 2's actual sync result type. Preserve repository protocol method signatures unless a lint-required coherent input value is needed; update callers/test fakes atomically. No schema, migration content, encryption, key, or selection-policy changes.

- [ ] Apply mechanical whitespace, conditional/identifier, and wrapping corrections from the actual baseline.
- [ ] Extract complex catalog, selection, worker-completion, release-mutation, and checkpoint methods along their existing transaction/ownership boundaries. Keep all database work on existing writer/actor paths; no detached tasks, unsafe Sendable, broader fixture mutation access, or added authorization reuse.
- [ ] Preserve committed-ciphertext/status atomic publication; do not reverse a real commit on cancellation. Preserve selection/manual/exclusion generations, invalidation-before-release ordering, and completing-worker checkpoint requests.
- [ ] Fix oversized types/files and excessive parameters with minimal responsibility-preserving helpers/identity inputs. Do not alter migration SQL or remove checks to lower complexity. Preserve existing release authority locking/reentrancy restrictions and TOTP algorithms.
- [ ] Run affected `DatabaseManagerTests`, `OfflineModeServiceTests`, `OfflineSnapshotRepositoryTests`, `OfflineReleaseAuthorityTests`, `OfflineReleaseMutationTests`, `OfflineStorageMaintenanceTests`, `OfflineSecretResolverTests`, `SyncCoordinatorOfflineTests`, and `TOTPGeneratorTests`; confirm actual suite names and include any additional directly affected persistence suites.
- [ ] Run strict lint on this group/new files, save evidence and task diff, and receive fresh persistence/concurrency/security/API review.

## Task 4: Presentation lint and user-facing scope/freshness guidance

**Files:**
- `Quick Access for Pass/App.swift`, `ViewModels/QuickAccessViewModel+Offline.swift`, `ViewModels/OfflineModeCoordinator.swift`.
- `Views/Main/ItemDetailView.swift`, `Views/Settings/OfflineSettingsTab.swift`, `Views/Settings/OfflineItemsManagerView.swift` under the application directory.
- `README.md`, `SECURITY.md`, `AGENTS.md`, `CLAUDE.md`, `.github/workflows/release.yml`.
- Candidate focused extractions if limits require them: `Views/Main/ItemDetailView+Rows.swift`, `ViewModels/OfflineModeCoordinator+Observation.swift`, `App+OfflineSetup.swift`. Do not change actor isolation or expose decrypted values to UI state.

**Interfaces:** Existing `QuickAccessViewModel` actions, stable row/selection identities, coordinator committed status/counts, and the shared resolver remain authoritative. No new setting or UI authorization bypass.

- [ ] Add tests/checks for exact policy note and both proxy exclusions in Settings, README, and the release body (use existing layout/source tests or a small narrowly scoped documentation assertion). Keep current keyboard/VoiceOver/stable-selection behavior covered before structural view changes.
- [ ] Add visible caption text near the Offline selection explanation: `Items and vaults enabled for Offline Mode use cached values when a usable copy is available. Sync is needed to refresh them. Without a usable cached copy, Quick Access uses Pass CLI.`
- [ ] Add adjacent visible scope text: `Offline copies are used for copy actions, Large Type, and System AutoFill. SSH Agent and Run proxies do not use offline copies.` Use existing accessible text styling; no new toggle/modal/badge.
- [ ] Update README/security/agent guidance and stale source comments to cache-first semantics. Retain every other Offline documentation-checklist guarantee and the non-secure-erasure caveats.
- [ ] Add the same policy/scope explanation to the existing **Build release body** heredoc in `.github/workflows/release.yml`. Preserve generated release notes, installation instructions, signing/notarization, and publishing behavior; no release publication or new changelog system.
- [ ] Resolve presentation/App composition lint findings with focused helper/view/extension extractions. Preserve stable IDs, action selection/focus, independent copy/Large Type ownership, and AppDelegate as a thin composition root.
- [ ] Run relevant view-model offline-action, keyboard selection, item-detail, offline settings/layout, AppDelegate offline lifecycle, accessibility, and coordinator suites. Verify release YAML/body generation without publishing or installing.
- [ ] Run full `swiftlint lint --strict`; it must now report zero violations. Save evidence/diff and receive fresh SwiftUI/API/testing/spec review before Task 5.

## Task 5: Integrated verification and final review

**Files:** No feature changes; results/reports/manifests only in this plan's ignored evidence namespace.

**Interfaces:** Consume settled reviewed checkpoints from Tasks 1–4; reviewers see the complete current diff versus the recorded starting HEAD, including new files, not only committed git ranges.

- [ ] Run exact `swiftlint lint --strict` and the full native Debug command with a fresh xcresult. Require exit 0 and zero failures; record all skips/runtime warnings honestly.
- [ ] Verify new cache-first tests make zero native/live calls, local TOTP vector and replacement/authorization races, preserved no-cache native limits, and visible policy/exclusion text in all required locations.
- [ ] Confirm no new suppressions/exclusions/config weakening, no proxy offline access, no database migration/secret diagnostics, no dropped relevant tests, unchanged initial index/HEAD, and no product changes outside the approved plan.
- [ ] Save final combined patch, file hashes, review references, command summaries, failure/skip details, and full-suite xcresult path. Do not erase evidence or old backup directories.
- [ ] Obtain fresh whole-change review using Swift concurrency/security/API/testing/SwiftUI skills. Address confirmed findings through one sequential writer fix wave and scoped re-review; rerun exact lint/full Debug if code changes.
- [ ] Report implementation/automated acceptance separately from manual acceptance. Ask permission before `make install` or inspecting the running app's real data. The original cached-item screenshot scenario, network-on/off copy, Large Type, and post-sync freshness remain unverified until the user approves and performs/observes installed-build testing.

## Execution and Review Rules

Plan review comes first: fresh Swift-focused reviewers, then a single documentation writer updates this plan from concrete findings; preserve the approved spec and record rulings. Begin Task 1 only after the plan review is approved.

Each production task has one writer, a saved before/after diff package, and a fresh spec/quality reviewer. Confirmed important findings require sequential fixes and scoped re-review before downstream work. Never advance on missing verification or unresolved load-bearing findings. Report child launch/runtime failures and stop; do not silently fall back to another agent runner.

Use the plan's ignored ledger as recovery authority. Check completed checkpoints before any resumed dispatch; do not replay completed tasks after compaction. Child agents do not delegate. Controller owns scope, acceptance, and external-side-effect permissions; workers own their assigned code. No additional user confirmation between reversible in-scope tasks is needed because execution is explicitly authorized.
