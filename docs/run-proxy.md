# Run Proxy and `qa-run`

The Run Proxy is an optional integration for injecting Proton Pass secrets into commands at runtime, with Touch ID authorization.

It is designed for command-line tools that need environment variables, such as API tokens for `gh`, deployment tools, or local development commands.

## What it does

Quick Access listens on:

```text
~/.local/share/quick-access/run.sock
```

The bundled `qa-run` helper sends a request to that socket. Quick Access verifies the local peer, resolves configured `pass://` references through Proton Pass, asks for authorization when needed, and returns environment variables to the helper for the wrapped command.

Secrets are not written to disk by Quick Access as part of this flow.

## Setup

1. Open **Settings → Run**.
2. Enable **Enable run proxy**.
3. Create a profile.
4. Map environment variables to `pass://` references.
5. Add the helper alias shown in Settings:

```bash
alias qa-run='/Applications/Quick Access for Pass.app/Contents/Helpers/qa-run'
```

6. Wrap commands with the helper:

```bash
qa-run --profile github-cli -- gh auth status
```

You can also alias a command through a profile:

```bash
alias gh='qa-run --profile github-cli -- gh'
gh auth status
```

## Scripts and non-interactive shells

Shell aliases are convenient for interactive terminals, but scripts, launch agents, cron jobs, and other non-interactive shells usually do not expand them. For those cases, install a real executable wrapper earlier in `PATH`. The command still needs to run in a macOS user session where Quick Access can authorize it, unless an existing remembered decision or cache entry applies. Launch agents and other sessions without the logged-in user's UI may not be able to present authorization.

Create a Run profile named `github-cli` (or `heroku-cli`) in **Settings → Run**, then add the environment-variable mappings required by that CLI. For example, use a placeholder Pass reference such as `pass://GitHub/token` for `GH_TOKEN`; use a separate mapping/profile for Heroku if needed. Replace the helper path below if the app is installed somewhere other than `/Applications`. Install the actual GitHub CLI and Heroku CLI separately using their official distribution instructions; these examples do not install either CLI.

The wrappers pass the command name and every argument as separate quoted arguments. They remove their own directory from `PATH` before starting `qa-run`, comparing existing directories by their physical filesystem paths so trailing slashes, relative paths and symlink aliases cannot point back to the shim. Retained entries keep their original spelling and order (including empty entries, which mean the current directory). Thus `qa-run` resolves the installed command instead of finding the wrapper again. If the command is not installed or cannot be resolved from the remaining `PATH`, `qa-run` reports the failure rather than recursively invoking the shim.

### Wrapper: ~/.local/bin/heroku

```bash
#!/bin/bash
set -eu

QA_RUN="/Applications/Quick Access for Pass.app/Contents/Helpers/qa-run"
SHIM_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RETAINED_PATH_ENTRIES=()
# Append a delimiter so read also retains a final empty PATH entry.
IFS=: read -r -a PATH_ENTRIES <<< "${PATH-}:"
for PATH_ENTRY in "${PATH_ENTRIES[@]}"; do
  PATH_ENTRY_DIR="$(CDPATH= cd -- "${PATH_ENTRY:-.}" 2>/dev/null && pwd -P)" || PATH_ENTRY_DIR=""
  if [[ "$PATH_ENTRY_DIR" != "$SHIM_DIR" ]]; then
    RETAINED_PATH_ENTRIES+=("$PATH_ENTRY")
  fi
done
PATH_WITHOUT_SHIM="$(IFS=:; printf '%s' "${RETAINED_PATH_ENTRIES[*]}")"

exec env PATH="$PATH_WITHOUT_SHIM" "$QA_RUN" --profile heroku-cli -- heroku "$@"
```

### Wrapper: ~/.local/bin/gh

```bash
#!/bin/bash
set -eu

QA_RUN="/Applications/Quick Access for Pass.app/Contents/Helpers/qa-run"
SHIM_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RETAINED_PATH_ENTRIES=()
# Append a delimiter so read also retains a final empty PATH entry.
IFS=: read -r -a PATH_ENTRIES <<< "${PATH-}:"
for PATH_ENTRY in "${PATH_ENTRIES[@]}"; do
  PATH_ENTRY_DIR="$(CDPATH= cd -- "${PATH_ENTRY:-.}" 2>/dev/null && pwd -P)" || PATH_ENTRY_DIR=""
  if [[ "$PATH_ENTRY_DIR" != "$SHIM_DIR" ]]; then
    RETAINED_PATH_ENTRIES+=("$PATH_ENTRY")
  fi
done
PATH_WITHOUT_SHIM="$(IFS=:; printf '%s' "${RETAINED_PATH_ENTRIES[*]}")"

exec env PATH="$PATH_WITHOUT_SHIM" "$QA_RUN" --profile github-cli -- gh "$@"
```

