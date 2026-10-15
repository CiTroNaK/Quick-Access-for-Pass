# Proton Pass CLI integration

Quick Access for Pass talks to Proton Pass through Proton's official `pass-cli`. For the simplest setup, install the signed app: it includes the CLI inside the app bundle, so you do not need Homebrew, Terminal setup, or a separate CLI install.

If you manage apps with Homebrew, you can install Quick Access that way and fetch updates through your normal `brew` workflow. Quick Access also supports an already installed Proton Pass CLI for users who want to manage CLI updates themselves.

## Bundled CLI fallback

Signed releases include Proton's official macOS CLI binaries in versioned helper directories inside the app bundle:

- `Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.4.2/pass-cli-arm64`
- `Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.4.2/pass-cli-x86_64`
- `Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.3.3/pass-cli-arm64`
- `Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.3.3/pass-cli-x86_64`
- `Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.3/pass-cli-arm64`
- `Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.2.3/pass-cli-x86_64`
- `Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.1.4/pass-cli-arm64`
- `Quick Access for Pass.app/Contents/Resources/ProtonPassCLI/2.1.4/pass-cli-x86_64`

The newest bundled version is the recommended version and the Auto fallback. Older bundled versions remain selectable so users can roll back temporarily if a newer CLI causes a problem.

On first run, if no installed CLI is discovered, Quick Access uses the bundled helper automatically. You can start login from the notification when it appears, or manually from **Settings → Pass CLI → Log In to Proton Pass CLI…**. With the Quick Access panel open, press `⌘,` to open Settings.

When Pass CLI login is required, Quick Access keeps the main panel usable and shows **Login** in the right sync-status area. Click **Login** to start the existing Proton Pass CLI login flow.

For generic sync failures or skipped-item diagnostics, Quick Access shows **Show sync errors** in the same right sync-status area. That opens a separate diagnostics window with copy/report actions and skipped-item inspect commands.

## CLI selection order

Quick Access chooses the CLI executable from the selected **Pass CLI source**:

1. **Auto (recommended)** — installed candidates first, then `bundled:latest`
2. **Installed path** — the selected discovered path; if it disappears, Quick Access falls back through Auto
3. **Bundled latest** — the newest bundled CLI included in the app
4. **Bundled version** — the selected pinned bundled version; if missing after an app update, Quick Access falls back to bundled latest
5. **Custom path** — the exact path entered by the user; no fallback is attempted

Installed candidates are discovered from `/opt/homebrew/bin/pass-cli`, `/usr/local/bin/pass-cli`, `~/.local/bin/pass-cli`, and `pass-cli` found on `PATH`.

A custom path is authoritative. If you enter one, Quick Access uses exactly that executable and does not fall back to an installed or bundled CLI if the custom path fails. Clear the field to return to auto-detection and bundled fallback.

Quick Access checks authenticated Pass CLI health with `pass-cli info --output json`. This command works in all bundled versions and replaces `pass-cli test`, which Proton removed in version 2.2.4. A separate `pass-cli --version` probe supplies version and compatibility metadata.

## Updating the CLI

The bundled CLI updates only when Quick Access updates. If you want to track Proton Pass CLI releases independently, install `pass-cli` yourself and leave **Pass CLI source** set to **Auto (recommended)** so the installed CLI wins.

## Recommended version warning

Quick Access treats the newest bundled CLI as the recommended version. If the active installed, custom, or pinned bundled CLI reports a version older than the newest bundled version, Quick Access shows a warning in Settings, marks the menu-bar icon with a warning badge, and sends one startup notification.

The warning is advisory. Quick Access does not switch CLIs automatically because doing so could hide version-specific bugs or change the session unexpectedly.

If the latest bundled CLI causes problems, select an older bundled version in **Settings → Pass CLI** and open a GitHub issue with the failure details so it can be investigated.

## Personal access token support

Quick Access can optionally store a Proton Pass CLI personal access token (PAT) in Keychain from **Settings → Pass CLI**.

