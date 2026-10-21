# Shared terminal-host presentation

## Approved intent

Replace the newly added hardcoded Herdr SSH presentation with configurable terminal-host mappings, shared by SSH and Run authorization windows. Put Terminal hosts in Settings → General. Herdr should configure itself when installed, without requiring the user to select its executable. Show Herdr workspace/tab, pane title, and working directory when the requesting pane can be matched reliably.

## Settings and discovery

- General contains Terminal hosts, with the explanation “Used by SSH and Run authorization.”
- A mapping contains an executable path, display name, enabled flag, and provider kind (generic or Herdr). All mappings use a terminal symbol; custom icon selection is out of scope.
- Add Executable… opens a file picker for an executable rather than a .app. Users can edit the display name, disable entries, and remove custom entries.
- Detect Herdr on app startup, when General settings opens, and from a matching executable encountered in requester ancestry. Detection uses filesystem inspection, not a login shell or executing arbitrary candidates.
- Automatically create one enabled Herdr entry with name Herdr and “Show Herdr pane details” enabled. The automatic entry can be disabled and edited. Keep it visible when its executable is temporarily unavailable, with an unavailable indication. Do not recreate removed custom entries or overwrite user edits. An explicit Herdr disable survives rediscovery and restart.
- An existing generic mapping of the same canonical executable, enabled or disabled, suppresses automatic Herdr matching/provider activation. Discovery never promotes or overwrites it, including after upgrades. Keep an existing automatic entry's saved choices without using its provider when a generic collision exists.
- Saved preferences are structurally validated independently of executable availability. Require a currently executable regular file only when adding/selecting a new path; disabling/renaming an unavailable entry remains possible.
- Keep the existing SSH-only Show command for apps setting separate; its existing authorization-context behavior must not change.

## Presentation and identity

A shared resolver matches canonical executable paths in the requester's bounded process ancestry. Match the nearest enabled configured host only when ordinary app identification found no app. Existing app names/icons take precedence.

The mapping changes only the displayed name/icon/details. Never replace bundle IDs, team IDs, requester names used for identity, SSH cache IDs, Run subcommand/profile scopes, or cached decision keys with mapping labels. Do not reinterpret the existing showCommand property. Run still rejects unverified clients before any presentation lookup.

Both windows share a requester header component; their existing SSH key/command/host and Run command/profile content remains unchanged. Run app/authorization attribution follows the trusted qa-run helper's parent, not the helper itself. Its separate display snapshot includes the verified helper and bounded ancestry, preserving helper-only inherited socket/pane hints; helper PID/start time and parent coherence are revalidated, and the identified parent must still match the captured helper parent. In particular, a detached helper's current Run authorization identifier remains "unknown", not the display name.

## Herdr details

Use Herdr's read-only API through its CLI to obtain snapshot metadata and pane process information. The installed CLI currently supports api snapshot and pane process-info --pane ID. Snapshot records expose workspace/tab labels, terminal_title_stripped, foreground_cwd/cwd, and stable IDs. Process information exposes shell_pid.

Route to the requesting process's Herdr socket, not the Quick Access application's inherited Herdr session. Read only the HERDR_SOCKET_PATH and HERDR_PANE_ID context hints from an appropriate ancestor's process arguments/environment. They are untrusted routing hints, not identity proofs. Check an absolute local socket owned by the current user; do not use remote forwarding, attach/create a session, launch a server, or read pane contents.

Carry the selected terminal-host process boundary and one coherent socket/pane hint pair with its process provenance into enrichment. Correlate the returned pane shell PID only with live requester-side ancestors below that host; validate requester/ancestor start times and parent-chain coherence to reject recycled PIDs. Never combine conflicting hints from different processes or cross nested hosts. Pane IDs/focus alone are insufficient. If an inherited ID is stale, bounded candidate scanning may locate the pane by shell PID. Complete the eligible scan before publishing; ambiguous, incomplete, or over-limit scans produce no details. Validate returned process_info.pane_id and join snapshot workspace/tab/pane arrays by IDs. Revalidate the entire candidate pane/workspace/tab association set and socket identity. Any visibly added, removed or reassociated candidate produces fallback without a rescan; array order and display-only label/title/directory updates do not invalidate stable associations. A matched-pane move/close or socket replacement also produces fallback. This is conservative point-in-time display attribution, not an atomic ownership guarantee.