Save the snippets as `~/.local/bin/heroku` and `~/.local/bin/gh` (create `~/.local/bin` first if needed), then make them executable:

```bash
chmod +x "$HOME/.local/bin/heroku" "$HOME/.local/bin/gh"
```

Put `"$HOME/.local/bin"` before the directories containing the real CLIs in the `PATH` used by your terminal or script launcher, and confirm the real `heroku`/`gh` executables are discoverable after the wrapper directory is excluded. Restart terminals or update the relevant session configuration after changing `PATH`. These wrappers are for command-line invocation, not app-managed wrapper generation or installation.

Herdr's optional settings in **Settings → Integrations** only affect best-effort display context in SSH/Run authorization prompts; they are independent of these wrappers and Run profiles. When a distinct Herdr pane title is available, it can appear separately from the command text; an empty or whitespace-equivalent title is omitted by case-sensitive equality, not substring or prefix matching. Display hints are untrusted and do not establish process ownership, permission, or authorization scope.

## Profiles and environment mappings

A Run profile groups environment-variable mappings and cache settings. Each mapping connects one environment variable to one Proton Pass reference.

Example model:

```text
Profile: github-cli
GH_TOKEN=pass://GitHub/token
```

When `qa-run --profile github-cli -- gh auth status` runs, Quick Access resolves the configured secret and the helper launches `gh auth status` with `GH_TOKEN` in the process environment.

## Prompt context and terminal hosts

**Settings → Integrations** contains the supported-app and custom-terminal settings shared by SSH and Run prompts. Herdr is automatically detected and enabled on first detection, including nonstandard installations encountered in requester ancestry. Rename or disable its entry, turn off **Show Herdr pane details**, or choose **Add Custom Terminal…** to add a custom mapping. In the editor, paste an absolute or `~`-relative executable path (spaces are supported) or use the optional **Choose…** picker; entering a path only records a mapping and never runs that executable. Explicit opt-out and edits survive rediscovery/restart; an unavailable installation remains listed. A custom mapping of the same executable suppresses automatic Herdr activation even when disabled. Custom mappings are not launched. Existing identified macOS apps keep their names/icons. Path, picker, and mapping availability do not establish ownership or permission evidence.

For the verified `qa-run` helper, app identity is attributed through its parent. The separate display-only process snapshot includes the helper and its bounded ancestry, so inherited Herdr socket/pane hints remain available even when the parent shell's kernel-visible environment lacks them. The helper is not promoted to an authorization identity. Best-effort Herdr context may show the requesting pane's workspace/tab, title, and working directory. These untrusted hints are display-only, not an authorization identity or permission scope. A detached helper's authorization identifier remains `unknown` regardless of the displayed terminal name; app/team IDs, subcommand/profile scopes, session decisions, and remembered decisions are unchanged. Unverified peers are rejected before header/model lookup.

Base prompts/countdowns never wait for metadata. Only a displayed eligible prompt receives one bounded lookup (750 ms total); cache-covered requests do not enrich. Configuration changes clear details and cancel active work. Unavailable or ambiguous context leaves the base prompt usable. Metadata is request-scoped in memory, never persisted or audited. No pane output, transcripts, or agent session files are accessed.

## Remembered decisions

Run Proxy can remember either an approval or a denial for the selected duration, bounded by the requesting app identity and profile. The authorization prompt defaults to **Exact command**: the complete ordered argument vector received from `qa-run`, including the executable string, flags, values, empty arguments, and argument boundaries. Matching uses literal UTF-8 bytes without normalization or shell parsing. Changing an argument, its order, or its grouping produces a different exact identity. For example, `gh api "user repos"` is not the same as `gh api user repos`. The natural exact-command text is presentation only, not a shell command or matching key; arguments that need boundary-preserving display remain quoted and escaped.

