# Integrations UI Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved Integrations pane, paste-friendly host editor, consistent compact requester headers, and tested Heroku/gh wrapper documentation.

**Architecture:** Continue using the single MainActor TerminalHostStore. Separate editor validation/save state from SwiftUI, derive header context rows as pure values, and let each authorization controller own panel resizing guarded by request identity. Identity/provider/lifecycle code remains authoritative and unchanged except for presentation sizing.

**Tech Stack:** Native macOS15 SwiftUI/AppKit, Swift6 strict concurrency, Swift Testing, Foundation; Bash documentation fixtures. No dependencies or database migration.

**Spec:** `docs/superpowers/specs/2026-10-11-integrations-ui-cleanup-design.md`

## Global Constraints

- Work in the existing checkout, not a worktree; one writer at a time.
- No additional commit/push/install/app launch or Pass CLI data access is authorized by this design approval.
- Preserve malformed-preference lockout/reset, opt-out, provider/provenance, canonical collisions and existing version1 JSON. No generic executable execution or promotion.
- Keep metadata untrusted, memory-only, display-only and once-per-request; original750ms/512KiB/32-candidate/four-child bounds remain.
- Keep SSH/Run peer/app identities, parent-derived Run unknown identity, scopes, queue/cache/cancellation behavior and countdowns unchanged.
- Use native localization/accessibility, bounded one-line metadata, and no Offline Mode changes.
- Manual paths are filesystem input only: absolute or home-relative; never shell/environment expression evaluation.
- Heroku/gh wrappers are documentation-only; test-target fixtures are allowed. No app templates/generation/install controls or wrapper execution features.

## Review Focus

1. Invalid manual saves must not partially add an entry or notify subscribers; valid named additions publish once.
2. Rename unavailable entries, cancel edits, and disappear/reconfigure while a sheet is open without losing saved provider/consent/provenance.
3. Supported Herdr remains visible when absent or masked by a disabled custom collision; status is not authorization or auto-consent.
4. Delayed/cleared/deduplicated context safely resizes both panels; stale request callbacks do not resize successors or restart countdowns.
5. Wrapper examples forward spaced arguments/profile slugs through fake helpers after excluding their own PATH directory; no recursion or real CLI execution.

---

### Task 1: Dedicated Integrations pane and paste-friendly editor

**Files:**
- Create `Quick Access for Pass/Models/SupportedTerminalHost.swift` (static supported catalog, Herdr only).
- Create `Quick Access for Pass/ViewModels/TerminalHostEditorModel.swift`.
- Create `Quick Access for Pass/Views/Settings/IntegrationsSettingsTab.swift` and `TerminalHostEditorSheet.swift`.
- Modify `Models/SettingsTab.swift`, `Views/Settings/SettingsView.swift`, `GeneralSettingsTab.swift`, `TerminalHostsSettingsView.swift`, `Services/TerminalHosts/TerminalHostStore.swift`, and `Resources/Localizable.xcstrings` under `Quick Access for Pass/`.
- Test `Quick Access for Pass Tests/TerminalHostEditorModelTests.swift`; extend `TerminalHostStoreTests.swift`; create `IntegrationsSettingsTests.swift` for catalog/tab/content-sizing checks using isolated store fixtures.

**Interfaces:**
- `SupportedTerminalHost: String, CaseIterable, Identifiable, Sendable` with `.herdr`, `id: String` and `displayName: String`; this is a static supported-product catalog, not a plugin system.
- Extend `TerminalHostStore.addExecutable(at: URL, displayName: String? = nil) throws`; validate final name/path before adding/persisting/notifying. Existing callers retain basename defaults. Add `var hasCustomHerdrOverride: Bool` derived from generic canonical paths and the saved/detected Herdr path, even for disabled generics; no mutations or executable invocation.
- `@MainActor @Observable final class TerminalHostEditorModel`: `init(store: TerminalHostStore, entryID: String? = nil)`, editable `displayName`/`executablePath`, read-only `isNameOnly`/`errorMessage`, `func save() -> Bool`. A name-only supported edit reloads the latest entry and preserves its path/flags. A custom edit changes only entered name/path; preserve latest enablement, ID/provider/provenance. Missing edit target yields error, never recreates a deleted entry.
- `TerminalHostEditorSheet(model:)` presents text fields, optional native file picker for custom paths, Cancel and Add/Save. Choose assigns a path into the same field; Save alone changes the store. Model trims input, expands `~`, rejects relative/shell-expression input, and delegates filesystem/duplicate validation to the store.
- Add `SettingsTab.integrations` with raw value `integrations`; existing raw values unchanged. `IntegrationsSettingsTab(store:)` owns host settings; General no longer takes the store. Keep the same SettingsRoot/AppDelegate-owned instance.

