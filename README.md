# Quick Access for Pass

**A macOS menu-bar app for fast, Touch-ID-protected access to your [Proton Pass](https://proton.me/pass) secrets.** Press a hotkey, search, copy — done.

<p align="center">
  <img src="docs/intro.gif" alt="Quick Access for Pass in action" width="640">
</p>

> 💛 **Like this project?** Sign up for Proton with my [referral link](https://pr.tn/ref/DRHZ4WW3) — you get 2 weeks of a paid plan, and I get a small reward if you subscribe.

## Why

I built this for myself and my wife after moving from 1Password to Proton Pass — and as a way to learn Swift and macOS development. If it's useful to you too, that's a nice bonus.

## Quick start

1. **Install and log in to [`pass-cli`](https://protonpass.github.io/pass-cli/)** — the app reads your vaults through it.
2. **Install** this app via [Homebrew](https://brew.sh/):
   ```bash
   brew install CiTroNaK/tap/quick-access-for-pass
   ```
   (or download from [Releases](../../releases) and install manually to `/Applications`)
3. Open the app.
4. **Press `⇧⌥Space`**, search for an item, hit Return to copy.

That's it. Everything else below is optional.

## Features

At a glance: global-hotkey search, Touch ID for sensitive actions, and two optional proxies that add biometric gating to SSH signing and secret-injected command execution.

<details>
<summary><strong>Quick Access panel</strong></summary>

- Global hotkey (default `⇧⌥Space`) opens a floating search panel
- Fast local search over synced item metadata (encrypted SQLite + FTS5)
- Keyboard-first flow: `↑` / `↓` move through results, `→` opens item detail, `←` goes back, and `Return` runs the selected action
- Default shortcuts: Copy Username `⌘C`, Copy Password `⇧⌘C`, Copy TOTP `⌥⌘C`, Open in Browser `⌘O`, Show in Large Type `⇧Return`
- All of these shortcuts can be changed in **Settings → Shortcuts**
- Usage-based ranking so your most-used items surface first
- Clipboard auto-clear with concealed-type support for clipboard managers

<table>
  <tr>
    <td align="center"><img src="docs/detail.png" alt="Item detail view with per-field actions" width="340"><br><sub>Item detail with per-field copy actions</sub></td>
    <td align="center"><img src="docs/large-type.png" alt="Large Type display of a value" width="340"><br><sub>Large Type display, handy when reading a password aloud</sub></td>
  </tr>
</table>

</details>

<details>
<summary><strong>SSH Agent Proxy (optional)</strong></summary>

Touch-ID-gated signing between SSH clients and the Proton Pass SSH agent.

- Identifies the requesting app and command context for the prompt
- BatchMode-aware handling for non-interactive probes (`ssh -o BatchMode=yes`)
- Remembered decisions + short in-memory session cache to avoid prompt fatigue during multi-step operations
- Vault filtering and per-app command-display controls in Settings

<table>
  <tr>
    <td align="center"><img src="docs/ssh-auth-terminal.png" alt="SSH authorization from a terminal (git fetch)" width="340"><br><sub>Terminal (Ghostty) running <code>git fetch</code></sub></td>
    <td align="center"><img src="docs/ssh-auth-app.png" alt="SSH authorization from a GUI app (Tower)" width="340"><br><sub>GUI app (Tower)</sub></td>
  </tr>
</table>

</details>

<details>
<summary><strong>Run Proxy (optional)</strong></summary>

Inject Proton Pass secrets into commands at runtime, with a Touch ID gate.

- Profiles map environment variables to `pass://` references
- Context-aware remembering (app identity + subcommand + profile)
- In-memory secret caching per profile with configurable TTL
- Peer verification rejects unverified local clients

<p align="center">
  <img src="docs/run-auth-gh.png" alt="Run Proxy authorization for a gh command" width="340"><br>
  <sub>Authorizing <code>gh status</code> with GitHub CLI secrets injected from Proton Pass</sub>
</p>

</details>

<details>
<summary><strong>Health & accessibility</strong></summary>

- Pass CLI / SSH / Run status rows in Settings
- Menu-bar icon reflects degraded/error state; automatic probe-driven recovery
- VoiceOver and Voice Control aware throughout
- Explicit selection state, announcements, and focus handling

</details>

<details>
<summary><strong>Settings</strong></summary>

Most of the app's behavior is configurable in Settings — from the global hotkey and per-action shortcuts to clipboard behavior, sync, and the optional SSH / Run proxies.

<table>
  <tr>
    <td align="center"><img src="docs/settings-general.png" alt="General settings with launch at login, global hotkey, and language options" width="340"><br><sub>General: launch at login, Quick Access hotkey, language</sub></td>
    <td align="center"><img src="docs/settings-shortcuts.png" alt="Shortcuts settings with configurable keyboard shortcuts for item actions" width="340"><br><sub>Shortcuts: customize copy and Large Type shortcuts</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/settings-security.png" alt="Security settings with clipboard, search clearing, concealment, and auto-lock options" width="340"><br><sub>Security: clipboard handling, search clearing, auto-lock</sub></td>
    <td align="center"><img src="docs/settings-cli.png" alt="Pass CLI settings with refresh interval, sync status, and CLI path" width="340"><br><sub>Pass CLI: sync cadence, status, and CLI path</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/settings-ssh.png" alt="SSH settings with proxy enablement, socket paths, and filtering options" width="340"><br><sub>SSH: proxy enablement, socket paths, filtering, remembered decisions</sub></td>
    <td align="center"><img src="docs/settings-run.png" alt="Run settings with run proxy enablement and profiles" width="340"><br><sub>Run: proxy enablement and secret-injection profiles</sub></td>
  </tr>
</table>

</details>

## Requirements

- macOS 15 or later
- [Proton Pass CLI](https://protonpass.github.io/pass-cli/) installed and authenticated
- Touch ID (required for biometric prompts)

## Optional integrations

<details>
<summary><strong>Set up the SSH Agent Proxy</strong></summary>

1. Enable **Settings → SSH → Enable SSH proxy**.
2. Add to `~/.ssh/config`:
   ```sshconfig
   Host *
        IdentityAgent "~/.ssh/quick-access-agent.sock"
   ```
3. Optional: configure upstream socket override, vault filtering, per-app command display, and remembered decisions in Settings.

</details>

<details>
<summary><strong>Set up the Run Proxy</strong></summary>

1. Enable **Settings → Run → Enable run proxy**.
2. Create a profile and map env variables to `pass://...` references.
3. Add the helper alias shown in Settings:
   ```bash
   alias qa-run='/Applications/Quick Access for Pass.app/Contents/Helpers/qa-run'
   ```
4. Wrap commands with the helper:
   ```bash
   qa-run --profile github-cli -- gh auth status
   ```
   Or alias the command itself:
   ```bash
   alias gh='qa-run --profile github-cli -- gh'
   gh auth status
   ```

</details>

## Security

Built around a few non-negotiable constraints:

- **No secrets in the local database** — only item metadata is cached
- **Secrets fetched on demand** from `pass-cli`, kept only in memory
- **Database encryption** via a Keychain-managed passphrase
- **Owner-only sockets** for local proxy communication; Run Proxy verifies peers
- **Reduced clipboard leakage** via `org.nspasteboard.ConcealedType`
- **Auto-lock** after 5+ minutes of inactivity; unlock with Touch ID or password

For vulnerability reporting, see [SECURITY.md](SECURITY.md). For the full security posture, read the source — it's the whole point.

## Building from source

```bash
make build      # Release build
make install    # Build + copy to /Applications + launch
xcodebuild -scheme "Quick Access for Pass" -configuration Debug build
xcodebuild -scheme "Quick Access for Pass" test
```

Requires Xcode 26+.

## Contributing

Contributions welcome.

- [CONTRIBUTING.md](CONTRIBUTING.md) — workflow and expectations
- [AGENTS.md](AGENTS.md) — guidance for coding agents

## Disclaimer

Not affiliated with, endorsed by, or associated with Proton AG. Proton Pass is a trademark of Proton AG.

## License

[MIT](LICENSE)

Uses [SQLCipher](https://www.zetetic.net/sqlcipher/) (BSD) and [GRDB.swift](https://github.com/groue/GRDB.swift) (MIT).
