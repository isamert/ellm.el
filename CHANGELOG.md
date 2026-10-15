# v0.2.0

- Browse saved conversations with `ellm-sessions`. This is a very
  similar interface to `ellm-list` but for saved
  sessions. Differently, `M-RET` opens a session's directory in Dired
  (where it's persisted).  `M-RET` also works in `ellm-list` now too.
- Faster `ellm-open-session`, with more predictable sorting. Fixed
  problems opening saved sessions and deleting them from the session
  browser.

## Dired integration

- Dired can show conversation titles instead of session directory IDs
  inside ellm persistence directories.  Enable this with:
  ```elisp
  (add-hook 'dired-after-readin-hook #'ellm-dired-display-titles)
  ```

## Org integration

- `org-store-link` now works from `ellm-list` and `ellm-sessions` too.
  From a conversation buffer, it links to the turn at point, so
  following the link takes you back to that turn.
- Find Org headings linking to the current conversation with
  `ellm-org-find-references`. It searches your Org agenda files and
  lists all the headings linking to current conversation. Also works
  from `ellm-list` and `ellm-sessions`.
- Set an `ELLM_WORKSPACE` property on an Org heading to choose the
  working directory for new conversations and ellm's project-based
  commands.  Alternatively, set `ELLM` to an ellm session link to use
  that conversation's working directory. Both properties are
  inherited. Customize `ellm-org-workspace-property` and
  `ellm-org-session-property` to use different property names or
  disable either lookup.

## Conversation controls

- `ellm-cancel` now stops processes started for the running request
  too.  Use `ellm-list-processes` to see the current conversation's
  live processes.
- Cancelling a request from `ellm-list` now asks for confirmation.
- Disable automatic title generation for llm.el conversations by
  setting `ellm-llm-auto-title` to `nil`. Use `auto-title: false` or
  `auto-title: true` in the frontmatter to override it per
  conversation.
- `ellm-show-log` enables logging for future requests in the current
  conversation and opens its backend log. Logs are reused across
  requests and include more information for diagnosing caching issues.

## Improvements and fixes

- Smoother reasoning streaming, and fixed line breaks in Codex
  reasoning summaries.
- Improved Codex prompt caching across consecutive requests.
- Clearer highlighting of parameters in turn headers.
- `ellm-comment` preserves your cursor position. Commands that use a
  selected region deactivate the selection afterwards.
- Automatic saving no longer runs `before-save-hook`.
- More reliable file searches, including glob patterns with directory
  components, and clearer errors for invalid search paths.
- Fixed text decoding problems in tool headers and ACP tool results.
- Subagent tools can use subagent names, not just IDs.

## Programmatic usage

- `ellm-new-buffer-with-configuration` accepts `:prompt` to fill in
  the first user turn. It does not send the prompt automatically.


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