Where available, **Broader scope** choices retain the existing command-prefix behavior and must be selected explicitly. They can match commands with different arguments. Existing legacy broad decisions are retained without migration or reset and can still apply to a changed command. Exact scope does not bind the working directory, environment, or executable contents; the same executable string can refer to a changed binary. Version commands such as `gh --version` are not automatically approved.

Matching checks exact scope first, then existing prefixes from narrowest to broadest, across both session and persistent decisions. A broader session approval cannot override a more specific remembered denial. Within the same scope, a current session decision takes precedence. **Do Not Remember** avoids a persistent decision but still uses the existing **10-second** in-memory burst cache for approvals and denials. Other remember durations, including Forever, are unchanged. This authorization cache is separate from the profile's resolved-secret cache.

A denial already matching at the initial check prevents secret resolution. A request waiting in the authorization queue is checked again when it reaches the front: a newly applicable queued denial prevents release of environment variables to the helper, but does not undo secret resolution that may already have happened. It cannot recall values already released.

### Stored command text and managing decisions

Exact authorization identity remains `exact-argv-v1` plus the unchanged full SHA256 digest over the ordered received argv; the digest is not encryption and is never shown in Settings. To make remembered decisions readable, the encrypted Run authorization table now also stores the full received command text. This is a narrow policy change: caller-supplied arguments can themselves contain tokens or passwords, so stored command text is not guaranteed redacted or secret-free. Do not put resolved profile environment variables, fetched Pass secrets, or Offline Mode snapshots into this field. Full command text is not written to public logs, FTS, UserDefaults, App Group storage, or an unencrypted sidecar. Explicit broader prefixes retain their literal matching value and are identified as command prefixes in Settings.

Open **Settings → Run → Manage Run decisions…** to review remembered approvals and denials. Rows show the full stored command text in the primary label and help, plus a localized **Exact command**, **Command prefix**, or **Unknown matching type** description with outcome, profile, and expiration. Display text never participates in matching, uniqueness, selection, or removal; persistent rows have stable IDs and matching still uses typed app/profile/type/value identity.

On the v14 upgrade, only strictly valid old exact-v1 fingerprint-only decisions are removed once because their original command text cannot be recovered. Malformed exact-looking values, literal prefixes, and other rows remain as command-prefix rules. Removing an old exact entry does not promise an unconditional prompt: another remembered broad rule or a live burst-cache decision may still apply.

Each decision retains its app, profile, outcome, expiration, and **Remove** action. Remove a remembered decision to require authorization again once any applicable brief session cache expires (another explicit broad decision may still match). Use **Done** or Escape to close the sheet. Run profiles remain in the main Run settings.

## Secret cache duration

Profiles can configure an in-memory cache duration. During that period, Quick Access can reuse resolved secrets for the same profile without fetching them again from Proton Pass.

The cache is in memory only. Secrets are not persisted locally by Quick Access.

## Peer verification

Run Proxy peer verification is mandatory. Quick Access rejects unverified local clients and only accepts trusted signed apps and the bundled `qa-run` helper.

This prevents arbitrary local processes from impersonating the helper and requesting secret injection.

## Troubleshooting

If `qa-run` cannot connect:

1. Confirm **Settings → Run → Enable run proxy** is on.
2. Confirm the helper alias points to `/Applications/Quick Access for Pass.app/Contents/Helpers/qa-run`.
3. Check the Run status row in Quick Access settings.
4. Confirm the selected profile exists and contains the expected environment mappings.
5. Re-authorize the command if a remembered deny decision is blocking it.

If a command does not receive an expected variable, review the profile mapping and confirm the `pass://` reference resolves through Proton Pass.

## Security notes

- The Run Proxy socket is local and owner-only.
- Peer verification rejects unverified local clients.
- Secrets are resolved on demand through Proton Pass and returned to the trusted
  `qa-run` helper for the wrapped process.
- Quick Access uses the bundled, signed `qa-env-export` helper internally to read
  only approved environment variables through a private FIFO channel; it does
  not print resolved secrets to stdout/stderr or persist them to disk.
- Optional profile cache duration is in memory only.
- Full caller-received command text for remembered decisions is stored only in the encrypted authorization table and may itself contain credentials; it is not redacted or secret-free by guarantee.

## Related docs

- [README](../README.md)
- [Security policy](../SECURITY.md)
