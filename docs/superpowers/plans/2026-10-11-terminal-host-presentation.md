# Shared Terminal-Host Presentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically configure Herdr and share configurable terminal-host names/icons/pane details across SSH and Run prompts.

**Architecture:** Preserve the existing coordinators and authorization identity flows. A MainActor observable preferences store feeds a pure presentation resolver and a request-scoped observable header model; an injected nonisolated Sendable Herdr provider performs bounded read-only enrichment. Each model owns its cancellable operation and a store-change subscription; view disappearance and every controller dismissal cancel it while permission queues/caches remain unchanged.

**Tech Stack:** Swift 6 strict concurrency, macOS 15+, SwiftUI/AppKit, Foundation, Darwin process inspection, existing CLIRunner, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-11-terminal-host-presentation-design.md`

## Global Constraints

- Put Terminal hosts under General; use it for SSH and Run.
- Herdr is automatically enabled when first detected; explicit disable and user edits survive rediscovery/restart.
- Presentation-only: do not change authorization identifiers, SSH showCommand/cache context, Run scopes, peer verification, secret handling, or cached decisions.
- Existing identified macOS apps take precedence over executable mappings.
- Preserve existing macOS 15 / Swift 6 boundaries; no dependencies or database migration.
- No generic configured executable is launched. Only matched Herdr executes fixed read-only CLI commands.
- Metadata remains request-scoped in memory, excluded from persistence/audit logs. Never read pane output, transcripts, or agent session files.
- Base prompt displays immediately; metadata cannot extend countdowns or block permission decisions.
- One enrichment attempt per displayed request, total 750 ms absolute deadline, stdout cap 512 KiB per command, at most 32 candidate panes/four concurrent process-info calls.
- Read only HERDR_SOCKET_PATH/HERDR_PANE_ID environment hints; validate a user-owned absolute local socket. Never inherit the app's unrelated Herdr routing context.
- Validate pane shell PID against ancestry below the selected host and revalidate start times, coherent parent chain, and socket identity before publishing; focus/IDs are not ownership proofs. Complete the bounded eligible scan to establish uniqueness; incomplete/over-limit scans return no details.
- Discovery never promotes, overrides, or duplicates a user-created generic mapping of the Herdr executable. Filesystem availability is not preference validity.
- Run's detached trusted-helper authorization identifier remains "unknown"; a displayed Herdr/custom name must never replace it.

## Review Focus

- Homebrew symlinks and upgrades must continue matching; disabled settings must not be recreated or overwritten (Tasks 1–2).
- Multiple Herdr sessions, stale/moved pane IDs, and a focused unrelated pane must never display unrelated metadata (Task 3).
- PID reuse/process exit between capture and response must discard metadata (Tasks 2–3).
- Slow/malformed/oversized API responses and long/control-character labels must leave auth usable and bounded (Tasks 3–4).
- Cancellation, setting disable, and queued/cached decisions must prevent stale headers without changing allow/deny scopes (Task 4).

## Existing Work

The working tree already contains the uncommitted hardcoded SSH-only fix and its tests. Refactor it rather than retaining a second compatibility path: replace `SSHRequesterPresentation`, its test suite, and `SSHClientInfo.presentation` with shared context/presentation types. Preserve the verified original requester name and existing cache-key expectations. Do not discard unrelated working-tree changes or commit without user authorization.

---

### Task 1: Persist configurable hosts and add General settings

**Files:**
- Create `Quick Access for Pass/Models/TerminalHostConfiguration.swift`.
- Create `Quick Access for Pass/Services/TerminalHosts/TerminalHostStore.swift` and `TerminalHostDiscovery.swift`.
- Create `Quick Access for Pass/Views/Settings/TerminalHostsSettingsView.swift`.
- Modify `Quick Access for Pass/Extensions/DefaultsKeys.swift`, `Views/Settings/GeneralSettingsTab.swift`, `Views/Settings/SettingsView.swift`, and `SettingsRoot.swift`.
- Test `Quick Access for Pass Tests/TerminalHostStoreTests.swift`.

**Interfaces:**
- `TerminalHostConfiguration: Codable, Identifiable, Equatable, Sendable`: `id: String`, `executablePath: String`, `displayName: String`, `isEnabled: Bool`, `provider: Provider` (`generic`, `herdr`), `showPaneDetails: Bool`, `isAutomaticallyDetected: Bool`.
- `@MainActor @Observable final class TerminalHostStore`: `init(defaults: UserDefaults, discovery: TerminalHostDiscovery)`, read-only `entries: [TerminalHostConfiguration]` and `revision: UInt64`; `refreshDetectedHosts()`, `addExecutable(at: URL) throws`, `update(_ entry: TerminalHostConfiguration) throws`, `remove(id: String)`, `observeExecutable(at: URL)`. Fixed automatic ID `herdr`; removal of this entry means persisted disable, not deletion.
- `TerminalHostDiscovery.discoverHerdr() -> URL?`; inject filesystem/candidate inputs for tests. Keep PATH/common install-path lookup separate from persistent settings.

- [ ] Write failing Swift Testing cases `herdrIsAddedOnce`, `disableSurvivesRestartAndRediscovery`, `editedNameSurvivesDiscovery`, `upgradeUpdatesAutomaticPathWithoutResettingChoices`, `missingInstallRetainsDisabledEntry`, `unavailableEnabledEntryCanBeDisabledAndRenamedAfterRestart`, `genericMappingSuppressesAutomaticHerdr` (enabled/disabled/symlink/restart/ancestry/upgrade variants), `customExecutableIsNotExecuted`, `symlinkDuplicateIsRejected`, `invalidPreferencesDoNotOverwriteSavedBytes`. Assert one `herdr` entry, initial name Herdr, enabled/details true, persisted disabled/name choices retained, and unrelated mappings untouched. Malformed saved JSON must not be silently replaced with defaults; show a configuration error and avoid automatic writes until explicit user reset.
- [ ] Run `xcodebuild -scheme "Quick Access for Pass" test -only-testing:"Quick Access for Pass Tests/TerminalHostStoreTests"`; confirm the intended failures.
- [ ] Implement versioned JSON under `DefaultsKey.terminalHosts`, an envelope with version 1 and entries. Validate saved preferences structurally (version, unique IDs, absolute paths, nonempty single-line names), independent of current file availability. Require an executable regular file only when adding/selecting a new path; permit other edits while unavailable. Expose availability separately. Canonicalize only for equality/matching; retain installation paths. A generic mapping of detected Herdr suppresses automatic addition regardless of enabled state; never promote it to a provider. If an upgrade/rediscovery makes an existing automatic entry collide, preserve its saved choices but suppress its effective match/provider in favor of the generic mapping. Refresh at startup/settings opening and observed ancestry. Never overwrite user names/enable/details choices.
- [ ] Expose a store-change subscription `observeChanges(_ handler: @escaping @MainActor () -> Void) -> UUID` and `removeObserver(_ token: UUID)`; notify on every effective configuration change. Active header models subscribe until explicit cancel/dismissal, even after details publish. Keep callbacks weak to avoid cycles.
- [ ] Implement the bounded scrollable settings list and executable picker. Provide enabled/name editing, path text, unavailable indication, custom removal, Herdr pane-details toggle and Add Executable…. Include required accessibility labels; use localization resources for new copy.
- [ ] Re-run Task 1 tests and inspect General settings at the existing 480-point width. Commit only if separately authorized.

### Task 2: Capture display context and resolve configured hosts

**Files:**
- Create `Quick Access for Pass/Models/RequesterProcessSnapshot.swift`, `RequesterPresentation.swift`, `HerdrPaneDetails.swift`, and `TerminalHostMatchingEntry.swift`.
- Create `Quick Access for Pass/Services/TerminalHosts/RequesterPresentationResolver.swift`.
- Modify `Quick Access for Pass/Services/SSHAgent/ProcessIdentifier.swift`; attach shared snapshots without removing the existing SSH-only presentation/helper yet, so this task remains independently buildable before controller integration.
- Add `Quick Access for Pass Tests/RequesterPresentationResolverTests.swift` and `RequesterProcessSnapshotTests.swift`. Task 4 removes the original helper/property/tests once both controllers consume the shared header.

**Interfaces:**
- `RequesterProcessSnapshot: Sendable`: effective requester and up to 10 ancestors. Nested `ProcessNode: Sendable` holds `pid: pid_t`, `parentPID: pid_t`, `startTimeMicroseconds: UInt64`, `executablePath: String`, and `canonicalExecutablePath: String`. `HerdrRoutingHint: Sendable` carries socket path, optional pane ID, and originating PID/start time from one process; never combine hints from different nodes. No full environment dictionary or raw process bytes escape capture.
- `TerminalHostMatch: Equatable, Sendable`: configuration ID, Herdr executable installation path, selected host ProcessNode, requester-side ProcessNodes below that host, and one coherent requester-side routing hint. Discard conflicting hints; nested host correlation cannot cross the selected host boundary.
- `ProcessIdentifier.requesterSnapshot(pid: pid_t) -> RequesterProcessSnapshot?`; capture the SSH caller or verified qa-run helper plus bounded ancestry as appropriate. Run's app/authorization identity still comes from its parent, while the display snapshot must preserve helper-only inherited routing hints and match that identified parent. Attach optional snapshot to SSHClientInfo without altering any existing identity properties.
- `HerdrPaneDetails: Equatable, Sendable`: optional `workspaceLabel: String?`, `tabLabel: String?`, `paneTitle: String?`, `workingDirectory: String?`.
- `RequesterPresentation: Equatable, Sendable`: `name: String`, `bundleURL: URL?`, `symbolName: String`, `hostID: String?`, `details: HerdrPaneDetails?`.
- `TerminalHostMatchingEntry: Equatable, Sendable` holds `configuration: TerminalHostConfiguration` and `canonicalExecutablePath: String`; it is derived matching data, not Codable preferences. `TerminalHostStore.matchingEntries` derives these from collision-filtered effectiveEntries using discovery's canonicalizer. Persisted entries/provider provenance remain unchanged.
- `RequesterPresentationResolver.resolve(clientInfo: SSHClientInfo, snapshot: RequesterProcessSnapshot?, entries: [TerminalHostMatchingEntry]) -> (presentation: RequesterPresentation, hostMatch: TerminalHostMatch?)` is pure. Canonical matching data is supplied without process or filesystem I/O inside the resolver. Production header consumers use store.matchingEntries after observing bounded ancestry installation paths. Explicitly declare value types, decoders, and provider work nonisolated under the project's default actor-isolation setting.

- [ ] Write failing resolver tests for detached Herdr, a custom executable, near-name `herdr-helper`, disabled entry, nearest-host precedence, existing-app precedence, unavailable snapshot, and symlink/canonical-path matching. Assert Herdr/terminal presentation while `SSHAuthorizationIdentity` still produces requester `ssh` and cache ID `ssh:github.com:git fetch --all`.
- [ ] Add capture/decoder tests rejecting malformed/truncated/oversized procargs and collecting only the two named HERDR hints. Include process exit/recycled PID fixtures, bounded depth, and qa-run parent versus helper attribution.
- [ ] Run both new suites to confirm failures.
- [ ] Implement bounded process inspection using existing Darwin conventions and start-time checks. Keep generic display context distinct from verified connection identity. Collect canonical paths for comparison and original installation paths for discovery; do not read pane contents or log process environment.
- [ ] Implement the pure resolver; use fallback original name/questionmark.app when no enabled mapping matches. Generic mappings do not invoke enrichment. Preserve ordinary app presentation and all existing showCommand behavior.
- [ ] Run resolver/capture tests plus `ProcessIdentifierTests`, `ProcessIdentifierConnectionTests`, and `SSHAuthorizationIdentityTests`.

### Task 3: Bounded Herdr enrichment for the actual requester

**Files:**
- Create `Quick Access for Pass/Services/TerminalHosts/HerdrPaneDetailsProvider.swift` and `HerdrMetadataDecoder.swift`.
- Modify `Quick Access for Pass/Services/CLIRunner.swift` only to expose the existing environment/deadline/output-limit combination.
- Test `Quick Access for Pass Tests/HerdrPaneDetailsProviderTests.swift`, with JSON fixtures/utilities confined to the test target.

**Interfaces:**
- Consumes `HerdrPaneDetails` and `RequesterProcessSnapshot` from Task 2.
- `HerdrPaneDetailsProviding: Sendable`: `func details(for match: TerminalHostMatch) async -> HerdrPaneDetails?`, consuming the selected host boundary and coherent hint provenance from Task 2.
- `LiveHerdrPaneDetailsProvider` injects a bounded command runner/process revalidator and one `@Sendable () -> UInt64` monotonic now dependency defaulting to real DispatchTime uptime. Use that source for initial capture and every provider budget check; synthetic tests control time, native runner deadline tests stay real. The runner accepts executable/argument arrays, environment overrides, `CLIExecutionDeadline`, and output limit. Add `CLIRunner.run(executablePath: String, arguments: [String], environmentOverrides: [String: String], deadline: CLIExecutionDeadline, maximumOutputBytes: Int) async throws -> Data`, forwarding through the existing hook-bearing deadline/cap overload with defaulted environmentOverrides and nil instrumentation to unchanged runInternal/LaunchInputs/Timing. This shares actual queued-admission test coverage without new hooks; do not rebase its budget or alter lifecycle internals.

- [ ] Write failures for exact shell-PID match, wrong focused pane, two matching panes including valid-hint-plus-another, nested hosts, conflicting hint origins, wrong session socket, inaccessible/not-owned/replaced socket, stale hint after pane move, move/close between snapshot and process-info, returned pane-ID mismatch, missing/nullable shell PID, zero/out-of-range unsigned PID, missing optional fields, process exit/PID reuse/incoherent parent chain, cancelled request, unsupported/malformed JSON, overflow, timeout, and incomplete/over-limit candidate scans. Verify no mutation/read/transcript commands run and each call receives the same absolute budget.
- [ ] Run the provider suite and confirm intended failures.
- [ ] Decode only metadata from `result.snapshot` of `api snapshot` and pane ID/nullable unsigned shell PID from `result.process_info` of `pane process-info --pane ID`. Join separate workspaces/tabs/panes arrays through explicit IDs. Reject zero/out-of-range PIDs before conversion. Validate returned pane_id equals the requested candidate and belongs to the snapshot; ignore unknown fields and never retain agent-session references or raw output. Use synthetic fixtures matching the supplied installed schema. Initially support verified protocol 22 and envelope discriminators only; other protocols produce base-header fallback. Optional/null shell PID in any candidate means incomplete ownership inspection, not a proven no-shell nonmatch.
- [ ] Route only through validated requester socket hints using HERDR_SOCKET_PATH. Clear every inherited HERDR_* key (names only, do not retain values) plus explicit defensive context/session/machine/config/bin selectors through empty overrides, then set only the validated requester socket; no --machine, --remote, --session, attach, or startup commands. Missing/unusable routing context returns nil instead of selecting the app's default session.
- [ ] Prioritize the hinted pane, but complete the eligible snapshot scan (at most 32 candidates/four concurrent child operations) within the shared 750 ms deadline and 512 KiB cap. Publish only exactly one matching shell PID in requester-side ancestry below the selected host; reject ambiguous, failed/incomplete, or over-limit scans. Do not cancel at the first match. Re-fetch snapshot metadata within that same deadline and require the entire candidate pane/workspace/tab association set to remain stable, independent of ordering and display-field changes. Added/removed/reassociated candidates yield fallback without a rescan; stable associations may publish fresh labels/title/directory. Retain the matched-pane association check. Cover final candidate deltas, a would-be second match, reordered-only snapshots and display-only updates with regression fixtures asserting unchanged calls/budget/caps. Check socket device/inode/owner before/after and revalidate every captured requester-side PID/start time/parent link plus selected host identity before publication. Cancel child work on failure/cancellation.
- [ ] Sanitize each displayed field to at most 256 characters, stripping terminal escapes/control characters; abbreviate home with ~. Missing labels are omitted, not inferred from focus. Re-run provider tests including cancellation cleanup. Add native CLIRunner tests proving environment overrides, queued expired original deadline, output cap, and cancellation for the new combined overload against a local fixture executable.

### Task 4: Shared header and both dialog integrations

**Files:**
- Create `Quick Access for Pass/ViewModels/RequesterHeaderModel.swift` and `Views/Shared/RequesterHeaderView.swift`.
- Modify `Views/SSH/SSHAuthDialog.swift`, `SSHAuthWindowController.swift`, `Views/Run/RunAuthDialog.swift`, `RunAuthWindowController.swift`, and `RunAuthWindowController+Identity.swift`.
- Remove `Services/SSHAgent/SSHRequesterPresentation.swift`, its original test file, and SSHClientInfo.presentation after replacing their consumers with the shared header; no compatibility/hardcoded presentation branch ships.
- Wire one store/provider through `App.swift`, `AppDelegate+Coordinators.swift`, `SettingsRoot.swift`, `Services/SSHAgent/SSHProxyCoordinator.swift`, and `Services/RunProxy/RunProxyCoordinator.swift`.
- Test `RequesterHeaderModelTests.swift`, extend `SSHAuthWindowControllerTests.swift`, add `RunAuthWindowControllerTests.swift`.
- Update `README.md`, `docs/ssh-agent-proxy.md`, `docs/run-proxy.md`, `SECURITY.md`, `AGENTS.md`, and `Resources/Localizable.xcstrings`.

**Interfaces:**
- `@MainActor @Observable final class RequesterHeaderModel`: `init(clientInfo: SSHClientInfo, snapshot: RequesterProcessSnapshot?, store: TerminalHostStore, detailsProvider: any HerdrPaneDetailsProviding)`, read-only `presentation: RequesterPresentation`, `loadDetails() async`, `cancel()`, and `refreshConfiguration()`. Own exactly one `Task<HerdrPaneDetails?, Never>?` and a store subscription token. loadDetails awaits that operation with a cancellation handler that propagates view-task cancellation to the owned task. Store callbacks invoke refreshConfiguration immediately, including after publication; any effective change invalidates generation, clears published details and cancels active work. A first attempt may start after re-enabling only if no attempt was ever started; a cancelled/completed attempt cannot restart. cancel is idempotent and terminal, clears operation/results/subscription and prevents later publishing. Retain an active model separately in each controller and cancel it on normal decision, dismissal/queue advance, view disappearance, and cancelAll; captured models from old requests can never affect the next request.
- Add optional `headerModel: RequesterHeaderModel?` to SSHAuthRequest and RunAuthRequest, with a default for existing fixtures. Preserve original appName/appBundleURL as identity-adjacent fallback data. Replace earlier appSymbolName wiring with the shared header model, not altered identity fields.
- `RequesterHeaderView(model: RequesterHeaderModel?, fallbackName: String, fallbackBundleURL: URL?, subtitle: LocalizedStringResource)` renders both headers and runs cancellation-aware enrichment only while mounted; preserve localized/interpolated subtitles. Reserve three immutable one-line detail rows for a process-backed unattributed terminal requester before loading, even if host/details are initially disabled or collision-suppressed. This permits a first lookup after late enable/new mapping without delayed panel clipping; empty rows are accessibility-hidden and do not grant eligibility. Identified-app headers need no reservation; verify the existing initially sized panels still show all permission controls. Caption/line truncation, not unbounded panel growth.
- Run controller gains injected `identifyParent: @MainActor (VerifiedConnection) -> SSHClientInfo` defaulting to trusted-helper parent identification, a header factory and dialog presenter. Keep production bundleIdentifier ?? "unknown" derivation inside resolveIdentity, not in the fake; signed and unverified branches never call the helper seam. Exercise production queue/cache decisions without a real window.

- [ ] Write header-model tests for immediate base presentation, matched details, fallback, once-only lookup, disable during execution, disable after publication, initial disabled then enabled, no retry after cancellation, disappearance and ordinary decision/queue advance, and a provider returning after cancellation. Explicitly start/join loadDetails in model tests with gates and suite time limits; AsyncStream controller presenters do not mount SwiftUI.
- [ ] Write real-controller tests asserting header-factory calls occur only for displayed requests, both requests use Herdr presentation, Run rejects unverified peers without model/metadata creation, cache-covered requests never enrich, and mapping rename/disable/details changes preserve SSH/Run persisted/session decision identities. Explicitly assert the detached qa-run parent retains Run authorization identifier "unknown", regardless of Herdr display name. Include cancelAll and queued requests; use in-memory databases and AsyncStream presenters, not sleep polling.
- [ ] Run these suites to confirm intended failures.
- [ ] Compose one shared observable store and provider in AppDelegate; inject through coordinator initializers and General settings. Put discovery in the store, not AppDelegate lifecycle logic. For displayed requests, feed captured bounded ancestry installation paths into observeExecutable(at:) before resolving with store.matchingEntries (canonical derived values from collision-filtered effectiveEntries). Preserve all existing controller identity/cache code. Instantiate header models only for actually displayed requests.
- [ ] Render the shared header with optional workspace/tab, pane title and directory below name/subtitle; retain existing command/key/profile rows. Keep details bounded, accessible, independent of color, and separate from permission scope copy. Use view .task lifetime plus controller cancelAll cancellation to avoid stale updates; settings disable refreshes/cancels without a second enrichment attempt.
- [ ] Update documentation with auto-detection, opt-out, shared General settings, best-effort display-only untrusted context, no terminal-content access, and unchanged authorization scopes. Do not alter Offline Mode documentation.
- [ ] Run `xcodebuild -scheme "Quick Access for Pass" test` and `git diff --check`; inspect diagnostics with Xcode build context. Report every failure by name. After user-authorized install, manually exercise SSH and qa-run from real Herdr, disabled details/host, ordinary terminal/GUI app, and long pane titles. Do not claim live UI verification without doing it.

## Handoff and Self-Review

The four tasks cover all approved settings, auto-discovery, identity separation, bounded pane correlation, shared UI, lifecycle, documentation, and test requirements. Review Focus cases are assigned to corresponding test steps. The existing hardcoded changes remain uncommitted and are inputs to the refactor, not a separate legacy feature. Planning itself made no expanded-feature application changes. Implementation has since completed all four reviewed tasks in the authorized checkout; per-task uncommitted diff/test/review evidence and parent-approved refinements are retained in the plan's ignored SDD workspace. Whole-feature review identified a final candidate-set consistency gap and pathname deprecation; the combined final fix addressed both, and scoped independent re-review returned FINAL_APPROVED with no remaining findings. Final retained full-suite evidence: 1505 declarations / 1831 expanded passes, zero failures, seven signed-Keychain skips. Authorized manual runtime checks remain a separate, unperformed gate.

User authorized Swift-skill review followed by subagent-driven implementation in this checkout, explicitly no worktree. Execute one writer at a time, fresh per-task reviewers, then one whole-feature review. Do not commit, install, or launch the app. Review packages compare saved uncommitted file snapshots, not commit ranges. Keep ignored evidence artifacts through delivery because there is no committed recovery record.