Render workspace/tab labels, pane title, and working directory only after a successful match. Omit unavailable fields and do not invent labels. Hide control characters, bound field lengths, and abbreviate the current user's home directory as ~. Labels and directories are informational hints and can be spoofed by local processes.

Metadata enrichment starts only when a dialog is actually presented. Show the base header immediately; do not extend countdowns or wait for metadata. No enrichment for cache-covered requests. The header model owns one cancellable operation and subscribes explicitly to store changes, including after details publish. Disable/configuration changes immediately clear details and cancel active work. View-task cancellation, disappearance, normal decision/dismissal/queue advance and cancelAll all invalidate/cancel the active model. Publication checks reject even a provider returning after cancellation. Re-enabling may start a first attempt if none ever started, but never retries an already cancelled/completed attempt.

Reserve three immutable one-line detail rows before enrichment for a process-backed unattributed terminal requester, even if its mapping/details are initially disabled or suppressed. A later first enable/new mapping cannot clip controls in the initially sized panel. This bounded blank space does not change provider eligibility and empty rows are accessibility-hidden; identified-app headers need none. Preserve localized subtitles and accessibility.

## Builder decisions and limits

These are implementation choices, not additional user requirements:

- Use existing macOS 15 / Swift 6 strict-concurrency conventions and native frameworks; no dependencies or database migration.
- Persist only mapping preferences as versioned JSON in UserDefaults. Keep pane metadata request-scoped in memory; never persist it or add it to audit logs.
- One enrichment attempt per displayed request. Use a single 750 ms absolute deadline, a 512 KiB stdout cap per CLI operation, at most 32 candidate panes, and at most four concurrent process-info requests. Timeout, excess output, malformed JSON, inaccessible socket, missing process, disabled entry, or ambiguity leaves the base header usable.
- Initially support verified Herdr protocol 22/type envelopes; unsupported versions and optional/null candidate shell PIDs produce conservative base-header fallback. Neutralize inherited HERDR_* routing context (key names only), setting only the validated requester socket.
- Inject a single monotonic now source into the provider, default real uptime unchanged, so synthetic ownership tests are deterministic under full-suite load. Real native deadline/admission/cancellation tests stay real; initial capture and all checks use one clock and the same original 750 ms budget.
- Use CLIRunner's existing bounded native process execution, cancellation, output cap, and termination handling. Execute only the detected/matched Herdr executable with fixed read-only argument arrays; never run a generic user mapping for discovery.
- Discover common installation candidates /opt/homebrew/bin/herdr, /usr/local/bin/herdr, ~/.local/bin/herdr and executable candidates from the GUI app's PATH; observe ancestry for nonstandard paths. Resolve symlinks for matching but retain the installation path for future updates.
- No new launch daemon, periodic pane polling, transcript access, agent-session-file access, secrets inspection, or permission migration.

## Verification and documentation

Use Swift Testing with isolated defaults, filesystem fixtures, process snapshots, bounded-runner doubles, and in-memory authorization databases. Verify configuration persistence, actual pathname matching, opt-out survival, pane ownership, malformed/slow API fallback, cancellation/stale response handling, both dialog integrations, and invariant authorization scopes. Run the full xcodebuild test suite. Manually inspect both dialogs from a real Herdr pane after a user-approved install, including long labels and disabled details.

Update README, both proxy guides, SECURITY, and AGENTS architecture guidance to describe shared settings and display-only untrusted metadata. No Offline Mode changes are included.
