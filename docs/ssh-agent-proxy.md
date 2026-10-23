# Authorize SSH signing with Touch ID

Use SSH Agent Proxy to require authorization when a local app asks Proton Pass's SSH agent to sign. This integration is optional and does not export private keys.

## Enable the proxy

1. Open **Settings → SSH**.
2. Enable **Enable SSH proxy**.
3. Add the following entry to `~/.ssh/config`:

```sshconfig
Host *
	IdentityAgent "~/.ssh/quick-access-agent.sock"
```

4. Start an SSH operation, such as `git fetch` in an SSH-backed repository.
5. Approve the request when Quick Access shows its authorization prompt.

Proton Pass's agent must be running and have the required keys. Quick Access listens at `~/.ssh/quick-access-agent.sock` and normally forwards to `~/.ssh/proton-pass-agent.sock`.

Identity listing passes through. Signing requires a decision. A matching cached approval can avoid another prompt, while a cached denial rejects the request.

## Limit exposed vaults

In **Settings → SSH**, select the vaults that the proxy can expose. Use this filter when unrelated vaults contain SSH keys you do not want clients to see.

## Review approvals and denials

1. Open **Settings → SSH → Manage SSH decisions…**.
2. Review the requesting app, command or host context, key fingerprint, and expiration.
3. Use **Remove** on a decision you no longer want.
4. Use **Done** or Escape to close the sheet.

Both approvals and denials can be remembered for a selected duration. The short in-memory session cache and persistent decisions use the same app, command or host, and key context. A different command or host approval cannot override a matching denial.

## Review BatchMode probes

For noninteractive requests such as `ssh -o BatchMode=yes`, review SSH probe decisions in the main SSH settings. BatchMode probes are denied by default and handled separately from ordinary authorization prompts. Decisions are keyed by fingerprint and host.

## Adjust requester details

Use **Settings → Integrations** for terminal names and optional Herdr pane details. Use **Show command for apps** in SSH settings for the separate per-app command-display behavior.

The prompt remains usable without extra metadata. Display labels and pane details never change authorization or remembered decisions. See [Terminal-host context](terminal-hosts.md) for lookup limits and privacy rules.

## Restore missing keys or blocked signing

1. Confirm **Enable SSH proxy** is on.
2. Check that `IdentityAgent` names `~/.ssh/quick-access-agent.sock`.
3. Confirm Proton Pass's agent is running and has keys available.
4. Check the SSH status row in Settings.
5. Review vault filters and remembered denials.

If a GUI app differs from Terminal, review that app's command-display and remembered-decision settings. Do not assume a terminal approval covers the GUI app.

The sockets are local and owner-only. Proton Pass's agent retains key material. Quick Access authorizes signing rather than copying private keys. See the [security policy](../SECURITY.md) for the shared authorization and requester-presentation limits.
