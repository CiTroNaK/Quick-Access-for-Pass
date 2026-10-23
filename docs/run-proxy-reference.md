# Run Proxy reference

Run Proxy returns configured environment variables to the trusted `qa-run` helper after peer verification and authorization. It listens on the owner-only socket `~/.local/share/quick-access/run.sock`.

The [setup guide](run-proxy.md) covers profiles, aliases, executable wrappers, and decision removal.

## Profiles and secret resolution

A profile maps environment-variable names to `pass://` references. For example, profile `github-cli` can map `GH_TOKEN` to `pass://GitHub/token`.

For `qa-run --profile github-cli -- gh auth status`, Quick Access resolves the profile and returns approved values. The helper then starts `gh auth status` with those variables in its environment.

The bundled `qa-env-export` helper carries only approved variables through a private FIFO. This flow does not print resolved values to stdout or stderr or persist them on disk. A profile can cache resolved secrets in memory for its configured duration.

The profile cache is separate from authorization decisions. Offline snapshots never supply Run secrets.

## Peer verification and requester identity

Run rejects unverified clients. Accepted clients are trusted signed apps and the bundled `qa-run` helper.

A verified helper uses parent attribution for its requesting app identity. The helper itself does not become an authorization identity. A detached helper retains identifier `unknown`, even if display metadata suggests a terminal name.

Unverified requests fail before prompt-context lookup. [Terminal-host context](terminal-hosts.md) describes the separate display-only mappings and Herdr lookup.

## Exact-command scope

The prompt defaults to **Exact command**. Exact identity includes the complete ordered arguments received from `qa-run`: executable string, flags, values, empty arguments, and argument boundaries.

Matching uses literal UTF-8 bytes without normalization or shell parsing. `gh api "user repos"` differs from `gh api user repos`. Changes in argument order or grouping also produce a different identity.

The human-readable command text preserves boundaries with quoting and escaping where needed. It is display text, not a shell command or matching key.

App identity and profile remain separate authorization checks. Exact scope does not bind the working directory, environment, or executable contents. The same executable string can later name a changed binary. Version commands such as `gh --version` are not automatically approved.

## Prefixes and decision precedence

**Broader scope** choices use command-prefix matching and require explicit selection. They can match commands with different arguments. Existing broad approvals and denials remain valid without migration or reset.

Lookup checks exact scope first, then prefixes from narrowest to broadest, across session and persistent decisions. A broad session approval cannot override a more specific persistent denial. Session wins only within the same scope.

Approval and denial support the existing durations, including Forever. **Do Not Remember** avoids persistence but still uses a 10-second in-memory burst cache for either outcome.

An initially matching denial prevents secret resolution. A queued request is checked again before its prompt. A newly matching queued denial prevents release to the helper but cannot undo resolution that already happened. Released values cannot be recalled.

## Stored command text

Exact matching uses `exact-argv-v1` and the unchanged full SHA256 digest over received arguments. The digest is not encryption and is not shown in Settings.

Remembered decisions also store the full received command text in the encrypted Run authorization table. Caller-supplied arguments can contain tokens or passwords. This persistence is not guaranteed redacted or secret-free.

Resolved profile variables, fetched Pass secrets, and offline snapshots never enter that text. Full command text does not enter public logs, FTS, UserDefaults, App Group storage, or an unencrypted sidecar. Explicit broader prefixes retain their literal value.

Settings shows the stored text and a localized **Exact command**, **Command prefix**, or **Unknown matching type** description. Rows also show outcome, profile, and expiration. Typed app, profile, type, and value determine matching and uniqueness. Stable row IDs determine selection and removal. Labels never authorize.

## Migration and removal

The v14 migration removes only strictly valid legacy exact-v1 fingerprint-only decisions because their command text cannot be recovered. Malformed exact-looking values, literal prefixes, and other rows remain prefix decisions.

Removing an exact row does not guarantee a new prompt. Another broad decision or live burst-cache entry can still apply. The [decision-management steps](run-proxy.md#remove-a-remembered-decision) cover removal without changing Run profiles.

The [Run Proxy security boundary](../SECURITY.md#run-proxy-authorization-boundary) defines the persistence and release limits.
