# Inject command secrets with `qa-run`

Use Run Proxy to start a command with environment variables resolved from Proton Pass. Quick Access verifies the requester and asks for authorization unless a cached decision applies.

## Create a profile

1. Open **Settings → Run**.
2. Enable **Enable run proxy**.
3. Create a profile, such as `github-cli`.
4. Add the environment-variable mappings required by the command.

For example, map `GH_TOKEN` to a reference such as `pass://GitHub/token`. Replace that placeholder with your actual reference. Install the GitHub CLI separately.

## Run a command interactively

Add the helper alias shown in Settings to your shell configuration. If the app is installed elsewhere, change the path:

```bash
alias qa-run='/Applications/Quick Access for Pass.app/Contents/Helpers/qa-run'
```

Wrap the command with the profile name:

```bash
qa-run --profile github-cli -- gh auth status
```

To route interactive `gh` calls through that profile, use:

```bash
alias gh='qa-run --profile github-cli -- gh'
gh auth status
```

Authorize the request when Quick Access prompts. Resolved values travel through a private FIFO and process environments, not persistent secret files. Remembered command text can contain credentials supplied in arguments. See the [Run Proxy reference](run-proxy-reference.md#stored-command-text) before remembering commands with sensitive arguments.

## Run from a script or noninteractive shell

Aliases usually do not expand in scripts, launch agents, or cron jobs. Use an executable wrapper earlier in `PATH` instead.

The command still needs a macOS user session where Quick Access can authorize it, unless a remembered decision or cache entry applies. A session without the logged-in user's UI may be unable to show a prompt.

1. Create the required profile in **Settings → Run**.
2. Install the actual CLI separately.
3. Create the wrapper directory:

```bash
mkdir -p "$HOME/.local/bin"
```

4. Save the following wrapper as `~/.local/bin/gh`:

```bash
#!/bin/bash
set -eu

QA_RUN="/Applications/Quick Access for Pass.app/Contents/Helpers/qa-run"
SHIM_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RETAINED_PATH_ENTRIES=()
# The extra delimiter retains a final empty PATH entry.
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

The wrapper removes its own directory from `PATH` before `qa-run` resolves `gh`. Physical-path comparison also removes trailing-slash, relative-path, and symlink aliases of that directory. Other entries keep their spelling and order, including empty entries for the current directory. This prevents the wrapper from calling itself.

5. Make the wrapper executable:

```bash
chmod +x "$HOME/.local/bin/gh"
```

6. Put `"$HOME/.local/bin"` before the real CLI directories in the launcher's `PATH`.
7. Restart the terminal or update that launcher's environment.
8. Confirm that the real `gh` remains discoverable when the wrapper directory is excluded.

If the real command is absent, `qa-run` reports a resolution failure rather than recursively invoking the wrapper.

For Heroku, create a separate `heroku-cli` profile and a `~/.local/bin/heroku` wrapper. Use the same script with this final line:

```bash
exec env PATH="$PATH_WITHOUT_SHIM" "$QA_RUN" --profile heroku-cli -- heroku "$@"
```

Make that file executable and configure the environment variables the Heroku CLI needs. These examples do not install either CLI or create app-managed wrappers.

## Choose authorization scope

Use the default **Exact command** scope when the approval must match the full received arguments. Select **Broader scope** only when you intend to approve or deny a command prefix with other arguments.

Exact scope does not bind the working directory, environment, or executable contents. **Do Not Remember** still retains a 10-second in-memory decision. The [authorization reference](run-proxy-reference.md#exact-command-scope) defines argument matching, prefix precedence, and queued denials.

## Remove a remembered decision

1. Open **Settings → Run → Manage Run decisions…**.
2. Review the stored command, outcome, profile, and expiration.
3. Use **Remove** on the selected row.
4. Use **Done** or Escape to close the sheet.

Another broad decision or a live burst-cache entry can still apply after removal. Run profiles remain in the main Run settings.

## Adjust caching and requester display

Set a profile's cache duration in **Settings → Run** to control its in-memory resolved-secret cache. The cache is separate from approval and denial decisions. It never uses offline snapshots.

Use **Settings → Integrations** for terminal names and Herdr pane details. Those labels are untrusted display context and do not change identity, command scope, or profile scope. See [Terminal-host context](terminal-hosts.md).

## Diagnose connection or injection failures

1. Confirm **Enable run proxy** is on.
2. Confirm the alias or wrapper uses the installed app's `Contents/Helpers/qa-run`.
3. Check the Run status row in Settings.
4. Confirm the profile exists and its mappings use the intended references.
5. Review remembered denials if the command is blocked.

If a variable is missing, review its mapping and confirm the reference resolves through Proton Pass. Do not paste its resolved value into a support report.

The [Run Proxy reference](run-proxy-reference.md) describes peer verification, storage, and authorization. The [security policy](../SECURITY.md#run-proxy-authorization-boundary) defines the limits.
