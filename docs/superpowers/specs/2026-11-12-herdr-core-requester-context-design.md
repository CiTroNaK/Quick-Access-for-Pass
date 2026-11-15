# Herdr Core requester context — design

Date: 2026-11-12

## Intent

Herdr Core (`hc`) is a headless terminal runtime for coding agents. The Herdr
desktop app (`/Applications/Herdr.app`) is one client of it, and agents can
also run in bare `hc` terminals. When an agent in a Core terminal triggers an
SSH signature or a `qa-run` command, the SSH/Run prompt currently shows only
"Herdr Core" with a blank icon. The user can't tell which terminal or project
is asking, so they can't decide quickly.

The goal is to give Core-hosted requests the same kind of header context that
classic Herdr panes already get: which program, which terminal, which folder.

Classic Herdr (the `herdr` TUI, existing integration) and Herdr Core are
**separate products**. They keep separate integrations. Classic Herdr keeps
working exactly as today.

## Observed facts (user's machine, Core 0.1.20, Herdr.app 0.1.15)

- `hc` is a symlink to
  `~/.local/share/herdr-core/current/Contents/MacOS/herdr-core`, inside
  `Herdr Core.app`: a signed, `LSUIElement` app bundle, bundle ID
  `dev.herdr.core`, team `2W9652Q7QR`. It ships no icon.
- `Herdr.app` is bundle ID `dev.herdr.app`, same team `2W9652Q7QR`.
- Process chain of an agent in a Herdr-app pane:
  `zsh → claude → zsh (terminal root) → Herdr Core.app/…/herdr-core (per-terminal holder) → ~/.local/bin/herdr-core (daemon) → launchd`.
  Herdr.app is **not** in the chain; it talks to the daemon through its own
  `herdr-core connect` child. A terminal created by the app and one created by
  `hc run` look the same from the requester side.
- Terminal processes inherit `HC_TERMINAL_ID` (e.g. `t5`),
  `HC_TERMINAL_SOCKET` (e.g. `~/.local/state/herdr-core/default/default.sock`)
  and `HC_SCOPE`.
- `hc get <address> --json` returns, among others: `address`, `name`
  (nullable), `title` (program-set terminal title), `pid` (terminal root
  process, here the shell), `cwd` (folder the terminal *started* in; stale),
  `foreground {pid, name, argv, cwd}`, `labels`, `state`.
- `hc get` ignores `HC_TERMINAL_SOCKET`; with a clean environment it reaches
  the default session. `hc connect --session` mentions `HC_SESSION` for
  choosing a session.
- `ProcessIdentifier.findAppBundle` walks up from executable paths and finds
  `Herdr Core.app`, so today the request is an **identified app**
  (`bundleIdentifier = dev.herdr.core`, `bundleURL` = Core bundle).
  `RequesterPresentationResolver` stops at identified apps, so no terminal-host
  enrichment runs at all.

## Goals

1. For SSH and Run prompts whose requester runs in a Herdr Core terminal, show:

   ```
   [icon] Herdr Core
          wants to use an SSH key        (or the Run subtitle)
   claude · Herdr core documentation    ← program · terminal name, else title
   ~/Code/xcode/Quick Access for Pass   ← current folder
   ```