- [ ] Write editor/store regressions: valid named pasted path containing spaces; `~` expansion; invalid executable/directory/nonexecutable/relative/blank/newline name; duplicate symlink; atomic no-change/no-notification on error; one notification on successful addition; cancelled sheet changes nothing; unavailable existing path can be renamed; deleted edit target stays deleted; supported rename retains latest detected path/provider/provenance and disabled consent.
- [ ] Write catalog tests: Herdr visible with empty defaults/no discovery; installed, unavailable and custom-override states; disabled generic still overrides; corrupt preferences lock controls until confirmed reset. Add tab raw-value preservation and short-list intrinsic-size checks (zero/one/two custom entries do not allocate a tall empty region).
- [ ] Run focused tests and retain intended RED before implementation:
  `xcodebuild -scheme "Quick Access for Pass" test -only-testing:"Quick Access for Pass Tests/TerminalHostEditorModelTests" -only-testing:"Quick Access for Pass Tests/TerminalHostStoreTests" -only-testing:"Quick Access for Pass Tests/IntegrationsSettingsTests"`
- [ ] Implement validated editor/store interfaces. Do not perform add followed by rename as separate persisted operations. Preserve existing store contracts, and keep canonical filesystem operations out of pure UI types.
- [ ] Replace the always-editing cards with compact supported/custom sections and sheets. Use content-sized stacks for short lists and a bounded scroll area only for longer lists. Show absent Herdr as not configured, unavailable saved installation as unavailable, and a custom override explicitly; no fake enablement or unsupported products. Retain localized reset/errors and all existing consent controls. Add Integrations before About; start with560pt settings width so nine native toolbar items fit without shrinking controls.
- [ ] Run GREEN, existing store tests, whitespace and fresh target-context compilation. Inspect accessibility/long paths/empty lists using fixture hosting; do not open the live SettingsRoot, which triggers CLI health refresh. Report any checks not performed.

### Task 2: Centered header, conditional context and safe panel fitting

**Files:**
- Create `Quick Access for Pass/Models/RequesterHeaderContext.swift` and `Views/Shared/AuthorizationPanelSizing.swift`.
- Modify `Views/Shared/RequesterHeaderView.swift`, `ViewModels/RequesterHeaderModel.swift`, both `Views/SSH/SSHAuthDialog.swift` / `Views/Run/RunAuthDialog.swift`, both auth window controllers, and `Resources/Localizable.xcstrings`.
- Create `Quick Access for Pass Tests/RequesterHeaderContextTests.swift` and `AuthorizationPanelSizingTests.swift`; update `RequesterHeaderModelTests.swift` and both controller suites.

**Interfaces:**
- Pure `RequesterHeaderContext.rows(for: RequesterPresentation, displayedCommand: String?) -> [Row]`; `Row: Equatable, Sendable` has `kind: Kind` and `value: String`, and `Kind` is workspaceAndTab/paneTitle/workingDirectory. Join available workspace/tab labels; omit absent/empty values. Omit pane title only when equal to the displayed command after trimming/collapsing whitespace, case-sensitive; do not modify published values or authorization commands.
- `RequesterHeaderView` adds `displayedCommand: String? = nil`. SSH passes triggerCommand only if showCommand; Run passes request.command. Center the existing icon/name group independently from the conditional context stack.
- Add defaulted optional `onContentHeightChange: (@MainActor (CGFloat) -> Void)? = nil` to each dialog request. Fixed-intrinsic-height dialog content reports height through a macOS15 geometry callback; no frame polling, new metadata tasks, or controller-owned provider operation.
- `@MainActor enum AuthorizationPanelSizing` with `static func resize(_ panel: NSPanel, contentHeight: CGFloat)` converts content to frame size, preserves width/top edge, and rejects nonfinite/nonpositive heights and no-op changes. Use screen visible bounds where needed. Both controller callbacks capture weak self and pending request ID and require that request to remain current before accessing the active panel.
- Remove `RequesterHeaderModel.reservesDetailRows` and its obsolete constant-height tests only once controller fitting is covered. Keep all operation/subscription/generation/attempt behavior intact.

