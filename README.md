# ellm

Minimal coding agent with special conversation format based on Markdown. Intuitive to read/navigate/edit.

## Usage

`ellm` is a major mode for plain-text LLM conversations.  A buffer is a
Markdown-like file with YAML frontmatter and turn delimiters.

```markdown
---
provider: openai
model: gpt-5.4-mini
---

>-| user
Write a small Emacs Lisp function that returns today's date.
```

Useful commands:

| Key       | Command               | What it does                                                     |
|-----------|-----------------------|------------------------------------------------------------------|
| `C-c C-c` | `ellm-send`           | Send the final `user` turn.                                      |
| `C-c C-k` | `ellm-cancel`         | Cancel the active request.                                       |
| `C-c C-l` | `ellm-load-session`   | Pick and load a backend session, when supported.                 |
| none      | `ellm-close-session`  | Close the current backend session, when supported.               |
| none      | `ellm-delete-session` | Delete the current backend session from history, when supported. |

Create a new conversation with `M-x ellm-new-buffer`, edit the final
`user` turn, then run `ellm-send`.

### llm.el Backend

Use this backend for direct LLM API calls through
[llm.el](https://github.com/ahyatt/llm).  Any `llm.el` chat provider can
be used.

```elisp
(require 'ellm)
(require 'ellm-llm)
(require 'llm-openai)

(setq ellm-provider-alist
      `((openai . ,(make-llm-openai
                    :key (getenv "OPENAI_API_KEY")
                    :chat-model "gpt-5.4-mini"))))
```

Conversation example:

```markdown
---
provider: openai
model: gpt-5.4-mini
system: You are concise.
temperature: 0.2
max-tokens: 1000
---

