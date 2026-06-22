# Troubleshooting

This page collects practical checks for common Quick Access for Pass issues.

## Find the `pass-cli` Quick Access is using

Quick Access chooses a system `pass-cli` first, then falls back to the
bundled helper in signed app releases. You can see the selected source in
**Settings → Pass CLI**.

If the signed app is installed in `/Applications` and Quick Access is using the
bundled CLI, run the matching helper directly:

```bash
APP="/Applications/Quick Access for Pass.app"

# Apple Silicon Macs
"$APP/Contents/Helpers/pass-cli-arm64" --version

# Intel Macs
"$APP/Contents/Helpers/pass-cli-x86_64" --version
```

To pick the right helper automatically:

```bash
APP="/Applications/Quick Access for Pass.app"

if [ "$(uname -m)" = "arm64" ]; then
  PASS_CLI="$APP/Contents/Helpers/pass-cli-arm64"
else
  PASS_CLI="$APP/Contents/Helpers/pass-cli-x86_64"
fi

"$PASS_CLI" --version
```

If you installed Quick Access somewhere else, replace the `APP` value with the
actual app path.

## Sync completed with skipped items

Quick Access stores only metadata locally and fetches secrets from Proton Pass
through `pass-cli`. During sync, a malformed or newly unsupported item shape can
fail to decode while the rest of the vault still syncs. In that case the main
Quick Access panel stays usable and the right sync-status area shows **Show sync
errors**.

Click **Show sync errors** to open the sync diagnostics window. The window is
separate from the main Quick Access panel, so it stays visible if you close the
main panel. If a later sync succeeds while the diagnostics window is open, the
window stays open, marks the issue as resolved, and keeps the last diagnostics
available for copying or reporting.

Use **Copy Inspect Command** first. It copies a ready-to-run command that uses
the same `pass-cli` executable Quick Access selected, including the bundled
helper path when the bundled CLI is active.

For a skipped item with a vault `share_id` and `item_id`, the copied command
looks like:

```bash
"$PASS_CLI" item view \
  --share-id "<share_id>" \
  --item-id "item-7" \
  --output json
```

The copied report still includes technical summaries for support, for example:

```text
vault=Personal share_id=<share_id> index=7 item_id=item-7 \
  path=items.Index 7.content reason=expected String
```

Use the command output to inspect the item, then fix the item in Proton Pass or
with `pass-cli`.

### 1. Inspect the item from Quick Access

Open **Show sync errors**, find the affected skipped-item row in the sync
diagnostics window, then click **Copy Inspect Command**. Paste the copied
command into Terminal.

If the item ID was available, the command opens the exact item by `share_id` and
`item_id`. If the item ID was not available, the command lists the vault JSON
and includes a comment telling you which zero-based item index to inspect.

### 2. Manual fallback commands

If you need to build the command yourself, prefer `share_id` plus `item_id`:

```bash
"$PASS_CLI" item view \
  --share-id "<share_id>" \
  --item-id "item-7" \
  --output json
```

If the skipped summary does not include `item_id`, list the vault in JSON and
inspect the reported `index`:

```bash
"$PASS_CLI" item list \
  --share-id "<share_id>" \
  --output json > /tmp/pass-items.json
jq '.items[7]' /tmp/pass-items.json
```

The index is zero-based because it comes from the JSON array returned by
`pass-cli item list`.

### 3. Fix the item

Most sync skips are caused by an item field that `pass-cli` returned in an
unexpected shape. The copied report includes `path=` and `reason=` to identify
the field that failed to parse.

Fix the item in the Proton Pass app or web UI, then run sync again from Quick
Access. For fields that Proton Pass CLI can update, you can also use:

```bash
"$PASS_CLI" item update \
  --vault-name "Personal" \
  --item-id "item-7" \
  --field "title=Corrected title"
```

Be careful when writing secrets in shell commands: commands can be stored in
shell history. Prefer the Proton Pass UI for sensitive edits unless you know
your shell history setup is safe.

## Copy diagnostics for support

For sync errors or skipped items, open **Show sync errors** and use **Copy
Report** in the sync diagnostics window. Review the copied text for anything
sensitive before sharing it. Quick Access sanitizes common tokens, login URLs,
email addresses, `pass://` URIs, and home-directory paths, but you should still
inspect the report first.
