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

The prompt supports remembered decisions so repeated approved workflows do not require a new Touch ID prompt every time.

## Remembered decisions and session cache

Quick Access uses two layers to reduce prompt fatigue:

- A short in-memory session cache for repeated requests during multi-step operations.
- Persistent remembered decisions keyed by app, command context, and key fingerprint.

Remembered decisions can be reviewed and cleared from **Settings → SSH**.

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
- Signing requests are gated by Touch ID unless covered by an allowed remembered decision.
- Key material remains with Proton Pass's SSH agent; Quick Access gates access to signing rather than exporting private keys.

## Related docs

- [README](../README.md)
- [Security policy](../SECURITY.md)
