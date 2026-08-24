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

<TODO: IMAGE HERE...>

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
are simple `ellm-mode` buffers/files with their own yaml-frontmatters.

_ellm_ also comes with bunch of different tools to let you do _agentic
coding_. The default _profile_ is the `agent` profile, which works
quite similarly to other agents like OpenCode, Claude Code etc. but
much more simplified and Emacs-y.

_ellm_ integrates itself with built-in Emacs tooling where it makes
sense, does not invent new ways of doing things. Everything is either
a buffer or a simple invocation of `completing-read` or a
`read-multiple-choice`. It also provides some convenience functions
that uses these primitives.

# Installation

Install it from this repository with your package manager.  For
example, with Elpaca and `use-package`:

```elisp
(use-package ellm
  ;; elpaca
  :ensure (:host github :repo "isamert/ellm.el" :files ("*.el"))
  ;; vc (requires use-package-vc)
  ;; :vc (:url "https://github.com/isamert/ellm.el")
  ;; straight.el
  ;; :straight (:host github :repo "isamert/ellm.el" :files ("*.el"))
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
system: You are an agent. # Overridden the system prompt compeletly.
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
    tools: [read_file_lines, git, glob, grep]
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

ellm comes with a lot of useful tools, like (list may not be complete,
see `ellm-tools.el`):

- `shell/bash`
- `files/glob`
- `files/grep`
- `files/file-edit`
- `files/read-file-lines`
- `buffers/buffer-edit`
- `buffers/list-buffers`
- `buffers/read-buffer-lines`
- `tool-outputs/read`
- `tool-outputs/search`
- `buffers/search-buffer`
- `buffers/get-buffer-issues`
- `emacs/elisp-info`
- `emacs/elisp-search`
- `emacs/elisp-eval`
- `tasks/todowrite`
- `agents/list-profiles`
- `agents/launch-subagent`
- `agents/list-subagents`
- `agents/wait-subagent`
- `buffers/send-ellm-buffer`
- `web/websearch`
- `web/webfetch`
- `user/ask`
- `git/git`

Again you can utilize the frontmatter to enable/disable tools:

```markdown
---
provider: codex
model: "gpt-5.6-terra"
profile: agent    # Brings all tools enabled in `agent` profile
tools: ["@files"] # This compeletly overrides tool selections for current buffer. Now we only have tools from the files category.
tools-: [file_edit] # We removed the file_edit tool from available tools. Again, you can use the @category notation to remove whole category.
tools+: ["@agents", websearch] # Added all @agents category of tools and websearch tool.
---
```

**Permissions**

When enabled, tools can be run directly without any user
approval. They also do not have any kind of sandboxing. However you
can change this with `tool-permissions`:

```markdown
---
# ...
tool-permissions:
  file_edit: ask  # Now you need to manually approve file_edit calls.
  "@emacs": ask   # This enables manual approval for whole emacs category of tools: elisp-info, elisp_search, elisp_eval
---
```

**Defining/replacing tools**

There is a public API to define tools, `ellm-deftools`. Here is an
example tool definition from my dotfiles. This one, when evalled,
replaces the current `web/websearch` tool. Of course you can define
new tools using this macro too.

```elisp
(ellm-deftool web/websearch (:async t)
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
`websearch` part.)

The tool definitions are kept in `gptel` compatible format. See
`ellm-tools-refs` variable, you can use this to convert ellm tools
into `gptel` tools if you want. For the opposite direction, converting
`gptel` tools into ellm tools, see the variable `ellm-tools-list`, but
I still recommend using `ellm-deftool` macro which comes with it's own
bells and whistles.

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
answer prompts for agents within this buffer.

<TODO: IMAGE HERE>

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

You can also use the `ellm-save` command to save the current
conversation and its live subagents/tool-outputs/encrypted reasonings
etc. even when automatic persistence is disabled; use a prefix
argument to choose its parent directory manually, otherwise it still
uses the `ellm-persistence-location`.

## MCPs

WARNING: This is not working properly right now

For ACP agents, configure available servers with `ellm-mcp-servers` and
select them in frontmatter.  Server entries use the same shape as
`mcp-hub-servers`: a command and arguments for stdio, or a URL for a remote
server.

```elisp
(setq ellm-mcp-servers
      '((filesystem . (:command "npx"
                       :args ("-y"
                              "@modelcontextprotocol/server-filesystem"
                              ".")
                       :category "local"))))
```

```markdown
---
mcp: [filesystem]
---
```

`mcp: true` enables every configured server.  `@CATEGORY` selects a category,
and inline server maps are also supported by frontmatter completion.

For the `llm.el` backend, install and configure `mcp.el`, connect its
servers, then load `ellm-mcp` and run `M-x ellm-register-mcp-tools`.  Registered tools are
named by server category, so `tools: ["@mcp-filesystem"]` enables the tools
from the `filesystem` server.

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
is not as powerful as `llm` backend because it comes with it's own
tools, profiles, system prompts etc. and you are not allowed to
customize but I believe the Emacs integration and the familiarity
makes it worthwhile. Still needs a lot of polishing though.

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

<TODO: MOVE OLD RATIONALE HERE? OR JUST LINK MY BLOGPOST?>

# Prior art

<TODO: GPTEL, ALSO SOMETHING ABOUT GPTEL CAN BE AN ANOTHER BACKEND?>
