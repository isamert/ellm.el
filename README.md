# ellm.el

_ellm_ is an _agent_ for Emacs. It's fully written in elisp, easily
extendible and introspectible.

It's more simply a plain text driven agent: _ellm-mode_ is a major
mode that extends Markdown format with _turns_ (as in *assistant turn*
or *user turn*). A turn is like a Markdown header, but instead of
starting with `#`, turns start with `>-|`. A second level turn is
`>>-|`. By making *turns* a first-class citizen of the format, it
becomes very intuitive to handle navigation, folding, narrowing,
etc. _ellm-mode_ integrates with `outline-minor-mode`.

There is no hidden conversation structure, everything is text in a
buffer, so it's quite easy to understand and manipulate. There is no
special UI for configuring, you simply edit the YAML frontmatter where
`completion-at-point` is available and you can see your options
in-buffer, interactively. Your Emacs knowledge transfers quite
cleanly.

<img width="1155" height="749" alt="image" src="https://github.com/user-attachments/assets/9ec8152f-e90a-4e54-ac36-376c0464d27e" />

## Basics

`ellm-mode` is a major mode for plain-text LLM conversations. A buffer
is a Markdown-like file with YAML frontmatter and turn delimiters.  A
simple conversation looks like this, without any formatting:

~~~markdown
---
provider: personal-deepseek
model: deepseek-v4-pro
reasoning: medium
temperature: 0.1
---

>-| system
You are a helpful programming assistant.
>-| user
Write a small Emacs Lisp function that returns today's date.
>-| assistant
>>-| reasoning
We need to write a small Emacs Lisp function that returns today's date. The user didn't specify the format, so I'll assume a common string format like "YYYY-MM-DD". Emacs Lisp has `format-time-string` function that uses the current time by default, and we can specify a format string. So:

```elisp
(defun today-date ()
  "Return today's date as a string in YYYY-MM-DD format."
  (format-time-string "%Y-%m-%d"))
```

That's straightforward. I'll provide that as the answer, possibly with a brief explanation.
>>-| assistant
```elisp
(defun today-date ()
  "Return today's date in ISO 8601 format (YYYY-MM-DD)."
  (format-time-string "%Y-%m-%d"))
```

You can call `(today-date)` to get a string like `"2025-03-14"`.
To change the format, adjust the format specifiers – for example, `"%A, %B %e, %Y"` gives `"Friday, March 14, 2025"`.
>-| user

~~~

Here, as you can see, everything is plain-text. You can manipulate the
yaml-frontmatter to configure your providers/models/tools etc. You can
even manipulate the conversation itself. There is (almost) no hidden
state. The good part is that `ellm-mode` is aware of these _turns_ so
all the navigation/folding is quite intuitive. You can also save this
file, re-open it and continue from where you left. Even the subagents
are simple `ellm-mode` buffers/files with their own YAML frontmatter.

_ellm_ also comes with a range of tools for _agentic coding_. The default
_profile_ is the `agent` profile, which works
quite similarly to other agents like OpenCode, Claude Code etc. but
much more simplified and Emacs-y.

_ellm_ integrates itself with built-in Emacs tooling where it makes
sense, does not invent new ways of doing things. Everything is either
a buffer or a simple invocation of `completing-read` or a
`read-multiple-choice`. It also provides some convenience functions
that uses these primitives.

Here's how a regular conversation might look like:

<img width="830" height="970" alt="image" src="https://github.com/user-attachments/assets/3931b281-177b-418c-a9a6-54b610e15f85" />

# Installation

Install it from this repository with your package manager.  For
example, with Elpaca and `use-package`:

```elisp
(use-package ellm
  ;; elpaca
  :ensure (:host github :repo "isamert/ellm.el"
           :files ("*.el" (:exclude "ellm-test.el")))
  ;; vc (requires use-package-vc)
  ;; :vc (:url "https://github.com/isamert/ellm.el")
  ;; straight.el
  ;; :straight (:host github :repo "isamert/ellm.el"
  ;;            :files ("*.el" (:exclude "ellm-test.el")))
  :config
  (require 'ellm-tools)
  (require 'ellm-llm)
  ;; Set this to not get bombarded by nonfree warnings
  (setq llm-warn-on-nonfree nil))
```

`ellm.el` provides the mode and conversation core.  Load `ellm-tools`
for the built-in tools and `ellm-llm` for API providers through
`llm.el`.  The Codex and ACP backends are optional; load `ellm-codex`
or `ellm-acp` when you use them.

