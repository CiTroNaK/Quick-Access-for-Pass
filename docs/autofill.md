# System AutoFill

Quick Access supplies Proton Pass passwords and current TOTP codes through macOS AutoFill in Safari and compatible native apps. System AutoFill requires macOS 27 or later and is optional.

The [setup guide](get-started.md#enable-optional-integrations) covers provider activation.

## Passwords, codes, and passkeys

Quick Access advertises passwords and one-time codes. It does not register, create, retrieve, store, sign, or complete passkeys. Proton Pass can remain enabled as the passkey provider.

A passkey request displays Quick Access's password and TOTP picker rather than a blank panel. That display does not mean Quick Access can complete the passkey request.

Verification-code suggestions use the item title and username or email so accounts with the same title remain distinguishable. An item without a username keeps its title. Existing labels update on the next sync after an upgrade.

## Picker matching

The picker places exact matches for the supplied service before broader matches. A login with several saved website hosts appears once and keeps its earliest matching service. Distinct items or usernames remain separate even when their display labels match.

Nonempty typed text starts a global search capped at 20 distinct logins. Before typing, the picker does not display a general vault list. Without a usable service identifier, the picker remains ready for search and does not attempt a contextual lookup.

Native-app matching starts with explicit app associations. After a login selection, **Remember for this app** can save an association. **Settings → Security → App associations** lists those associations and supports removal. Associations are host-local, non-secret metadata. The app never infers them from a website or app display name.

Empty results invite search. A generic loading error does not imply that the Mac is locked.

## Recently used passwords

After a complete successful password delivery to its extension, the host can retain one recent selection for two minutes. The record contains an opaque descriptor ID, exact saved domain, lifecycle generation, and monotonic expiry. It contains no password, TOTP seed, code, username, or title.

For matching website TOTP candidates, the picker can mark that descriptor **Recently used** and move it first within its existing service-match tier. Other accounts remain available. Global search and native-app matching do not change.

The record remains in memory. Transient-access revocation, including explicit app or system lock, clears it. Expired or locked state cannot produce a new preference. App termination also discards it.

This hint does not prove login success, identify browser tabs, or detect passwords entered manually or through another provider. It does not change macOS's suggestion dropdown, identity rankings, or authorization.

## Host launch and unlock

The main app alone runs Pass CLI and resolves secrets. The extension never does.

Selecting a credential can wake a quit host without bringing it to the front. A locked host shows its existing unlock panel before resolving a value. The wake URL contains a random expiring handle, not a credential identifier or authorization.

## Identity-store availability

While the system credential identity store is disabled, Quick Access skips system identity updates without a sync error. Ordinary metadata sync and offline-copy refresh continue. Local AutoFill metadata remains current, and the next sync reconciles system identities after the store is enabled.

## Broker and storage limits

The host and extension verify each connected socket through its audit token and exact signed identity. The provisioned `group.codes.petr.quick-access-for-pass` App Group contains only the owner-only broker socket directory and socket.

Protocol v3 returns at most 20 non-secret candidate records. Each record contains an opaque descriptor ID, title, username, kind, match tier, and presentation-only recent-use flag. The extension keeps those records in memory for the active picker only.

The host alone owns the database, descriptor storage, app associations, Keychain material, and secret resolution. The extension cannot open the unified SQLCipher database or access Keychain.

An authorized, usable selected offline snapshot can supply the requested password or TOTP value without a live request or connectivity probe. Otherwise, the host uses Pass CLI. Sync refreshes selected copies. The extension receives neither cache access nor fallback diagnostics, and unavailable values fail generically.

The [System AutoFill security boundary](../SECURITY.md#system-autofill-boundary) defines peer verification, cold-host claims, release checks, and deadline limits. The [Offline Mode reference](offline-mode.md) describes selection and refresh behavior.
