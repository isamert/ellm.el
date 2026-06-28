# ellm

Minimal coding agent with special conversation format based on Markdown. Intuitive to read/navigate/edit.

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

For LLM API interactions, *ellm* uses *llm.el* and it comes with pre-defined tools for *agentic* work (I hate this word).