When a PAT is saved, Quick Access validates it immediately with `pass-cli login`. Later, if the CLI session is lost, Quick Access uses the saved PAT to recreate the session before asking you to use the normal browser login flow from the notification or **Settings → Pass CLI**. Authentication failures during sync (including **⌘R**) request recovery immediately rather than waiting for the next health check. The specific unreadable-session diagnosis stays visible through this path, including when no saved token is available; it is not reduced to a generic logged-out status. Sync does not show **Login** before PAT recovery decides whether manual login is needed; an invalid PAT still shows **Update PAT**.

If the saved PAT is unavailable because your Mac is locked, subsequent logged-out health checks recheck its availability. After unlocking, automatic recovery can resume on the next check (normally every 30 seconds), without opening Settings. Keychain protection remains unchanged, and a completed automatic login attempt is not repeated until a healthy CLI session has been observed.

If login reports **Already authenticated** but an authenticated probe confirms the cached CLI session is no longer usable (including **failed to authenticate: non-existent session** or **Error decrypting local session**), Quick Access clears the stale local CLI session with `pass-cli logout --force` and retries the saved PAT once. The same bounded recovery handles **Error decrypting local session** directly from login. Health checks show **Local CLI session could not be decrypted** for this specific failure and request automatic saved-token recovery; authentication failures during sync also request recovery immediately. Automatic recovery makes one completed attempt per unhealthy episode, resetting only after a healthy session is observed.

Quick Access does not clear a healthy session or clear one merely because a probe times out, encounters a network error, reports a generic decryption error, or cannot access Keychain. It revokes transient host secret access before forced logout and checks cancellation before cleanup and retry. The saved PAT stays in Keychain; it is passed only to login via the child-process environment, never as a command-line argument. Quick Access does not directly delete CLI session files or encryption keys or switch to a weaker key provider.

