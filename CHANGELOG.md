# v0.1.0

- Added `ellm-attach-file` and `ellm-paste`. You can attach files,
  screenshots etc. to buffers with these commands. Attachments also
  have in-buffer previews.
- More **org-mode** integration: Now you can store ellm buffers as org
  links via `org-store-link`.
- Manage saved conversations more easily: `ellm-open-session` searches
  project-local and global sessions, `ellm-delete-conversation`
  removes a locally saved conversation, and reopened sessions restore
  their working directory.
- The conversation list (`ellm-list`) marks completions you have not
  yet seen. Makes easier to track things when you are dealing with
  multiple running agents.

## Behavioral changes

- Tool calls now ask for approval by default unless a permission rule
  allows them. Built-in profiles include permission defaults, ACP
  permission prompts respect applicable rules, and `yolo: true`
  explicitly allows all enabled tools without prompting.
- Various persistence and interface improvements, including less
  disruptive automatic saving, table highlighting, and folding tag
  contents from either tag boundary.

## Programmatic usage

- Create a conversation with one-off settings using
  `ellm-new-buffer-with-configuration`.

## Codex

- View Codex subscription usage with `ellm-codex-usage`. It shows
  something like this:
  > Codex usage (plus); 5-hour: 74% remaining; resets in 18m 44s
  > (2026-09-24 16:45 +03); weekly: 95% remaining; resets in 70h 31m
  > (2026-09-27 14:58 +03); 3 rate-limit resets available
- You can redeem available rate-limit reset credits with
  `ellm-codex-redeem-rate-limit-reset` which interactively lets you
  select one of the resets.

## Kagi

- Import existing Kagi Assistant conversations. Kagi support also uses
  updated endpoints, with improved streaming and an updated model
  list.

## Somewhat breaking changes

- **Configuration change:** MCP tool names now use `mcp_SERVER_TOOL`
  (with hyphens and slashes converted to underscores). Update any tool
  selectors or permission rules using the old `mcp-SERVER/TOOL` names.

- **Command rename:** remote-session loading (for example loading a
  Kagi session from the server) is now `ellm-import-session`.
  `ellm-open-session` remains the command for locally saved
  conversations (via `ellm-save` or automatic persistence).


# v0.0.2

Performance improvements

# v0.0.1

Initial release.
