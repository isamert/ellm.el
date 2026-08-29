# The project

This is an Emacs Lisp package that is a coding agent with a special conversation format based on Markdown.

ellm is a major mode. It extends Markdown with *turns* (as in *assistant turn* or *user turn*). A turn is like a Markdown header, but instead of starting with `#`, turns start with `>-|`. A second level turn is `>>-|`. By making *turns* a first-class citizen of the format, it becomes very intuitive to handle navigation, folding, narrowing, etc. Per session controls are handled with a YAML frontmatter.

# Architecture

- `ellm.el` owns conversation state, request lifecycle, permissions, persistence, hooks, and transcript rendering. ellm-mode itself is defined near the end of the file, also the interface for backends.
- `ellm-llm.el`, `ellm-acp.el`, and `ellm-kagi.el` only translate backend events and requests.
- `ellm-tools.el` defines and executes backend-neutral tools through the core permission layer. Not every backend uses them, some may have their own tooling like ACP.
- `ellm-acp-extensions.el` contains optional agent-specific ACP behavior.
- `ellm-codex.el` implements the Codex provider for `llm.el`.

Backends emit events; core decides how they affect the conversation.

# Coding style

- Be concise.
- Prefer easier to understand and especially easier to extend solutions as opposed to ad-hoc solutions.
- Use data-driven style whenever possible for better code flow.
- Use built-ins, existing solutions etc. without re-inventing them.
- Do not use internal functions of other libraries.
- Do not use advices unless it's absolutely necessary or unless it's the advertised way of doing it.
- Do not leave stale/unused functions/variables.
- Do not make code duplication, unless it's really justified.
- Use sections to group similar functions/variables together, like `;;;; Buffer state` etc.
- This project is still in development. Backward compatibility is not a goal; prefer clean, final designs over supporting legacy approaches.

# Testing

Use the Makefile for validation:

```sh
make compile  # Byte-compile without writing .elc files to the repository.
make test     # Run the full ERT suite.
make load     # Load ellm.el in a clean batch Emacs.
make check    # Run all of the above.
```

- If a dependency is missing, add its sibling source directory to `LISP_DIRS` in the Makefile.
- For focused checks, reuse `$(EMACS_BATCH)` from the Makefile with the required Emacs forms.
