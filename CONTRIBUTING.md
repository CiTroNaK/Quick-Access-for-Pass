# Contribute to Quick Access for Pass

Use this guide to build the app, test a change, and open a pull request. Read [AGENTS.md](AGENTS.md) for the full architecture and repository constraints.

## Build the app

1. Fork the repository and clone your fork.
2. Open `Quick Access for Pass.xcodeproj` in Xcode.
3. Select the **Quick Access for Pass** scheme.
4. Build and run with `⌘R`.

The app appears in the menu bar. A separate Pass CLI installation is not required to build or test. Runtime secret access needs a working CLI session.

Use these commands from the repository root:

```bash
# Build Release.
make build

# Build Debug.
xcodebuild -scheme "Quick Access for Pass" -configuration Debug build

# Run the default test suite.
xcodebuild -scheme "Quick Access for Pass" test
```

Use Xcode 27 for the current CI toolchain. Keep source compatible with Xcode 26.6, which CodeQL requires. The [CI workflow](.github/workflows/ci.yml) uses the `xcode-27` preview runner. The [CodeQL workflow](.github/workflows/codeql.yml) selects Xcode 26.6 on `macos-26` because traced extraction does not support Xcode 27 or macOS 27.

## Install a development build

`make install` builds the app, adds the bundled helpers, copies the app to `/Applications`, and launches it. Run that command only when you intend to replace your installed app.

The install step reuses the built host's signing certificate for the CLI helpers and host app. Automatic selection uses the certificate fingerprint, which avoids ambiguity between same-name certificates and encoding problems in accented names.

For an unsigned or ad-hoc build, provide an explicit identity:

```bash
SIGN_IDENTITY="<certificate fingerprint or signing identity>" make install
```

Use an identity that matches the host provisioning profile and the embedded AutoFill extension's signing configuration.

## Prepare a change

1. Create a branch from `main`.
2. Add or update regression tests for the behavior you change.
3. Keep shared mutable state in an `actor` and UI orchestration on `@MainActor`.
4. Use `Sendable` values across actor boundaries.
5. Keep `AppDelegate` focused on composition rather than lifecycle logic.
6. Update documentation when behavior, setup, architecture, or security guarantees change.

Use Swift Testing with `@Suite`, `@Test`, `#expect`, and `#require`. Do not add XCTest tests. Prefer real implementations with controlled inputs over broad mocks. Use the existing GRDB.swift dependency rather than adding a package without discussion.

For accessibility, label icon-only buttons with `.accessibilityLabel`. Hide decorative images with `.accessibilityHidden(true)`. Mark selection with `.accessibilityAddTraits(.isSelected)` and announce asynchronous state changes with `AccessibilityNotification.Announcement`.

## Preserve secret and authorization boundaries

Keep fetched Pass content out of ordinary database tables, FTS, logs, and presentation metadata. Sync may hold full CLI items temporarily to derive metadata. Ordinary live actions fetch values on demand.

Persist selected offline secrets only in encrypted `offlineSnapshots`. Cover individual selection without whole-vault consent in tests. Keep snapshots out of SSH and Run proxies. The AutoFill extension may receive a requested password or TOTP value through the verified host broker, but never cache access or diagnostics.

Folder features require the shared active-executable capability gate at Pass CLI **2.5.0+**, not cached health or persisted names. Test same-path reprobes, old/unknown CLI, incomplete discovery, recursive future/moved membership, independent overlap/exclusions, pre-fetch capture ownership, and downgrade retention/removal. Search folder paths are presentation-only: never add folder matching/ranking/filtering or SSH folder scopes. Settings rows consume committed set-based metadata; no database, CLI, or secret reads in row bodies. Keep native checkbox/disclosure keyboard behavior, literal full-path help/accessibility, selected traits, locale-bound resources, and fixed non-secret error announcements. Use only synthetic metadata for UI inspection. Main Offline Settings stays compact; the folder tree is in a bounded native manager with its footer outside list scrolling. Picker-only folder-name/path filtering is allowed there, but must not change Quick Access or item-manager matching. Test 40/1300-row bounds, ancestor context, inherited/independent coverage, capability loss with active filters, literal duplicate names, and dismissal during service-owned work. Done closes presentation only; checkbox changes retain immediate-apply behavior.

Keep selection authority and release proofs in the repository and database. Use the database-owned release authority for invalidation ordering and `SecretReleaseGuard` for final lifecycle validation. Put catalog-mutation fixture helpers in the test target only.

Retain `PeerVerifier` checks for Run clients. Keep the AutoFill extension IPC-only. The host owns Pass CLI, unlock UI, Keychain access, storage, and resolution. Protocol v3 allows at most 20 in-memory, non-secret candidate records.

Remembered Run command text is a separate persistence exception. Caller-supplied arguments can contain credentials. Preserve the encrypted-table restriction and do not describe that text as redacted or secret-free.

Read [SECURITY.md](SECURITY.md) before changing these boundaries.

## Add reliable tests

Use in-memory `DatabaseManager` instances for persistence logic. Use a temporary encrypted pool when a test must verify `DatabasePool` scheduling.

Keep test load separate from security deadlines:

- Use `FixtureSetupExecutor` when synchronous database setup causes measured contention. Keep test bodies parallel and preserve encryption, migrations, deadlines, and assertions.
- When a fake AutoFill clock is needed, drive its watchdog sleeper with the same `ManualDeadlineClock`. Keep native CLI deadline tests on real time.
- Observe delayed diagnostics after the deadline-bound operation returns, not inside its result path.
- For native deadline fixtures, use `CLIRunnerTestTaskExecutor` when needed to keep caller continuations off a busy cooperative pool. Forward the original absolute deadline. Do not replace `MainActor` isolation or production executors.
- Give native timeout fixtures a finite exit path. Do not busy-spin or leave inherited pipe writers running. After TERM, use a small builtin write to cross an output cap rather than requiring a child launch or large transfer.
- Keep AppKit rendering on `MainActor` and move expensive pure pixel comparisons off the UI thread. Inject outside-click monitoring instead of consuming desktop input.

Add regressions for migrations, concurrency, recovery, and security changes. For SSH or Run changes, cover probes and lifecycle behavior.

### Test keyboard focus

The hosted search-focus test needs exclusive access to an unlocked desktop. Run it alone, without interacting with other apps:

```bash
TEST_RUNNER_QA_RUN_FOCUS_UI_TESTS=1 xcodebuild -scheme "Quick Access for Pass" test \
	-only-testing:"Quick Access for Pass Tests/SearchFocusRequestTests"
```

Keep deterministic focus-retry and native field-editor checks in the default suite.

### Test AutoFill

Use injected fakes or temporary fixtures. Never access real credentials, Keychain items, or the production database.

Cover the 20-candidate limit, nonempty typed global search, and explicit host-local app associations. Keep offline resolution in the host broker and keep selection, source, and cache diagnostics out of the extension.

For a release change, have the owner validate an isolated account with non-production fixtures. Cover Safari, a native app, exact-subdomain ranking before parent domains, typed global search, and association opt-in. Also cover repeat ranking, host unlock, Cancel, an unavailable host, and a passkey request that displays the password and TOTP picker. Do not inspect or record credential values.

## Localize interface changes

Use `Quick Access for Pass/Resources/Localizable.xcstrings` as the shared English and Czech catalog. Keep its resource membership in both targets. Do not duplicate the catalog or load translations from an installed host app.

Localize visible text, native placeholders, accessibility labels and help, announcements, statuses, and presented errors. Prefer generated `LocalizedStringResource` symbols for new messages. Add manual extraction state and translator comments for interpolated values.

Localize native controls and runtime `String` values explicitly. `Text(String)` does not localize them automatically. Preserve titles, usernames, domains, commands, and technical values verbatim. Pass the view locale to formatters and native-control updates.

Use catalog plural forms, not English suffixes. Test English and Czech counts 0, 1, 2, and 5. Preserve printf argument positions and types. Keep Czech units nonempty and marked translated. Do not change global locale preferences in tests.

Build both targets and keep `LocalizationBundleTests` plus native-control, formatter, accessibility, and value-preservation tests. Compiler extraction alone misses runtime strings.

The expected standard validator and fixture suite are absent from this checkout. When those files are present, run:

```bash
xcodebuild -scheme "Quick Access for Pass" -derivedDataPath build/ build
python3 -m unittest discover -s scripts/tests -p 'test_verify_localizations.py'
python3 scripts/verify-localizations.py \
	--catalog "Quick Access for Pass/Resources/Localizable.xcstrings" \
	--stringsdata-root build/Build/Intermediates.noindex \
	--app "build/Build/Products/Debug/Quick Access for Pass.app"
```

Report missing validation tools as a limitation. A few compiled-string checks do not replace catalog, compiler-extraction, and independent-bundle validation.

## Open a pull request

1. Run the full test command and report every failure.
2. Run `git diff --check`.
3. Review the changed code and documentation.
4. Open a pull request against `main`.

Use a Conventional Commits title, such as `fix: preserve offline copies after a failed refresh`. Use `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`, `perf:`, or `security:` to describe the change.

Keep the description short. State what changed, why, and how you checked it. Link long reports instead of pasting logs. Do not describe a focused test pass as a passing full suite. CI must pass before merge.

## Configure release signing

For the tag-triggered [release workflow](.github/workflows/release.yml), configure these repository secrets:

- `APPLE_CERTIFICATE_P12` and `APPLE_CERTIFICATE_PASSWORD` for the Developer ID Application certificate.
- `APPLE_PROVISIONING_PROFILE` for the host profile named `Quick Access for Pass - Developer ID`.
- `APPLE_AUTOFILL_PROVISIONING_PROFILE` for the extension profile named `Quick Access AutoFill - Developer ID`.
- `APPLE_TEAM_ID`, `APPLE_ID`, and `APPLE_APP_SPECIFIC_PASSWORD` for notarization.
- `HOMEBREW_TAP_TOKEN` for the Homebrew update.

Encode each provisioning profile without line wrapping:

```bash
base64 < profile.provisionprofile | tr -d '\n'
```

Use the installed profile names. The workflow maps both bundle IDs during export and checks the signed host and extension before notarization. Do not use the retired `APPLE_PROFILE_NAME` secret.

For project structure and coordinator responsibilities, see [AGENTS.md](AGENTS.md#project-layout). For private vulnerability reports, use the [security policy](SECURITY.md#reporting-a-vulnerability) rather than a public issue.