>-| user
Explain lexical binding in Emacs Lisp.
```

Enable built-in local tools:

```elisp
(require 'ellm-tools)
```

```markdown
---
provider: openai
tools: ["@files"]
---

>-| user
Read this project and summarize the main package entry point.
```

Supported by the `llm.el` backend:

| Feature | Status |
| --- | --- |
| Editable full conversation history | yes |
| `system`, `model`, `temperature`, `max-tokens`, `reasoning` frontmatter | yes |
| `cwd:` as the buffer-local `default-directory` for requests and tools | yes |
| Local `tools:` selection | yes |
| Tool call/result serialization in the buffer | yes |
| Streaming text and reasoning | yes, when provider supports it |
| ACP sessions, permissions, slash commands, plans | no |
| `mcp:` servers | parsed by ellm, not used by this backend yet |

### ACP Backend

Use this backend for agents that speak the Agent Client Protocol over
stdio, such as `opencode --acp`.

```elisp
(require 'ellm)
(require 'ellm-acp)

(setq ellm-provider-alist
      `((opencode . ,(ellm-make-acp-provider
                      :command "opencode"
                      :args '("--acp")
                      :model "openai/gpt-5.4"))))
```

Conversation example:

```markdown
---
provider: opencode
model: openai/gpt-5.4
cwd: /home/me/project
---

>-| user
Find one simple refactor in this repository and explain it first.
```

`ellm` persists the ACP session id in frontmatter:

```markdown
---
provider: opencode
acp:
  session-id: sess_abc123
---
```

On a fresh connection, saved sessions are restored with `session/resume`
when the agent supports it, otherwise `session/load` when available.

Set `ellm-acp-tool-detail-limit` to keep ACP buffers smaller.  Nil renders
full tool params and results, `0` inserts only `tool-call` and `tool-result`
headings, and a positive integer truncates each rendered parameter value and
result body to that many characters. This setting is ACP-only and does not
affect the `llm.el` backend.

Supported by the ACP backend:

| Feature                                                         | Status                     |
|-----------------------------------------------------------------|----------------------------|
| stdio JSON-RPC transport                                        | yes                        |
| `initialize`, `session/new`, `session/prompt`, `session/cancel` | yes                        |
| Saved session restore with `session/resume` or `session/load`   | yes                        |
| `session/list` through `ellm-load-session`                      | yes                        |
| `session/close` through `ellm-close-session`                    | yes                        |
| `session/delete` through `ellm-delete-session`                  | yes                        |
| ACP text, thought, and replayed user message chunks             | yes                        |
| Tool calls, tool updates, diffs, locations, raw input/output    | yes                        |
| Plans and usage updates                                         | yes                        |
| Slash command completion from the agent                         | yes                        |
| Permission requests                                             | yes, via `completing-read` |
| Model config option                                             | yes                        |
| MCP servers from `mcp:`                                         | yes                        |
| `acp.additional-directories`                                    | yes                        |
| ACP auth/logout                                                 | no                         |
| Client filesystem methods                                       | no, advertised unsupported |
| Client terminal methods                                         | no, advertised unsupported |
| Image/audio/resource prompt blocks                              | no, text prompts only      |
| Deprecated ACP session modes                                    | no                         |
| HTTP/WebSocket ACP transports                                   | no, stdio only             |

### MCP Servers

MCP server configuration follows the shape used by `mcp.el`'s
`mcp-hub-servers`: each entry is a name and a plist with either
`:command` plus `:args`, or `:url`.

```elisp
(setq ellm-mcp-servers
      '(("filesystem" . (:command "npx"
                         :args ("-y" "@modelcontextprotocol/server-filesystem"
                                "/home/me/project")
                         :category "local"))
        ("docs" . (:url "https://example.com/mcp"
                   :headers (("X-API-Key" . "secret"))
                   :category "remote"))))
```

Enable all configured MCP servers:

```yaml
mcp: true
```

Enable named servers:

```yaml
mcp: [filesystem, docs]
```

Enable a category:

```yaml
mcp: ["@local"]
```

Define an inline server in a conversation:

```yaml
mcp:
  - name: filesystem
    command: npx
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/home/me/project"]
```

ACP agents always support stdio MCP servers.  URL-based MCP servers are
sent only when the agent advertises the matching ACP MCP transport
capability.

### ACP Workspace Roots

Set `cwd:` for the main project root.  Use `acp.additional-directories`
when an ACP agent supports extra workspace roots.

```yaml
cwd: /home/me/project
acp:
  additional-directories:
    - /home/me/shared-lib
    - /home/me/docs
```

## Rationale

**TLDR**: This is a plain-text-first approach to LLM interaction that extends Markdown with a simple turn delimiter syntax (`>-| user`, `>-| assistant`, `>>-| tool-call`, etc.) to create self-contained, homoiconic conversation files. Conversations are regular text files you can edit, fork, and navigate with existing tooling—no special management software needed. A YAML frontmatter holds per-buffer configuration to make files self-contained, and the format is fully customizable.

---


I like plain text. I don't like having separate definitions for serialized (like having a transcript of an LLM interaction) and *real* data. Just like Lisp being homoiconic, I want my LLM interactions to be homoiconic (yes, that's not what it exactly means but I hope you got where I'm heading to. I also want to sound cool.). Being able to edit conversations just like a regular old file opens the doors to different opportunities. First of all, your all *file editing and navigation* knowledge transfers here completely. You also get *forking conversations* feature for free, just copy the parts you want and continue your discussion in another buffer. This also relieves you from learning another management tool, you are just switching between buffers which you do all day. You also get this for free. Also, you are able to edit the conversations as you want, this gives you different powers like this[1:https://haskellforall.com/2026/01/prompting-101-show-dont-tell]. Using this approach, build conversations that you like, save them as a file and use them anytime you want, or just share them. I can go on much more but you got the point.

The natural extension to this mindset in Emacs world is Org. It has properties, you can attach data to headers. Runnable code blocks, or just any type of blocks. It's also extensible. As much as I wanted to use org-mode for interacting with LLMs-like for everything else I do--it's not feasible. First of all, you can't make LLMs output Org directly. You need to convert it to Org syntax on-the-fly. GPTel does this-along with a lot of other wonderful things, great package-but there is no real way to get it right, it almost always does something wrong. So, in a nutshell, conversion to Org is a frustrating practice that'll simply waste your time.

The second best thing is, staying in the plain-text world, is using Markdown. LLMs love it for some reason, not matter how abusive you are, they don't back off from outputting Markdown. But there are couple problems with using Markdown, or as people use it right now:

- No special syntax for conversation like interface. People utilize headers for prompts. But what if your prompt is quite long? How do I separate the LLM output from my prompt? LLMs also output Markdown and you can't reliable tell them "JUST USE SECOND LEVEL HEADERS AND NOTHING ELSE" or whatever you want to yell at those clankers. They are going to use the Markdown construct that you want to keep it to yourself, and output it.
- This is an Emacs specific thing but markdown-mode, at least in my experience, is slow. `markdown-ts-mode` is not very mature. Also again, there is no special Markdown syntax for conversational interface. You can select a good non-conflicting prefix for your conversations but none of the Markdown modes will play with it nicely when it comes to folding. The conversational turns should have their own *block*, the folding should work within that block without swallowing your special turn separator.

Because LLMs are outputting Markdown-and they do not use every Markdown construct from every different Markdown spec, they simply use a fairly simple subset of features-, I didn't want to have a format that is different from Markdown, hence this, I extended Markdown with the following:

```
>-| user
...
>-| assistant
...
```

We can call these a turn delimiter. Ending with `-|` because Markdown already uses `>` for denoting quotes and we need to differentiate and make it visually distinguishable. Also because quoting someone can introduce multiple `>`s stacking, that's why `>>` is not feasible. The choice of starting with `>` is deliberate because even without using a special mode for this type of file, you get a free syntax highlighting, other Markdown parsers will think this is a quote (and in a sense, it is). From one turn delimiter to another, all the Markdown features should work properly. For example, if you fold a header, it should fold at maximum to the next turn delimiter. Now that `>-|` lines belongs to our use, we can use it for the tool calls too. Adding more `>` would denote hierarchy, just like Markdown or Org headers, so you can have easily parsable hierarchies without keeping state:

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

The `>>-| assistant` line is the continuation of the assistant after the calls. Current implementation renders this line blank but it is required for being able to distinguish between different types of continuation lines, like tool calls and results.

With this, we have a really simple conversational interface on top of Markdown. The rest of the features, like sending text from other buffers, forking conversations, attaching context etc. are responsibilities of the user. You can simply transfer your file editing know-how that is already existing.

To make these files self-contained, I also put a YAML frontmatter. This can contain various configurations of ellm specificly for this buffer. It's also editable and after editing, the conversation will continue with these new configurations. For features that are not easily editable via YAML-like a long system prompt, you can still use the turn delimiters:

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