The CLI's local session can be shared with other invocations using the same session configuration, so recovery may affect those clients. Forced logout removes local session data through the CLI but does not invalidate the old remote session; it may remain listed in Proton account settings. See Proton's [logout documentation](https://protonpass.github.io/pass-cli/commands/logout/) and [session/key-provider configuration](https://protonpass.github.io/pass-cli/get-started/configuration/). A decryption failure does not establish that the saved PAT is expired; recovery cannot guarantee that the underlying session/key mismatch will never recur.

PAT expiration is managed by Proton Pass. Quick Access cannot discover the expiration date or extend a session created from a PAT. If the token expires or is revoked, replace it in Settings or complete the normal browser login flow from the notification or **Settings → Pass CLI**.

## Browser-only session repair

Without a saved PAT, background health checks never silently reset the CLI session. For the specific **Error decrypting local session** failure, Settings and the menu offer **Reset CLI Session and Log In…**. Login actions from the panel or notifications use the same confirmation flow. If browser login encounters this error before producing a URL, Quick Access reports the unreadable session rather than a misleading missing-login-URL error.

The confirmation explains that CLI session cleanup may affect other clients sharing the session configuration and leaves the old remote session listed in Proton account settings. **Cancel** performs no cleanup. After confirmation, Quick Access revokes transient host secret access, runs bounded `pass-cli logout --force`, and starts browser sign-in once using the same selected executable. Cleanup failure or cancellation stops before browser login; a failed restarted login does not cause another reset. The saved PAT and Quick Access's selected offline snapshots are retained. No CLI files or keys are directly deleted by Quick Access.

### Authentication ownership and fresh consent

Browser sign-in/repair, saved-token sign-in/recovery, and explicit logout share one non-queuing authentication owner. The first operation finishes; a competing manual request reports **Sign-in already in progress.** without another confirmation, login, or logout. Settings does not save a replacement token or remove the saved token while another owner is active. Automatic recovery defers contention without consuming its completed-attempt allowance or showing another login prompt, and rechecks current health after token availability lookup. Cancellation keeps ownership until the operation actually unwinds.

Reset consent is bound to the full diagnosed CLI selection. Quick Access rechecks the current unreadable health, selection, and cancellation ownership after confirmation and before queued cleanup begins. If that authority changed, it abandons the request without revocation, cleanup, or an alternate browser login; request login again using the current state. Once admitted cleanup begins, cleanup and the subsequent browser login remain bound to the same executable. These are checks of Quick Access's observed health/configuration, not an atomic lock against other CLI clients.

Session repair retains saved credentials and selected offline snapshots. Explicit user logout remains a separate action: only successful CLI logout triggers its existing offline-data purge; a busy logout performs neither revocation nor purge.

## Provenance

The bundled CLI is not a fork. Quick Access vendors Proton's release binaries under `ThirdParty/ProtonPassCLI/<version>/`, verifies their SHA256 checksums during release preparation, copies them into `Contents/Resources/ProtonPassCLI/<version>/`, and signs the copied helpers so macOS will run them inside the signed app.

Current bundled Proton Pass CLI assets:

| Version | Architecture | Upstream asset | SHA256 |
| --- | --- | --- | --- |
| 2.4.2 | Apple Silicon | `pass-cli-macos-aarch64` | `99e862094fd2a4f82788c9000ba5a92246e7739f86c35a84655b9d7e2adf7227` |
| 2.4.2 | Intel | `pass-cli-macos-x86_64` | `44f7cd45bdfabe34079e6d6ba2ff54e3a3e9e3150046b6cbee326cad52edff18` |
| 2.3.3 | Apple Silicon | `pass-cli-macos-aarch64` | `3281587ac9c50ae2f1604ba75e9d1d39b6debb221b65a6cc56f64d626ede3dbc` |
| 2.3.3 | Intel | `pass-cli-macos-x86_64` | `275f6159f63d152ecdd9d4e2969ef515291619005e0d30ab762daee26081621c` |
| 2.2.3 | Apple Silicon | `pass-cli-macos-aarch64` | `8318e5af39d899780214ec62c6d1c2cfdc7628bb2036dba8f72af74c9a63c732` |
| 2.2.3 | Intel | `pass-cli-macos-x86_64` | `2babdfaf4badf1c428d66acd784377e5a9312c8a35b1fb6dea19e7eb051ae839` |
| 2.1.4 | Apple Silicon | `pass-cli-macos-aarch64` | `8b579bf452c346da57349a5e72c3839c466e064179b9383f481eefbfa8a65a44` |
| 2.1.4 | Intel | `pass-cli-macos-x86_64` | `ee0f41d3a1c26022e3f99aff6f2280ec3e0f0e1c443c2c58652c26d3456dc235` |

## Verifying vendored CLI files

You can verify the vendored files match Proton's release assets:

```bash
VERSION=2.4.2
curl -L -o /tmp/pass-cli-macos-aarch64 \
  "https://github.com/protonpass/pass-cli/releases/download/$VERSION/pass-cli-macos-aarch64"
curl -L -o /tmp/pass-cli-macos-x86_64 \
  "https://github.com/protonpass/pass-cli/releases/download/$VERSION/pass-cli-macos-x86_64"

shasum -a 256 /tmp/pass-cli-macos-aarch64 \
  ThirdParty/ProtonPassCLI/$VERSION/pass-cli-arm64
shasum -a 256 /tmp/pass-cli-macos-x86_64 \
  ThirdParty/ProtonPassCLI/$VERSION/pass-cli-x86_64

cmp /tmp/pass-cli-macos-aarch64 ThirdParty/ProtonPassCLI/$VERSION/pass-cli-arm64
cmp /tmp/pass-cli-macos-x86_64 ThirdParty/ProtonPassCLI/$VERSION/pass-cli-x86_64
```

The final app helpers are code-signed during packaging, so their bytes may differ from Proton's raw release downloads because the signature is added for macOS distribution. The verification point is the vendored input plus the packaging scripts: `scripts/prepare-bundled-pass-cli.sh` checksum-verifies the upstream bytes, and `scripts/inject-bundled-pass-cli.sh` only copies those files into the app and code-signs them.

## Related docs

- [README](../README.md)
- [Troubleshooting](troubleshooting.md)
- [Security policy](../SECURITY.md)
