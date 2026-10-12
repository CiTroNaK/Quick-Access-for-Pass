# Integrations and requester UI cleanup

## Approved intent

The user approved the browser mockup and specifically requested a new settings pane, separate lists for supported third-party apps and custom mappings, and manual executable-path entry because developers paste paths from terminals. The user also requested documentation examples matching their Heroku/GitHub CLI wrapper.

## Settings

- Add **Integrations** before About; remove terminal-host configuration from General. Reuse the existing shared TerminalHostStore, native SwiftUI controls and persisted raw settings-tab values.
- **Supported apps** lists the supported catalog even if an app is absent. Initially only Herdr has a pane-detail integration; do not claim other providers exist. Show detected/unavailable/not-configured or custom-override state without confusing saved enablement with availability.
- Herdr has its saved enable toggle, a pane-detail toggle, detected/configured path, and an Edit sheet for display name. Do not let an ordinary edit change its provider or discovery provenance.
- **Custom terminal hosts** contains a compact list or empty state, plus Add. Existing custom rows have enable, Edit and Remove. No permanently exposed name editors or large empty scroll area.
- Add/Edit custom sheets include Display name, a pasteable Executable path text field and an optional Choose file button. Support absolute paths and `~` home paths, including spaces. Trim surrounding input whitespace and expand home notation as filesystem input; never evaluate shell text, environment-variable expressions or run an entered executable.
- Saving validates the entire entry before any persistence or notification. Invalid names, directories, missing/nonexecutable files, and canonical duplicate paths keep the sheet open with a localized inline error and no partial addition. Editing only name/enablement still works when an existing executable is unavailable. Cancel writes nothing.
- Preserve corrupt-preference reset confirmation, explicit opt-out, custom-collision suppression and automatic choices. Never promote a custom mapping into a metadata provider.

## Authorization dialogs

- Match ordinary SSH/Run dialogs: center the icon-and-name block, with the icon left of the name. Metadata must not alter its alignment.
- Show a separate left-aligned bounded context stack: workspace/tab, optional distinct pane title, working directory.
- Compare pane title with the actual displayed authorization command (SSH only when its command row is visible; Run's complete displayed command). Omit a missing/empty title or a whitespace-equivalent duplicate. Equality remains case-sensitive, not substring/prefix matching; preserve the original command and distinct title values.
- Omitted fields produce no invisible rows or fixed empty metadata area. Base presentation appears immediately. When usable context arrives or is cleared, safely fit the panel while preserving its top edge and width; never clip permission controls or restart countdown/focus/auth state. Old request geometry callbacks cannot resize the next request.
- Keep field-length/one-line truncation and accessibility labels, hide decorative icons, and announce context availability accessibly without reading secrets.
- Keep metadata untrusted, memory-only, display-only and once-per-request. Preserve provider deadlines/caps, cancellation/configuration guards, Run parent-derived identity and mandatory peer verification, and all remembered/session scopes.

## Developer documentation

This requirement is documentation-only: do not add wrapper templates, generation, installation controls or execution features to the app. Test fixtures may validate the examples but must remain in the test target.

Document complete `~/.local/bin/heroku` and `~/.local/bin/gh` Bash wrappers using the proven pattern: calculate the shim directory, remove it from PATH, then `exec env PATH=...` the installed qa-run helper with `--profile heroku-cli` / `github-cli`, the real command name and `"$@"`. Explain profile setup, argument safety, preventing recursion, PATH ordering, chmod, noninteractive macOS-session requirements, real CLI installation, and the separation from optional Herdr metadata. Use placeholders only, not personal absolute paths or credentials. Test examples with fake helpers/commands and temporary PATH fixtures, never real Pass CLI/Heroku/GitHub services.

## Builder calls and boundaries

- Use native macOS15/Swift6 UI, existing localization and Swift Testing, no dependencies or schema migration. Use a settings width sufficient for nine native toolbar items (initial proposal 560pt); do not scale down ordinary controls to fit.
- Use a content-sized custom list for short lists and a bounded scroll region for longer lists. Keep general/security/proxy settings otherwise unchanged.
- Record compact conditional-row sizing as replacing the previous immutable blank-slot strategy; controller-owned top-anchored resizing must be covered before removing reservation.
- Work in the existing checkout, not a worktree. No additional commit/push/install/app launch or Pass CLI data access is authorized by this design approval. The already-running mockup server is only a visual aid.
- Existing whole-feature full-suite evidence predates this cleanup. Focused fixture tests are mandatory; a full-suite run requires verifying it cannot access live CLI data under the user's restriction. Never report unperformed live UI/VoiceOver checks as passed.

Mockup: `.superpowers/brainstorm/71704-1791739991/content/integrations-and-requester-headers.html` (ignored, visual reference only).
