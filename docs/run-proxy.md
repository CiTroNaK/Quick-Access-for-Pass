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

Shell aliases are convenient for interactive terminals, but scripts, launch agents, cron jobs, and other non-interactive shells usually do not expand them. For those cases, create a real executable wrapper earlier in `PATH`. The command still needs to run in a macOS user session where Quick Access can authorize it, unless an existing remembered decision or cache entry applies.

For GitHub CLI, put this wrapper at `/Users/petr/.local/bin/gh`:

```sh
#!/bin/sh
set -eu

QA_RUN="/Applications/Quick Access for Pass.app/Contents/Helpers/qa-run"

if [ -x /opt/homebrew/bin/gh ]; then
  REAL_GH="/opt/homebrew/bin/gh"
elif [ -x /usr/local/bin/gh ]; then
  REAL_GH="/usr/local/bin/gh"
else
  echo "gh wrapper: install GitHub CLI at /opt/homebrew/bin/gh or /usr/local/bin/gh" >&2
  exit 127
fi

exec "$QA_RUN" --profile github-cli -- "$REAL_GH" "$@"
```

Make it executable:

```bash
chmod +x /Users/petr/.local/bin/gh
```

Then make sure `/Users/petr/.local/bin` appears before Homebrew in the environment that runs your command:

```bash
export PATH="/Users/petr/.local/bin:$PATH"
```

Now both interactive and non-interactive commands can call `gh` normally:

```bash
gh auth status
gh api user
```

The wrapper intentionally calls the real `gh` binary by absolute path. Do not use `gh` as the wrapped command inside `/Users/petr/.local/bin/gh`, or the wrapper will recursively call itself.

## Profiles and environment mappings

A Run profile groups environment-variable mappings and cache settings. Each mapping connects one environment variable to one Proton Pass reference.

Example model:

```text
Profile: github-cli
GH_TOKEN=pass://GitHub/token
```

When `qa-run --profile github-cli -- gh auth status` runs, Quick Access resolves the configured secret and the helper launches `gh auth status` with `GH_TOKEN` in the process environment.

## Remembered decisions

Run Proxy authorization decisions are context-aware. They can include the requesting app, subcommand, and profile, so a decision for one command profile does not automatically authorize unrelated commands.

Remembered decisions can be reviewed and cleared from **Settings → Run**.

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
- Secrets are resolved on demand and returned to the trusted helper for the wrapped process.
- Optional profile cache duration is in memory only.

## Related docs

- [README](../README.md)
- [Security policy](../SECURITY.md)