You still need to configure a provider before sending a request.  See
[Configuration](#configuration) and [Configuring
providers](#configuring-providers).

# Usage

The basic agentic workflow would look like this:

- Open a project (any file/folder).
- `M-x ellm-new-buffer`.
- Write your request, hit `C-c C-c` to send, `C-c C-k` to cancel the
  current request.

There is also `ellm-dwim` which is like `ellm-new-buffer` but instead
of creating a new buffer every time, it opens an already existing
project ellm buffer. If there are more than one, it asks you which one
to open. If there is a selected region while calling `ellm-dwim`, it
automatically copies the region with correct fenced blocks and file
name and line references to the target _ellm_ buffer. With prefix
argument, it creates a new buffer.

`ellm-toggle-side-window` is exactly like `ellm-dwim` but it opens the
buffers in a side window to the right (feels like what Cursor does).

## Profiles and system prompts

There are _profiles_ that you can use (see `ellm-profiles`). The
default profile is called `agent`. By default it has access to file
reading and editing tools, shell tools (where it can run arbitrary
shell commands), web tools (to do web search, fetch web pages),
sub-agent tools (creating/waiting/listing sub agents etc.) You can
either edit the `ellm-profiles` `defcustom` to change what a profile
should have, or you can simply edit the frontmatter to customize it
for the current buffer:

```markdown
---
provider: personal-deepseek
model: deepseek-v4-pro
profile: agent     # Explicitly setting a profile. The changes below will override the profiles configuration.
tools-: ["@shell"] # Now your agent does not have shell access
reasoning: high    # Reasoning is now high.
system: You are an agent. # Overrides the system prompt completely.
---

>>-| system
You can also override the system prompt this way which is much cleaner than using the frontmatter.
>>-| user
...
```

You can even define profiles within the frontmatter:

```markdown
---
provider: personal-deepseek
model: deepseek-v4-pro
profile: agent
profiles:
  - name: reviewer-agent
    tools: [read, git, glob, grep]
    system: You are a reviewer. Review the code changes and report possible issues.

# Here we defined a profile that has no access to shell and but tools
# like git (a readonly git tool), file reading, file listing etc. so
# that it can do proper reviews.
---
```

This is generally useful for subagents. The agent tool sees these
profiles and selects the appropriate subagent (or you can direct the
agent to use one of these profiles).

It is also useful in a sense that instead of configuring elisp
variables, you can create your template files and fill your _ellm_
buffers from these templates. This gives you even more explicitness
and ease of ad-hoc configurations. The frontmatter supports
`completion-at-point`, so it is quite easy to discover what you can
configure and how. It's all plain-text.

### Default system prompt

The default system prompt (see `ellm--agent-system-prompt`) is a
simple prompt that works well with any type of workflow (be it
exploring a code base, or doing changes across multiple files,
delivering e2e features). It wants you to be explicit a bit, if you
want something to be done, just say "do it" or "implement it".

_ellm_ also comes with another profile, called `explore` which is a
read-only agent (no access to shell, file editing etc.) but it also
has access to tools like `git` (a read only git tool, so that agent
can access git diffs/commits etc. without relying on unrestricted
shell access), `glob`, `grep` etc.

### System prompt templating and code execution

System prompts support code execution/templating. For example the
default system prompt contains the following:

```markdown
<tool_usage>
#{(when (ellm-tool-enabled-p "todowrite")
   "- Use todowrite for complex, multi-step work to track progress. Keep the list concise and update it as work is completed; do not use it for straightforward tasks.")}
#{(when (ellm-tool-enabled-p "agents")
   "- Use the agents tool to launch subagents when the user explicitly requests delegation, or an independent review. Otherwise, complete the work yourself.")}
#{(when (ellm-tool-enabled-p "ask")
   "- Use the ask tool only when the user explicitly requests planning or brainstorming, or when essential information is missing and proceeding would risk a consequential mistake. Otherwise, make reasonable assumptions and proceed autonomously.")}
</tool_usage>
```

If you were to remove the `agents` tool from the default profile:

```markdown
---
...
tools-: ["@agents"] # Removed all tools from the agents category of tools.
---
```

The part about `agents` in the system prompt automatically disappears,
no unnecessary context is used and LLM is not confused. Similarly,
reading your `AGENTS.md` is done through this templating system:

```markdown
#{(ellm-prompt-read
   '("AGENTS.md" "CLAUDE.md")
   :heading "Follow these project instructions:"
   :tag "project_instructions")}
```

which in turn produces something like this if you have an `AGENTS.md`
or `CLAUDE.md`:

```xml
<project_instructions>
Project's AGENTS.md here...
</project_instructions>
```

ellm also supports XML tags, meaning that they are fontifed and you
can toggle what's between them with `TAB`. This is also supported
within anywhere in the buffer, not just for system prompts.

### System prompt cache

System prompt evaluation happens only when a backend consumes system
prompts.  Rendered values are memoized by exact template text in the
conversation buffer, so identical frontmatter and turn templates share
one value.  New or edited template text is evaluated once; changing it
back reuses its earlier value.  `M-x ellm-refresh-system-prompts`
clears the buffer's cache.  The cache is not saved.  `M-x
ellm-show-effective-system-prompts` shows cached output without
running any Lisp.

For example, expire the caches in every live ellm buffer at midnight
so that they get re-evalutated:

```elisp
(require 'midnight)

(defun my-ellm-refresh-system-prompts-at-midnight ()
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'ellm-mode)
        (ellm-refresh-system-prompts 'quiet)))))

(add-hook 'midnight-hook #'my-ellm-refresh-system-prompts-at-midnight)
(midnight-mode 1)
```

Also, here are the functions that may help in system prompts:

- `ellm-prompt-read-file` — read a file relative to the request
  directory.
- `ellm-prompt-read` — read the first available file from an ordered
  list, with optional headings and tags.
- `ellm-prompt-frontmatter` — read the request's frontmatter snapshot.
- `ellm-tool-enabled-p` — check whether a local tool is enabled by the
  request's `tools:` selection.
- `ellm-prompt-directory` and `ellm-prompt-project-root` — inspect
  request paths.

## Tools

`ellm-tools-list` is the authoritative runtime registry: after loading
`ellm-tools`, use `M-x describe-variable RET ellm-tools-list` to
inspect the available tools, including any tools you have added or
replaced.  The built-in registry contains:

- `user/ask`
- `shell/bash`
- `git/git`
- `files/glob`
- `files/grep`
- `files/edit`
- `files/read`
- `buffers/edit-buffer`
- `buffers/buffers`
- `buffers/read-buffer`
- `tool-outputs/output`
- `buffers/search-buffer`
- `tool-outputs/search-output`
- `buffers/buffer-issues`
- `emacs/elisp-info`
- `emacs/elisp-search`
- `emacs/elisp-eval`
- `tasks/todowrite`
- `agents/profiles`
- `agents/launch-subagent`
- `agents/subagents`
- `agents/wait-subagent`
- `agents/send-subagent`
- `web/web-search`
- `web/web-fetch`

The category is only for grouping.  The name exposed to providers and used in
frontmatter is the part after `/`, with hyphens written as underscores: for
example, `files/read` is `read` and `web/web-search` is `web_search`.  Exposed
names are globally unique.

Again you can utilize the frontmatter to enable/disable tools:

```markdown
---
provider: codex
model: "gpt-5.6-terra"
profile: agent    # Brings all tools enabled in `agent` profile
tools: ["@files"] # This completely overrides the tool selection for the current buffer; only tools from the files category remain.
tools-: [edit] # We removed the edit tool from available tools. Again, you can use the @category notation to remove whole category.
tools+: ["@agents", web_search] # Added all @agents category of tools and web_search tool.
---
```

### Permissions

When enabled, tools can be run directly without any user
approval. They also do not have any kind of sandboxing. However you
can change this with `tool-permissions`:

```markdown
---
# ...
tool-permissions:
  edit: ask  # Now you need to manually approve edit calls.
  "@emacs": ask   # This enables manual approval for whole emacs category of tools: elisp-info, elisp_search, elisp_eval
---
```

### Defining/replacing tools

There is a public API to define tools, `ellm-deftools`. Here is an
example tool definition from my dotfiles. This one, when evalled,
replaces the current `web/web-search` tool. Of course you can define
new tools using this macro too.

```elisp
(ellm-deftool web/web-search (:async t)
    ((query :string "The search query."))
    "Perform a web search and receive concise results and links to sources."
    (my-kagi-search
     query
     :success
     (lambda (results)
       (funcall
        callback
        (mapconcat
         (lambda (res)
           (let-alist res
             (concat
              (when .title (format "Title: %s\n" .title))
              (when .url (format "URL: %s\n" .url))
              (when .description (format "Desc: %s\n" .description))
              "---\n")))
         results "")))
     :error (lambda (it)
              (funcall
               callback
               (format "Error while searching: %s" it)))))
```

The category name (`web/` part in this case) is there just for
grouping, it can be anything. The tool names should be unique (the
`web_search` part.)

The tool definitions are kept in `gptel` compatible format. See
`ellm-tools-refs` variable, you can use this to convert ellm tools
into `gptel` tools if you want. For the opposite direction, converting
`gptel` tools into ellm tools, see the variable `ellm-tools-list`, but
I still recommend using the `ellm-deftool` macro, which comes with its own
bells and whistles.

### Tool customization and extras

Some tools have their own configuration and extensions. For example, you can
edit `ellm-tools-glob-options` to change the behavior of the glob tool etc.
Do `M-x customize-group ellm-tools` to learn more about these.

There are also extra functionalities some tools offer. For example, if
`file/edit` tool realizes it's editing a lisp file, then it'll do a
parenthesis check after the edit automatically and report back to the
ellm if it finds and unmatched parenthesis:

```
Successfully edited file ellm-test.el
Post-edit checks reported:
- Emacs Lisp has an unmatched delimiter near line 8364, column 0: Unmatched bracket or quote
```

Extras like these saves a few roundtrips and quite useful. They
generally do not report anything extra if everything goes well. You
can edit the `ellm-tools-file-edit-checkers` defcustom to change which
checkers run with `file/edit` or define yours too.

## Utilities

There are a few utilities that make everyday interactions easier, I
found them to be very effective and hence here is a detailed
breakdown:

### `ellm-comment`

Comment on current line or selected text and send this to the bottom
of your next input. This can be called from any buffer:

- If called from the current ellm buffer itself, quotes the selected
  region or line, asks you for your comment and puts this at the end
  of your input. For example:

  ```markdown
  >-| assistant
  ...
  I’d take this path:
  1. **Batch row updates, with one point/window restore and one redisplay.**
  ...
  >-| user


       (You selected the line with (1.) and commented)
                           ↓


  >-| assistant
  ...
  I’d take this path:
  1. **Batch row updates, with one point/window restore and one redisplay.**
  ...
  >-| user
  > 1. **Batch row updates, with one point/window restore and one redisplay.**
  Lay out the exact implementation plan for this.
  ```

  If you select a code to comment from another buffer for example, and
  commented on it, this is inserted to your prompt:

  ~~~markdown
  ``` emacs-lisp ellm.el:1347:1350
  (replace-regexp-in-string
     (ellm-tools--escaped-tool-body-prefix-regexp)
     (lambda (match) (substring match 1))
     text nil t)
  ```
  Instead of passing `t`, pass `'literal` so we can track what we enabled here.
  ~~~

  If the LLM is currently streaming, then your comments will be
  written into the compose area.

I recommend you to bind this command to a global key, it is especially
useful for referencing code blocks from the project or doing a code
review inside a diff buffer and commenting on different parts in quick
successions.

### `ellm-compose`

While LLM is streaming, the buffer becomes read-only. This is a simple
work around to schedule messages for your next input. When you `M-x
ellm-compose` then another temporary buffer will be opened and you can
enter your next prompt. When ellm finishes streaming, the prompt is
automatically inserted as your next prompt. It is not sent
automatically, just inserted.

### `ellm-set-config`

Edit the configuration interactively, the results will be eventually
written into the frontmatter. This is useful for changing something
quickly or discovering what's available (especially for ACP backend,
other than that editing frontmatter directly is easier).

---

Every utility function knows about the compose area and will work
intuitively.

If there are multiple ellm buffers open, then each function will ask
you for which buffer to insert your comments/compose or guess from
your current layout (like if you have one visible ellm buffer, it'll
target it)

## Managing multiple agents & subagents

`M-x ellm-dwim` finds the main conversations for the current project
(or current directory outside a project).  It reuses one when possible
and asks when there are several.  Use a prefix argument to always
start a new one.  `ellm-toggle-side-window` does the same thing in a
side window.

`M-x ellm-switch-to-project-buffer` switches to a main conversation
for the current project.  With a prefix argument it includes subagents
too.  The agent can create subagents with the `launch-subagent` tool;
they are ordinary ellm buffers with their own frontmatter and can be
visited, edited, and sent like any other conversation. There is also
`ellm-switch-to-subagent-buffer` which is pretty self explanatory.

`M-x ellm-list` shows every live conversation, grouped by project or
directory.  It shows request status, todos, context use, and model.
Main conversations show their subagents as children; `TAB` folds
either a project or a subagent tree. The updates are reflected in real
time. This is a simple and very effective interface for managing
multiple agents across many different projects. It also uses some
colors, temporary pulsing etc. to get your attention. You can directly
answer prompts for agents within this buffer. Press `C` on a project or
directory group (or one of its conversations) to create a new conversation
there.

<img width="1099" height="647" alt="image" src="https://github.com/user-attachments/assets/718b617b-4ad0-40c9-8cf5-6c82bf3101f8" />

## In buffer controls

Turns and Markdown headings work with the usual outline commands.
`TAB` cycles the subtree at point and `S-TAB` cycles the whole buffer.
`C-c C-c` sends the current prompt, `C-c C-k` cancels the current
request, and `C-c C-e` opens a compose buffer while a response is
streaming. You can jump between headings with, again, using the usual
outline commands like `outline-{next,prev,up}-heading` etc.

Some other useful commands are:

- `ellm-narrow-to-turn`, `ellm-narrow-to-header`, and
  `ellm-narrow-dwim` narrow to the relevant turn or Markdown section.
- `ellm-jump-to-tool-pair` jumps between a tool call and its result.
- `ellm-toggle-tag`, `ellm-fold-all-tags`, and `ellm-unfold-all-tags`
  fold XML-style prompt tags. Again, `TAB` also works for folding
  them.
- `ellm-fold-all-tool-blocks`, `ellm-fold-all-reasoning-blocks`, and
  `ellm-fold-all-blocks` fold generated details.

## Persistence

Conversations are plain text, so you can always save an `.ellm` file yourself
and reopen it later.  Automatic persistence is optional.  Set
`ellm-persistence-enabled` to non-nil and new main conversations are saved as
`main.ellm` in their own session directories.  Their subagents, retained tool
outputs, and reasoning state are saved alongside them.

`ellm-persistence-location` controls where sessions go.  The default
`global` location is `ellm-persistence-directory` (`~/ellm/`).  Set it to
`project` to store sessions below `ellm-persistence-project-directory`
(`.ellm`) in each project.  `M-x ellm-open-session` opens a saved main
conversation.

<img width="761" height="113" alt="image" src="https://github.com/user-attachments/assets/8df682dd-046a-4051-93ee-82f3350978f1" />


You can also use the `ellm-save` command to save the current
conversation and its live subagents/tool-outputs/encrypted reasonings
etc. even when automatic persistence is disabled; use a prefix
argument to choose its parent directory manually, otherwise it still
uses the `ellm-persistence-location`.

## MCPs

This requires [mcp.el](https://github.com/lizqwerscott/mcp.el).

```elisp
(use-package mcp
  :ensure t
  :config (require 'mcp-hub))
```

Configure available servers with `ellm-mcp-servers` and select them in
frontmatter. You can also use `mcp-hub-servers` instead too, ellm
automatically picks up both. `ellm-mcp-servers` has precedence. They
both use the same configuration style, except you can also have
`:category` while defining using `ellm-mcp-servers`.

```elisp
(setq ellm-mcp-servers
      '((filesystem . (:command "npx"
                       :args ("-y" "@modelcontextprotocol/server-filesystem" ".")
                       :category "local"))))
;; or

(setq mcp-hub-servers
      '((filesystem . (:command "npx"
                       :args ("-y" "@modelcontextprotocol/server-filesystem" ".")))))
```

Now you can enable MCP servers in the frontmatter:

```markdown
---
mcp: [filesystem]
# or by category, if available
# mcp: ["@local"]
---
```

ellm automatically starts and waits for the MCP server to become
online, then adds each MCP tool to current sessions tool list. Tools
are named `mcp-SERVER/TOOL`, which keeps tool calls from different
servers distinct. (ACP backend does not require mcp.el, it directly
takes the list of MCPs)

`mcp: true` enables every configured server.  `@CATEGORY` selects a
category, and inline server maps are also supported by frontmatter:

```markdown
---
mcp+:
  # Enable another_mcp_server that is defined in ellm-mcp-servers/mcp-hub-servers
  - another_mcp_server
  # Define and enable a new MCP server inline:
  - name: local-tools
    command: npx
    args:
      - "-y"
      - "@example/local-tools"
# Remove an MCP server from active servers for current session:
mcp-: [some_mcp_server]
---
```

---

Also, you can simply define your servers via `mcp-hub-servers`, start
them via `(mcp-hub-start-all-server)` and then:

```elisp
(require 'ellm-mcp)
(ellm-register-mcp-tools)
```

Now, you can enable/disable tools from given MCP servers via the
fronmatter:

```markdown
---
# Assuming you have an MCP server named "filesystem",
# it becomes a category of tools named "mcp-filesystem"
tools: ["@mcp-filesystem"]

# You can also selectively enable them:
tools:
  - mcp-filesystem/read_file
  - mcp-github/create_issue
---
```

This is not supported by the ACP backend.

# Configuration

Most configuration is either a regular Emacs customization variable or YAML
frontmatter.  Use `M-x customize-group RET ellm` for global defaults, and use
frontmatter when a setting belongs to one conversation.  Frontmatter has
completion-at-point, and `M-x ellm-set-config` provides an interactive editor.

The important global starting point is `ellm-provider-alist`, which maps the
names used by `provider:` to provider objects.  `ellm-provider` is the
fallback when a buffer does not name one.  `ellm-profiles` contains reusable
frontmatter defaults such as tools, system prompts, and model choices.  See
[Profiles and system prompts](#profiles-and-system-prompts) for profile
examples.

## `ellm-new-buffer-default-configuration-function`

This is a function that you can define to decide what the
configuration for a new ellm buffer would be. For example, I have
something along the lines of:

```elisp
(setq
   ellm-new-buffer-default-configuration-function
   #'(lambda ()
       (let ((work-project? (f-ancestor-of? "~/Workspace/projects/work" default-directory))
             (elisp-project? (f-ancestor-of? "~/.emacs.d/elpaca" default-directory))
             (provider (cond
                         (work-project?
                          (intern (completing-read "Which one? " '("internal-llm-gateway" "cursor"))))
                         (t "codex"))))
         (list
          :provider provider
          :model (ellm-provider-default-model provider)
          :profile
          (cond
           ((eq 'cursor provider) nil)
           ((or work-project? elisp-project?) "agent")
           (t "explore"))
          :tools+
          (cond
           (elisp-project? '("@emacs")))))))
```

This what it roughly does:
- Checks if the current project is a work project or an Elisp project.
- Sets the default profile to "explore" if we are not in a project at all.
- For work and Elisp projects, uses the "agent" profile.
- For Elisp projects, enables the "@emacs" category of tools.

The harness is one of the most important parts of these kind of
workflows. Hence, having a project-appropriate harness selected
automatically for you is quite useful. I also realized this was taking
more than necessary time to configure and found this customization to
be utterly useful.

You can add/remove tools based on the path, the language of the
project, you can check how much credit you have in your subscription
and depending on that, you can select a different provider etc. Or you
can do a small synchronous LLM call to determine all of these
automatically. The sky is the limit here.

## Visuals and the header line

The header line can show:

- session title
- active todo
- todo completion progress
- context usage
- request cost
- pending user prompt status
- next-prompt draft state

`ellm-header-line-template` supports placeholders:

- `%t` title
- `%a` current TODO
- `%p` TODO progress
- `%u` context usage
- `%c` cost
- `%q` pending user prompt
- `%d` next draft
- `%l` title + TODO progress
- `%r` context usage + cost
- `%>` right alignment
- `%%` literal percent sign

Visual controls include:

- `ellm-heading-rescale` — use distinct sizes for Markdown and
  turn-heading levels; set to `nil` for uniform heading sizes.
- `ellm-pretty-separators` — replace raw turn delimiter lines with
  decorative overlays.
- `ellm-turn-rules` — draw horizontal rules above top-level turns.
- `ellm-reveal-separator-at-point` — temporarily reveal a raw
  delimiter when point enters it.
- `ellm-fold-tool-calls` — insert tool-call turns folded by default.
- `ellm-fold-reasoning-blocks` — insert reasoning turns folded by
  default.
- `ellm-turn-header-1`, `ellm-turn-header-2`, and `ellm-turn-header-3`
  — customize the delimiter text for top-level turns, child turns, and
  grandchild turns, respectively.
- `ellm-tool-header-summary-width` — set the maximum width of tool
  call and result titles; longer titles are truncated.

## Notifications

ellm notifies you when a permission is requested or when a logical
request completes or fails, but only when the conversation buffer is
not visible in a focused Emacs frame.

`ellm-notification-function` controls delivery.  Its default,
`ellm-notify-default`, tries native `notifications-notify`, then the
optional `alert` package, and finally `message`.  A custom function
receives a plist with `:event`, `:request`, `:buffer`, `:title`,
`:body`, and `:urgency`, plus event-specific context such as
`:permission` or `:outcome`.

Use `ellm-notifications-enabled` to disable notifications entirely, or
`ellm-notification-events` to select notification event categories.

Of course, you can override `ellm-notification-function` to write your
own custom notifier.

## Lifecycle hooks

Lifecycle hooks run in the conversation buffer.  Register one for a
specific conversation with a buffer-local hook, for example:

```elisp
(add-hook 'ellm-request-finished-hook #'my-ellm-finished nil t)

(defun my-ellm-finished (request outcome)
  (message "Request %s" (plist-get outcome :state)))
```

Notifications are implemented by using these hooks. You can utilize
them to do other similar things but for normal use, not something that
you'll reach for but here are they:

- `ellm-before-request-hook` `(REQUEST EVENT)` — Runs after request
  configuration is resolved but before the conversation or request
  state is mutated; signaling an error vetoes the send.
- `ellm-request-started-hook` `(REQUEST EVENT)` — Runs once
  immediately before the initial backend leg of a logical request
  starts.
- `ellm-request-finished-hook` `(REQUEST OUTCOME)` — Runs once after a
  logical request’s final cleanup; `OUTCOME` has a `:state` of
  `completed`, `cancelled`, or `failed`.
- `ellm-tool-call-hook` `(REQUEST EVENT)` — Reports a normalized tool
  invocation observed by a backend.
- `ellm-tool-finished-hook` `(REQUEST EVENT)` — Reports a normalized
  terminal backend-observed tool outcome (`completed` or `failed`).
- `ellm-before-permission-hook` `(REQUEST PERMISSION)` — Runs before
  ellm queues a normalized permission prompt.
- `ellm-after-permission-hook` `(REQUEST PERMISSION DECISION)` — Runs
  after a permission decision; `DECISION` is `nil` when the prompt was
  cancelled.
- `ellm-tools-tool-call-start-hook` `(TOOL ARGS)` — Runs before a
  local `ellm-deftool` body begins execution.
- `ellm-tools-tool-call-end-hook` `(TOOL ARGS ERROR RAW RESULT)` —
  Runs after a local `ellm-deftool` finishes; `RAW` is its
  pre-transform result and `RESULT` is the value returned to the
  model.

# Configuring providers

## API providers using `llm.el`

ellm uses [`llm.el`](https://github.com/ahyatt/llm) for ordinary API
providers.  Load the provider implementation you need, create its provider
object, then add it to `ellm-provider-alist`.  For example, an OpenAI
provider can look like this:

```elisp
(require 'auth-source)
(require 'llm-openai)

(setq ellm-provider-alist
      `((openai . (:provider ,(make-llm-openai
                                :key (auth-source-pick-first-password :host "api.openai.com")
                                :chat-model "gpt-5.5")
                   :models ("gpt-5.5" "gpt-5.6-sol") ; optional list of models, known ones will be available by default
                   :small-model "gpt-5.4-nano"))))
```

Then select it in a conversation:

```markdown
---
provider: openai
model: gpt-5.5
temperature: 0.1
---
```

`llm.el` has providers for a number of services and local models.  The same
pattern applies to all of them: require its library, construct a provider,
and give it a name in `ellm-provider-alist`.  `:models` supplies frontmatter
completion; `:small-model` is used for small auxiliary requests such as
title generation.

## Codex

The Codex provider uses your ChatGPT subscription rather than an API
key.  Load `ellm-codex`, create a provider, and add it to the provider
alist:

```elisp
(require 'ellm-codex)

(setq ellm-provider-alist
      `((codex . (:provider ,(ellm-make-codex-provider :chat-model "gpt-5.6-terra")
                  :models ("gpt-5.6-terra" "gpt-5.6-sol" "gpt-5.6-luna")))))
```

Run `M-x ellm-codex-login` once to sign in.  It opens a browser by
default; with a prefix argument it uses device-code login.
Credentials are stored in `ellm-codex-auth-file`.  Select it with
`provider: codex` in frontmatter.  The available models and reasoning
levels are completed in the buffer.

## ACP

[Agent Client Protocol](https://agentclientprotocol.com/) (ACP) lets
ellm use an external coding agent while keeping the same conversation
buffer and controls.

The whole reason this exists is that sometimes at work I also use a
subscription my company gives me and I want the same level of
controls, ease of use and familiarity of ellm. Of course, this backend
is not as powerful as `llm` backend because it comes with its own
tools, profiles, and system prompts that cannot be customized.  I
still believe the Emacs integration and familiarity make it
worthwhile. It still needs a lot of polishing, though.

Load `ellm-acp`, configure the program that starts the agent's ACP
server, and add it to `ellm-provider-alist`:

```elisp
(require 'ellm-acp)

(defvar my-agent
  (ellm-make-acp-provider
   :command "YOUR-AGENT"
   :args '("acp")
   :model "YOUR-MODEL"))

(setq ellm-provider-alist
      `((my-agent . ,my-agent)))
```

Use `provider: my-agent` in frontmatter.  ellm starts a session for the
buffer, translates ACP events into turns, and forwards permission requests
to the usual ellm permission UI.  Agent capabilities differ, so frontmatter
completion discovers session configuration when the agent exposes it.

# Rationale

There are two different parts of ellm, which I believe makes it
powerful:

- Plain text conversation files with an extended Markdown format. So
  you get a lot of things for free, and because it's a superset of
  Markdown, it defines *turns* as first-class citizens, which makes
  navigation/folding etc. a breeze.
- It's a frontend for any LLM provider. Right now it supports many API
  providers through llm.el, Kagi Assistant, and ACP agents. You can also
  implement a couple of functions and use ellm as your frontend for
  another backend. Of course, each backend has a different level of
  flexibility, but this lets you mix your different subscriptions. For
  example, you can use Fable from your API subscription to make plans
  and issue the real implementation work to your Codex subscription
  through the ACP backend, which is orchestrated by Fable using
  subagents. Subagents are also simple ellm buffers that agents can
  manipulate. It also gives you a unified frontend for dealing with
  all these nonsense.

---

Here is a longer rant about why having it all plain-text is better (of
course, not all backends have this level of power but you get the
idea):

I like plain text. I don't like having separate definitions for
serialized (like having a transcript of an LLM interaction) and *real*
data. Just like Lisp being homoiconic, I want my LLM interactions to
be homoiconic (yes, that's not what it exactly means but I hope you
got where I'm heading to. I also want to sound cool). Being able to
edit conversations just like a regular old file opens the doors to
different opportunities. First of all, your all *file editing and
navigation* knowledge transfers here completely. You also get *forking
conversations* feature for free, just copy the parts you want and
continue your discussion in another buffer. This also relieves you
from learning another management tool, you are just switching between
buffers which you do all day. You also get this for free. Also, you
are able to edit the conversations as you want, this gives you
different powers [like
this](https://haskellforall.com/2026/01/prompting-101-show-dont-tell). Using
this approach, build conversations that you like, save them as a file
and use them anytime you want, or just share them. I can go on much
more but you got the point.

The natural extension to this mindset in Emacs world is Org. It has
properties, you can attach data to headers. Runnable code blocks, or
just any type of blocks. It's also extensible. As much as I wanted to
use org-mode for interacting with LLMs-like for everything else I
do--it's not feasible. First of all, you can't make LLMs output Org
directly. You need to convert it to Org syntax on-the-fly. GPTel does
this-along with a lot of other wonderful things, great package-but
there is no real way to get it right, it almost always does something
wrong. So, in a nutshell, conversion to Org is a frustrating practice
that'll simply waste your time.

The second best thing is, staying in the plain-text world, is using
Markdown. LLMs love it for some reason, not matter how abusive you
are, they don't back off from outputting Markdown. But there are
couple problems with using Markdown, or as people use it right now:

- No special syntax for conversation like interface. People utilize
  headers for prompts. But what if your prompt is quite long? How do I
  separate the LLM output from my prompt? LLMs also output Markdown
  and you can't reliable tell them "JUST USE SECOND LEVEL HEADERS AND
  NOTHING ELSE" or whatever you want to yell at those clankers. They
  are going to use the Markdown construct that you want to keep it to
  yourself, and output it.
- This is an Emacs specific thing but markdown-mode, at least in my
  experience, is slow. `markdown-ts-mode` is not very mature. Also
  again, there is no special Markdown syntax for conversational
  interface. You can select a good non-conflicting prefix for your
  conversations but none of the Markdown modes will play with it
  nicely when it comes to folding. The conversational turns should
  have their own *block*, the folding should work within that block
  without swallowing your special turn separator.

Because LLMs are outputting Markdown-and they do not use every
Markdown construct from every different Markdown spec, they simply use
a fairly simple subset of features-, I didn't want to have a format
that is different from Markdown, hence this, I extended Markdown with
the following:

```
>-| user
...
>-| assistant
...
```

We can call these a turn delimiter. Ending with `-|` because Markdown
already uses `>` for denoting quotes and we need to differentiate and
make it visually distinguishable. Also because quoting someone can
introduce multiple `>`s stacking, that's why `>>` is not feasible. The
choice of starting with `>` is deliberate because even without using a
special mode for this type of file, you get a free syntax
highlighting, other Markdown parsers will think this is a quote (and
in a sense, it is). From one turn delimiter to another, all the
Markdown features should work properly. For example, if you fold a
header, it should fold at maximum to the next turn delimiter. Now that
`>-|` lines belongs to our use, we can use it for the tool calls
too. Adding more `>` would denote hierarchy, just like Markdown or Org
headers, so you can have easily parsable hierarchies without keeping
state:

```
>-| user
...
>-| assistant
...
>>-| tool-call
...
>>-| tool-result
...
>>-| assistant
...
```

The `>>-| assistant` line is the continuation of the assistant after
the calls. Current implementation renders this line blank but it is
required for being able to distinguish between different types of
continuation lines, like tool calls and results.

With this, we have a really simple conversational interface on top of
Markdown. The rest of the features, like sending text from other
buffers, forking conversations, attaching context etc. are
responsibilities of the user. You can simply transfer your file
editing know-how that is already existing.

To make these files self-contained, I also put a YAML
frontmatter. This can contain various configurations of ellm
specificly for this buffer. It's also editable and after editing, the
conversation will continue with these new configurations. For features
that are not easily editable via YAML-like a long system prompt, you
can still use the turn delimiters:

```
>-| system
...
>-| user
...
>-| assistant
```

Of course, this is all customizable. You can change it to whatever.

These lines can also carry custom data:

```
>-| user | token: 300, cost: 0.25$,
...
>-| assistant | took: 10s, cost: 0.03$
...
```

This is the simple idea.

# Prior art

There are other really good LLM tooling that you can use in Emacs.

- **[gptel](https://github.com/karthink/gptel/)** :: I think this is
  the gold standard. It is moldable, can be used anywhere in Emacs
  with anything. To make it "agentic", you can add your own tools or
  use packages like
  [gptel-agent](https://github.com/karthink/gptel-agent/). ellm is
  quite similar to gptel-agent but mainly differs itself with the
  conversation format being fully plain-text, the configuration being
  plain-text and in-buffer completable, everything being explicit
  instead of having implicit state and also all the bells and whistles
  that comes with it (turns, buffer formatting, folding capabilities,
  `ellm-list`, `ellm-comment`, `ellm-save`... etc.)  Another
  difference is ellm is mostly a UI + tools, it defers the
  LLM-interactions to other packages/programs (like using llm.el or an
  ACP server). gptel might as well be an another backend for ellm
  (which I am considering for the future so that you can use ellm as
  your "agent" and gptel anywhere else in the Emacs with a shared
  configuration)
- **[agent-shell](https://github.com/xenodium/agent-shell)** :: Great
  package for integrating Emacs with ACP servers. ellm also provides
  an ACP integration but it's very primitive. I added it so that I can
  simply use the same ellm interface with the Cursor subscription that
  my company gives to me. **agent-shell** is built on top
  [acp.el](https://github.com/xenodium/acp.el) (from the same author,
  xenodium), which ellm does not use for now but in the future, it
  might to have a better ACP integration.
- **Other Claude/Codex etc. wrappers** :: These are different class of
  packages. They simply wrap these CLI tools and provide some
  contextual integration with Emacs. Whole reason ellm exists is that
  I want minimal friction between Emacs and my LLM usage. ellm is
  *native*, your Emacs knowledge transfers quite well.