- [ ] Write pure row tests: repeated SSH/Run commands omit title; missing/blank title omitted; whitespace-equivalent duplicate omitted; distinct/case-different/prefix-only title retained; unknown command retains useful title; workspace/tab omission/join and directory values unchanged.
- [ ] Write real component size tests for zero/two/three rows, late metadata, long fields, initially disabled then enabled, and settings-clear/cancel. Assert omitted rows have no invisible allocation and both full dialogs' permission content remains within measured content size; replace old immutable-height expectations with measured fitting expectations.
- [ ] Write panel tests for top-edge/width preservation, grow/shrink/no-op, invalid heights and screen bounds. Add controller request-callback tests covering late geometry from completed/cancelled/queued request vs active successor, without opening windows or reading keys/profiles from production stores.
- [ ] Run affected tests for intended RED; retain output. Do not change the provider to make sizing tests pass.
- [ ] Implement row derivation, separate centered header/left-aligned context, and request-scoped measured panel fitting. Preserve view identity, countdown, focus and permission content. Keep caption values bounded/truncated and accessibility-labelled; context availability announcements are non-secret and must not reset auth state.
- [ ] Run GREEN across context/sizing/model/provider/controller/identity suites. Explicitly verify Run unknown identity and early unverified rejection, SSH login-shell trigger regression, single-attempt/configuration cancellation, and no new provider calls. Use fixture UI/geometry only under the no-live-CLI restriction.

### Task 3: Documentation-only wrapper examples and final acceptance

**Files:**
- Modify `docs/run-proxy.md`, `docs/ssh-agent-proxy.md`, `README.md`, `AGENTS.md`; update new spec/plan with actual interfaces if needed. Change SECURITY only if presentation guarantees need clarification; do not edit Offline Mode material.
- Create `Quick Access for Pass Tests/RunWrapperDocumentationTests.swift` (test-target-only temporary process/filesystem utilities).

**Interfaces:**
- Documentation owns two complete Bash fenced wrappers, clearly labelled `~/.local/bin/heroku` and `~/.local/bin/gh`, with corresponding `heroku-cli` and `github-cli` profile slugs. Each calculates its directory with quoted BASH_SOURCE, filters that exact directory from PATH, and execs the bundled helper through env with the real command name and quoted `"$@"`.
- Tests extract those labelled examples rather than duplicating their logic. Replace only the helper installation path with a temporary fake helper dependency; fake commands/helper return synthetic argv/PATH through a fixture output channel. No actual sockets, remote services or installed helpers.

- [ ] Write shell fixture tests for both profile slugs/command names, arguments containing spaces/quotes, helper path containing spaces, repeated own-directory PATH components, genuine binary resolution after shim exclusion, missing command behavior, and chmod/launch through a temporary PATH. Verify wrappers do not recursively invoke themselves. Add a short fixture timeout and clean all created files/processes.
- [ ] Run intended RED against current docs (Heroku example missing and gh example uses fixed Homebrew paths). Keep the fake external boundary explicit.
- [ ] Replace the personal `/Users/petr`/fixed-Homebrew gh example with both portable home-directory examples matching the user's wrapper. Explain profile/env-mapping setup using placeholders, installed real CLIs, PATH/chmod/macOS session requirements, and manual path paste/optional picker in Integrations. Update all General→Terminal hosts references to Integrations and explain distinct vs duplicate context without promising ownership/permission evidence.
- [ ] Run wrapper GREEN plus all newly affected fixture suites; `git diff --check` and, when staging is later authorized, staged whitespace checks for new files. Audit full-suite real external-call boundaries before running it; if safe under the user's data restriction, run full `xcodebuild -scheme "Quick Access for Pass" test`, otherwise clearly report focused scope and the unperformed full/live checks.
- [ ] Review complete uncommitted cleanup diff against the spec: no identity/cache/verification/provider-limit changes, no secret/Offline effects, no custom execution, preserved opt-out/corrupt-state behavior, no clipping or stale geometry, working manual paths and accurate supported catalog.
- [ ] Deliver verified counts/failures/warnings and unperformed live/install/VoiceOver checks. No automatic commit, install, push or app launch; request permission separately.

## Self-review and handoff

The three independently testable deliverables cover the approved mockup/manual-path requirements and new wrapper examples. Backend validation remains store-owned and atomic; pure header rows do not become authorization state; geometry remains controller-owned and request-guarded. All five Review Focus cases have explicit owning tests. Review the spec/plan before execution, keeping the current-checkout/no-live-data constraints. The previous commit962addb is the recovery baseline; ignored mockup/evidence stays retained.
