# SSH Agent Proxy

The SSH Agent Proxy is an optional integration that places a Touch ID authorization gate between SSH clients and Proton Pass's SSH agent.

It is useful when Proton Pass stores SSH keys and you want local apps such as Terminal, Git clients, or GUI Git tools to request approval before a key signs an SSH challenge.

## What it does

Quick Access listens on:

```text
~/.ssh/quick-access-agent.sock
```

It proxies requests to Proton Pass's SSH agent, normally at:

```text
~/.ssh/proton-pass-agent.sock
```

Identity-listing requests pass through transparently. Signing requests are intercepted so Quick Access can identify the requesting process, show an authorization prompt, and apply remembered decisions.

## Setup

1. Open **Settings → SSH**.
2. Enable **Enable SSH proxy**.
3. Add this to `~/.ssh/config`:

```sshconfig
Host *
     IdentityAgent "~/.ssh/quick-access-agent.sock"
```

4. Start a command that uses SSH, such as `git fetch`.
5. Approve the Touch ID prompt when Quick Access asks whether the app may use the key.

## Prompt context

Quick Access resolves the requesting process so the prompt can show the app and command context when available. This helps distinguish a terminal command from a GUI app request.

### Shared terminal-host presentation

In **Settings → Integrations**, configure supported-app options and custom executable-to-display-name mappings shared by SSH and Run prompts. Herdr auto-detection runs at startup and when its executable appears in captured requester ancestry, without running discovery candidates. It is enabled on first detection. You can edit its name, disable it, or turn off **Show Herdr pane details**; saved opt-out and edits survive rediscovery/restart and temporarily unavailable installations. **Add Custom Terminal…** opens an editor where you can paste an absolute or `~`-relative executable path (including paths with spaces), or optionally choose a file. Adding a mapping only records filesystem input; custom mappings are never executed for enrichment. A custom mapping of the same executable suppresses automatic Herdr activation, even if disabled. Existing identified macOS apps take precedence.

Herdr prompts can display a bounded, one-line workspace/tab, optional distinct pane title, and working-directory context after a best-effort match to the requesting pane. An empty title or a title that is whitespace-equivalent to the command text shown in the prompt is omitted using case-sensitive equality, not substring or prefix matching; comparison does not replace or alter the original command or title. Metadata is untrusted and display-only, stays in memory for that prompt, and does not change the requesting app identity, command/host cache context, key fingerprint, or remembered decision. These display hints do not establish process ownership or permission evidence. The SSH-only **Show command for apps** setting stays separate and retains its existing behavior.

The base prompt and countdown appear immediately. Lookup is attempted once only for a displayed eligible prompt, with a total 750 ms budget. Missing, stale, disabled, ambiguous, or slow metadata falls back to the base header; disabling or changing configuration clears details. Quick Access reads only allowlisted routing hints and read-only Herdr metadata, not pane output, transcripts, or agent session files.

The prompt supports remembered approvals and denials, each with the selected duration. This avoids repeated Touch ID prompts for a workflow you have already approved or intentionally blocked.

## Remembered decisions and session cache

Quick Access uses two layers to reduce prompt fatigue:

- A short in-memory session cache for repeated requests during multi-step operations.
- Persistent remembered decisions keyed by app, command/host context, and key fingerprint.

Both layers use the same authorization context, including for queued requests. An approval for another command or host cannot override a matching remembered denial.

Open **Settings → SSH → Manage SSH decisions…** to review remembered approvals and denials in a separate management sheet. Each decision retains its context, key fingerprint, expiration, and Remove action. Use **Done** or Escape to close the sheet. SSH probe decisions remain in the main SSH settings.

## BatchMode handling

Non-interactive SSH probes often use `ssh -o BatchMode=yes`. Quick Access treats BatchMode requests separately so background probes do not unexpectedly open normal authorization prompts.

BatchMode decisions are keyed by key fingerprint and host. Settings include controls for reviewing these decisions.

## Vault filtering

If you have multiple Proton Pass vaults, **Settings → SSH** can limit which vaults are exposed through the proxy. Use this to keep unrelated keys out of SSH agent responses.

## Troubleshooting

If SSH cannot see your keys:

1. Confirm **Settings → SSH → Enable SSH proxy** is on.
2. Confirm `~/.ssh/config` points `IdentityAgent` to `~/.ssh/quick-access-agent.sock`.
3. Confirm Proton Pass's own SSH agent is running and has keys available.
4. Check the SSH status row in Quick Access settings.
5. Clear remembered decisions if an old deny decision is blocking a workflow.

If a GUI app behaves differently from Terminal, review the per-app command-display and remembered-decision settings in **Settings → SSH**.

## Security notes

- The proxy socket is local and owner-only.
- Signing requests are gated by Touch ID unless covered by a remembered authorization decision; remembered denials reject the request without prompting.
- Key material remains with Proton Pass's SSH agent; Quick Access gates access to signing rather than exporting private keys.

## Related docs

- [README](../README.md)
- [Security policy](../SECURITY.md)
