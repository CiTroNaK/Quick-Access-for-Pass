# Troubleshoot login and sync

Use these checks when Quick Access cannot sign in, sync an item, or copy a value. Keep command output private. CLI item output can contain passwords, notes, TOTP seeds, and other secrets.

## Find the selected CLI

1. Open **Settings → Pass CLI**.
2. Check the selected source, version, and executable path.
3. Use that executable for diagnosis, not whichever `pass-cli` your shell finds.

**Features** lists what the selected version supports:

- **Supported** — the version has the feature and is a release Quick Access was tested with.
- **Untested** — the version should have the feature, but that release was not tested. It is expected to work; open a GitHub issue if it does not. For **Fast offline sync**, Quick Access also checks one item per vault on each sync and fetches items one by one if the list disagrees.
- **Unsupported** — the version is too old (the row says which version is needed) or the feature is turned off for that release.

The list is informational; it does not change which features are enabled.

With **Auto (recommended)**, an installed CLI takes precedence over the bundled fallback. A custom path has no fallback. See the [selection reference](pass-cli.md#cli-selection-order).

If Settings selects a bundled CLI, use its versioned resource path. Set `VERSION` to the selected version and change `APP` if needed:

```bash
APP="/Applications/Quick Access for Pass.app"
VERSION="2.7.0"

if [ "$(uname -m)" = "arm64" ]; then
	PASS_CLI="$APP/Contents/Resources/ProtonPassCLI/$VERSION/pass-cli-arm64"
else
	PASS_CLI="$APP/Contents/Resources/ProtonPassCLI/$VERSION/pass-cli-x86_64"
fi

"$PASS_CLI" --version
```

For an installed or custom CLI, assign `PASS_CLI` to the exact path shown in Settings.

## Restore login

If the panel shows **Login**, select it and complete the browser flow. You can also use **Settings → Pass CLI → Log In to Proton Pass CLI…**.

If a saved-token attempt fails, use **Update PAT** or choose browser login explicitly. Do not assume a local decryption error means the token expired.

For **Local CLI session could not be decrypted**, use the offered **Reset CLI Session and Log In…** action. Read its shared-session warning before confirming. Cancelling leaves the session unchanged. Avoid deleting CLI files or keys yourself.

The [authentication reference](pass-cli.md#personal-access-token-support) explains automatic token recovery, browser repair, and cases that do not allow cleanup.

## Inspect a skipped item

A malformed or unsupported item can fail to decode while the rest of the vault syncs. The panel remains usable and shows **Show sync errors**.

1. Open **Show sync errors**.
2. Find the skipped-item row.
3. Select **Copy Inspect Command**.
4. Review the command before pasting it into Terminal.
5. Run the command locally and inspect the reported field.

The copied command uses the selected CLI, including its bundled version path. With an item ID, it opens that item by `share_id` and `item_id`. Without an ID, it lists the vault and names the zero-based array index to inspect.

A typical command is:

```bash
"$PASS_CLI" item view \
	--share-id="<share_id>" \
	--item-id="item-7" \
	--output json
```

Keep the `=` between each option and its value. Proton IDs can start with `-`, and separate arguments can be mistaken for options.

If only an array index is available, inspect it without writing the JSON to a temporary file:

```bash
"$PASS_CLI" item list \
	--share-id="<share_id>" \
	--output json | jq '.items[7]'
```

This command requires `jq` and prints private item data in Terminal. Index 7 refers to the eighth item in that returned JSON array.

## Correct the item

Use the report's `path=` and `reason=` fields to find the parsing problem. A report can include:

```text
vault=Personal share_id=<share_id> index=7 item_id=item-7 path=items.Index 7.content reason=expected String
```

1. Correct the field in Proton Pass.
2. Run sync again in Quick Access.
3. If the item still fails, prepare a redacted report rather than deleting the original.

For a non-sensitive field supported by the CLI, you can use:

```bash
"$PASS_CLI" item update \
	--vault-name "Personal" \
	--item-id="item-7" \
	--field "title=Corrected title"
```

For sensitive edits, prefer the Proton Pass UI. Shell history can retain command-line values.

If recreating or duplicating the item resolves the problem, verify the replacement before removing or archiving the original. Check every field, note, attachment, passkey, and two-factor detail you need.

## Check an unavailable alias email

**Copy Alias** needs a nonblank top-level `alias_email` from Pass CLI 2.4.0 or later. It does not fall back to the title or nested `Alias.email`.

If the app shows **Alias email is unavailable.**, check the selected CLI version and inspect the item locally. The failed action leaves the clipboard and panel unchanged.

An old selected offline alias refreshes on ordinary sync once usable email evidence is available. If you need to force that selected item's refresh, use **Retry** in **Settings → Offline**. See [Offline Mode](offline-mode.md#content-revisions).

## Passwords hidden by vault policy

With Pass CLI 2.7.0 or later, a shared vault's owner can hide sensitive content. The CLI then refuses to list that vault with secrets or to show its items. Quick Access keeps syncing your other vaults and shows **Synced · Passwords hidden by vault policy in …**. Items already synced from that vault stay searchable, but **Copy Password** shows **The owner of this vault doesn't allow viewing its passwords.** Ask the vault owner if you need access.

## Share diagnostics safely

1. Open **Show sync errors**.
2. Select **Copy Report**, or use **Copy & Report** to begin a report.
3. Review the text and any CLI JSON before sharing.
4. Remove secrets and private identifiers.

Remove passwords, TOTP seeds and codes, recovery codes, notes, URLs, usernames, email addresses, and other private data. Diagnostic sanitization covers common tokens, login URLs, email addresses, `pass://` URIs, and home paths, but does not replace your review.

The diagnostics window stays open if you close the search panel. A later successful sync marks the issue resolved and keeps the last diagnostics available.

For a suspected security vulnerability, use [private security reporting](../SECURITY.md#reporting-a-vulnerability), not a public support issue.