2. Title stays "Herdr Core" (the identified app's name). It is never replaced
   by the program, terminal name or title.
3. Icon: the installed Herdr.app's icon when Herdr.app is present and its code
   signature verifies as `dev.herdr.app` from team `2W9652Q7QR`; otherwise the
   SF Symbol `terminal`. (User's decision: the icon may come from the app; data
   may not.)
4. Works automatically. No Settings entry, no switch, no discovery mapping.
5. Works identically for SSH and Run (both use `RequesterHeaderModel` /
   `RequesterHeaderView` via the shared `TerminalHostStore` and provider
   wiring in the two coordinators).

## Non-goals

- Reading anything from the Herdr app: no `herdr.*` labels, no `where` label,
  no Herdr.app API, no reuse of the classic Herdr data path.
- Showing terminal labels in general.
- Agent logos (Claude, Codex, …) or agent-specific symbols.
- Remote Core terminals (`hc run --on box`).
- Any change to classic Herdr behavior, Settings → Integrations, or the
  terminal-host store's mappings.
- Any change to authorization: bundle/team IDs, SSH session/persistent cache
  keys, `showCommand`, host/command context, Run scope/profile, remembered
  decisions.

## Anti-goals (failure even if it "works")

- Context shown for the **wrong** terminal. If ownership can't be proven, show
  nothing extra.
- The prompt or countdown waiting on Core. The base header appears
  immediately; enrichment is best-effort.
- Core- or program-supplied text treated as identity or authority, persisted,
  or logged.
- Reading terminal output (`hc read`), transcripts, agent files, `hc events`
  streams, or unrelated environment values.

## Constraints (inherited from the existing terminal-host rules)

Follow `CLAUDE.md` "Shared requester presentation", `docs/terminal-hosts.md`,
and `SECURITY.md#terminal-host-presentation-boundary`:

- One `RequesterHeaderModel` per actually displayed request; cache-covered
  requests create no model and do no lookup. Run rejects unverified peers
  before any lookup.
- At most one lookup per displayed prompt, one absolute 750 ms deadline,
  512 KiB output cap per command, cancellable on decision, queue advance,
  disappearance and `cancelAll`; no blank reserved rows; existing panel fitting
  behavior.
- Fixed read-only commands only. Routing hints are hints, never ownership proof.
- Metadata is request-scoped and in memory only.
- Display text from Core (name, title) is untrusted: strip control characters,
  bound length, preserve verbatim otherwise; never pass through
  `LocalizedStringKey`.
- Swift 6 strict concurrency; Swift Testing; English + Czech catalog entries
  with translator context for every new string (row accessibility labels,
  announcements if any).

## How it works (decided)

### Recognition

A request is Core-hosted when **all** hold:

- The identified client is Herdr Core (`bundleIdentifier == dev.herdr.core`).
- A node in the captured `RequesterProcessSnapshot` chain (requester +
  ≤10 ancestors) is the Core holder, and that running process's code signature
  verifies against identifier `dev.herdr.core` and team `2W9652Q7QR`.
  Recognition is by verified signature, not by path or Settings mapping.
- The node directly below the holder is the terminal root process.

This is a new branch alongside the existing resolver's identified-app
short-circuit. The identified app's `name`, `bundleIdentifier` and
`bundleURL` stay unchanged. The icon override is a separate presentation field
so that `bundleURL` is never repurposed.

### Routing hint

Extend the existing bounded procargs decoding (`RequesterProcessCapture`) with
an allowlist for `HC_TERMINAL_ID` (and whatever is needed to pick the session;
see "Left to the builder"). Apply the same validation as the Herdr fields:
UTF-8, non-empty, ≤4096 bytes, no control characters, no duplicates. Retain
nothing else from the environment. Keep these hints separate from
`HerdrRoutingHint` so the two products don't mix.

### Lookup and ownership proof

1. Run the verified Core executable with a fixed read-only command
   (`get <address> --json`), in a neutralized environment (clear inherited
   `HC_*` selectors, like the Herdr provider clears `HERDR_*`).
2. Accept the result only if:
   - `address` equals the hinted address and `state` is live;
   - `pid` equals the terminal-root node (pid **and** start time re-read)
     whose parent is the verified holder node;
   - the whole requester chain revalidates (pids, start times, parent links)
     after the command returns, within the deadline.
3. Any failure, ambiguity, schema mismatch, timeout or cancellation → no
   details, no logging of raw output or errors.

### What each row shows

- **Program row:** `program · label`.
  - Program: the topmost non-shell process on the requester side of the
    terminal root (e.g. `claude` in `git ← zsh ← claude ← zsh(root)`). If the
    root itself is not a shell (`hc run claude`), the root is the program.
    *(Designer's call)* The requester node itself (`ssh`, `git`) and the
    trusted `qa-run` helper are never the program; they are already described
    by the command line. If nothing else remains, the program part is omitted. The name is the
    executable's last path component from our own snapshot, not Core's
    `foreground` report and not argv. Accepted limitation (user's decision):
    interpreter-hosted agents (npm-installed Gemini CLI, etc.) show as
    `node`/`python`/`bun`; argv-derived names are out of scope for now.
  - Label: the terminal's `name` if set, otherwise its `title`; omitted if
    empty or if equal to the displayed command (same rule as the Herdr pane
    title).
  - If both parts are empty, there is no row.
- **Folder row:** the current working directory of the program process,
  read by us from the process (not Core's `cwd`, which is the start folder),
  home-abbreviated with `~`. Omitted if unreadable.

Program and folder come from our own process walk, but they are shown only
after the Core ownership proof succeeds, so all rows appear together or not at
all.

### Icon

Locate `dev.herdr.app` through `NSWorkspace`; verify its static code
signature (identifier `dev.herdr.app`, team `2W9652Q7QR`). Use its icon if
that passes, otherwise the `terminal` symbol. It changes nothing else.

*(Designer's call)* The icon swap requires recognition: the Core bundle ID
**and** a holder in the chain whose running code signature verifies. It does
not wait for the `hc get` ownership proof. Signature checks run inside the
async lookup, not on the main actor at model init, so the header first shows
today's Core icon and switches when the holder verifies. If recognition fails,
the header keeps today's presentation unchanged.

## Left to the builder

- **Session routing.** `hc get` reaches the default session with a clean
  environment and ignores `HC_TERMINAL_SOCKET`. Decide how to make sure the
  query hits the same Core instance as the hinted `HC_TERMINAL_SOCKET` (e.g.
  derive and pass `HC_SESSION`, or talk JSON-RPC over the hinted socket after
  the same owner/socket checks as `HerdrSocketIdentity`). Hard requirement: if
  the queried instance cannot be tied to the hinted socket, show nothing. A
  default-session-only first version is acceptable if non-default sessions
  fall back cleanly.
- CLI subprocess vs direct JSON-RPC on the socket, as long as it is read-only,
  bounded, and within the deadline.
- How to verify the running holder's signature (e.g. `SecCodeCopyGuestWithAttributes`
  for the pid plus a requirement string) and whether to cache verification per
  executable identity.
- The shell-name list for "topmost non-shell" (reuse `ProcessIdentifier.shellNames`
  if suitable).
- Type names, file layout, and how the header model chooses between the Herdr
  and Core providers, keeping `AppDelegate` thin and one shared provider
  instance per product.
- New `RequesterHeaderContext.Kind` cases and their symbols/accessibility
  labels (e.g. "Program and terminal").
- Tolerant JSON decoding: ignore unknown fields; required fields missing →
  fallback.

## Testing

- Decoder fixtures from real `hc get --json` output (live, unnamed with title,
  named, finished, malformed, oversized).
- Recognition: verified vs unsigned/wrong-team holder; identified app other
  than Core; Core not in chain; chain deeper than the cap.
- Ownership: pid mismatch, start-time mismatch, address mismatch, chain change
  during lookup, timeout, cancellation.
- Program selection: shells only, agent under shell, `hc run <program>` root.
- Label rules: name over title, empty, equal to displayed command.
- Icon: Herdr.app present and verified, missing, wrong team.
- Classic Herdr unaffected (existing tests stay green).
- Localization: new strings in English and Czech; `scripts/verify-localizations.py`.

## Docs to update

- `docs/terminal-hosts.md`: a Herdr Core section (automatic, what is shown,
  limits, separation from classic Herdr and the app).
- `SECURITY.md` terminal-host boundary: Core routing hints, ownership proof,
  icon-only use of Herdr.app.
- `CLAUDE.md`/`AGENTS.md` "Shared requester presentation" paragraph.

## Changes from plan review

These calls were made while reviewing the implementation plan and replace the corresponding parts above.

- **Socket instead of the CLI.** Running the holder's executable path could execute a binary swapped in after verification. Lookup now connects to `HC_TERMINAL_SOCKET`, verifies the peer's audit token against the Core requirement, and sends one read-only JSON-RPC `terminal.get`. No binary is executed.
- **All Core sessions are supported.** Because the hinted socket is used directly, the default-session limitation is gone.
- **Requirements pin Developer ID.** Both requirements also require the Developer ID leaf (`certificate leaf[field.1.2.840.113635.100.6.1.13] exists`).
- **One lookup, one deadline.** The icon is published together with the details from a single provider call. The Herdr.app check runs in parallel, is cached, and never holds the lookup past 750 ms.
- **Folder fallback.** When there is no program, the folder is the requester's current folder.

## Changes after testing

- **Workspace and tab row.** Herdr.app leaves a terminal's `name` empty and records its tab in the Core `where` label (`workspace / tab`). The user chose to show it as its own row, first, like classic Herdr. It is read from the same `terminal.get` reply; nothing is requested from Herdr.app. This replaces the non-goal about `where`; other `herdr.*` labels remain unused. An unusable label is ignored without rejecting the reply.
- **Integrations row.** The user asked for Herdr Core in Settings → Integrations, with a switch. This replaces goal 4's "no Settings entry, no switch". The row shows install status (`~/.local/bin/herdr-core`, display only) and one switch, on by default, stored in `herdrCoreContextEnabled` outside the terminal-host store. While it is off no lookup runs and the prompt keeps the plain Herdr Core presentation; a result arriving after it is turned off is dropped. An open prompt is not re-rendered when the switch changes.
- **Consistent with Herdr.** The user chose to match classic Herdr's rows: workspace and tab, then the terminal name or title as the existing pane-title row, then the folder. The program name and the "Program and terminal" row are removed. The program process is still found, only to read its current folder. The Settings description uses Herdr's wording.
- **Settings match Herdr.** The Core row has Herdr's layout without Edit…: name, status, full path, an enable switch, and a separate **Show workspace, pane title and directory** switch (`herdrCoreShowDetails`, default on). With details off, the holder is still verified for the Herdr.app icon, but Core is not queried and no rows appear.
- **Review fixes.** Both signature checks run off the cooperative pool and are awaited only within the deadline; a finished Herdr.app check keeps the icon even when Core replies late. Open prompts observe the switches and clear what a switch turns off, replacing the earlier "an open prompt is not re-rendered" note. Core results map into `HerdrPaneDetails`, so both products share one row pipeline. Install status also finds the `Herdr Core.app` bundle through Launch Services. The socket sets `SO_NOSIGPIPE`.
- **Second review.** The socket peer check is also awaited only within the deadline: the client connects, reads the peer token (length-checked through the shared `LocalPeerToken`), validates it as bounded work, and writes only after it passes. Peer verdicts are cached by full audit token (exec-safe); running-code checks keep `kSecCSStrictValidate` alone, because `kSecCSDoNotValidateResources` is rejected for dynamic validation (errSecCSInvalidFlags). Turning details off keeps the in-flight lookup for the icon and drops its details. Core prompts no longer subscribe to the terminal-host store or run its discovery. Install status also checks `~/.local/bin/hc` and `~/.local/share/herdr-core/current`.
