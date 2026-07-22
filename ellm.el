;;; ellm.el --- Homoiconic agent  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (yaml "0.5.5") (s "1.13.1") (llm "0.31.1") (plz "0.9"))
;; Keywords: TODO

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; TODO: ...

;;;; Installation

;; TODO: ...

;;;; Usage

;; TODO: ...

;;;; Credits

;; This package would not have been possible without the following
;; packages: TODO

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'json)
(require 'outline)
(require 'xdg)
(require 'yaml)

;;;; Customization

(defgroup ellm nil
  "LLM interaction buffer."
  :group 'applications)

(defcustom ellm-provider nil
  "Default provider used by `ellm-send'.
A provider object supported by one of ellm's loaded backends.

Used as a fallback when the buffer's frontmatter does not specify a
`provider:' key (resolved through `ellm-provider-alist').  Can also be
set buffer-locally."
  :type '(restricted-sexp :match-alternatives (null recordp))
  :group 'ellm)

(defcustom ellm-provider-alist nil
  "Alist mapping symbolic provider names to provider objects.
The car is a symbol usable from frontmatter as `provider: NAME'.  The
cdr is either:

  - a provider object directly, or
  - a plist `(:provider PROV :models (\"m1\" \"m2\" …))' where the
    optional `:models' list constrains the candidates offered by
    frontmatter `model:' completion.

Used by `ellm--resolve-provider' to look up the provider named in the
buffer's frontmatter, and by `ellm--frontmatter-capf' for completion."
  :type '(alist :key-type symbol
                :value-type
                (choice (restricted-sexp :match-alternatives (recordp))
                        (plist :options ((:provider sexp)
                                          (:models (repeat string))))))
  :group 'ellm)

(defcustom ellm-subagents nil
  "Global defaults and profiles for subagent buffers.
This has the same shape as frontmatter `subagents:'.  A buffer-local
frontmatter `subagents:' map takes precedence when present.

The common shape is:

  ((default . \"cheap\")
   (profiles . ((cheap . ((model . \"small\")))
                (reviewer . ((model . \"large\")
                             (tools . (\"@files\" \"@buffers\")))))))

`default' may be a profile name or a map of settings.  Profile maps may
set any frontmatter key useful to a child buffer, most commonly `provider',
`model', `tools', `system', and `cwd'."
  :type 'sexp
  :group 'ellm)

(defcustom ellm-initial-buffer-name #'ellm-default-buffer-name
  "Initial buffer name for ellm buffers."
  :type '(choice string function)
  :group 'ellm)

(defcustom ellm-buffer-name-function #'ellm-default-buffer-name
  "Function used to name buffers from backend-provided session titles.
The function is called with the title in the target ellm buffer and should
return a buffer name, or nil to leave the name unchanged.  When this option is
nil, backend title updates do not rename buffers."
  :type '(choice (const :tag "Do not rename buffers automatically" nil)
                 function)
  :group 'ellm)

(defcustom ellm-current-project-function #'ellm-current-project-root
  "Function used to return the current project root.
The function is called without arguments with `default-directory' set to
the ellm buffer's base directory.  The default implementation finds the
closest parent containing a `.git' directory."
  :type 'function
  :group 'ellm)

(defcustom ellm-persistence-enabled nil
  "When non-nil, automatically persist ellm conversation buffers.
New main conversations receive a session directory and `main.ellm' file.
Subagents are stored below that directory in `subagents/'."
  :type 'boolean
  :group 'ellm)

(defcustom ellm-persistence-location 'global
  "Where automatically persisted ellm sessions are stored.
`global' uses `ellm-persistence-directory'.  `project' uses the directory
named by `ellm-persistence-project-directory' below the current project
root, falling back to `ellm-persistence-directory' outside a project.  A
function value is called without arguments in the ellm buffer and should
return a directory name; nil means not to persist that buffer."
  :type '(choice (const :tag "Global directory" global)
                 (const :tag "Current project" project)
                 (function :tag "Directory function"))
  :group 'ellm)

(defcustom ellm-persistence-directory (expand-file-name "~/ellm/")
  "Directory used for globally persisted ellm sessions."
  :type 'directory
  :group 'ellm)

(defcustom ellm-persistence-project-directory ".ellm"
  "Directory below a project root used for project-local sessions."
  :type 'string
  :group 'ellm)

(defcustom ellm-cache-directory
  (file-name-as-directory (expand-file-name "ellm" (xdg-cache-home)))
  "Directory for durable ellm state not owned by a persisted session.
Opaque reasoning state is stored here when conversation persistence is
disabled or the current buffer is ephemeral."
  :type 'directory
  :group 'ellm)

(defun ellm-current-project-root ()
  "Return the current project root, or nil outside a Git repository."
  (when-let* ((path (locate-dominating-file default-directory ".git")))
    (expand-file-name path)))

(defun ellm--provider-entry-provider (entry)
  "Return the provider object from an `ellm-provider-alist' ENTRY value.
ENTRY is either a provider object directly or a plist with a
`:provider' key."
  (if (and (listp entry) (plist-member entry :provider))
      (plist-get entry :provider)
    entry))

(defun ellm--provider-entry-models (entry)
  "Return the explicit `:models' list from ENTRY, or nil.
Returns nil for bare provider objects or plist entries without a
`:models' key."
  (and (listp entry)
       (plist-member entry :models)
       (plist-get entry :models)))

(cl-defstruct (ellm-tool (:constructor ellm-make-tool))
  "Backend-neutral tool definition used by ellm buffers."
  name description args function async category)

(defcustom ellm-tools-list nil
  "List of `ellm-tool' objects available to ellm buffers.

Tools are referenced from a buffer's YAML frontmatter `tools:' key
either by the tool's `name' slot, or by `@CATEGORY' to enable every
`ellm-tool' whose `category' slot equals CATEGORY.

Example:

  (setq ellm-tools-list
        (list
         (ellm-make-tool
          :name \"current_time\"
          :description \"Return the current local time.\"
          :args nil
          :function (lambda () (format-time-string \"%F %T\"))
          :category \"util\")
         (ellm-make-tool
          :name \"shell\"
          :description \"Run a shell command and return its stdout.\"
          :args (list (list :name \"command\" :type \\='string
                            :description \"The shell command to run.\"))
          :function (lambda (cmd) (shell-command-to-string cmd))
          :category \"shell\")))

A buffer can then enable a single tool with `tools: [current_time]' or
a whole category with `tools: [\"@shell\"]'."
  :type '(repeat (restricted-sexp :match-alternatives (ellm-tool-p)))
  :group 'ellm)

(defcustom ellm-tools-transform-tool-result-functions
  '(ellm-tools--coerce-tool-result-to-string
    ellm-tools--escape-tool-result-turn-delimiters)
  "Functions used to transform tool text before serializing it.
Each function is called with TOOL, ARGS, ERROR and RESULT, and must return
the next RESULT value.  Custom tools use this for returned results; ACP
and backend renderers also use it for tool params/results before writing
them into conversation buffers."
  :type 'hook
  :group 'ellm)

(defcustom ellm-tool-header-summary-width 80
  "Maximum width of tool call and result titles.
Single-line tool parameters are appended to tool titles before the complete
title is truncated to this width.  Multiline parameter values are kept in
their nested `tool-param' turns but omitted from the title."
  :type 'natnum
  :group 'ellm)

(defcustom ellm-mcp-servers nil
  "Alist of MCP server configurations available to ellm buffers.

The shape intentionally follows `mcp-hub-servers' from mcp.el: each
entry is (NAME . PLIST), where NAME is a string or symbol and PLIST may
contain `:command' plus `:args' for stdio servers, or `:url' for remote
servers.  `:env', `:headers', `:token', `:roots', and `:timeout' are kept
compatible with mcp.el where possible.  ellm also recognizes optional
`:category' for frontmatter category references.

Buffers select servers through top-level YAML frontmatter `mcp:'.  The
value may be:

  true             enable all configured MCP servers
  SERVER          enable a named server
  [SERVER, ...]   enable several named servers
  [\"@CAT\", ...]  enable servers with `:category' CAT
  [{name: ..., command: ...}, ...]
                   define inline server configurations"
  :type '(alist :key-type (choice string symbol)
                :value-type
                (plist :options ((:command string)
                                 (:args (repeat string))
                                 (:url string)
                                 (:type string)
                                 (:env sexp)
                                 (:headers sexp)
                                 (:token sexp)
                                 (:roots sexp)
                                 (:timeout integer)
                                 (:category string))))
  :group 'ellm)

(defconst ellm--heading-specs
  '((ellm-heading-1 1.3 outline-1)
    (ellm-heading-2 1.2 outline-2)
    (ellm-heading-3 1.1 outline-3)
    (ellm-heading-4 1 outline-4)
    (ellm-heading-5 1 outline-5)
    (ellm-heading-6 1 outline-6))
  "List of (FACE HEIGHT INHERIT) specs for heading faces.")

(defconst ellm--turn-heading-specs
  '((ellm-turn-heading-1 1.4)
    (ellm-turn-heading-2 0.95)
    (ellm-turn-heading-3 0.8))
  "List of (FACE HEIGHT) specs for turn heading faces.")

(defun ellm--apply-heading-rescale (val)
  "Apply heading rescale setting VAL to heading faces.
No-op for any face that hasn't been defined yet (so this is safe to
call from a defcustom :set before the faces' `defface' forms have run)."
  (pcase-dolist (`(,face ,height ,inherit) ellm--heading-specs)
    (when (facep face)
      (set-face-attribute face nil
                           :height (if val height 'unspecified)
                           :inherit inherit :weight 'bold)))
  (pcase-dolist (`(,face ,height) ellm--turn-heading-specs)
    (when (facep face)
      (set-face-attribute face nil
                          :height (if val height 'unspecified)))))

(defcustom ellm-heading-rescale t
  "When non-nil, Markdown and turn headings use sizes for each level.
Set to nil to make all headings the same size."
  :type 'boolean
  :group 'ellm-visuals
  :set (lambda (sym val)
         (set-default sym val)
         (ellm--apply-heading-rescale val)))

(defcustom ellm-pretty-separators t
  "If non-nil, hide raw turn delimiter lines behind decorative overlays."
  :type 'boolean
  :group 'ellm-visuals
  :set (lambda (sym val)
         (set-default sym val)
         (when (fboundp 'ellm--refresh-pretty-separators-all-buffers)
           (ellm--refresh-pretty-separators-all-buffers))))

(defcustom ellm-turn-rules t
  "If non-nil, draw horizontal rules above top-level turns.
When nil, ellm does not install ruler update hooks or perform ruler work
during fontification and buffer edits."
  :type 'boolean
  :group 'ellm-visuals
  :set (lambda (sym val)
         (set-default sym val)
         (when (fboundp 'ellm--refresh-turn-rules-all-buffers)
           (ellm--refresh-turn-rules-all-buffers))))

(defcustom ellm-reveal-separator-at-point t
  "If non-nil, temporarily show the raw delimiter line when point enters it."
  :type 'boolean
  :group 'ellm-visuals)

(defcustom ellm-fold-tool-calls t
  "If non-nil, insert `tool-call' turns folded (collapsed)."
  :type 'boolean
  :group 'ellm-visuals)

(defcustom ellm-fold-reasoning-blocks t
  "If non-nil, insert reasoning turns folded (collapsed)."
  :type 'boolean
  :group 'ellm-visuals)

(defcustom ellm-turn-header-1 ">-|"
  "Text for denoting turn headers."
  :type 'string
  :group 'ellm-visuals)

(defcustom ellm-turn-header-2 ">>-|"
  "Text for denoting child turn headers.
A turn whose delimiter line uses this header is a *continuation* of the
preceding top-level turn (e.g. tool calls/results following an assistant
turn, or an indented assistant turn that flows visually from the
preceding one)."
  :type 'string
  :group 'ellm-visuals)

(defcustom ellm-turn-header-3 ">>>-|"
  "Text for denoting grandchild turn headers.
Used for `tool-param' sub-turns nested under a `tool-call' continuation
turn.  A turn whose delimiter line uses this header is also treated as
a continuation for visual nesting (no horizontal rule above it)."
  :type 'string
  :group 'ellm-visuals)

;;;; Regexps & predicates

;;;;; Regexpes

(defconst ellm--turn-header-regexp
  (concat "\\(?:"
          ;; Order matters: longest first so the regex engine prefers
          ;; the most-specific header (`>>>-|') over its prefixes.
          (regexp-quote ellm-turn-header-3) "\\|"
          (regexp-quote ellm-turn-header-2) "\\|"
          (regexp-quote ellm-turn-header-1)
          "\\)")
  "Regexp matching any turn header token, without surrounding anchors.")

(defun ellm--turn-header-prefix-regexp (header)
  "Return regexp matching HEADER followed by its separator space."
  (concat (regexp-quote header) " "))

(defconst ellm--turn-delimiter-prefix-regexp
  (concat ellm--turn-header-regexp " ")
  "Regexp matching any turn header followed by its separator space.")

(defconst ellm-turn-regexp
  (concat "^\\("
          ellm--turn-header-regexp
          "\\) \\([a-zA-Z-]+\\)\\(?: | \\)?\\(.*\\)$")
  "Regexp matching turn delimiter lines.
Group 1: header (`ellm-turn-header-1', `ellm-turn-header-2', or
`ellm-turn-header-3'), Group 2: role, Group 3: rest of attributes.")

(defconst ellm-page-delimiter-regexp
  (concat "^"
          (ellm--turn-header-prefix-regexp ellm-turn-header-1))
  "Regexp matching top-level turn delimiter lines only.
These are exactly the lines that get a horizontal rule drawn above them
by `ellm--make-rule-overlay'.  Used as the buffer-local `page-delimiter'
so `forward-page' / `backward-page' stop at each rendered ruler.")

(defconst ellm-code-block-header-regexp
  "^[ \t]*```\\(?: ?\\([a-zA-Z-]+\\)\\)?[^`\n]*\n"
  "Regexp matching the opening line of a fenced code block.
Group 1: language when the info string starts with a supported language tag.")

(defconst ellm-code-block-end-regexp
  "^[ \t]*```\n"
  "Regexp matching the closing line of a fenced code block.")

(defconst ellm-code-block-fence-regexp
  "^[ \t]*```"
  "Regexp matching any fenced code block line (open or close).
Anchored at beginning of line; the line may have an info string after it
or be a bare ``` close fence.")

(defconst ellm-code-block-regexp
  (concat ellm-code-block-header-regexp
          "\\(\\(?:.*\n\\)*?\\)"
          (string-trim-left ellm-code-block-fence-regexp "\\^[ \t]*")
          "$")
  "Regexp matching fenced code blocks.
Group 1: language, Group 2: body.")

(defconst ellm-frontmatter-regexp
  "\\`---\n\\(\\(?:.*\n\\)*?\\)---$"
  "Regexp matching YAML frontmatter.")

(defconst ellm-heading-any-regexp "^\\(#+\\) "
  "Markdown heading regexp.")

(defconst ellm-heading-n-regexp "^\\(#\\{1,%d\\}\\) "
  "Markdown heading regexp.

Intended to be used like
  (format ellm-heading-n-regexp 3) ;; → Gives level 3 header regexp.

Group 1: the leading hash characters indicating the heading level.")

;;;;; Roles & role predicates

(defconst ellm--roles
  '((user        :face ellm-role-user      :glyph "❯ USER")
    (assistant   :face ellm-role-assistant :glyph "❮ ASSISTANT")
    (system      :face ellm-role-system    :glyph "❯ SYSTEM")
    (tool-call   :face ellm-role-tool      :glyph "❮❮ CALL"     :tool t :shade ellm-block     :markdown nil)
    (tool-result :face ellm-role-tool      :glyph "❯❯ RESULT"   :tool t :shade ellm-block     :markdown nil)
    (tool-param  :face ellm-role-tool      :glyph "  ↳ PARAM"   :tool t :shade ellm-block     :markdown nil)
    (reasoning   :face ellm-role-reasoning :glyph "❮❮ REASONING"        :shade ellm-reasoning :markdown nil))
  "Single source of truth for role metadata.
Each entry is `(ROLE-SYM . PLIST)' where PLIST may include:
  :face   FACE-SYMBOL  Face used for the role's keyword on the delimiter line.
  :glyph  STRING       Display string used in pretty turn separators.
  :tool   BOOL         Non-nil for `tool-call'/`tool-result'/`tool-param'
                       roles, whose bodies are shaded with `ellm-block'.
  :shade  FACE-SYMBOL  Face appended to the role's turn body (see
                       `ellm--fontify-shaded-turns').
  :markdown BOOL       Nil when the role's body is raw text rather than
                       Markdown prose.")

(defun ellm--role-prop (role prop)
  "Return PROP for ROLE (string or symbol) from `ellm--roles', or nil."
  (let* ((sym (if (stringp role) (intern-soft role) role))
         (entry (and sym (assq sym ellm--roles))))
    (and entry (plist-get (cdr entry) prop))))

(defun ellm--role-face (role)
  "Return face for ROLE string."
  (or (ellm--role-prop role :face) 'ellm-turn-delimiter))

(defun ellm--turn-heading-face (header)
  "Return heading-scale face for turn delimiter HEADER."
  (pcase (ellm--turn-header-depth header)
    (1 'ellm-turn-heading-1)
    (2 'ellm-turn-heading-2)
    (3 'ellm-turn-heading-3)))

(defun ellm--role-glyph (role)
  "Return the display glyph string for ROLE.
ROLE is the string captured from `ellm-turn-regexp'."
  (or (ellm--role-prop role :glyph) role))

(defun ellm--tool-role-p (role)
  "Return non-nil if ROLE is a tool role.
Tool roles are `tool-call', `tool-result', and `tool-param'."
  (and (ellm--role-prop role :tool) t))

(defun ellm--role-shade-face (role)
  "Return the face used to shade ROLE's turn body, or nil if none."
  (ellm--role-prop role :shade))

(defun ellm--role-markdown-p (role)
  "Return non-nil if ROLE's body should be treated as Markdown prose."
  (let* ((sym (if (stringp role) (intern-soft role) role))
         (entry (and sym (assq sym ellm--roles)))
         (plist (cdr-safe entry)))
    (if (plist-member plist :markdown)
        (plist-get plist :markdown)
      t)))

(defun ellm--continuation-header-p (header)
  "Return non-nil if HEADER (the captured group 1 of `ellm-turn-regexp')
denotes a continuation turn.

A turn is a continuation when its delimiter line begins with
`ellm-turn-header-2' (e.g. `>>-|') or `ellm-turn-header-3' (e.g.
`>>>-|').  Continuation turns are visually nested under their preceding
top-level turn: they get no horizontal rule above them and, for
`assistant', have their delimiter line collapsed to a blank row in
pretty mode."
  (or (equal header ellm-turn-header-2)
      (equal header ellm-turn-header-3)))

(defun ellm--turn-header-depth (header)
  "Return the nesting depth (1, 2, or 3) of HEADER, or nil."
  (cond
   ((equal header ellm-turn-header-1) 1)
   ((equal header ellm-turn-header-2) 2)
   ((equal header ellm-turn-header-3) 3)))

;;;; General utilities

(defun ellm--alist-set-nested (alist keys value)
  "Return ALIST with VALUE set at nested KEYS path, creating levels as needed.
KEYS may be a single key or a list of keys."
  (let ((keys (if (listp keys) keys (list keys))))
    (if (null (cdr keys))
        (setf (alist-get (car keys) alist) value)
      (setf (alist-get (car keys) alist)
            (ellm--alist-set-nested (alist-get (car keys) alist)
                                    (cdr keys) value))))
  alist)

(defun ellm--alist-get-nested (alist keys)
  "Return nested value from ALIST at KEYS.
KEYS may be a single key or a list of keys.  String and symbol keys are
treated interchangeably to match YAML parser output and caller input."
  (let ((keys (if (listp keys) keys (list keys)))
        (value alist))
    (while (and keys (listp value))
      (let* ((key (car keys))
             (sym (if (stringp key) (intern key) key))
             (str (if (symbolp key) (symbol-name key) key)))
        (setq value (or (alist-get sym value)
                        (and str (alist-get str value nil nil #'equal)))
              keys (cdr keys))))
    (and (null keys) value)))

(defun ellm--alist-get-nested-cell (alist keys)
  "Return cons cell for nested KEYS in ALIST, or nil when absent.
KEYS may be a single key or a list of keys.  Unlike
`ellm--alist-get-nested', this distinguishes an absent key from a present
key whose value is nil."
  (let ((keys (if (listp keys) keys (list keys)))
        (value alist)
        cell)
    (while (and keys (listp value))
      (let* ((key (car keys))
             (sym (if (stringp key) (intern key) key))
             (str (if (symbolp key) (symbol-name key) key)))
        (setq cell (or (assq sym value)
                       (and str (assoc str value)))
              value (cdr cell)
              keys (cdr keys))))
    (and (null keys) cell)))

(defmacro ellm--preserve-user-position (&rest body)
  "Run BODY while preserving or following user point/window positions.
This is intended for asynchronous backend insertions into the current
buffer.  A point at the buffer end, or immediately before its final
newline, follows output to the new end.  Other positions and their window
starts are restored after the edit.  Each visible window follows
independently.  BODY runs with `inhibit-read-only' so backend insertions
can update request-locked buffers."
  (declare (indent 0) (debug t))
  `(let* ((ellm--preserve-buffer (current-buffer))
          (ellm--preserve-end (point-max))
          (ellm--preserve-follow-p
           (lambda (position)
             (or (= position ellm--preserve-end)
                 (and (> ellm--preserve-end (point-min))
                      (= position (1- ellm--preserve-end))
                      (eq (char-before ellm--preserve-end) ?\n)))))
          (ellm--preserve-point (copy-marker (point) nil))
          (ellm--preserve-point-follows
           (funcall ellm--preserve-follow-p (point)))
          (ellm--preserve-window-states
           (mapcar (lambda (window)
                     (let ((window-point (window-point window)))
                       (list window
                             (copy-marker window-point nil)
                             (copy-marker (window-start window) nil)
                             (window-hscroll window)
                             (funcall ellm--preserve-follow-p window-point))))
                    (get-buffer-window-list (current-buffer) nil t))))
     (unwind-protect
         (let ((inhibit-read-only t))
           (save-current-buffer
             (save-excursion
               ,@body)))
       (unwind-protect
            (when (buffer-live-p ellm--preserve-buffer)
              (with-current-buffer ellm--preserve-buffer
                (let ((new-end (point-max)))
                  (if ellm--preserve-point-follows
                      (goto-char new-end)
                    (when-let* ((pos (marker-position ellm--preserve-point)))
                      (goto-char pos)))
                  (dolist (state ellm--preserve-window-states)
                    (let ((window (nth 0 state))
                          (point-marker (nth 1 state))
                          (start-marker (nth 2 state))
                          (hscroll (nth 3 state))
                          (follows (nth 4 state)))
                      (when (and (window-live-p window)
                                 (eq (window-buffer window)
                                     ellm--preserve-buffer))
                        (if follows
                            (progn
                              (set-window-point window new-end)
                              (unless (pos-visible-in-window-p new-end window)
                                (save-excursion
                                  (goto-char new-end)
                                  (vertical-motion
                                   (- 1 (max 1 (window-body-height window)))
                                   window)
                                  (set-window-start window (point) t))))
                          (when-let* ((start (marker-position start-marker)))
                            (set-window-start window start t))
                          (when-let* ((point (marker-position point-marker)))
                            (set-window-point window point)))
                        (set-window-hscroll window hscroll)))))))
         (set-marker ellm--preserve-point nil)
         (dolist (state ellm--preserve-window-states)
           (set-marker (nth 1 state) nil)
           (set-marker (nth 2 state) nil))))))

;;;; Faces
;;;;; Utilities

(defun ellm--alt-bg ()
  "Return a slightly off-default background color string, or `unspecified'.
Returns `unspecified' (the symbol, suitable as a face attribute value)
when there is no usable default background color (e.g. running in batch
mode or on a TTY before a theme is loaded).  This keeps face definitions
and `set-face-attribute' calls safe in non-graphical contexts."
  (let ((bg (face-background 'default nil 'default)))
    (if (or (not (stringp bg))
            (member bg '("unspecified-bg" "unspecified-fg")))
        'unspecified
      (let* ((adjust (if (eq (frame-parameter nil 'background-mode) 'dark)
                         #'color-lighten-name
                       #'color-darken-name))
             (adjusted (funcall adjust bg 10)))
        (color-desaturate-name adjusted 70)))))

;;;;; Faces

(defface ellm-turn-delimiter
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for turn delimiter lines."
  :group 'ellm)

(defface ellm-turn-heading-1
  '((t :height unspecified))
  "Face controlling height for top-level turn headers."
  :group 'ellm)

(defface ellm-turn-heading-2
  '((t :height unspecified))
  "Face controlling height for continuation turn headers."
  :group 'ellm)

(defface ellm-turn-heading-3
  '((t :height unspecified))
  "Face controlling height for nested turn headers."
  :group 'ellm)

(defface ellm-role-user
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for user role."
  :group 'ellm)

(defface ellm-role-assistant
  '((t :inherit font-lock-type-face :weight bold))
  "Face for assistant role."
  :group 'ellm)

(defface ellm-role-reasoning
  '((t :inherit font-lock-regexp-face :weight bold :height 0.85))
  "Face for assistant role."
  :group 'ellm)

(defface ellm-role-system
  '((t :inherit font-lock-warning-face :weight bold))
  "Face for system role."
  :group 'ellm)

(defface ellm-role-tool
  '((t :inherit font-lock-constant-face :weight bold :height 0.85))
  "Face for tool-call and tool-result roles."
  :group 'ellm)

(defface ellm-turn-rule
  '((t :inherit shadow :strike-through t))
  "Face for the horizontal rule line between turns."
  :group 'ellm)

(defface ellm-frontmatter
  `((t :inherit shadow :background ,(ellm--alt-bg) :extend t))
  "Face for YAML frontmatter `---' delimiter lines."
  :group 'ellm)

(defface ellm-code-block-delimiter
  `((t :inherit shadow :background ,(ellm--alt-bg) :extend t))
  "Face for ``` lines."
  :group 'ellm)

(defface ellm-bold
  '((t :weight bold))
  "Face for **bold** text."
  :group 'ellm)

(defface ellm-italic
  '((t :slant italic))
  "Face for *italic* text."
  :group 'ellm)

(defface ellm-inline-code
  `((t :inherit fixed-pitch :background ,(ellm--alt-bg)))
  "Face for `inline code`."
  :group 'ellm)

(defface ellm-heading-1
  '((t :weight bold :inherit outline-1))
  "Face for markdown heading level 1."
  :group 'ellm)

(defface ellm-heading-2
  '((t :weight bold :inherit outline-2))
  "Face for markdown heading level 2."
  :group 'ellm)

(defface ellm-heading-3
  '((t :weight bold :inherit outline-3))
  "Face for markdown heading level 3."
  :group 'ellm)

(defface ellm-heading-4
  '((t :weight bold :inherit outline-4))
  "Face for markdown heading level 4."
  :group 'ellm)

(defface ellm-heading-5
  '((t :weight bold :inherit outline-5))
  "Face for markdown heading level 5."
  :group 'ellm)

(defface ellm-heading-6
  '((t :weight bold :inherit outline-6))
  "Face for markdown heading level 6."
  :group 'ellm)

(defface ellm-blockquote
  '((t :inherit font-lock-doc-face :slant italic))
  "Face for > blockquotes."
  :group 'ellm)

(defface ellm-list-marker
  '((t :inherit font-lock-builtin-face))
  "Face for list markers (-, *, numbered)."
  :group 'ellm)

(defface ellm-block `((t :inherit fixed-pitch
                         :background ,(ellm--alt-bg)
                         :extend t))
  "Face used for text inside various blocks."
  :group 'ellm)

(defface ellm-reasoning
  '((t :inherit (shadow ellm-block) :slant italic))
  "Face used for text inside reasoning turn bodies."
  :group 'ellm)

;;;;; Keep faces in sync with theme

(defun ellm--update-faces (&rest _)
  "Update face colors that requires recalculation after theme change.
Used in {load,enable,disable}-theme hooks."
  ;; FIXME: If changed by user, don't change?
  (let* ((alt-bg (ellm--alt-bg)))
    (set-face-attribute 'ellm-block nil :background alt-bg)
    (set-face-attribute 'ellm-inline-code nil :background alt-bg)
    (set-face-attribute 'ellm-frontmatter nil :background alt-bg)
    (set-face-attribute 'ellm-code-block-delimiter nil :background alt-bg)))

(dolist (hook '(load-theme enable-theme disable-theme))
  (advice-add hook :after #'ellm--update-faces))

;;;; Code block highlighting

(defvar ellm--fence-positions)
(defvar ellm--fence-positions-vector)
(defvar ellm--turn-body-cache-vector)

(defvar ellm--lang-mode-cache (make-hash-table :test 'equal)
  "Cache mapping language name to major mode symbol.")

(defvar ellm--special-lang-name-alist
  '(("elisp" . emacs-lisp-mode))
  "Language names requiring special mode inference.
Entries here override the default language mode inference logic.")

(defun ellm--lang-mode (lang)
  "Return major mode symbol for LANG, or nil."
  (when (and lang (not (string-empty-p lang)))
    (or (gethash lang ellm--lang-mode-cache)
        (when-let* ((mode (alist-get lang ellm--special-lang-name-alist nil nil #'equal)))
          (puthash lang mode ellm--lang-mode-cache)
          mode)
        (let ((mode (seq-find #'fboundp (list (intern-soft (concat lang "-ts-mode"))
                                              (intern-soft (concat lang "-mode"))))))
          (when mode
            (puthash lang mode ellm--lang-mode-cache)
            mode)))))

(defun ellm--code-block-mode (lang header)
  "Return the major mode inferred from LANG or fenced block HEADER.
HEADER may contain a file name prefixed by a START:END line range."
  (or (ellm--lang-mode lang)
      (let* ((info (string-trim
                    (string-remove-prefix "```" (string-trim-left header))))
             (file (replace-regexp-in-string
                    "\\`[0-9]+:[0-9]+:" "" info))
             (entry (assoc-default file auto-mode-alist #'string-match))
             (mode (if (consp entry) (car entry) entry)))
        (and (symbolp mode) (fboundp mode) mode))))

(defun ellm--fontify-region-as (mode body-beg body-end)
  "Fontify region BODY-BEG..BODY-END as if it were in MODE.

The region is copied into a hidden per-mode scratch buffer, fontified
there with `font-lock-ensure', and the resulting `face' runs are merged
back onto the original text with `add-face-text-property' (which is
list- and plist-face aware, so anonymous faces produced by e.g.
tree-sitter modes are carried over intact).

Collected ranges are stored as offsets relative to the scratch buffer's
`point-min' so they translate cleanly to BODY-BEG, regardless of
narrowing in either buffer."
  (let* ((text (buffer-substring-no-properties body-beg body-end))
         (inhibit-message t)
         (buf (get-buffer-create
               (format " *ellm-fontification:%s*" mode)))
         (ranges
          (with-current-buffer buf
            (unless (eq major-mode mode)
              (delay-mode-hooks (funcall mode)))
            (let ((inhibit-modification-hooks t))
              (erase-buffer)
              (insert text))
            (font-lock-ensure)
            (let ((base (point-min))
                  (max (point-max))
                  (pos (point-min))
                  result)
              (while (< pos max)
                (let ((next (next-single-property-change pos 'face nil max))
                      (face-val (get-text-property pos 'face)))
                  (when face-val
                    (push (list (- pos base) (- next base) face-val) result))
                  (setq pos next)))
              result))))
    (pcase-dolist (`(,beg ,end ,face) ranges)
      (add-face-text-property (+ body-beg beg) (+ body-beg end) face t))))

(defun ellm--fontify-code-blocks (beg end &optional _loudly)
  "Apply language font-lock to fenced code blocks between BEG and END.
Also fontifies YAML frontmatter if present and overlaps the region."
  (save-excursion
    ;; Frontmatter is always anchored at `point-min'. Re-fontify it whenever
    ;; the region being fontified overlaps it, not only at initial load.
    (goto-char (point-min))
    ;; TODO: Maybe cache the boundaries of the frontmatter so that it
    ;; can be used here AND while sending requests (it should be
    ;; parsed every time)
    (when (looking-at ellm-frontmatter-regexp)
      (let* ((fm-beg (match-beginning 0))
             (fm-end (match-end 0))
             (body-beg (match-beginning 1))
             (body-end (match-end 1))
             (mode (ellm--lang-mode "yaml"))
             (open-end (save-excursion
                         (goto-char fm-beg)
                         (min (1+ (line-end-position)) (point-max))))
             (close-beg (save-excursion (goto-char fm-end)
                                        (line-beginning-position)))
             (close-end (min (1+ fm-end) (point-max))))
        (when (and (< beg fm-end) (> end fm-beg))
          (when mode
            (ellm--fontify-region-as mode body-beg body-end))
          (font-lock-append-text-property body-beg body-end 'face 'ellm-block)
          ;; `---' delimiter lines: apply the frontmatter face on top,
          ;; including the trailing newline so `:extend' fills the line.
          (put-text-property fm-beg open-end 'face 'ellm-frontmatter)
          (put-text-property close-beg close-end 'face 'ellm-frontmatter))))
    ;; Pair recognized fences within each turn.  An unmatched opening fence
    ;; ends implicitly at the next turn delimiter, so code never leaks into
    ;; the following turn.
    (let* ((vec ellm--fence-positions-vector)
           (count (length vec))
           (beg-container (ellm--code-container-bounds-at beg))
           (index (ellm--fence-index-before beg)))
      ;; `ellm--code-block-scan-bounds' normally moves BEG to the opening
      ;; fence.  Retain support for direct callers that pass a position in
      ;; the block body by stepping back to that opening here as well.
      (when (and beg-container
                 (cl-oddp (- index
                             (ellm--fence-index-before
                              (car beg-container)))))
        (cl-decf index))
      (while (and (< index count) (< (aref vec index) end))
        (let* ((open (aref vec index))
               (container (ellm--code-container-bounds-at open))
               (container-end (and container (cdr container)))
               (close (and container-end
                            (< (1+ index) count)
                            (< (aref vec (1+ index)) container-end)
                            (aref vec (1+ index))))
               (body-end (or close container-end))
               (block-end (if close
                              (save-excursion
                                (goto-char close)
                                (forward-line 1)
                                (point))
                            container-end)))
          (when (and body-end block-end
                     (< open end) (> block-end beg))
            (goto-char open)
            (when (looking-at ellm-code-block-header-regexp)
              (let* ((lang (match-string 1))
                     (header (match-string-no-properties 0))
                     (body-beg (match-end 0))
                     (mode (ellm--code-block-mode lang header)))
                (when mode
                  (ellm--fontify-region-as mode body-beg body-end))
                (font-lock-append-text-property
                 body-beg body-end 'face 'ellm-block))))
          (cl-incf index (if close 2 1)))))))

(defun ellm--fontify-shaded-turns (beg end)
  "Shade turn bodies between BEG and END per each role's `:shade' face.
The body of each turn whose role has a `:shade' face in `ellm--roles'
\(e.g. tool and reasoning roles) gets that face appended.  A body is the
region from the character after the delimiter line through the character
before the next turn delimiter line, or `point-max'.  The delimiter
lines themselves are not shaded.

Search begins from the turn delimiter strictly preceding BEG so that
bodies that start before the fontified region are still shaded within
it."
  (save-excursion
    (let ((search-beg (or (save-excursion
                            (goto-char beg)
                            (when (re-search-backward ellm-turn-regexp nil t)
                              (line-beginning-position)))
                          (point-min))))
      (goto-char search-beg)
      (while (and (re-search-forward ellm-turn-regexp nil t)
                  (< (match-beginning 0) end))
        (let* ((role (match-string-no-properties 2))
               (shade (ellm--role-shade-face role))
               (body-beg (min (1+ (line-end-position)) (point-max)))
               (body-end (or (save-excursion
                               (when (re-search-forward ellm-turn-regexp end t)
                                 (line-beginning-position)))
                             end)))
          (when (and shade
                     (< body-beg body-end)
                     ;; Only act when this body overlaps the fontified region.
                     (< beg body-end) (> end body-beg))
            (let ((shade-beg (max body-beg beg))
                  (shade-end (min body-end end)))
              (font-lock-append-text-property
               shade-beg shade-end 'face shade))))))))

;;;; Tools

(defun ellm-tools--transform-tool-result (tool args error? raw)
  "Return RAW after running tool result transformer functions.
TOOL is a tool identifier, ARGS are the tool arguments when known, and
ERROR is non-nil when RAW represents an error result."
  (let ((result raw))
    (dolist (fn ellm-tools-transform-tool-result-functions)
      (setq result (funcall fn tool args error? result)))
    result))

(defun ellm-tools--coerce-tool-result-to-string (_tool _args _error? raw)
  "Return RAW as a string suitable for serialized tool text."
  (cond
   ((null raw) "")
   ((stringp raw) raw)
   (t (format "%s" raw))))

(defun ellm-tools--escaped-tool-body-prefix-regexp ()
  "Return regexp matching reversible tool-body escape sequences."
  (concat "^\\\\\\(\\\\\\|"
          ellm--turn-delimiter-prefix-regexp
          "\\)"))

(defun ellm--escape-turn-delimiters (text)
  "Reversibly escape turn delimiters and backslashes at line starts in TEXT."
  (replace-regexp-in-string
   (concat "^\\(?:\\\\\\|"
           ellm--turn-delimiter-prefix-regexp
           "\\)")
   (lambda (match) (concat "\\" match))
   text nil t))

(defun ellm--escape-turn-delimiters-for-insertion (text at-bol)
  "Escape TEXT for insertion, treating its start as a line start when AT-BOL."
  (if at-bol
      (ellm--escape-turn-delimiters text)
    (substring (ellm--escape-turn-delimiters (concat "x" text)) 1)))

(defun ellm--escape-turn-delimiters-in-region (beg end)
  "Escape unprotected turn delimiter lines between BEG and END.
This catches delimiters assembled across streaming chunk boundaries."
  (save-excursion
    (goto-char beg)
    (forward-line 0)
    (while (re-search-forward
            (concat "^" ellm--turn-delimiter-prefix-regexp) end t)
      (goto-char (match-beginning 0))
      (insert "\\")
      (forward-char 1))))

(defun ellm--unescape-turn-delimiters (text)
  "Decode reversible line-prefix escaping in TEXT."
  (replace-regexp-in-string
   (ellm-tools--escaped-tool-body-prefix-regexp)
   (lambda (match) (substring match 1))
   text nil t))

(defun ellm-tools--escape-tool-result-turn-delimiters (_tool _args _error? raw)
  "Prevent RAW tool text from being parsed as ellm turn delimiters.
Tool params and results are serialized directly into conversation buffers,
so a raw line beginning with `>-|', `>>-|', or `>>>-|' would become
structural on the next parse.  Prefix such lines with a backslash.  Lines
already beginning with a backslash are also escaped so the transform is
reversible via `ellm-tools--unescape-tool-body'."
  (ellm--escape-turn-delimiters raw))

(defun ellm-tools--unescape-tool-body (body)
  "Decode reversible tool-body escaping in BODY.
Only encoded prefixes produced by
`ellm-tools--escape-tool-result-turn-delimiters' are decoded."
  (ellm--unescape-turn-delimiters body))

;;;; Fontification

;;;;; Font-lock keywords

(defun ellm--make-markdown-matcher (regexp)
  "Return a font-lock matcher for Markdown REGEXP.
Matches inside fenced code blocks and Markdown-disabled turn bodies are
ignored.  When a match lands inside a Markdown-disabled turn body, point
jumps to that body's end so large tool outputs are skipped in one step."
  (lambda (limit)
    (let (found)
      (while (and (not found)
                  (re-search-forward regexp limit t))
        (let* ((mb (match-beginning 0))
               (md (match-data))
               (idx (ellm--turn-body-cache-index-at mb))
               (vec ellm--turn-body-cache-vector)
               (entry (and idx (aref vec idx)))
               (body-p (and entry (>= mb (aref entry 1))))
               (container-beg
                (cond
                 (body-p (aref entry 1))
                 ((or (= (length vec) 0)
                      (< mb (aref (aref vec 0) 0)))
                  (point-min))))
               (body-end
                (and body-p
                     (if (< (1+ idx) (length vec))
                         (aref (aref vec (1+ idx)) 0)
                       (point-max)))))
          (cond
           ((and body-p (aref entry 3))
            (goto-char (min limit (max (point) body-end))))
           ((ellm--in-code-block-p mb container-beg)
            nil)
           (t
            (set-match-data md)
            (setq found t)))))
      found)))

(defun ellm--make-code-fence-matcher (regexp)
  "Return a font-lock matcher for code-fence REGEXP.
Matches in Markdown-disabled turn bodies are ignored."
  (lambda (limit)
    (let (found)
      (while (and (not found)
                  (re-search-forward regexp limit t))
        (let ((md (match-data)))
          (if-let* ((bounds
                     (ellm--markdown-disabled-bounds-at (match-beginning 0))))
              (goto-char (min limit (max (point) (cdr bounds))))
            (set-match-data md)
            (setq found t))))
      found)))

(defconst ellm-font-lock-keywords
  `(;; Turn delimiters
    (,ellm-turn-regexp
     (0 (list 'ellm-turn-delimiter
              (ellm--turn-heading-face (match-string 1)))
        t)
     (2 (ellm--role-face (match-string 2)) t))
    ;; Frontmatter delimiter lines (`---' open and close) and YAML body
    ;; are handled by `ellm--fontify-code-blocks'.
    ;; Code block delimiters
    (,(ellm--make-code-fence-matcher ellm-code-block-header-regexp)
     (0 'ellm-code-block-delimiter t))
    (,(ellm--make-code-fence-matcher ellm-code-block-end-regexp)
     (0 'ellm-code-block-delimiter t))
    ;; Bold **text**
    (,(ellm--make-markdown-matcher "\\*\\*\\([^*]+\\)\\*\\*") (0 'ellm-bold t))
    ;; Italic *text* (not bold)
    (,(ellm--make-markdown-matcher "\\(?:^\\|[^*]\\)\\(\\*\\([^*]+\\)\\*\\)[^*]") (1 'ellm-italic t))
    ;; Inline code `text`
    (,(ellm--make-markdown-matcher "`\\([^`\n]+\\)`") (0 'ellm-inline-code t))
    ;; Headings
    (,(ellm--make-markdown-matcher "^# .*$") (0 'ellm-heading-1 t))
    (,(ellm--make-markdown-matcher "^## .*$") (0 'ellm-heading-2 t))
    (,(ellm--make-markdown-matcher "^### .*$") (0 'ellm-heading-3 t))
    (,(ellm--make-markdown-matcher "^#### .*$") (0 'ellm-heading-4 t))
    (,(ellm--make-markdown-matcher "^##### .*$") (0 'ellm-heading-5 t))
    (,(ellm--make-markdown-matcher "^###### .*$") (0 'ellm-heading-6 t))
    ;; Blockquotes
    (,(ellm--make-markdown-matcher "^> .*$") (0 'ellm-blockquote t))
    ;; List markers
    (,(ellm--make-markdown-matcher "^\\s-*\\([-*]\\|[0-9]+\\.\\) ") (1 'ellm-list-marker t)))
  "Font-lock keywords for `ellm-mode'.")

;;;;; Fence position cache

;; To keep code-block highlighting correct without re-fontifying the
;; entire buffer on every change, we maintain a buffer-local sorted
;; vector of positions where each recognized ``` fence line begins.
;; Fences in Markdown-disabled turns are not recognized.  The cache lets us:
;;   - decide cheaply whether a change actually touched a fence;
;;   - extend font-lock's region to the surrounding fence pair when it
;;     did, so flipped block-membership is reflected immediately on the
;;     lines below the change.

(defvar-local ellm--fence-positions nil
  "Sorted list of recognized ``` fence line positions.
Fences in Markdown-disabled turn bodies are excluded.  Positions are line
beginnings, sorted in ascending order.
Maintained by `ellm--update-fences-after-change'.  A nil value means the
cache is uninitialized; call `ellm--rebuild-fence-cache' to populate it.")

(defvar-local ellm--fence-positions-vector []
  "Vector copy of `ellm--fence-positions' for binary-search lookups.")

(defvar-local ellm--fence-cache-valid nil
  "Non-nil when `ellm--fence-positions' is up to date with the buffer.")

(defun ellm--rebuild-fence-cache ()
  "Rebuild `ellm--fence-positions' from buffer contents."
  (ellm--ensure-turn-body-cache)
  (save-excursion
    (save-match-data
      (goto-char (point-min))
      (let* ((turns ellm--turn-body-cache-vector)
             (turn-count (length turns))
             (turn-index -1)
             positions)
        (while (re-search-forward ellm-code-block-fence-regexp nil t)
          (let ((pos (match-beginning 0)))
            (while (and (< (1+ turn-index) turn-count)
                        (<= (aref (aref turns (1+ turn-index)) 0) pos))
              (cl-incf turn-index))
            (let ((entry (and (>= turn-index 0)
                              (aref turns turn-index))))
              (unless (and entry
                           (>= pos (aref entry 1))
                           (aref entry 3))
                (push (line-beginning-position) positions))))
          (forward-line 1))
        (setq ellm--fence-positions (nreverse positions)
              ellm--fence-cache-valid t)
        (ellm--sync-fence-vector)))))

(defvar-local ellm--fence-parity-flipped nil
  "Set non-nil by `ellm--update-fences-after-change' when the most
recent change altered fence count by an odd number.  Read (and cleared)
by `ellm--extend-after-change-region' to decide whether to extend
fontification all the way to `point-max'.")

(defvar-local ellm--fence-structure-changed nil
  "Non-nil when a turn edit changed which fences are recognized.
Consumed by `ellm--extend-after-change-region', which refontifies the buffer
so stale code faces and fence parity cannot survive the structural edit.")

(defvar-local ellm--pending-fold-turn nil
  "Pending foldable turn waiting for a stable following boundary.
The value is a list (MARKER ROLE LEVEL), where MARKER points at the
turn delimiter line, ROLE is the turn role string, and LEVEL is its
outline level.")

(defun ellm--sync-fence-vector ()
  "Synchronize `ellm--fence-positions-vector' from the fence list."
  (setq ellm--fence-positions-vector (vconcat ellm--fence-positions)))

(defun ellm--update-fences-after-change (beg end old-len)
  "Incrementally update `ellm--fence-positions' for a buffer change.
BEG..END is the new region; OLD-LEN is the length of the replaced text.
Strategy:
  1. Drop cached fence positions on the line(s) the change touched
     (their existence/positions may have shifted within those lines).
  2. Shift cached fence positions strictly past the change by
     (- (- END BEG) OLD-LEN).
  3. Re-scan the affected line range in the new buffer state and merge
     any newly visible fence lines back into the cache.

Sets `ellm--fence-parity-flipped' to non-nil when the net change in
fence count is odd, so code-block membership after the change may need
to be refontified."
  (when ellm--fence-cache-valid
    (save-excursion
      (save-match-data
        (let* ((delta (- (- end beg) old-len))
               (old-end (+ beg old-len))
               (old-line-beg (save-excursion (goto-char beg)
                                             (line-beginning-position)))
               (dropped 0)
               (kept nil))
          (dolist (p ellm--fence-positions)
            (cond
             ((< p old-line-beg)
              (push p kept))
             ((<= p old-end)
              (cl-incf dropped))
             (t
              (push (+ p delta) kept))))
          (setq ellm--fence-positions (nreverse kept))
          (let* ((scan-beg old-line-beg)
                 (scan-end (save-excursion
                             (goto-char (max end beg))
                             (line-end-position)))
                 (added 0)
                 (new-fences nil))
            (goto-char scan-beg)
            (while (re-search-forward ellm-code-block-fence-regexp
                                      (1+ scan-end) t)
              (unless (ellm--markdown-disabled-at-p (match-beginning 0))
                (push (line-beginning-position) new-fences)
                (cl-incf added))
              (forward-line 1))
            (when new-fences
              (setq ellm--fence-positions
                    (sort (nconc (nreverse new-fences) ellm--fence-positions)
                          #'<)))
            (ellm--sync-fence-vector)
            (setq ellm--fence-parity-flipped
                  (cl-oddp (+ dropped added)))))))))

(defun ellm--refresh-fences-in-region (beg end)
  "Rescan recognized fences in BEG..END and return non-nil if they changed."
  (let ((old ellm--fence-positions)
        refreshed)
    (save-excursion
      (save-match-data
        (goto-char beg)
        (while (re-search-forward ellm-code-block-fence-regexp end t)
          (unless (ellm--markdown-disabled-at-p (match-beginning 0))
            (push (line-beginning-position) refreshed))
          (forward-line 1))))
    (setq refreshed (nreverse refreshed))
    (let* ((vec ellm--fence-positions-vector)
           (start (ellm--fence-index-before beg))
           (stop (ellm--fence-index-before end))
           (same (= (length refreshed) (- stop start)))
           (index start))
      (when same
        (dolist (pos refreshed)
          (unless (= pos (aref vec index))
            (setq same nil))
          (cl-incf index)))
      (if same
          nil
        (let (before after)
          (dolist (pos old)
            (cond
             ((< pos beg) (push pos before))
             ((>= pos end) (push pos after))))
          (setq ellm--fence-positions
                (nconc (nreverse before)
                       refreshed
                       (nreverse after)))
          (ellm--sync-fence-vector)
          t)))))

(defun ellm--fence-index-before (pos)
  "Return the number of recognized fence positions strictly before POS."
  (let ((vec ellm--fence-positions-vector)
        (lo 0)
        (hi (length ellm--fence-positions-vector)))
    (while (< lo hi)
      (let ((mid (/ (+ lo hi) 2)))
        (if (< (aref vec mid) pos)
            (setq lo (1+ mid))
          (setq hi mid))))
    lo))

(defun ellm--fence-before (pos)
  "Return the largest fence position <= POS, or nil."
  (let* ((vec ellm--fence-positions-vector)
         (count (length vec))
         (index (ellm--fence-index-before pos)))
    (cond
     ((and (< index count) (= (aref vec index) pos))
      (aref vec index))
     ((> index 0)
      (aref vec (1- index))))))

(defun ellm--in-code-block-p (&optional pos container-beg)
  "Return non-nil if POS (or point) is inside a turn-local code block.
When CONTAINER-BEG is non-nil, reuse it instead of looking up the turn body."
  (let* ((target (or pos (point)))
         (container-beg
          (or container-beg
              (car-safe (ellm--code-container-bounds-at target)))))
    (and container-beg
         (cl-oddp (- (ellm--fence-index-before target)
                     (ellm--fence-index-before container-beg))))))

;;;;; Turn body cache

(defvar-local ellm--turn-body-cache nil
  "Sorted list of cached turn body entries.
Each entry is a vector [DELIMITER-BEG BODY-BEG ROLE MARKDOWN-DISABLED].")

(defvar-local ellm--turn-body-cache-vector []
  "Vector copy of `ellm--turn-body-cache' for binary-search lookups.")

(defvar-local ellm--turn-body-cache-valid nil
  "Non-nil when `ellm--turn-body-cache' is up to date with the buffer.")

(defvar-local ellm--turn-body-cache-force-rebuild nil
  "Non-nil when the next change update must rebuild the turn body cache.")

(defun ellm--sync-turn-body-cache-vector ()
  "Synchronize `ellm--turn-body-cache-vector' from the cache list."
  (setq ellm--turn-body-cache-vector (vconcat ellm--turn-body-cache)))

(defun ellm--turn-body-cache-entry (delimiter-beg body-beg role)
  "Return a turn body cache entry for ROLE at DELIMITER-BEG/BODY-BEG."
  (vector delimiter-beg body-beg role (not (ellm--role-markdown-p role))))

(defun ellm--rebuild-turn-body-cache ()
  "Rebuild `ellm--turn-body-cache' from buffer contents."
  (save-excursion
    (save-match-data
      (goto-char (point-min))
      (let (entries)
        (while (re-search-forward ellm-turn-regexp nil t)
          (push (ellm--turn-body-cache-entry
                 (line-beginning-position)
                 (min (1+ (line-end-position)) (point-max))
                 (match-string-no-properties 2))
                entries)
          (forward-line 1))
        (setq ellm--turn-body-cache (nreverse entries)
              ellm--turn-body-cache-valid t
              ellm--turn-body-cache-force-rebuild nil)
        (ellm--sync-turn-body-cache-vector)))))

(defun ellm--ensure-turn-body-cache ()
  "Ensure the turn body cache is initialized and current."
  (unless ellm--turn-body-cache-valid
    (ellm--rebuild-turn-body-cache)))

(defun ellm--turn-delimiter-in-region-p (beg end)
  "Return non-nil if any line touched by BEG..END is a turn delimiter."
  (save-excursion
    (save-match-data
      (let ((scan-beg (save-excursion
                        (goto-char beg)
                        (line-beginning-position)))
            (scan-end (save-excursion
                        (goto-char end)
                        (min (1+ (line-end-position)) (point-max)))))
        (goto-char scan-beg)
        (re-search-forward ellm-turn-regexp scan-end t)))))

(defun ellm--shift-turn-body-cache-after-change (beg end old-len)
  "Shift cached turn body positions after a non-structural change.
BEG, END, and OLD-LEN are the values passed to `after-change-functions'."
  (let* ((delta (- (- end beg) old-len))
         (old-end (+ beg old-len))
         (insertion-p (zerop old-len)))
    (unless (zerop delta)
      (let* ((vec ellm--turn-body-cache-vector)
             (count (length vec))
             (lo 0)
             (hi count))
        ;; Find the first delimiter at or after OLD-END.  The preceding entry
        ;; may still have a BODY-BEG after the edit, so inspect it too.
        (while (< lo hi)
          (let ((mid (/ (+ lo hi) 2)))
            (if (< (aref (aref vec mid) 0) old-end)
                (setq lo (1+ mid))
              (setq hi mid))))
        (let ((index (max 0 (1- lo))))
          (while (< index count)
            (let* ((entry (aref vec index))
                   (delimiter-beg (aref entry 0))
                   (body-beg (aref entry 1)))
              (when (>= delimiter-beg old-end)
                (aset entry 0 (+ delimiter-beg delta)))
              ;; Text inserted exactly at BODY-BEG belongs to that body, so
              ;; keep the boundary before the newly inserted text.
              (when (if insertion-p
                        (> body-beg old-end)
                      (>= body-beg old-end))
                (aset entry 1 (+ body-beg delta))))
            (cl-incf index)))))))

(defun ellm--update-turn-body-cache-after-change (beg end old-len)
  "Update turn body cache after a buffer change.
Rebuild only when the changed old/new lines contain turn delimiters;
otherwise shift cached positions past the edit."
  (when ellm--turn-body-cache-valid
    (if (or ellm--turn-body-cache-force-rebuild
            (ellm--turn-delimiter-in-region-p beg end))
        (ellm--rebuild-turn-body-cache)
      (ellm--shift-turn-body-cache-after-change beg end old-len)))
  (setq ellm--turn-body-cache-force-rebuild nil))

(defun ellm--turn-body-cache-index-at (pos)
  "Return index of the turn cache entry containing POS structurally."
  (ellm--ensure-turn-body-cache)
  (let ((vec ellm--turn-body-cache-vector)
        (lo 0)
        (hi (length ellm--turn-body-cache-vector)))
    (while (< lo hi)
      (let ((mid (/ (+ lo hi) 2)))
        (if (<= (aref (aref vec mid) 0) pos)
            (setq lo (1+ mid))
          (setq hi mid))))
    (let ((idx (1- lo)))
      (and (>= idx 0) idx))))

(defun ellm--turn-body-bounds-at (&optional pos)
  "Return turn body bounds containing POS, or nil on a delimiter line."
  (let* ((target (or pos (point)))
         (idx (ellm--turn-body-cache-index-at target))
         (vec ellm--turn-body-cache-vector)
         (entry (and idx (aref vec idx))))
    (when (and entry (>= target (aref entry 1)))
      (cons (aref entry 1)
            (if (< (1+ idx) (length vec))
                (aref (aref vec (1+ idx)) 0)
              (point-max))))))

(defun ellm--code-container-bounds-at (&optional pos)
  "Return the turn-local region in which a fence at POS may be paired.
Turn delimiter lines are outside all such regions.  Text before the first
turn delimiter is treated as one region."
  (let* ((target (or pos (point)))
         (body (ellm--turn-body-bounds-at target))
         (vec ellm--turn-body-cache-vector))
    (or body
        (when (or (= (length vec) 0)
                  (< target (aref (aref vec 0) 0)))
          (cons (point-min)
                (if (> (length vec) 0)
                    (aref (aref vec 0) 0)
                  (point-max)))))))

(defun ellm--markdown-disabled-bounds-at (&optional pos)
  "Return raw turn body bounds containing POS, or nil.
The returned cons is (BODY-BEG . BODY-END).  Delimiter lines are never
considered part of the body, so turn delimiters remain structural even
for Markdown-disabled roles."
  (let* ((target (or pos (point)))
         (idx (ellm--turn-body-cache-index-at target))
         (vec ellm--turn-body-cache-vector)
         (entry (and idx (aref vec idx))))
    (when (and entry
               (aref entry 3)
               (>= target (aref entry 1)))
      (cons (aref entry 1)
            (if (< (1+ idx) (length vec))
                (aref (aref vec (1+ idx)) 0)
              (point-max))))))

(defun ellm--markdown-disabled-at-p (&optional pos)
  "Return non-nil if POS is in a turn body that disables Markdown prose."
  (and (ellm--markdown-disabled-bounds-at pos) t))

(defun ellm--markdown-excluded-at-p (&optional pos)
  "Return non-nil if Markdown prose syntax should be ignored at POS."
  (let ((target (or pos (point))))
    (or (ellm--in-code-block-p target)
        (ellm--markdown-disabled-at-p target))))

;;;;; Core

(defun ellm--extend-after-change-region (beg end _old-len)
  "Extend the font-lock refontification region for a buffer change.
Called as `font-lock-extend-after-change-region-function'.  Returns nil
\(no extension) in the common case where the change didn't affect a ```
fence; otherwise a (BEG . END) cons.

Extension policy:
  - Cache up to date: assumed; `ellm--update-fences-after-change' has
    already run from `after-change-functions' before us.
  - If a turn delimiter edit changed which fences are recognized,
    refontify the whole buffer.
  - If the change kept the total fence count's parity (added/removed an
    even number of fences), only the local block surrounding the change
    can have flipped: extend to the previous fence (or `point-min') and
    past the next fence (or `point-max').
  - If parity flipped (odd number of fences added/removed), conservatively
    extend END to `point-max'; turn-local pairing still prevents code syntax
    from crossing a turn delimiter."
  (if ellm--fence-structure-changed
      (progn
        (setq ellm--fence-structure-changed nil
              ellm--fence-parity-flipped nil)
        (unless (and (= beg (point-min)) (= end (point-max)))
          (cons (point-min) (point-max))))
    (let* ((line-beg (save-excursion (goto-char beg) (line-beginning-position)))
           (line-end (save-excursion (goto-char end) (line-end-position)))
           (vec ellm--fence-positions-vector)
           (line-index (ellm--fence-index-before line-beg))
           ;; Touched a fence line iff:
           ;; - some cached fence is currently on the affected line range
           ;;   (i.e. either survived as-is or was just inserted), or
           ;; - the parity flag is set (we removed one without adding one).
           (touched-fence
            (or ellm--fence-parity-flipped
                (and (< line-index (length vec))
                     (<= (aref vec line-index) line-end)))))
      (when touched-fence
        (let* ((parity-flipped ellm--fence-parity-flipped)
               (prev (ellm--fence-before (1- line-beg)))
               (next-index (ellm--fence-index-before (1+ line-end)))
               (next (and (not parity-flipped)
                          (< next-index (length vec))
                          (aref vec next-index)))
               (next-end (and next
                              (save-excursion
                                (goto-char next)
                                (forward-line 1)
                                (point))))
               (new-beg (or prev (point-min)))
               (new-end (cond
                         (parity-flipped (point-max))
                         (next-end next-end)
                         (t (point-max)))))
          ;; Clear the parity flag now that we've consumed it.
          (setq ellm--fence-parity-flipped nil)
          (when (or (< new-beg beg) (> new-end end))
            (cons (min new-beg beg) (max new-end end))))))))

(defvar-local ellm--pending-delimiter-deletion nil
  "Bounds of a pending deletion that intersects a turn delimiter line.
Set by `ellm--before-change-function' to a cons (DEL-BEG . DEL-END)
when the to-be-deleted region contains at least one turn delimiter
line.  Consumed and cleared by `ellm--after-change-function', which
uses it to clean up rule overlays that collapsed onto a single point
when the surrounding text was deleted.")

(defun ellm--before-change-function (beg end)
  "Record pending deletions that will affect a turn delimiter line.
BEG and END bound the to-be-changed region.  Insertions (BEG == END)
can't collapse any overlays, so they're ignored."
  (when (ellm--turn-delimiter-in-region-p beg end)
    (setq ellm--turn-body-cache-force-rebuild t))
  (when (and ellm-turn-rules
             (not ellm--pending-delimiter-deletion)
             (/= beg end))
    (when (ellm--turn-delimiter-in-region-p beg end)
      (setq ellm--pending-delimiter-deletion (cons beg end)))))

(defun ellm--refresh-rules-around (pos &optional window)
  "Rebuild rule overlays in the local neighborhood of POS.
The neighborhood spans from the previous turn delimiter line (or
`point-min') to the next one (or `point-max'), so any merging or
splitting of turns caused by an edit at POS is reflected.

Optional WINDOW determines the rule width."
  (when ellm-turn-rules
    (let ((rb (save-excursion
                (goto-char pos)
                (forward-line 0)
                (if (re-search-backward ellm-turn-regexp nil t)
                    (line-beginning-position)
                  (point-min))))
          (re (save-excursion
                (goto-char pos)
                (forward-line 1)
                (if (re-search-forward ellm-turn-regexp nil t)
                    (line-end-position)
                  (point-max)))))
      (ellm--put-turn-rules rb re window))))

(defun ellm--turn-neighborhood-bounds (beg end)
  "Return bounds of turn bodies adjacent to the change at BEG..END."
  (save-match-data
    (cons (save-excursion
            (goto-char beg)
            (forward-line 0)
            (if (re-search-backward ellm-turn-regexp nil t)
                (line-beginning-position)
              (point-min)))
          (save-excursion
            (goto-char end)
            (if (re-search-forward ellm-turn-regexp nil t)
                (line-beginning-position)
              (point-max))))))

(defun ellm--after-change-function (beg end old-len)
  "Update fence cache and rule overlays after a buffer change.
BEG END OLD-LEN are passed by `after-change'."
  (let ((turn-structure-changed
         (or ellm--turn-body-cache-force-rebuild
             (ellm--turn-delimiter-in-region-p beg end))))
    ;; Fence recognition depends on the current turn role, so update turn
    ;; boundaries before scanning changed lines for fences.
    (ellm--update-turn-body-cache-after-change beg end old-len)
    (ellm--update-fences-after-change beg end old-len)
    (when (and turn-structure-changed ellm--fence-cache-valid)
      ;; A delimiter edit can change fence recognition in its adjacent turn
      ;; bodies even when the fence lines themselves were untouched.  Rescan
      ;; only those bodies rather than rebuilding the whole-buffer cache.
      (pcase-let ((`(,scan-beg . ,scan-end)
                   (ellm--turn-neighborhood-bounds beg end)))
        (unless (and (not (ellm--refresh-fences-in-region scan-beg scan-end))
                      (not (ellm--in-code-block-p beg))
                      (not (ellm--in-code-block-p
                            (max (point-min) (1- beg)))))
          (setq ellm--fence-structure-changed t)))))
  ;; If the deletion intersected a delimiter line, every rule overlay
  ;; that lived inside the deleted range has now collapsed to the
  ;; single post-change point.  Sweep just that point for orphans and
  ;; refresh the local neighborhood.  Insertions, and deletions that
  ;; don't touch a delimiter line, are handled by the normal font-lock
  ;; pass via `ellm--fontify-region'.
  (when ellm--pending-delimiter-deletion
    (setq ellm--pending-delimiter-deletion nil)
    (when ellm-turn-rules
      ;; All collapsed rule overlays sit at BEG (== END after deletion).
      ;; `remove-overlays' on a zero-length range still catches overlays
      ;; touching that point.
      (remove-overlays beg (min (1+ end) (point-max)) 'ellm-rule t)
      (ellm--refresh-rules-around beg))))

(defun ellm--code-block-scan-bounds (beg end)
  "Return a (SCAN-BEG . SCAN-END) cons covering whole code blocks for BEG..END.
To avoid that ambiguity we snap the scan range to real block
boundaries using the parity-aware fence cache (`ellm--fence-positions'):
a position is inside a block iff an odd number of fence lines precede it
in the same turn body.
Falls back to a conservative whole-line range when the cache is not
available."
  (if (and ellm--fence-cache-valid ellm--fence-positions)
      (let* ((scan-beg
              ;; If BEG is inside a block, back up to its opening fence;
              ;; otherwise leave BEG untouched.
              (if (ellm--in-code-block-p beg)
                  (or (ellm--fence-before beg) beg)
                beg))
             (scan-end
              ;; If END is inside a block, advance past its closing
              ;; fence or turn boundary so the whole block is scanned.
              (if (ellm--in-code-block-p end)
                  (let* ((container (ellm--code-container-bounds-at end))
                         (container-end (cdr container))
                         (vec ellm--fence-positions-vector)
                         (index (ellm--fence-index-before (1+ end)))
                         (closer (and (< index (length vec))
                                      (< (aref vec index) container-end)
                                      (aref vec index))))
                    (if closer
                        (save-excursion
                          (goto-char closer)
                          (forward-line 1)
                          (point))
                      container-end))
                end)))
        (cons scan-beg scan-end))
    ;; Cache unavailable: fall back to whole-line bounds (no fence
    ;; pairing across the region, but at least no mispairing either).
    (cons (save-excursion (goto-char beg) (line-beginning-position))
          (save-excursion (goto-char end) (min (1+ (line-end-position))
                                               (point-max))))))

(defun ellm--fontify-region (beg end &optional loudly)
  "Fontify region between BEG and END, passing LOUDLY to font-lock.
Run default font-lock, then apply code block highlighting.

`font-lock-default-fontify-region' may widen the region to \"safe\"
boundaries (whole lines via `font-lock-extend-region-wholelines',
multiline ranges via `font-lock-extend-region-multiline', etc.) and
calls `font-lock-unfontify-region' over that *extended* range, clearing
the `face' property there.  It reports the range it actually touched as
the `(jit-lock-bounds BEG . END)' value.  We must re-apply our own
shading/code-block faces over that *same* extended range, otherwise the
slivers outside the original BEG..END (typically the start of the first
line and the tail of the last line) get unfontified but never
re-shaded, leaving unshaded gaps at line beginnings/ends."
  (pcase-let ((`(jit-lock-bounds ,beg . ,end)
               (font-lock-default-fontify-region beg end loudly)))
    (pcase-let ((`(,scan-beg . ,scan-end) (ellm--code-block-scan-bounds beg end)))
      (ellm--fontify-code-blocks scan-beg scan-end))
    (ellm--fontify-shaded-turns beg end)
    (when ellm-turn-rules
      (ellm--put-turn-rules beg end))
    (ellm--put-pretty-separators beg end)
    `(jit-lock-bounds ,beg . ,end)))

;;;; Overlays
;;;;;; Turn rules (---)

(defun ellm--rule-window (&optional buffer)
  "Return the window whose width should size rules for BUFFER.
BUFFER defaults to the current buffer.  Prefer a window currently
displaying BUFFER (preferring the selected window if it shows BUFFER)
over the selected window, since the selected window may be on an
unrelated buffer."
  (let ((buf (or buffer (current-buffer))))
    (or (and (eq (window-buffer) buf) (selected-window))
        (get-buffer-window buf t)
        (selected-window))))

(defun ellm--rule-string (&optional window)
  "Return a full-width horizontal rule string sized for WINDOW.
WINDOW defaults to a window displaying the current buffer."
  (let ((w (or window (ellm--rule-window))))
    (propertize (make-string (window-width w) ?─) 'face 'ellm-turn-rule)))

(defun ellm--make-rule-overlay (bol win)
  "Create a rule overlay at BOL sized for WIN.

The rule is drawn by covering the real newline character that ends the
preceding line (the char in [BOL-1, BOL)) with a `display' property that
re-emits that newline, the rule, and a closing newline.  This keeps both
BOL-1 (end of the previous line) and BOL (start of the delimiter line)
as real, point-accessible buffer positions with the rule rendered as its
own screen line between them.

This matters for point motion and scrolling: a `before-string' /
`after-string' that contains a newline on a zero-length overlay creates
a phantom screen line with no corresponding buffer position.  Line-based
vertical motion and scrolling (e.g. `scroll-up') cannot place point
inside that display string and gets stuck at it, so scrolling appears to
stop at each rule.  Covering an existing newline instead avoids
introducing a phantom line."
  (if (> bol (point-min))
      (let ((ov (make-overlay (1- bol) bol)))
        (overlay-put ov 'ellm-rule t)
        ;; Cover the preceding newline and re-emit it after the rule, so
        ;; the rule occupies its own screen line without adding a phantom
        ;; (position-less) newline.
        (overlay-put ov 'display (concat "\n" (ellm--rule-string win) "\n"))
        ov)
    ;; No preceding newline to anchor to (rule would be at BOB); fall
    ;; back to the zero-length overlay form.
    (let ((ov (make-overlay bol bol)))
      (overlay-put ov 'ellm-rule t)
      (overlay-put ov 'before-string
                   (concat (ellm--rule-string win) "\n"))
      ov)))

(defun ellm--put-turn-rules (beg end &optional window)
  "Place rule overlays on turn delimiter lines between BEG and END.
Continuation delimiter lines (those using `ellm-turn-header-2', e.g.
`tool-call', `tool-result', or an indented `assistant') do not get a
rule above them, so they appear visually nested under their parent
top-level turn.

This is the local refresh path used by `ellm--fontify-region' and
`ellm--refresh-rules-around'.  It only touches overlays in [BEG, END]
and assumes no orphaned rule overlays exist in that range from outside
it.  The buffer-wide refresh, used on window resize, is
`ellm--rebuild-turn-rules'.

Optional WINDOW determines the rule width; defaults to a window
displaying the current buffer."
  (when ellm-turn-rules
    (remove-overlays beg end 'ellm-rule t)
    (let ((win (or window (ellm--rule-window))))
      (save-excursion
        (goto-char beg)
        (while (re-search-forward ellm-turn-regexp end t)
          (let ((bol (line-beginning-position))
                (header (match-string-no-properties 1)))
            (unless (or (= bol (point-min))
                        (ellm--continuation-header-p header))
              (ellm--make-rule-overlay bol win))))))))

(defun ellm--rebuild-turn-rules (&optional window)
  "Rebuild all rule overlays in the current buffer from scratch.
Used on window resize, where every rule needs its width refreshed.
Cost is O(buffer overlays + buffer size); rule overlays are sparse
(one per top-level turn).

Optional WINDOW determines the rule width; defaults to a window
displaying the current buffer."
  (when ellm-turn-rules
    (remove-overlays (point-min) (point-max) 'ellm-rule t)
    (let ((win (or window (ellm--rule-window))))
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward ellm-turn-regexp nil t)
          (let ((bol (line-beginning-position))
                (header (match-string-no-properties 1)))
            (unless (or (= bol (point-min))
                        (ellm--continuation-header-p header))
              (ellm--make-rule-overlay bol win))))))))

(defun ellm--update-rules (&optional frame-or-window)
  "Refresh all turn rule widths in ellm buffers visible on FRAME-OR-WINDOW.
Each buffer's rules are sized for the window currently displaying it,
not for the selected window (which may be on an unrelated buffer)."
  (when ellm-turn-rules
    (let ((frame (cond
                  ((framep frame-or-window) frame-or-window)
                  ((windowp frame-or-window) (window-frame frame-or-window))
                  (t (selected-frame)))))
      (dolist (win (window-list frame 'no-minibuf))
        (with-current-buffer (window-buffer win)
          (when (and ellm-turn-rules (derived-mode-p 'ellm-mode))
            (ellm--rebuild-turn-rules win)))))))

(defvar-local ellm--was-narrowed-p nil
  "Non-nil if this buffer was narrowed after the previous command.")

(defun ellm--refresh-rules-after-widen ()
  "Rebuild turn rule overlays after an interactive narrowing exit.
Narrowed fontification can legitimately remove rule overlays whose anchor
falls outside the accessible part of the buffer.  When the buffer is widened
again, rebuild from the full buffer so those rulers come back even if no
subsequent edit happens near them."
  (when ellm-turn-rules
    (let ((narrowed (buffer-narrowed-p)))
      (when (and ellm--was-narrowed-p (not narrowed))
        (ellm--rebuild-turn-rules))
      (setq ellm--was-narrowed-p narrowed))))

(defun ellm--configure-turn-rules (&optional defer-rebuild)
  "Enable or disable ruler maintenance in the current ellm buffer.
When DEFER-REBUILD is non-nil, fontification will create the initial rules."
  (if ellm-turn-rules
      (progn
        (add-hook 'window-size-change-functions #'ellm--update-rules nil t)
        (add-hook 'post-command-hook #'ellm--refresh-rules-after-widen nil t)
        (setq ellm--was-narrowed-p (buffer-narrowed-p))
        (unless defer-rebuild
          (ellm--rebuild-turn-rules)))
    (remove-hook 'window-size-change-functions #'ellm--update-rules t)
    (remove-hook 'post-command-hook #'ellm--refresh-rules-after-widen t)
    (setq ellm--pending-delimiter-deletion nil)
    (save-restriction
      (widen)
      (remove-overlays (point-min) (point-max) 'ellm-rule t))))

(defun ellm--refresh-turn-rules-all-buffers ()
  "Apply `ellm-turn-rules' to all existing ellm buffers."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'ellm-mode)
        (ellm--configure-turn-rules)))))

;;;;;; Pretty separators

(defvar-local ellm--revealed-separator-overlay nil
  "Currently revealed pretty-separator overlay, if any.")

(defun ellm--blank-separator-p (role continuation)
  "Return non-nil if the pretty separator for ROLE/CONTINUATION should be blank.
A continuation `assistant' line collapses to a blank row so it flows
visually from the preceding turn.  All other roles display their glyph."
  (and continuation (equal role "assistant")))

(defun ellm--turn-pipe-title (tail)
  "Return the pipe-delimited title from raw turn delimiter TAIL."
  (when (string-prefix-p " | " tail)
    (let* ((value (substring tail 3))
           (attrs-beg (string-match " :[[:alnum:]-]+ [^[:space:]]+" value))
           (title (string-trim-right
                   (if attrs-beg (substring value 0 attrs-beg) value))))
      (unless (string-empty-p title)
        title))))

(defun ellm--apply-pretty-separator (ov role continuation &optional title)
  "Configure overlay OV as a pretty separator for ROLE.
CONTINUATION is non-nil when the delimiter line uses
`ellm-turn-header-2' (i.e. the turn is a continuation of the preceding
top-level turn).  TITLE is the optional pipe-delimited turn title.

For continuation `assistant' lines, the overlay blanks the line text by
displaying the empty string, but leaves the trailing newline intact so
the delimiter line still occupies one (blank) row.  The user can move
point onto that row to trigger `ellm-reveal-separator-at-point' and edit
it.  For other roles, the overlay covers just the line text and displays
the role's glyph followed by TITLE when present."
  (let ((line-beg (save-excursion
                    (goto-char (overlay-start ov))
                    (line-beginning-position)))
        (line-end (save-excursion
                    (goto-char (overlay-start ov))
                    (line-end-position))))
    (overlay-put ov 'ellm-pretty-separator t)
    (overlay-put ov 'ellm-pretty-separator-role role)
    (overlay-put ov 'ellm-pretty-separator-continuation continuation)
    (overlay-put ov 'evaporate t)
    (move-overlay ov line-beg line-end)
    (if (ellm--blank-separator-p role continuation)
        (overlay-put ov 'display "")
      (let* ((glyph (ellm--role-glyph role))
             (face (ellm--role-face role))
             (label (if title (concat glyph " | " title) glyph)))
        (overlay-put ov 'display (propertize label 'face face))))))

(defun ellm--put-pretty-separators (beg end)
  "Place pretty separator overlays on turn delimiter lines between BEG and END.
When `ellm-pretty-separators' is nil, only removes existing overlays.

The currently revealed delimiter line (if any) is left untouched so that
the user can edit it without the glyph reappearing on every keystroke."
  (let* ((revealed ellm--revealed-separator-overlay)
         (revealed-beg (and revealed (overlay-buffer revealed)
                            (overlay-start revealed)))
         (revealed-end (and revealed (overlay-buffer revealed)
                            (overlay-end revealed))))
    (dolist (ov (overlays-in beg end))
      (when (and (overlay-get ov 'ellm-pretty-separator)
                 (not (eq ov revealed)))
        (delete-overlay ov)))
    (when ellm-pretty-separators
      (save-excursion
        (goto-char beg)
        (while (re-search-forward ellm-turn-regexp end t)
          (let* ((line-beg (line-beginning-position))
                 (line-end (line-end-position)))
            ;; Skip the currently revealed line so editing it isn't
            ;; clobbered by font-lock re-runs.  Also skip folded lines:
            ;; outline already hides their real delimiter text, so adding
            ;; display overlays there makes hidden child turns visible again.
            (unless (or (invisible-p line-beg)
                        (and revealed-beg revealed-end
                             (<= revealed-beg line-beg)
                             (<= line-beg revealed-end)))
               (let* ((header (match-string-no-properties 1))
                      (role (match-string-no-properties 2))
                      (title (ellm--turn-pipe-title
                              (buffer-substring-no-properties
                               (match-end 2) (match-end 0))))
                      (continuation (ellm--continuation-header-p header))
                      (ov (make-overlay line-beg line-end nil t nil)))
                 (ellm--apply-pretty-separator
                  ov role continuation title)))))))))

(defun ellm--reveal-separator-at-point ()
  "Temporarily reveal the raw turn delimiter line under point."
  (when (and ellm-pretty-separators ellm-reveal-separator-at-point)
    (let ((ov-here (cl-find-if
                    (lambda (ov) (overlay-get ov 'ellm-pretty-separator))
                    (overlays-at (line-beginning-position)))))
      (unless (eq ov-here ellm--revealed-separator-overlay)
        ;; Restore glyph on the previously revealed overlay.
        (when (and ellm--revealed-separator-overlay
                   (overlay-buffer ellm--revealed-separator-overlay))
          (let ((ov ellm--revealed-separator-overlay))
            (save-excursion
              (goto-char (overlay-start ov))
              (beginning-of-line)
              (if (looking-at ellm-turn-regexp)
                  (ellm--apply-pretty-separator
                   ov
                   (match-string-no-properties 2)
                   (ellm--continuation-header-p
                    (match-string-no-properties 1))
                   (ellm--turn-pipe-title
                    (buffer-substring-no-properties
                     (match-end 2) (match-end 0))))
                ;; Line no longer matches a turn delimiter; drop overlay.
                (delete-overlay ov)))))
        (setq ellm--revealed-separator-overlay nil)
        (when ov-here
          ;; Shrink the overlay to just the line text and clear the
          ;; display so the raw text becomes visible and editable.
          (let ((line-beg (save-excursion
                            (goto-char (overlay-start ov-here))
                            (line-beginning-position)))
                (line-end (save-excursion
                            (goto-char (overlay-start ov-here))
                            (line-end-position))))
            (move-overlay ov-here line-beg line-end))
          (overlay-put ov-here 'display nil)
          ;; Don't let edits collapse the overlay to zero length.
          (overlay-put ov-here 'evaporate nil)
          (setq ellm--revealed-separator-overlay ov-here))))))

(defun ellm--refresh-pretty-separators-all-buffers (&rest _)
  "Refresh pretty-separator overlays in all `ellm-mode' buffers."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'ellm-mode)
        (ellm--put-pretty-separators (point-min) (point-max))))))

;;;; Buffer parsing

(cl-defstruct (ellm-turn (:constructor ellm-turn-create))
  "A single turn in the conversation.
ROLE is the role string (e.g. \"user\", \"assistant\", \"tool-call\").
CONTINUATION is non-nil when the turn's delimiter line uses
`ellm-turn-header-2' or `ellm-turn-header-3' (i.e. the turn is a child
of the preceding top-level turn).
DEPTH is the nesting depth of the delimiter (1, 2, or 3)."
  role attrs content beg end continuation depth)

(defun ellm--parse-turn-attrs (rest)
  "Parse REST of turn delimiter into an alist.
Recognises org-block-style attribute syntax: a sequence of `:KEY VALUE'
pairs interleaved with bare positional arguments.  Bare tokens are
collected under the key `\"arg\"' (one entry each, in order).  Keys are
stored without their leading colon, e.g. `:id call_1' becomes
`(\"id\" . \"call_1\")'."
  (let (result
        (parts (split-string (string-trim rest))))
    (while parts
      (let ((part (pop parts)))
        (if (and (> (length part) 1) (eq (aref part 0) ?:))
            ;; Keyword: consume the next token as its value (or nil if
            ;; the keyword is dangling at end of line).
            (push (cons (substring part 1) (or (pop parts) "")) result)
          (push (cons "arg" part) result))))
    (nreverse result)))

(defun ellm--parse-turns ()
  "Parse all turns in buffer, return list of `ellm-turn'."
  (save-excursion
    (goto-char (point-min))
    (let (turns current-role current-attrs current-beg current-cont current-depth)
      (while (re-search-forward ellm-turn-regexp nil t)
        (let ((header (match-string-no-properties 1))
              (role (match-string-no-properties 2))
              (rest (match-string-no-properties 3))
              (line-end (line-end-position)))
          ;; Close previous turn
          (when current-role
            (push (ellm-turn-create
                   :role current-role
                   :attrs current-attrs
                   :beg current-beg
                   :end (match-beginning 0)
                   :continuation current-cont
                   :depth current-depth
                   :content (string-trim
                             (buffer-substring-no-properties
                              current-beg (match-beginning 0))))
                  turns))
          (setq current-role role
                current-attrs (ellm--parse-turn-attrs rest)
                current-beg (1+ line-end)
                current-cont (ellm--continuation-header-p header)
                current-depth (ellm--turn-header-depth header))))
      ;; Close final turn
      (when current-role
        (push (ellm-turn-create
               :role current-role
               :attrs current-attrs
               :beg current-beg
               :end (point-max)
               :continuation current-cont
               :depth current-depth
               :content (string-trim
                         (buffer-substring-no-properties
                          current-beg (point-max))))
              turns))
      (nreverse turns))))

(defun ellm--turn-delimiter-beg (turn)
  "Return the beginning of TURN's delimiter line."
  (save-excursion
    (goto-char (ellm-turn-beg turn))
    (forward-line -1)
    (line-beginning-position)))

;;;;; Frontmatter

(defvar-local ellm--frontmatter-cache-valid nil
  "Non-nil when `ellm--frontmatter-cache-*' reflects the last parsed body.")

(defvar-local ellm--frontmatter-cache-body nil
  "YAML frontmatter body string used for the cached parse result.")

(defvar-local ellm--frontmatter-cache-value nil
  "Cached parsed YAML frontmatter value.")

(defvar-local ellm--frontmatter-cache-error nil
  "Cached parse error for `ellm--frontmatter-cache-body', or nil.")

(defvar-local ellm--base-default-directory nil
  "Buffer default directory before applying frontmatter `cwd:'.")

(defun ellm-default-buffer-name (&optional title)
  "Return the default buffer name for backend-provided session TITLE."
  (let* ((default-directory
           (or ellm--base-default-directory default-directory))
         (root (funcall ellm-current-project-function))
         (project-name
          (and root
               (file-name-nondirectory
                (directory-file-name (expand-file-name root))))))
    (if (or (not (stringp title)) (string-empty-p title))
        (if project-name
            (format "*ellm: %s*" project-name)
          (format "*ellm*"))
      (if (and project-name (not (string-empty-p project-name)))
          (format "*ellm (%s): %s*" project-name title)
        (format "*ellm: %s*" title)))))

(defun ellm-update-session-title (title &optional buffer)
  "Update BUFFER's name from backend-provided session TITLE.
BUFFER defaults to the current buffer.  Do nothing when
TITLE is missing, or `ellm-buffer-name-function' is nil or returns nil."
  (let ((buffer (or buffer (current-buffer))))
    (when (and (stringp title) (not (string-empty-p title))
               ellm-buffer-name-function (buffer-live-p buffer))
      (with-current-buffer buffer
        (when-let* ((name (funcall ellm-buffer-name-function title)))
          (rename-buffer name t))))))

(defvar-local ellm--frontmatter-cwd-directory nil
  "Resolved directory from frontmatter `cwd:', or nil when unset.")

(defvar-local ellm--persistence-ephemeral-p nil
  "Non-nil when this ellm buffer must not be automatically persisted.")

(defvar-local ellm--session-directory nil
  "Directory containing this conversation and its subagent files.")

(put 'ellm--persistence-ephemeral-p 'permanent-local t)
(put 'ellm--session-directory 'permanent-local t)

(defvar-local ellm--persistence-saving-p nil
  "Non-nil while ellm is assigning or saving this buffer's persistence file.")

(defun ellm--warn-frontmatter-parse-error (err)
  "Warn about frontmatter parse ERR."
  (lwarn 'ellm :warning "Failed to parse frontmatter: %S" err))

(defun ellm--frontmatter-bounds ()
  "Return (BEG END CONTENTS-BEG CONTENTS-END CONTENTS) of YAML frontmatter.
BEG is `point-min'; END is the position just after the closing `---'
delimiter line (i.e. the end of the match against
`ellm-frontmatter-regexp')."
  (save-excursion
    (save-match-data
      (goto-char (point-min))
      (and-let* (((looking-at ellm-frontmatter-regexp))
                 (beg (match-beginning 0))
                 (end (match-end 0)))
        (list beg
              end
              (+ beg 4)
              (- end 4)
              (match-string-no-properties 1))))))

(defun ellm--parse-frontmatter (&optional quiet)
  "Return alist parsed from the buffer's YAML frontmatter, or nil.
Keys are symbols.  Returns nil when there is no frontmatter or when
parsing fails.  Unless QUIET is non-nil, parsing failures issue a
`lwarn'."
  (if-let* ((bounds (ellm--frontmatter-bounds))
            (body (nth 4 bounds)))
      (if (and ellm--frontmatter-cache-valid
               (equal body ellm--frontmatter-cache-body))
          (progn
            (when (and ellm--frontmatter-cache-error (not quiet))
              (ellm--warn-frontmatter-parse-error
               ellm--frontmatter-cache-error))
            (copy-tree ellm--frontmatter-cache-value))
        (condition-case err
            ;; NOTE: yaml.el currently coerces scalar-looking quoted and block
            ;; strings (such as "false" or "1").  We accept that limitation
            ;; because no supported provider is known to rely on such values.
            (let ((value (yaml-parse-string body
                                            :object-type 'alist
                                            :sequence-type 'list
                                            :null-object nil
                                            :false-object :false)))
              (unless (or (null value)
                          (and (listp value) (cl-every #'consp value)))
                (error "Frontmatter must be a YAML mapping"))
              (setq ellm--frontmatter-cache-valid t
                    ellm--frontmatter-cache-body body
                    ellm--frontmatter-cache-value (copy-tree value)
                    ellm--frontmatter-cache-error nil)
              (copy-tree value))
          (error
           (setq ellm--frontmatter-cache-valid t
                 ellm--frontmatter-cache-body body
                 ellm--frontmatter-cache-value nil
                 ellm--frontmatter-cache-error err)
           (unless quiet
             (ellm--warn-frontmatter-parse-error err))
           nil)))
    (setq ellm--frontmatter-cache-valid nil)
    nil))

(defun ellm--false-value-p (value)
  "Return non-nil when VALUE represents boolean false."
  (or (null value)
      (memq value '(:false :json-false))
      (and (stringp value) (equal (downcase value) "false"))))

(defun ellm--frontmatter-value (key)
  "Return frontmatter KEY from the current buffer.
KEY may be a symbol/string or a list naming a nested path."
  (ellm--alist-get-nested (ellm--parse-frontmatter) key))

(defun ellm--set-frontmatter-value (key &optional value)
  "Set scalar frontmatter KEY to VALUE in the current buffer.
When the buffer has no frontmatter, create one at the beginning.  VALUE is
written as a YAML scalar string.  Nil VALUE deletes KEY.  This ignores
request-time read-only protection."
  (if (null value)
      (ellm--delete-frontmatter-value key)
    (let ((inhibit-read-only t))
      (pcase-let ((fm (ellm--parse-frontmatter))
                  (`(_ _ ,beg ,end _) (ellm--frontmatter-bounds)))
        (replace-region-contents
         (or beg (point-min)) (or end (point-min))
         (lambda ()
           (concat (unless beg "---\n")
                   (ellm--yaml-encode (ellm--alist-set-nested fm key value))
                   (unless beg "\n---\n\n"))))))))

(defun ellm--yaml-encode (object)
  "Encode OBJECT as YAML."
  ;; NOTE: yaml.el may emit scalar-looking strings such as "false" or "1" as
  ;; plain YAML scalars.  We accept that limitation because no supported
  ;; provider is known to rely on those exact string values.
  (yaml-encode object))

(defun ellm--frontmatter-key-equal-p (left right)
  "Return non-nil when frontmatter keys LEFT and RIGHT name the same key."
  (equal (if (symbolp left) (symbol-name left) left)
         (if (symbolp right) (symbol-name right) right)))

(defun ellm--alist-delete-nested (alist keys)
  "Return ALIST without the nested value at KEYS.
Empty maps created by deleting the final child are removed as well."
  (let* ((keys (if (listp keys) keys (list keys)))
         (key (car keys))
         (cell (cl-find key alist :key #'car
                        :test #'ellm--frontmatter-key-equal-p)))
    (cond
     ((not cell) alist)
     ((null (cdr keys)) (delq cell alist))
     ((listp (cdr cell))
      (let ((child (ellm--alist-delete-nested (cdr cell) (cdr keys))))
        (if child
            (setcdr cell child)
          (setq alist (delq cell alist)))
        alist))
     (t alist))))

(defun ellm--delete-frontmatter-value (key)
  "Delete frontmatter KEY and prune empty parent maps.
KEY may be a symbol/string or a list naming a nested path."
  (when-let* ((bounds (ellm--frontmatter-bounds)))
    (let ((fm (copy-tree (ellm--parse-frontmatter))))
      (when ellm--frontmatter-cache-error
        (user-error "ellm: cannot edit malformed frontmatter"))
      (pcase-let ((`(_ _ ,beg ,end _) bounds))
        (let ((inhibit-read-only t))
          (replace-region-contents
           beg end
           (lambda ()
             (if-let* ((updated (ellm--alist-delete-nested fm key)))
                 (ellm--yaml-encode updated)
               ""))))))))

;;;;; Persistence

(defconst ellm--reasoning-state-id-regexp
  "\\`rs-[[:xdigit:]]\\{64\\}\\'"
  "Regexp matching a content-addressed reasoning state identifier.")

(defun ellm--reasoning-state-root (&optional global)
  "Return the reasoning state root for the current buffer.
When GLOBAL is non-nil, or no persisted session directory exists, return the
global cache root."
  (file-name-as-directory
   (if (and ellm--session-directory (not global))
       (expand-file-name ".state" ellm--session-directory)
     (expand-file-name ellm-cache-directory))))

(defun ellm--reasoning-state-directory (&optional global)
  "Return the reasoning state directory for the current buffer.
GLOBAL has the same meaning as in `ellm--reasoning-state-root'."
  (expand-file-name "reasoning/" (ellm--reasoning-state-root global)))

(defun ellm--reasoning-state-path (id &optional global)
  "Return the state file path for reasoning state ID.
GLOBAL has the same meaning as in `ellm--reasoning-state-root'."
  (and (stringp id)
       (string-match-p ellm--reasoning-state-id-regexp id)
       (expand-file-name (concat id ".json")
                         (ellm--reasoning-state-directory global))))

(defun ellm--reasoning-state-json (state)
  "Return canonical JSON text for reasoning STATE."
  (json-serialize state :null-object nil :false-object :json-false))

(defun ellm--reasoning-state-id (json)
  "Return the content-addressed identifier for reasoning state JSON."
  (concat "rs-" (secure-hash 'sha256 json)))

(defun ellm--ensure-reasoning-state-directory (&optional global)
  "Create and return the private reasoning state directory.
GLOBAL has the same meaning as in `ellm--reasoning-state-root'."
  (let ((root (ellm--reasoning-state-root global))
        (directory (ellm--reasoning-state-directory global)))
    (make-directory directory t)
    (set-file-modes root #o700)
    (set-file-modes directory #o700)
    directory))

(defun ellm--write-reasoning-state-file (id json &optional global)
  "Atomically write reasoning state JSON for ID and return ID.
GLOBAL has the same meaning as in `ellm--reasoning-state-root'."
  (let* ((directory (ellm--ensure-reasoning-state-directory global))
         (target (expand-file-name (concat id ".json") directory)))
    (unless (file-exists-p target)
      (let ((temporary (make-temp-file
                        (expand-file-name ".reasoning-" directory))))
        (unwind-protect
            (progn
              (let ((coding-system-for-write 'utf-8-unix))
                (write-region json nil temporary nil 'silent))
              (set-file-modes temporary #o600)
              (rename-file temporary target t)
              (set-file-modes target #o600))
          (when (file-exists-p temporary)
            (delete-file temporary)))))
    id))

(defun ellm-reasoning-state-write (state)
  "Persist opaque reasoning STATE and return its content-addressed ID.
Persisted conversations store state in their session directory.  Other
buffers use `ellm-cache-directory'."
  (let* ((json (ellm--reasoning-state-json state))
         (id (ellm--reasoning-state-id json)))
    (ellm--write-reasoning-state-file id json (not ellm--session-directory))))

(defun ellm--read-reasoning-state-file (id file)
  "Read and validate reasoning state ID from FILE, returning a plist."
  (when (and file (file-readable-p file))
    (condition-case nil
        (let ((json (with-temp-buffer
                      (let ((coding-system-for-read 'utf-8-unix))
                        (insert-file-contents file))
                      (buffer-string))))
          (when (equal id (ellm--reasoning-state-id json))
            (let ((state (json-parse-string
                          json :object-type 'plist
                          :null-object nil :false-object :json-false)))
              (and (equal (plist-get state :version) 1) state))))
      (error nil))))

(defun ellm-reasoning-state-read (id)
  "Return validated reasoning state referenced by ID, or nil.
The current session store is preferred over the global cache."
  (when (and (stringp id)
             (string-match-p ellm--reasoning-state-id-regexp id))
    (or (and ellm--session-directory
             (ellm--read-reasoning-state-file
              id (ellm--reasoning-state-path id)))
        (ellm--read-reasoning-state-file
         id (ellm--reasoning-state-path id t)))))

(defun ellm--localize-reasoning-state-files ()
  "Copy globally cached reasoning state referenced by this session locally."
  (when ellm--session-directory
    (dolist (turn (ellm--parse-turns))
      (when-let* ((id (alist-get "reasoning-state" (ellm-turn-attrs turn)
                                 nil nil #'equal))
                  ((string-match-p ellm--reasoning-state-id-regexp id))
                  (target (ellm--reasoning-state-path id))
                  ((not (file-exists-p target)))
                  (source (ellm--reasoning-state-path id t))
                  (state (ellm--read-reasoning-state-file id source)))
        (ellm--write-reasoning-state-file
         id (ellm--reasoning-state-json state))))))

(defun ellm--persistence-root ()
  "Return the automatic persistence root for the current buffer."
  (let ((root
         (pcase ellm-persistence-location
           ('global ellm-persistence-directory)
           ('project
            (if-let* ((default-directory
                        (or ellm--base-default-directory default-directory))
                      (project-root
                       (funcall ellm-current-project-function)))
                (expand-file-name ellm-persistence-project-directory
                                  project-root)
              ellm-persistence-directory))
           ((pred functionp)
            (funcall ellm-persistence-location))
           (_ nil))))
    (and root (file-name-as-directory (expand-file-name root)))))

(defun ellm--new-session-id ()
  "Return a new session id suitable for a directory name."
  (format "%s-%06x"
          (format-time-string "%Y%m%dT%H%M%S")
          (random #x1000000)))

(defun ellm--persistence-session-role ()
  "Return the persistence role of the current ellm buffer."
  (if (ellm--frontmatter-value '(subagent id))
      "subagent"
    (or (ellm--frontmatter-value '(ellm role)) "main")))

(defun ellm--persistence-session-directory-from-file (role)
  "Return the session directory implied by `buffer-file-name' and ROLE."
  (when buffer-file-name
    (let ((directory (file-name-directory buffer-file-name)))
      (if (and (equal role "subagent")
               (equal (file-name-nondirectory
                       (directory-file-name directory))
                      "subagents"))
          (file-name-directory (directory-file-name directory))
        directory))))

(defun ellm--persistence-target-file (role)
  "Return the file name for ROLE in `ellm--session-directory'."
  (if (equal role "subagent")
      (when-let* ((id (ellm--frontmatter-value '(subagent id))))
        (expand-file-name (concat (format "%s" id) ".ellm")
                          (expand-file-name "subagents/"
                                            ellm--session-directory)))
    (expand-file-name "main.ellm" ellm--session-directory)))

(defun ellm--persistence-set-frontmatter-value (key value)
  "Set frontmatter KEY to VALUE only when it differs."
  (unless (equal (ellm--frontmatter-value key) value)
    (ellm--set-frontmatter-value key value)))

(defun ellm--persistence-recognize-buffer ()
  "Restore persistence state from an already visited ellm file."
  (when (and buffer-file-name
             (ellm--frontmatter-value '(ellm session-id)))
    (setq-local
     ellm--session-directory
     (ellm--persistence-session-directory-from-file
      (ellm--persistence-session-role)))))

(defun ellm--persistence-setup-buffer ()
  "Assign persistence metadata and a visited file to the current buffer."
  (when (and ellm-persistence-enabled
             (not ellm--persistence-ephemeral-p)
             (not ellm--persistence-saving-p))
    (let* ((ellm--persistence-saving-p t)
           (role (ellm--persistence-session-role))
           (session-id (or (ellm--frontmatter-value '(ellm session-id))
                           (ellm--new-session-id))))
      (unless ellm--session-directory
        (setq-local
         ellm--session-directory
         (or (ellm--persistence-session-directory-from-file role)
             (when-let* ((root (ellm--persistence-root)))
               (expand-file-name (concat session-id "/") root)))))
      (when ellm--session-directory
        (make-directory ellm--session-directory t)
        (ellm--persistence-set-frontmatter-value '(ellm session-id) session-id)
        (ellm--persistence-set-frontmatter-value '(ellm role) role)
        (unless buffer-file-name
          (when-let* ((file (ellm--persistence-target-file role)))
            (make-directory (file-name-directory file) t)
            (let ((name (buffer-name)))
              (set-visited-file-name file t)
              (rename-buffer name t))))))))

(defun ellm--persistence-checkpoint ()
  "Persist the current ellm buffer at a stable conversation boundary."
  (when (and ellm-persistence-enabled
             (not ellm--persistence-ephemeral-p)
             (not ellm--persistence-saving-p))
    (condition-case err
        (progn
          (ellm--persistence-setup-buffer)
          (ellm--localize-reasoning-state-files)
          (when buffer-file-name
            (let ((ellm--persistence-saving-p t)
                  (save-silently t)
                  (inhibit-message t))
              (save-buffer)))
          buffer-file-name)
      (error
       (lwarn 'ellm :warning "Failed to persist conversation: %s"
              (error-message-string err))
       nil))))

(defun ellm--persistence-before-kill ()
  "Save the current conversation before backend session cleanup."
  (ellm--persistence-checkpoint))

(defun ellm-open-session ()
  "Open a persisted main conversation from the current persistence root."
  (interactive)
  (let* ((root (or (ellm--persistence-root)
                   (user-error "ellm: persistence has no directory here")))
         (files (and (file-directory-p root)
                     (directory-files-recursively root "main\\.ellm\\'")))
         (choices (mapcar (lambda (file)
                            (cons (file-relative-name
                                   (file-name-directory file) root)
                                  file))
                          files)))
    (unless choices
      (user-error "ellm: no persisted sessions in %s" root))
    (find-file (cdr (assoc (completing-read "Ellm session: " choices nil t)
                           choices)))))

;;;;; Provider resolution

(defun ellm--provider-with-model (provider model)
  "Return PROVIDER configured with MODEL where its backend supports it."
  (ellm-provider-with-model provider model))

(defun ellm--resolve-provider (frontmatter)
  "Return the provider to use for the current buffer.
Lookup order:
  1. `provider' in FRONTMATTER, looked up in `ellm-provider-alist'.
  2. `ellm-provider' (buffer-local or global).

When FRONTMATTER specifies a `model:', the resolved provider is passed
through `ellm-provider-with-model'.

Signals `user-error' when no provider can be resolved."
  (let* ((named (alist-get 'provider frontmatter))
         (provider
          (cond
           (named
            (let* ((sym (if (stringp named) (intern named) named))
                   (entry (alist-get sym ellm-provider-alist)))
              (unless entry
                (user-error
                 "ellm: provider `%s' not found in `ellm-provider-alist'"
                 sym))
              (ellm--provider-entry-provider entry)))
           (ellm-provider ellm-provider)
           (t (user-error
               "ellm: no provider configured (set `ellm-provider' or use frontmatter `provider:')"))))
         (model (alist-get 'model frontmatter)))
    (if model
        (ellm--provider-with-model provider model)
      provider)))

;;;;; Tool resolution

(defun ellm--resolve-tools (frontmatter)
  "Return the list of tools enabled for the current buffer.

Reads the `tools' key from FRONTMATTER (a list of strings), and for
each entry resolves it against `ellm-tools-list':

  - A bare string is matched against `ellm-tool-name' equality.
  - A string of the form `@CATEGORY' expands to every `ellm-tool' in
    `ellm-tools-list' whose `category' slot equals CATEGORY."
  (let ((entries (alist-get 'tools frontmatter))
        (resolved nil))
    (cond
     ((listp entries)
      (dolist (entry entries)
        (dolist (tool (ellm--resolve-tool entry))
          (unless (memq tool resolved)
            (push tool resolved)))))
     ((and (stringp entries))
      (dolist (tool (ellm--resolve-tool entries))
        (unless (memq tool resolved)
          (push tool resolved))))
     ((eq entries t)
      (setq resolved (copy-sequence ellm-tools-list))))
    resolved))

(defun ellm--resolve-tool (entry)
  "Given string ENTRY, resolve the tool corresponding to that.
ENTRY can be a category string starting with @ like, \"@category\" or it
can be a tool name like \"a_tool_name\"."
  (let ((spec (format "%s" entry)))
    (cond
     ;; @category ref
     ((and (> (length spec) 1) (eq (aref spec 0) ?@))
      (let* ((cat (substring spec 1))
             (matches
              (cl-loop for tool in ellm-tools-list
                       when (equal (ellm-tool-category tool) cat)
                       collect tool)))
        (if matches matches
          (warn "ellm: no tools in `ellm-tools-list' have category `%s'" cat))))
     ;; name ref
     (t
      (let ((tool (cl-find spec ellm-tools-list
                           :key #'ellm-tool-name
                           :test #'equal)))
        (if tool (list tool)
          (warn "ellm: tool `%s' not found in `ellm-tools-list'" spec)))))))

;;;;; MCP server resolution

(defun ellm--plistish-get (object key)
  "Return KEY from OBJECT, which may be a plist or YAML-style alist.
KEY may be a keyword, symbol, or string.  This keeps Elisp configuration
plists and parsed YAML maps on the same path."
  (let* ((name (cond ((keywordp key) (substring (symbol-name key) 1))
                     ((symbolp key) (symbol-name key))
                     (t key)))
         (sym (intern name))
         (kw (intern (concat ":" name))))
    (cond
     ((and (listp object) (keywordp (car object)))
      (plist-get object kw))
     ((listp object)
      (or (alist-get sym object nil nil #'eq)
          (alist-get name object nil nil #'equal)
          (alist-get kw object nil nil #'eq))))))

(defun ellm--mcp-server-name (name)
  "Return NAME as a stable MCP server name string."
  (cond ((stringp name) name)
        ((symbolp name) (symbol-name name))
        (t (format "%s" name))))

(defun ellm--mcp-inline-server-p (entry)
  "Return non-nil if ENTRY looks like an inline MCP server config."
  (and (listp entry)
       (ellm--plistish-get entry 'name)
       (or (ellm--plistish-get entry 'command)
           (ellm--plistish-get entry 'url))))

(defun ellm--resolve-mcp-servers (frontmatter)
  "Return MCP servers enabled by FRONTMATTER.

Servers come from top-level `mcp:' frontmatter and are resolved against
`ellm-mcp-servers'.  The accepted syntax mirrors `tools:': true enables
all configured servers, strings name servers, and strings beginning with
@ expand categories.  Unlike `tools:', inline server maps are also
accepted."
  (let ((entries (alist-get 'mcp frontmatter))
        resolved)
    (cond
     ((ellm--false-value-p entries)
      nil)
     ((eq entries t)
      (dolist (server ellm-mcp-servers)
        (push server resolved)))
     ((or (stringp entries) (symbolp entries) (ellm--mcp-inline-server-p entries))
      (dolist (server (ellm--resolve-mcp-server entries))
        (push server resolved)))
     ((listp entries)
      (dolist (entry entries)
        (dolist (server (ellm--resolve-mcp-server entry))
          (unless (cl-find (car server) resolved :key #'car :test #'equal)
            (push server resolved))))))
    (nreverse resolved)))

(defun ellm--resolve-mcp-server (entry)
  "Resolve MCP server ENTRY to a list of (NAME . CONFIG) conses."
  (cond
   ((ellm--mcp-inline-server-p entry)
    (list (cons (ellm--mcp-server-name (ellm--plistish-get entry 'name))
                entry)))
   ((or (stringp entry) (symbolp entry))
    (let ((spec (ellm--mcp-server-name entry)))
      (if (and (> (length spec) 1) (eq (aref spec 0) ?@))
          (let* ((category (substring spec 1))
                 (matches
                  (cl-loop for server in ellm-mcp-servers
                           when (equal (ellm--plistish-get (cdr server) 'category)
                                       category)
                           collect server)))
            (unless matches
              (warn "ellm: no MCP servers in `ellm-mcp-servers' have category `%s'"
                    category))
            matches)
        (let ((server (cl-find spec ellm-mcp-servers
                               :key (lambda (server)
                                      (ellm--mcp-server-name (car server)))
                               :test #'equal)))
          (unless server
            (warn "ellm: MCP server `%s' not found in `ellm-mcp-servers'"
                  spec))
          (and server (list server))))))))

(defun ellm--capf-mcp-candidates ()
  "Return completion strings for `mcp:' frontmatter entries."
  (append
   (mapcar (lambda (server) (ellm--mcp-server-name (car server)))
           ellm-mcp-servers)
   (mapcar (lambda (cat) (concat "@" cat))
           (delete-dups
            (delq nil (mapcar (lambda (server)
                                (ellm--plistish-get (cdr server) 'category))
                              ellm-mcp-servers))))))

;;;;; Frontmatter completion

(defvar-local ellm--active-request nil
  "Active backend request handle for this buffer, or nil.
Set by `ellm-send' to the object returned by `ellm-backend-send'.
Cleared on completion, error, or cancellation.")

(defvar-local ellm--config-in-flight nil
  "Config path currently being applied asynchronously, or nil.")

(defvar-local ellm-request-finished-hook nil
  "Hook run when the current request fully finishes.
This runs after success, cancellation, or failure, but not between internal
backend request legs such as recursive tool-call handling.")

(defvar-local ellm--request-finished-notified-p nil
  "Non-nil when the current request has fired `ellm-request-finished-hook'.")

(defvar-local ellm--request-start-time nil
  "Time at which the current user turn was submitted, or nil.")

(defvar-local ellm--request-assistant-marker nil
  "Marker at the top-level assistant turn for the current request.")

(defvar-local ellm--request-read-only-state nil
  "Saved `buffer-read-only' value before the current request locked the buffer.")

(defvar-local ellm--request-read-only-state-saved-p nil
  "Non-nil when `ellm--request-read-only-state' should be restored.")

(defun ellm--set-active-request (request)
  "Set active REQUEST for the current buffer.
Non-nil REQUEST makes the buffer read-only so user edits cannot race with
streaming backend insertions.  Nil REQUEST restores the previous
`buffer-read-only' value."
  (setq ellm--active-request request)
  (if request
      (progn
        (unless ellm--request-read-only-state-saved-p
          (setq ellm--request-read-only-state buffer-read-only
                ellm--request-read-only-state-saved-p t))
        (setq buffer-read-only t))
    (when ellm--request-read-only-state-saved-p
      (setq buffer-read-only ellm--request-read-only-state
            ellm--request-read-only-state nil
            ellm--request-read-only-state-saved-p nil)))
  request)

(defun ellm--finalize-request-turn ()
  "Add completion metadata to the current request's assistant turn.
Return non-nil when a live top-level assistant header was updated."
  (let ((marker ellm--request-assistant-marker)
        (started-at ellm--request-start-time)
        updated)
    (unwind-protect
        (when (and started-at
                   (markerp marker)
                   (eq (marker-buffer marker) (current-buffer)))
          (let ((finished-at (ellm--now)))
            (save-excursion
              (goto-char marker)
              (when (and (looking-at ellm-turn-regexp)
                         (equal (match-string-no-properties 1)
                                ellm-turn-header-1)
                         (equal (match-string-no-properties 2) "assistant"))
                (ellm--set-turn-header-attrs
                 marker
                 `(("ts" . ,(ellm--timestamp finished-at))
                   ("took" . ,(ellm--format-elapsed-time
                                (float-time
                                 (time-subtract finished-at started-at))))))
                (setq updated t)))))
      (when (markerp marker)
        (set-marker marker nil))
      (setq ellm--request-assistant-marker nil
            ellm--request-start-time nil))
    updated))

(defun ellm--notify-request-finished ()
  "Finalize request metadata and run `ellm-request-finished-hook' once."
  (unless ellm--request-finished-notified-p
    (when (ellm--finalize-request-turn)
      ;; Backends generally checkpoint immediately before notifying.  The
      ;; completion timestamp is added here, so persist that final mutation.
      (ellm--persistence-checkpoint))
    (ellm--flush-pending-fold)
    (setq ellm--request-finished-notified-p t)
    (run-hooks 'ellm-request-finished-hook)))

(defconst ellm--default-reasoning-candidates
  '(("light" :desc "Prefer a small reasoning budget.")
    ("medium" :desc "Prefer a moderate reasoning budget.")
    ("maximum" :desc "Prefer the largest reasoning budget.")
    ("none" :desc "Disable reasoning when supported."))
  "Fallback reasoning candidates for providers without model metadata.")

(defconst ellm--frontmatter-keys
  '(("provider"    :ann "provider"
     :desc "Provider name from `ellm-provider-alist'."
     :values ellm--capf-provider-candidates)
    ("model"       :ann "model"
     :desc "Chat model name."
     :values ellm--capf-model-candidates
     :type enum :editable t)
    ("system"      :ann "string"
     :desc "System prompt (used when no `system' turn present)."
     :type string :editable t)
    ("temperature" :ann "number"
     :desc "Sampling temperature (number)."
     :type number :editable t)
    ("max-tokens"  :ann "integer"
     :desc "Max output tokens (integer)."
     :type integer :editable t)
    ("reasoning"   :ann "level"
     :desc "Provider-supported reasoning effort."
     :type enum :editable t
     :values ellm--capf-reasoning-candidates)
    ("tools"       :ann "list"
     :desc "Tools enabled for this buffer; names from `ellm-tools-list' or `@CATEGORY'."
     :type list :editable t
     :items ellm--capf-tool-candidates)
    ("mcp"         :ann "list|true"
     :desc "MCP servers enabled for this buffer; true means all, names come from `ellm-mcp-servers', and `@CATEGORY' expands categories."
     :type mcp :editable t
     :values (("true" :value t
               :desc "Enable every MCP server in `ellm-mcp-servers'."))
     :items ellm--capf-mcp-candidates)
    ("cwd"         :ann "directory"
     :desc "Working directory used by backends and local tools when supported."
     :type directory :editable t)
    ("subagents"   :ann "map"
     :desc "Subagent defaults and named profiles. Buffer-local `subagents:' overrides `ellm-subagents'."
     :children (("default" :ann "profile|map"
                 :desc "Default subagent profile name or inline settings map.")
                ("profiles" :ann "map"
                 :desc "Named subagent profile maps. Each profile may set provider, model, tools, system, cwd, and related frontmatter.")))
    ("ellm"        :ann "metadata"
     :desc "Persistence metadata maintained by ellm."
     :children (("session-id" :ann "string"
                 :desc "Stable id shared by a conversation and its subagents.")
                ("role" :ann "main|subagent"
                 :desc "File role within a persisted session.")))
    ("acp" :ann "acp"
     :desc "ACP related configurations."
     :children (("session-id" :ann "string"
                 :desc "ACP session id used to continue an existing session.")
                 ("additional-directories" :ann "list"
                  :desc "Additional ACP workspace roots sent on session lifecycle requests."
                  :type directories :editable t)
                ("config" :ann "map"
                 :desc "ACP session config options advertised by the active agent."
                 :children ellm--capf-acp-config-entries))))
  "Alist of (KEY . SPEC) for known YAML frontmatter keys.
SPEC is a plist with:
  :ann     Short annotation string, shown inline next to the candidate
            (via `:annotation-function').
  :desc    Longer description, exposed via `:company-doc-buffer' for
           rich documentation popups.
  :values  Scalar value candidates.  Either a list or a function
            returning either a list of strings or `(STRINGS . SOURCE)'
            where SOURCE is appended to the value annotation.
  :items   Array item candidates, resolved the same way as `:values'.
           Used for block lists (`- ITEM') and inline arrays (`[ITEM]').
  :children Nested key entries with the same shape as this top-level alist.
  :type     Value reader used by `ellm-set-config'.
  :editable Whether `ellm-set-config' may offer this entry.

Candidate lists may contain plain strings or entries of the form
  `(STRING :ann ANN :desc DESC :value VALUE)'.  ANN, DESC, and VALUE are
optional.  VALUE is the typed value used by `ellm-set-config'; STRING is used
when VALUE is absent.
Keys without `:values', `:items', or `:children' get only key-side completion.
`:children' may be a list or a function returning a list.")

(defun ellm--in-frontmatter-p (&optional pos)
  "Return non-nil if POS (or point) is inside YAML frontmatter body.
Excludes the opening and closing `---' delimiter lines themselves.

Avoids the O(frontmatter-size) non-greedy match used by
`ellm--frontmatter-bounds' by probing only: the first line, the line
under POS, and a bounded `re-search-forward' for the closing
delimiter starting from POS."
  (save-excursion
    (save-match-data
      (let* ((p (or pos (point)))
             (line-bol (progn (goto-char p) (line-beginning-position))))
        (and (> line-bol (point-min))   ; not on opening `---' line
             (progn (goto-char (point-min))
                    (looking-at-p "---\n"))
             (progn (goto-char line-bol)
                    (not (looking-at-p "---$")))
             (progn (goto-char p)
                    (re-search-forward "^---$" nil t)))))))

(defun ellm--capf-provider-candidates ()
  "Return list of provider name strings from `ellm-provider-alist'."
  (mapcar (lambda (e) (symbol-name (car e))) ellm-provider-alist))

(defun ellm--capf-maybe-start-session-for-models (provider frontmatter)
  "Maybe start PROVIDER's session to load model candidates.
This only prompts for an explicit `completion-at-point' command, avoiding
surprise prompts from automatic completion UIs."
  (when (and provider
             (eq this-command 'completion-at-point)
             (not noninteractive)
             (not ellm--active-request)
             (ellm-provider-model-completion-session-start-p
              provider (current-buffer))
             (y-or-n-p "Start provider session to load model completions? "))
    (condition-case err
        (progn
          (ellm-provider-start-session-for-model-completion
           provider frontmatter (current-buffer))
          t)
      (error
       (message "ellm: failed to start session: %s"
                (error-message-string err))
       nil))))

(defun ellm--capf-model-candidates ()
  "Return (MODELS . SOURCE) for `model:' frontmatter completion.
MODELS is a list of model name strings.  SOURCE is one of:
  `explicit'   - taken from the alist entry's `:models' list,
  `provider'   - supplied by the resolved provider backend."
  (let* ((fm (ignore-errors (ellm--parse-frontmatter t)))
          (named (or (alist-get 'provider fm)
                     (ellm--capf-frontmatter-provider-name)))
          (sym (and named (if (stringp named) (intern named) named)))
          (entry (and sym (alist-get sym ellm-provider-alist)))
          (explicit (and entry (ellm--provider-entry-models entry)))
          (provider (or (and entry (ellm--provider-entry-provider entry))
                        (and (not named) ellm-provider)))
          (models (and provider
                       (ellm-provider-buffer-model-candidates
                        provider (current-buffer)))))
    (cond
      (explicit (cons explicit 'explicit))
      (models (cons models 'provider))
      ((and provider
            (ellm--capf-maybe-start-session-for-models provider fm))
       (cons (ellm-provider-buffer-model-candidates
              provider (current-buffer))
             'provider))
      (t (cons nil nil)))))

(defun ellm--capf-reasoning-candidates ()
  "Return reasoning candidates for the current provider and model."
  (let* ((frontmatter (ignore-errors (ellm--parse-frontmatter t)))
         (provider (ellm--capf-current-provider))
         (model (and frontmatter (alist-get 'model frontmatter))))
    (or (and provider
             (ellm-provider-reasoning-candidates
              provider (and model (format "%s" model)) (current-buffer)))
        ellm--default-reasoning-candidates)))

(defun ellm--capf-tool-candidates ()
  "Return list of completion strings for `tools:' frontmatter.
Combines every tool name in `ellm-tools-list' with `@CATEGORY' for each
distinct `category' slot of `ellm-tool' entries."
  (append
   (mapcar #'ellm-tool-name ellm-tools-list)
   (mapcar (lambda (cat) (concat "@" cat))
           (delete-dups
            (delq nil (mapcar #'ellm-tool-category ellm-tools-list))))))

(defun ellm--capf-frontmatter-provider-name ()
  "Return `provider:' from frontmatter using a cheap line scan.
This is used only for completion while the YAML body may be temporarily
invalid, such as when completing a new key before typing `:'."
  (when-let* ((bounds (ellm--frontmatter-bounds)))
    (pcase-let ((`(_ _ ,contents-beg ,contents-end _) bounds))
      (save-excursion
        (goto-char contents-beg)
        (when (re-search-forward
               "^[ \t]*provider:[ \t]*\\([^#\n]+\\)" contents-end t)
          (string-trim (match-string-no-properties 1)
                       "[ \t\"']+" "[ \t\"']+"))))))

(defun ellm--capf-current-provider ()
  "Return the current frontmatter provider for completion, or nil."
  (let ((named (ellm--capf-frontmatter-provider-name)))
    (cond
     (named
      (let* ((sym (if (stringp named) (intern named) named))
             (entry (alist-get sym ellm-provider-alist)))
        (and entry (ellm--provider-entry-provider entry))))
     (ellm-provider ellm-provider))))

(defun ellm--capf-provider-frontmatter-entries (path)
  "Return provider-supplied frontmatter key entries under PATH."
  (let ((provider (ellm--capf-current-provider)))
    (and provider
         (ellm-provider-frontmatter-entries
          provider path (current-buffer)))))

(defun ellm--capf-acp-config-entries ()
  "Return dynamic key entries for `acp.config' frontmatter."
  (ellm--capf-provider-frontmatter-entries '(acp config)))

(defun ellm--capf-resolve-values (values-spec)
  "Resolve VALUES-SPEC from a `ellm--frontmatter-keys' entry.
Returns (CANDIDATES . SOURCE) where SOURCE may be nil."
  (let ((raw (cond ((functionp values-spec) (funcall values-spec))
                   (t values-spec))))
    (if (and (consp raw) (not (stringp (car raw))) (symbolp (cdr raw)))
        raw
      (cons raw nil))))

(defun ellm--frontmatter-capf--candidate-name (candidate)
  "Return the completion string for CANDIDATE."
  (if (consp candidate) (car candidate) candidate))

(defun ellm--frontmatter-capf--candidate-plist (candidate)
  "Return metadata plist for CANDIDATE, or nil."
  (and (consp candidate) (cdr candidate)))

(defun ellm--frontmatter-capf--candidate-plist-for (candidate candidates)
  "Return metadata plist for CANDIDATE in CANDIDATES."
  (catch 'found
    (dolist (entry candidates)
      (when (equal candidate (ellm--frontmatter-capf--candidate-name entry))
        (throw 'found (ellm--frontmatter-capf--candidate-plist entry))))))

(defun ellm--frontmatter-capf--doc-buffer (text)
  "Return a documentation buffer containing TEXT."
  (with-current-buffer (get-buffer-create " *ellm-doc*")
    (erase-buffer)
    (insert text)
    (current-buffer)))

(defun ellm--frontmatter-capf--make-result (beg end candidates context &optional source)
  "Return a completion-at-point result for CANDIDATES from BEG to END.
CONTEXT is used as the fallback annotation.  SOURCE, when non-nil, is
appended to the fallback annotation."
  (let ((names (mapcar #'ellm--frontmatter-capf--candidate-name candidates)))
    (list beg end names
          :exclusive 'no
          :annotation-function
          (lambda (cand)
            (or (when-let* ((plist (ellm--frontmatter-capf--candidate-plist-for cand candidates))
                            (ann (plist-get plist :ann)))
                  (concat " " ann))
                (if source
                    (format " %s (%s)" context source)
                  (concat " " context))))
          :company-doc-buffer
          (lambda (cand)
            (when-let* ((plist (ellm--frontmatter-capf--candidate-plist-for cand candidates))
                        (desc (plist-get plist :desc)))
              (ellm--frontmatter-capf--doc-buffer desc))))))

(defun ellm--frontmatter-capf--key-entries (spec)
  "Return child key entries for SPEC, or top-level entries when SPEC is nil."
  (let ((entries (if spec
                     (plist-get spec :children)
                   ellm--frontmatter-keys)))
    (append (if (functionp entries) (funcall entries) entries)
            (unless spec
              (ellm--capf-provider-frontmatter-entries nil)))))

(defun ellm--frontmatter-capf--lookup-key (key entries)
  "Return the spec for KEY in ENTRIES."
  (cdr (assoc key entries)))

(defun ellm--frontmatter-capf--parent-spec (indent)
  "Return the nearest known parent key spec for a line at INDENT."
  (pcase-let ((`(_ _ ,contents-beg _ _) (ellm--frontmatter-bounds))
              (current-bol (line-beginning-position))
              (stack nil))
    (save-excursion
      (goto-char contents-beg)
      (while (< (point) current-bol)
        (when (looking-at "^\\([ \t]*\\)\\([a-zA-Z0-9_-]+\\):")
          (let* ((line-indent (length (match-string-no-properties 1)))
                 (key (match-string-no-properties 2)))
            (while (and stack (>= (caar stack) line-indent))
              (pop stack))
            (when-let* ((spec (ellm--frontmatter-capf--lookup-key
                               key (ellm--frontmatter-capf--key-entries (cdar stack)))))
              (push (cons line-indent spec) stack))))
        (forward-line 1)))
    (while (and stack (>= (caar stack) indent))
      (pop stack))
    (cdar stack)))

(defun ellm--frontmatter-capf--key-spec (key indent)
  "Return the known spec for KEY on a line at INDENT."
  (ellm--frontmatter-capf--lookup-key
   key (ellm--frontmatter-capf--key-entries
        (ellm--frontmatter-capf--parent-spec indent))))

(defun ellm--frontmatter-capf--quoted-token-bounds-at (pos quote)
  "Return content bounds of the quoted token around POS using QUOTE.
The returned bounds exclude the quote characters, so completing inside a
quoted scalar preserves the existing YAML quoting."
  (save-excursion
    (let ((line-beg (line-beginning-position))
          (line-end (line-end-position))
          open
          bounds)
      (goto-char line-beg)
      (while (and (< (point) line-end) (not bounds))
        (when (and (eq (char-after) quote)
                   (not (and (eq quote ?\")
                             (> (point) line-beg)
                             (eq (char-before) ?\\))))
          (if open
              (let ((close (point)))
                (when (and (>= pos open) (<= pos (1+ close)))
                  (setq bounds (cons (1+ open) close)))
                (setq open nil))
            (setq open (point))))
        (forward-char 1))
      (when (and open (not bounds) (>= pos open) (<= pos line-end))
        (setq bounds (cons (1+ open) line-end)))
      bounds)))

(defun ellm--frontmatter-capf--token-bounds-at (pos)
  "Return (BEG . END) of the YAML/JSON-array token at POS.
A bare token is a run of non-delimiter characters: anything except
whitespace, brackets `[]', braces `{}', commas `,', colons `:',
and quotes.  Quoted strings are treated as a single token whose bounds
cover only the string contents, not the quote characters.  Returns nil
when POS is not inside any token."
  (save-excursion
    (goto-char pos)
    (or (ellm--frontmatter-capf--quoted-token-bounds-at pos ?\")
        (ellm--frontmatter-capf--quoted-token-bounds-at pos ?\')
        ;; Bare token (no quotes): a token exists at POS if there is a valid
        ;; token char immediately after OR immediately before point (the latter
        ;; covers the common case of point sitting at the end of the token).
        (let* ((token-char "^ \t\[\]{},:\"'\n")
               (after-tok
                (and (not (eolp))
                     (not (string-match-p "[ \t\[\]{},:\"'\n]"
                                          (char-to-string (char-after))))))
               (before-tok
                (and (not (bolp))
                     (not (string-match-p "[ \t\[\]{},:\"'\n]"
                                          (char-to-string (char-before)))))))
        (when (or after-tok before-tok)
          (let ((end (save-excursion
                       (skip-chars-forward token-char)
                       (point)))
                (beg (save-excursion
                       (skip-chars-backward token-char)
                       (point))))
            (cons beg end)))))))

(defun ellm--frontmatter-capf--inline-token-at (pos line-value-beg line-value-end)
  "Return (BEG . END) for the token at POS within an inline value region.
LINE-VALUE-BEG..LINE-VALUE-END are the bounds of the full value portion
of the `KEY: VALUE' line.  Strips enclosing `[...]' when present and
then delegates to `ellm--frontmatter-capf--token-bounds-at'.
Returns nil when POS is outside the value region or not on a token."
  (when (and (>= pos line-value-beg) (<= pos line-value-end))
    ;; Strip the surrounding [ ] if the value is an inline list.
    (let* ((val-beg (save-excursion
                      (goto-char line-value-beg)
                      (skip-chars-forward " \t")
                      (if (eq (char-after) ?\[)
                          (1+ (point))
                        (point))))
           (val-end (save-excursion
                      (goto-char line-value-end)
                      (skip-chars-backward " \t")
                      (if (eq (char-before) ?\])
                          (1- (point))
                        (point)))))
      (when (and (>= pos val-beg) (<= pos val-end))
        (when-let* ((tok (ellm--frontmatter-capf--token-bounds-at pos)))
          (cons (max (car tok) val-beg)
                (min (cdr tok) val-end)))))))

(defun ellm--frontmatter-capf--inline-array-p (value-beg value-end)
  "Return non-nil when VALUE-BEG..VALUE-END is a bracketed inline array."
  (save-excursion
    (goto-char value-beg)
    (skip-chars-forward " \t" value-end)
    (and (< (point) value-end)
         (eq (char-after) ?\[))))

(defun ellm--frontmatter-capf ()
  "Completion-at-point function for ellm YAML frontmatter.
Completes:
  - YAML keys from `ellm--frontmatter-keys' and nested `:children',
  - scalar `:values' after `KEY: VALUE',
  - array `:items' on block-list item lines (`- ITEM') and inside
    bracketed inline arrays (`KEY: [ITEM]')."
  (when (ellm--in-frontmatter-p)
    (let ((orig (point)))
      (save-excursion
        (beginning-of-line)
        (cond
         ((looking-at "^\\([ \t]*\\)-[ \t]*\\(.*\\)$") ; - <something>
          (let* ((indent (length (match-string-no-properties 1)))
                 (item-beg (match-beginning 2))
                 (item-end (match-end 2))
                 (spec (ellm--frontmatter-capf--parent-spec indent))
                 (items-spec (and spec (plist-get spec :items))))
            (when (and items-spec (>= orig item-beg) (<= orig item-end))
              ;; Find the precise token bounds at point so completion replaces
              ;; only the word being typed, not the whole line suffix.
              (let* ((tok (ellm--frontmatter-capf--token-bounds-at orig))
                     (tbeg (or (car tok) orig))
                     (tend (or (cdr tok) orig)))
                (pcase-let ((`(,cands . ,source)
                             (ellm--capf-resolve-values items-spec)))
                  (ellm--frontmatter-capf--make-result
                   tbeg tend cands "item" source))))))
         ;; KEY: VALUE (inline) — value-side completion.
         ;; Handles both bare values and inline arrays like ["a", "b"].
         ((looking-at "^\\([ \t]*\\)\\([a-zA-Z0-9_-]+\\):[ \t]*\\(.*?\\)[ \t]*$")
          (let* ((indent (length (match-string-no-properties 1)))
                 (key (match-string-no-properties 2))
                 (vbeg (match-beginning 3))
                 (vend (match-end 3))
                 (spec (ellm--frontmatter-capf--key-spec key indent))
                 (values-spec (and spec (plist-get spec :values)))
                 (items-spec (and spec (plist-get spec :items)))
                 (arrayp (ellm--frontmatter-capf--inline-array-p vbeg vend))
                 (candidates-spec (if arrayp items-spec values-spec)))
            (when candidates-spec
              (let* ((tok (ellm--frontmatter-capf--inline-token-at orig vbeg vend))
                     (tbeg (or (car tok) orig))
                     (tend (or (cdr tok) orig)))
                (when (and (>= orig vbeg) (<= orig vend))
                  (pcase-let ((`(,cands . ,source)
                               (ellm--capf-resolve-values candidates-spec)))
                    (ellm--frontmatter-capf--make-result
                     tbeg tend cands key source)))))))
         ;; No `:' yet — key-side completion.
         ((looking-at "^\\([ \t]*\\)\\([a-zA-Z0-9_-]*\\)[ \t]*$")
          (let* ((indent (length (match-string-no-properties 1)))
                 (kbeg (match-beginning 2))
                 (kend (match-end 2))
                 (entries (ellm--frontmatter-capf--key-entries
                           (ellm--frontmatter-capf--parent-spec indent))))
            (when (and (>= orig kbeg) (<= orig kend))
              (list kbeg kend
                    (mapcar #'car entries)
                    :exclusive 'no
                    :annotation-function
                    (lambda (cand)
                      (when-let* ((spec (ellm--frontmatter-capf--lookup-key cand entries))
                                  (ann (plist-get spec :ann)))
                        (concat " " ann)))
                    :company-doc-buffer
                    (lambda (cand)
                      (when-let* ((spec (ellm--frontmatter-capf--lookup-key cand entries))
                                  (desc (plist-get spec :desc)))
                        (ellm--frontmatter-capf--doc-buffer desc)))
                    :exit-function
                    (lambda (_string status)
                      (when (and (memq status '(finished sole exact))
                                 (not (looking-at-p ":")))
                        (insert ": "))))))))))))

(defun ellm--turn-at-point ()
  "Return parsed turn containing point, or nil."
  (let ((pos (point)))
    (cl-find-if (lambda (turn)
                  (and (>= pos (ellm-turn-beg turn))
                       (<= pos (ellm-turn-end turn))))
                (ellm--parse-turns))))

(defun ellm--slash-command-capf ()
  "Complete backend-provided slash commands in user turns."
  (when-let* ((turn (ellm--turn-at-point))
              ((equal (ellm-turn-role turn) "user")))
    (save-excursion
      (let ((orig (point)))
        (beginning-of-line)
        (when (looking-at "[ \t]*\\(/[^ \t\n]*\\)")
          (let ((beg (match-beginning 1))
                (end (match-end 1)))
            (when (and (>= orig beg) (<= orig end))
              (let* ((fm (ellm--parse-frontmatter))
                     (provider (ignore-errors (ellm--resolve-provider fm)))
                     (commands (and provider
                                    (ellm-provider-slash-command-candidates
                                     provider (current-buffer)))))
                (when commands
                  (ellm--frontmatter-capf--make-result
                   beg end commands "command"))))))))))

;;;;;; Insertion

(defun ellm--defer-call (function &rest args)
  "Call FUNCTION with ARGS from a timer when no minibuffer is active."
  (run-at-time 0 nil #'ellm--call-when-minibuffer-free function args))

(defun ellm--call-when-minibuffer-free (function args)
  "Call FUNCTION with ARGS, waiting while another minibuffer is active."
  (if (active-minibuffer-window)
      (run-at-time 0.1 nil #'ellm--call-when-minibuffer-free function args)
    (apply function args)))

(defun ellm--new-buffer (ephemeral &optional select-provider-model)
  "Create a new ellm conversation buffer.
When EPHEMERAL is non-nil, do not automatically persist it.
When SELECT-PROVIDER-MODEL is non-nil, prompt for the provider and model."
  (let* ((buf (generate-new-buffer (if (functionp ellm-initial-buffer-name)
                                       (funcall ellm-initial-buffer-name)
                                     ellm-initial-buffer-name)))
         (provider-name
          (if select-provider-model
              (let ((name (completing-read
                           "Provider: " (ellm--capf-provider-candidates) nil t)))
                (and (not (string-empty-p name)) (intern name)))
            (caar ellm-provider-alist)))
         (provider-entry (and provider-name
                              (alist-get provider-name ellm-provider-alist)))
         (provider (ellm--provider-entry-provider provider-entry)))
    (with-current-buffer buf
      (setq-local ellm--persistence-ephemeral-p ephemeral)
      (insert (format "---\nprovider: %s\nmodel: %s\ncreated: %s\n---\n\n"
                      (or provider-name "null")
                      (or (ellm-provider-current-model provider)
                          "null")
                      (ellm--timestamp)))
      (ellm--insert-turn "user")
      (ellm-mode))
    (switch-to-buffer buf)
    (when select-provider-model
      (cl-labels
          ((on-error
            (error-object)
            (message "ellm: new buffer configuration failed: %s"
                     (or (plist-get error-object :message)
                         (condition-case nil
                             (error-message-string error-object)
                           (error (format "%s" error-object))))))
           (select-model
            ()
            (when (buffer-live-p buf)
              (with-current-buffer buf
                (when-let* ((models
                             (or (ellm--provider-entry-models provider-entry)
                                 (and provider
                                      (ellm-provider-buffer-model-candidates
                                       provider buf))))
                            (model (completing-read "Model: " models nil t)))
                  (ellm--set-frontmatter-value 'model model)
                  (ellm-provider-configure-new-buffer
                   provider (ellm--parse-frontmatter) buf
                   (lambda ()
                     (message "ellm: new buffer configuration complete"))
                   #'on-error))))))
        (if (and provider
                 (not (ellm--provider-entry-models provider-entry))
                 (not (ellm-provider-buffer-model-candidates provider buf))
                 (ellm-provider-model-completion-session-start-p provider buf))
            (progn
              (message "ellm: starting provider session...")
              (ellm-provider-prepare-new-buffer
               provider (with-current-buffer buf (ellm--parse-frontmatter)) buf
               (lambda ()
                 (message "ellm: provider session ready; select a model")
                 (ellm--defer-call #'select-model))
               #'on-error))
          (select-model))))
    buf))

(defun ellm-new-buffer (&optional select-provider-model)
  "Create a new ellm conversation buffer.
With prefix argument SELECT-PROVIDER-MODEL, prompt for provider and model.
Session-backed providers may start a session to discover model candidates."
  (interactive "P")
  (ellm--new-buffer nil select-provider-model))

(defun ellm-new-temp-buffer ()
  "Create an ephemeral ellm conversation buffer.
This is equivalent to `ellm-new-buffer' when automatic persistence is
disabled.  When persistence is enabled, neither this buffer nor subagents
launched from it receive automatic files."
  (interactive)
  (ellm--new-buffer 'ephemeral))

(defun ellm--now ()
  "Return the current time.
This small wrapper keeps request lifecycle timing deterministic in tests."
  (current-time))

(defun ellm--timestamp (&optional time)
  "Return TIME as an ISO 8601 timestamp, defaulting to the current time."
  (format-time-string "%Y-%m-%dT%H:%M:%S" time))

(defun ellm--format-elapsed-time (seconds)
  "Return elapsed SECONDS in a compact, single-token form."
  (let* ((total (max 0 (round seconds)))
         (hours (/ total 3600))
         (minutes (/ (% total 3600) 60))
         (secs (% total 60)))
    (concat (and (> hours 0) (format "%dh" hours))
            (and (> minutes 0) (format "%dm" minutes))
            (if (or (> secs 0) (zerop total))
                (format "%ds" secs)
              ""))))

(defun ellm--ensure-newline (s)
  (if (string-suffix-p "\n" s)
      s
    (concat s "\n")))

(defun ellm--turn-header-for-role (role attrs)
  "Return the delimiter header for ROLE with ATTRS plist."
  (cond
   ((equal role "tool-param") ellm-turn-header-3)
   ((or (ellm--tool-role-p role)
        (plist-get attrs :continuation))
    ellm-turn-header-2)
   (t ellm-turn-header-1)))

(defun ellm--get-turn (role &rest attrs)
  (let* ((header (ellm--turn-header-for-role role attrs))
         (positional nil)
         (pipe-arg nil)
         (kv-tail nil))
    (cl-loop for (key val) on attrs by #'cddr do
             (cond
              ((eq key :continuation) nil)
              ((eq key :arg)
               (dolist (a (if (listp val) val (list val)))
                 (push a positional)))
              ((eq key :pipe-arg)
               (setq pipe-arg val))
              (t
               (push (format ":%s %s"
                             (substring (symbol-name key) 1)
                             val)
                     kv-tail))))
    (string-join
     (delq nil (append (list header role)
                       (nreverse positional)
                       (and pipe-arg (list "|" pipe-arg))
                       (nreverse kv-tail)))
     " ")))

(defun ellm--insert-turn (role &rest attrs)
  "Insert a new turn delimiter for ROLE with ATTRS plist.

ATTRS recognises three reserved keywords:

  `:continuation' (non-nil): use `ellm-turn-header-2' so the turn is
    rendered as a continuation of the preceding top-level turn.  Tool
    roles always use the continuation header regardless of this flag.
    The `tool-param' role specifically uses `ellm-turn-header-3'
    (deeper nesting under its parent `tool-call').

  `:arg' STRING (or list of strings): bare positional argument(s)
    inserted between ROLE and the keyword block, e.g. the function name
    on a `tool-call' line.

  `:pipe-arg' STRING: like `:arg' but rendered after a literal `| '
    separator, matching the `>>-| tool-call | TOOL_NAME' style.

All other keywords are serialised in `org-block' style as `:KEY VALUE'
pairs, e.g. `:ts 2025-01-01T00:00:00 :id call_1'."
  (let ((depth (ellm--insert-turn-depth role attrs)))
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (let ((beg (point)))
      (insert (apply #'ellm--get-turn role attrs) "\n")
      (ellm--flush-pending-fold depth)
      (ellm--mark-pending-fold beg role depth))))

(defun ellm--set-turn-header-attrs (position attrs)
  "Set keyword ATTRS on the turn delimiter at POSITION.
ATTRS is an alist of string keys and single-token string values.  Existing
occurrences are replaced, while positional and pipe-delimited title text is
preserved."
  (save-excursion
    (goto-char position)
    (beginning-of-line)
    (when (looking-at ellm-turn-regexp)
      (let* ((beg (point))
             (end (line-end-position))
             (line (buffer-substring-no-properties beg end)))
        (dolist (attr attrs)
          (let ((key (car attr))
                (value (cdr attr)))
            (setq line
                  (replace-regexp-in-string
                   (format "[ \t]+:%s\\(?:[ \t]+[^ \t\n]+\\)?"
                           (regexp-quote key))
                   "" line t t))
            (setq line (concat line " :" key " " value))))
        (let ((inhibit-read-only t))
          (delete-region beg end)
          (insert line))
        (when (fboundp 'font-lock-flush)
          (font-lock-flush beg (line-end-position)))
        t))))

(defun ellm--clear-buffer-keeping-frontmatter ()
  "Clear the conversation, preserving frontmatter and adding an empty user turn."
  (let* ((bounds (ellm--frontmatter-bounds))
         (frontmatter (and bounds
                           (buffer-substring-no-properties
                            (point-min) (nth 1 bounds)))))
    (delete-region (point-min) (point-max))
    (when frontmatter
      (insert frontmatter "\n\n"))
    (ellm-update-todos nil)
    (ellm--insert-turn "user")))

(defun ellm--format-tool-param-value (value)
  "Return a stable buffer representation for tool parameter VALUE."
  (cond
   ((null value) "")
   ((stringp value) value)
   (t (json-serialize value :false-object :json-false :null-object nil))))

(defun ellm--tool-header-title (name params)
  "Return a concise tool title from NAME and PARAMS.
PARAMS is an alist.  Single-line values are rendered as `KEY=VALUE'; multiline
values are omitted because their nested turns remain available when unfolded."
  (let ((parts (list (ellm--tool-header-fragment name))))
    (dolist (param params)
      (let ((value (ellm--format-tool-param-value (cdr param))))
        (unless (string-match-p "[\n\r]" value)
          (setq parts
                (append parts
                        (list (format "%s=%s"
                                      (car param)
                                      (ellm--tool-header-fragment value))))))))
    (truncate-string-to-width
     (string-join parts " ") ellm-tool-header-summary-width nil nil "...")))

(defun ellm--tool-header-fragment (value)
  "Return VALUE as safe single-line turn-header text.
Whitespace is collapsed and colons at token boundaries are escaped so a
display summary cannot be parsed as real turn metadata."
  (let ((text (replace-regexp-in-string
               "[ \t]+" " " (format "%s" value))))
    (setq text (string-replace " :" " \\:" text))
    (if (string-prefix-p ":" text)
        (concat "\\" text)
      text)))

(defun ellm--insert-tool-call-with-params (name id params)
  "Insert a `tool-call' turn for NAME and ID with PARAMS.
PARAMS is an alist of (PARAM-NAME . VALUE).  Each parameter is inserted
as a nested `tool-param' turn so values remain visible and parseable."
  (ellm--insert-turn "tool-call"
                     :pipe-arg (ellm--tool-header-title name params)
                     :id id)
  (dolist (param params)
    (ellm--insert-turn "tool-param" :pipe-arg (format "%s" (car param)))
    (insert (ellm--ensure-newline
             (ellm-tools--transform-tool-result
              name (list param) nil
              (ellm--format-tool-param-value (cdr param)))))))

;;;;;; Outline / folding

;; `outline-regexp' is not used when `outline-search-function' is set, but
;; `outline-level' still reads the current match via `match-string', so we
;; need both the regexp (for the search function to match against) and the
;; level function.

(defun ellm--outline-regexp ()
  "Return the outline heading regexp for `ellm-mode'.
Matches turn delimiter lines (longest first) and Markdown heading lines.
Used unanchored — outline prepends \"^\" internally."
  (concat ellm--turn-delimiter-prefix-regexp ".*\\|#+\\ .*$"))

(defun ellm--outline-level ()
  "Return the outline level for the heading matched at point.
Intended as variable `outline-level' in `ellm-mode' buffers.

Level mapping:
  turn depth 1 (\">-|\")   → level 1
  turn depth 2 (\">>-|\")  → level 2
  turn depth 3 (\">>>-|\") → level 3
  Markdown \"#\"           → level 4
  Markdown \"##\"          → level 5  (and so on)"
  (save-match-data
    (let ((text (or (match-string 0) "")))
      (cond
       ((string-match (concat "\\`\\(" ellm--turn-header-regexp "\\) ") text)
        (ellm--turn-header-depth (match-string 1 text)))
       ((string-match "^\\(#+\\) " text)
        (+ 3 (length (match-string 1 text))))
       (t 1)))))

(defun ellm--outline-match-enabled-p ()
  "Return non-nil if the current outline regexp match is a real heading.
Turn delimiters are always structural.  Markdown headings are ignored
inside fenced code blocks and Markdown-disabled turn bodies."
  (let ((pos (match-beginning 0)))
    (or (save-excursion
          (goto-char pos)
          (save-match-data
            (looking-at ellm-turn-regexp)))
        (not (ellm--markdown-excluded-at-p pos)))))

(defun ellm--outline-search-function (&optional bound move backward looking-at)
  "Markdown-aware heading search for `outline-search-function'.
Searches for turn delimiters and Markdown headings while skipping
Markdown headings inside fenced code blocks and Markdown-disabled turn
bodies.

The four optional arguments follow the `outline-search-function'
contract exactly:
  BOUND    — stop position (nil means no limit).
  MOVE     — if non-nil, move to BOUND on failure instead of staying put.
  BACKWARD — if non-nil, search backward.
  LOOKING-AT — if non-nil, test whether point is on a heading right now."
  (let ((re (concat "^\\(?:" (ellm--outline-regexp) "\\)")))
    (if looking-at
        ;; Test-only mode: is point currently on a heading line?
        (save-excursion
          (forward-line 0)
          (when (and (looking-at re)
                     (ellm--outline-match-enabled-p))
            (set-match-data (match-data))
            t))
      ;; Search mode: find the next/previous heading outside code blocks.
      (let ((search (if backward #'re-search-backward #'re-search-forward))
            (noerror (if move 'move t))
            found)
        (while (and (not found)
                    (funcall search re bound noerror))
          (when (ellm--outline-match-enabled-p)
            (setq found t)))
        found))))

;;;;;; Defun navigation (turns & headings as defuns)

;; Treat every heading line -- a turn delimiter (`ellm-turn-header-1/2/3')
;; or a Markdown heading -- as the start of a "defun".  Wiring this into
;; `beginning-of-defun-function' / `end-of-defun-function' makes all the
;; defun-oriented commands work over turns and headings: `C-M-a' /
;; `C-M-e', `mark-defun', `narrow-to-defun', `bounds-of-thing-at-point'
;; with the `defun' thing, and Evil's section motions (`[[', `]]', `[]',
;; `][', and `evil-{forward,backward}-section-{begin,end}').

(defun ellm--heading-at-point-p ()
  "Return non-nil if point is on a heading line (turn or Markdown).
Headings inside fenced code blocks do not count."
  (save-excursion
    (forward-line 0)
    (ellm--outline-search-function nil nil nil t)))

(defun ellm--outline-level-at-point ()
  "Return the outline level of the heading on the current line."
  (save-excursion
    (forward-line 0)
    (when (ellm--outline-search-function nil nil nil t)
      (ellm--outline-level))))

(defun ellm--blank-separator-heading-at-point-p ()
  "Return non-nil if point is on a heading whose turn separator is blank."
  (save-excursion
    (forward-line 0)
    (and (ellm--outline-search-function nil nil nil t)
         (looking-at ellm-turn-regexp)
         (ellm--blank-separator-p
          (match-string-no-properties 2)
          (ellm--continuation-header-p
           (match-string-no-properties 1))))))

(defun ellm--show-visible-blank-separator-subtrees ()
  "Show visible outline subtrees whose turn separator is intentionally blank."
  (save-excursion
    (goto-char (point-min))
    (while (ellm--outline-search-function nil nil nil)
      (forward-line 0)
      (let ((pos (point)))
        (when (and (not (invisible-p pos))
                   (ellm--blank-separator-heading-at-point-p))
          (outline-show-subtree))
        (goto-char pos)
        (forward-line 1)))))

(defun ellm-outline-cycle (&optional event)
  "Like `outline-cycle', but reveal implementation-detail assistant turns.
When point is itself on such a turn, preserve plain `outline-cycle'
behaviour so the turn can still be cycled directly."
  (interactive (list last-nonmenu-event))
  (let* ((mouse-event (and (mouse-event-p event) event))
         (heading (save-excursion
                    (when mouse-event
                      (mouse-set-point mouse-event))
                    (forward-line 0)
                    (and (ellm--outline-search-function nil nil nil t)
                         (if (looking-at ellm-turn-regexp)
                             (if (ellm--blank-separator-p
                                  (match-string-no-properties 2)
                                  (ellm--continuation-header-p
                                   (match-string-no-properties 1)))
                                 'blank-turn
                               'turn)
                           'markdown)))))
    (outline-cycle mouse-event)
    (when (eq heading 'turn)
      (ellm--show-visible-blank-separator-subtrees))))

(defun ellm-outline-cycle-buffer (&optional level)
  "Like `outline-cycle-buffer', but reveal implementation-detail assistant turns."
  (interactive (list (when current-prefix-arg
                       (prefix-numeric-value current-prefix-arg))))
  (outline-cycle-buffer level)
  (ellm--show-visible-blank-separator-subtrees))

(defun ellm-beginning-of-defun (&optional arg)
  "Move backward to the beginning of the ARG-th preceding heading.
A heading is a turn delimiter or a Markdown heading (outside code
blocks).  Serves as `beginning-of-defun-function'; with negative ARG
moves forward.  Returns non-nil when point moved to a heading."
  (let ((arg (or arg 1))
        (found nil))
    (if (< arg 0)
        (dotimes (_ (- arg))
          (when (ellm--heading-at-point-p)
            (end-of-line))
          (setq found (ellm--outline-search-function nil nil nil))
          (when found (forward-line 0)))
      (dotimes (_ arg)
        (setq found (ellm--outline-search-function nil nil t))
        (when found (forward-line 0))))
    found))

(defun ellm-end-of-defun ()
  "Move forward to the end of the current heading's section.
The section ends just before the next heading (turn or Markdown) or at
end of buffer.  Serves as `end-of-defun-function'."
  (unless (eobp)
    (when (ellm--heading-at-point-p)
      (forward-line 1))
    (if (ellm--outline-search-function nil nil nil)
        (forward-line 0)
      (goto-char (point-max)))))

;;;;; Automatic turn folding

;; Folding is expressed entirely in terms of the outline machinery wired
;; up above (`outline-search-function' / `outline-level'), so folded
;; turns integrate with `outline-cycle' (TAB), `outline-show-all', etc.
;; A single primitive -- `ellm--fold-subtree-at' -- does the actual
;; hiding; everything else (tool calls, reasoning, load-time folding)
;; drives that one primitive so the behaviour never diverges.

(defun ellm--insert-turn-depth (role attrs)
  "Return the outline depth that `ellm--insert-turn' will use for ROLE.
ATTRS is the plist passed to `ellm--insert-turn'."
  (ellm--turn-header-depth (ellm--turn-header-for-role role attrs)))

(defun ellm--clear-pending-fold ()
  "Clear `ellm--pending-fold-turn' and release its marker."
  (when-let* ((marker (car-safe ellm--pending-fold-turn)))
    (set-marker marker nil))
  (setq ellm--pending-fold-turn nil))

(defun ellm--flush-pending-fold (&optional next-level)
  "Fold the pending turn if NEXT-LEVEL closes its outline subtree.
When NEXT-LEVEL is nil, fold any pending turn.  A nested heading does not
close its parent, so it leaves the pending fold in place."
  (pcase-let ((`(,marker ,role ,level) ellm--pending-fold-turn))
    (when (and marker
               (or (null next-level)
                   (<= next-level level)))
      (setq ellm--pending-fold-turn nil)
      (unwind-protect
          (when (marker-buffer marker)
            (ellm--fold-turn-at marker role))
        (set-marker marker nil)))))

(defun ellm--mark-pending-fold (pos role level)
  "Mark the foldable turn at POS as waiting for its following boundary.
ROLE and LEVEL describe the turn at POS.  Non-foldable roles clear no
existing pending fold because nested non-foldable children may belong to
that pending parent."
  (when (ellm--role-should-fold-p role)
    (ellm--clear-pending-fold)
    (setq ellm--pending-fold-turn
          (list (copy-marker pos nil) role level))))

(defun ellm--subtree-end-at-point ()
  "Return the end of the outline subtree whose heading is at point."
  (let ((level (ellm--outline-level-at-point)))
    (save-excursion
      (forward-line 1)
      (catch 'end
        (while (ellm--outline-search-function nil nil nil)
          (forward-line 0)
          (when (<= (ellm--outline-level-at-point) level)
            (throw 'end (point)))
          (forward-line 1))
        (point-max)))))

(defun ellm--fold-region-at (pos subtree-end)
  "Collapse the heading at POS through SUBTREE-END.
Empty or whitespace-only bodies are not folded."
  (save-excursion
    (goto-char pos)
    (when (ignore-errors (outline-back-to-heading t) t)
      (let* ((heading-end (line-end-position))
             (body-beg (min (1+ heading-end) (point-max))))
        (when (save-excursion
                (goto-char (min body-beg subtree-end))
                (re-search-forward "[^[:space:]]" subtree-end t))
          (when (and (> subtree-end heading-end)
                     (eq (char-before subtree-end) ?\n))
            (setq subtree-end (1- subtree-end)))
          (when (> subtree-end heading-end)
            ;; Start at the heading newline so child headings stay hidden,
            ;; but leave the final newline visible.  Hiding that separator
            ;; newline can leave a one-character outline ellipsis overlay
            ;; behind after unfolding.
            (outline-flag-region heading-end subtree-end t)
            t))))))

(defun ellm--fold-subtree-at (pos)
  "Collapse the outline subtree of the heading containing POS."
  (save-excursion
    (goto-char pos)
    (when (ignore-errors (outline-back-to-heading t) t)
      (ellm--fold-region-at (point) (ellm--subtree-end-at-point)))))

(defun ellm--role-should-fold-p (role)
  "Return non-nil if a turn with ROLE should be inserted folded.
Honours `ellm-fold-tool-calls' and `ellm-fold-reasoning-blocks'."
  (cond
   ((member role '("tool-call" "tool-result")) ellm-fold-tool-calls)
   ((equal role "reasoning") (and ellm-fold-reasoning-blocks t))
   (t nil)))

(defun ellm--fold-turn-at (pos role)
  "Fold the subtree of the turn with ROLE at POS, if configured to.
Shared entry point used both for freshly inserted turns and when
folding a loaded buffer.  A no-op when ROLE should not be folded."
  (when (ellm--role-should-fold-p role)
    (ellm--fold-subtree-at pos)))

(defun ellm--fold-configured-turns ()
  "Fold every turn in the buffer that is configured to be folded.
Walks the parsed turns and folds each `tool-call' / `reasoning' turn
according to `ellm-fold-tool-calls' / `ellm-fold-reasoning-blocks'."
  (let* ((turns (ellm--parse-turns))
         (indexed (cl-loop for turn in turns
                           for rest on turns
                           collect (cons turn rest))))
    (pcase-dolist (`(,turn . ,rest) indexed)
      (let ((role (ellm-turn-role turn))
            (depth (ellm-turn-depth turn)))
        (when (and (ellm--role-should-fold-p role)
                   ;; Skip continuation-nested params etc.; only fold the
                   ;; top of a foldable subtree.
                   (not (equal role "tool-param")))
          (let ((subtree-end
                 (or (cl-loop for next in (cdr rest)
                              when (<= (ellm-turn-depth next) depth)
                              return (ellm--turn-delimiter-beg next))
                     (point-max))))
            (ellm--fold-region-at (ellm--turn-delimiter-beg turn)
                                  subtree-end)))))))

;;;; Narrowing

(defun ellm-narrow-to-turn ()
  "Narrow buffer to the outline subtree at point."
  (interactive)
  (save-excursion
    (outline-back-to-heading t)
    (let ((start (point)))
      (outline-end-of-subtree)
      (narrow-to-region (1+ start) (point)))))

(defun ellm-narrow-to-header ()
  "Narrow buffer to the Markdown heading section at point.
Searches backward for the nearest Markdown heading if point is not on
one, then narrows to its outline subtree."
  (interactive)
  (save-excursion
    (forward-line 0)
    ;; If not already on a markdown heading, search backward for one,
    ;; skipping any heading that is inside a code block.
    (unless (and (ellm--outline-search-function nil nil nil t)
                 (looking-at ellm-heading-any-regexp))
      (let (found)
        (while (and (not found)
                    (ellm--outline-search-function nil nil t))
          (when (looking-at ellm-heading-any-regexp)
            (setq found t)))
        (unless found
          (user-error "No Markdown heading found at/near point"))))
    (outline-back-to-heading t)
    (let ((start (point)))
      (outline-end-of-subtree)
      (narrow-to-region start (point)))))

(defun ellm-narrow-dwim ()
  "Narrow to Markdown heading at point, or to turn subtree if not on a heading."
  (interactive)
  (unless (ignore-errors (ellm-narrow-to-header))
    (ellm-narrow-to-turn)))

;;;; Sending

(defconst ellm--request-starting :ellm-request-starting
  "Internal sentinel used while `ellm-send' starts a backend request.")

(defun ellm--ensure-trailing-user-turn ()
  "Signal `user-error' unless the buffer ends with a `user' turn."
  (let* ((turns (ellm--parse-turns))
         (last  (car (last turns))))
    (unless (and last (equal (ellm-turn-role last) "user"))
      (user-error "ellm: last turn must be `user' (got %s)"
                  (if last (ellm-turn-role last) "no turns")))))

(defun ellm-send ()
  "Send the conversation to the configured provider and stream the reply.

The buffer must end in a `user' turn.  An `assistant' turn is appended
and the streamed response is inserted into it as it arrives.

Backend implementations decide how provider requests, tool calls, and
results are handled.

Errors during streaming are signalled normally."
  (interactive)
  (ellm--ensure-no-config-in-flight)
  (when ellm--active-request
    (user-error "ellm: a request is already in flight; M-x ellm-cancel"))
  (ellm--ensure-trailing-user-turn)
  (setq ellm--request-finished-notified-p nil)
  (let* ((fm       (ellm--parse-frontmatter))
         (provider (ellm--resolve-provider fm))
         (buf      (current-buffer))
         (started-at (ellm--now))
         (user-turn (car (last (ellm--parse-turns))))
         request)
    (ellm--set-turn-header-attrs
     (ellm--turn-delimiter-beg user-turn)
     `(("ts" . ,(ellm--timestamp started-at))))
    (setq ellm--request-start-time started-at)
    (ellm--persistence-checkpoint)
    (ellm--insert-turn "assistant")
    (setq ellm--request-assistant-marker
          (save-excursion
            (goto-char (point-max))
            (forward-line -1)
            (let ((marker (point-marker)))
              (set-marker-insertion-type marker nil)
              marker)))
    (ellm--set-active-request ellm--request-starting)
    (condition-case err
        (progn
          (setq request (ellm-backend-send provider fm buf))
          ;; Some backends can complete synchronously while `ellm-backend-send' is
          ;; still on the stack.  In that case completion already cleared
          ;; `ellm--active-request'; do not resurrect a stale request handle here.
          (when (eq ellm--active-request ellm--request-starting)
            (ellm--set-active-request request))
          (unless ellm--active-request
            (ellm--persistence-checkpoint)
            (ellm--notify-request-finished)))
      (error
       (ellm--set-active-request nil)
       (ellm--persistence-checkpoint)
       (ellm--notify-request-finished)
       (signal (car err) (cdr err))))))

(defun ellm-cancel (&optional quiet)
  "Cancel the in-flight LLM request for this buffer, if any.
If QUIET is non-nil, then do not print any messages."
  (interactive)
  (if (not ellm--active-request)
      (unless quiet
        (message "ellm: no active request"))
    (ellm-backend-cancel ellm--active-request)
    (ellm--set-active-request nil)
    (ellm--persistence-checkpoint)
    (ellm--notify-request-finished)
    (unless quiet
      (message "ellm: request cancelled"))))

;;;; Configuration

(defun ellm--ensure-no-config-in-flight ()
  "Signal when a live configuration change is still being applied."
  (when ellm--config-in-flight
    (user-error "ellm: configuration is still being applied")))

(defun ellm--config-path-string (path)
  "Return dotted display text for frontmatter PATH."
  (mapconcat (lambda (key) (if (symbolp key) (symbol-name key) key))
             path "."))

(defun ellm--config-effect-label (effect)
  "Return a concise display label for config EFFECT."
  (pcase effect
    ('live "applies now")
    ('next-send "next send")
    ('new-session "new session")
    (_ "unsupported")))

(defun ellm--config-entry-children (spec)
  "Return resolved child entries from frontmatter SPEC."
  (let ((children (plist-get spec :children)))
    (if (functionp children) (funcall children) children)))

(defun ellm--config-settings (provider buffer &optional removal)
  "Return editable settings supported by PROVIDER in BUFFER.
When REMOVAL is non-nil, return only settings currently present in frontmatter."
  (with-current-buffer buffer
    (let ((frontmatter (ellm--parse-frontmatter)))
      (cl-labels
        ((walk (entries prefix)
           (let (result)
             (dolist (entry entries result)
               (let* ((key (car entry))
                      (spec (cdr entry))
                      (path (append prefix (list (intern key))))
                      (children (ellm--config-entry-children spec)))
                 (if children
                     (setq result (append result (walk children path)))
                   (let* ((cell (and removal
                                     (ellm--alist-get-nested-cell
                                      frontmatter path)))
                          (effect
                           (or (ellm-provider-config-effect
                                provider path buffer)
                               (and cell 'next-send))))
                     (when (and (plist-get spec :editable)
                                effect
                                (or (not removal) cell))
                       (setq result
                             (append result
                                     (list (list :path path :spec spec
                                                 :effect effect))))))))))))
        (walk (ellm--frontmatter-capf--key-entries nil) nil)))))

(defun ellm--config-current (provider setting frontmatter)
  "Return (PRESENT . VALUE) for SETTING with PROVIDER and FRONTMATTER."
  (let* ((path (plist-get setting :path))
         (spec (plist-get setting :spec))
         (type (plist-get spec :type))
         (cell (ellm--alist-get-nested-cell frontmatter path)))
    (cond
     ((and cell
           (or (cdr cell) (memq type '(boolean list directories mcp))))
      (cons t (cdr cell)))
     ((plist-member spec :current) (cons t (plist-get spec :current)))
     ((plist-member spec :default)
      (let ((value (plist-get spec :default)))
        (cons t (if (functionp value) (funcall value) value))))
     ((equal path '(model))
      (and-let* ((model (ellm-provider-current-model provider)))
        (cons t model))))))

(defun ellm--config-value-label (type value)
  "Return a minibuffer display label for VALUE of TYPE."
  (pcase type
    ('boolean (if (ellm--false-value-p value)
                  "false"
                "true"))
    ('mcp
     (cond
      ((eq value t) "true")
      ((ellm--false-value-p value) "false")
      (t
       (mapconcat (lambda (item) (format "%s" item))
                  (cond ((vectorp value) (append value nil))
                        ((listp value) value)
                        (value (list value)))
                  ", "))))
    ((or 'list 'directories)
     (mapconcat (lambda (item) (format "%s" item))
                (cond ((vectorp value) (append value nil))
                      ((listp value) value)
                      (value (list value)))
                ", "))
    (_ (format "%s" value))))

(defun ellm--config-choice-label (provider setting frontmatter)
  "Return selection label for SETTING using PROVIDER and FRONTMATTER."
  (let* ((current (ellm--config-current provider setting frontmatter))
         (type (plist-get (plist-get setting :spec) :type)))
    (format "%s%s  [%s]"
            (ellm--config-path-string (plist-get setting :path))
            (if current
                (format " (current: %s)"
                        (ellm--config-value-label type (cdr current)))
              "")
            (ellm--config-effect-label (plist-get setting :effect)))))

(defun ellm--config-resolve-candidates (spec property)
  "Return completion candidates from SPEC's PROPERTY."
  (when-let* ((candidate-spec (plist-get spec property)))
    (car (ellm--capf-resolve-values candidate-spec))))

(defun ellm--config-candidate-value (selected candidates)
  "Return typed value represented by SELECTED in CANDIDATES."
  (let ((entry (cl-find selected candidates
                        :key #'ellm--frontmatter-capf--candidate-name
                        :test #'equal)))
    (if (and (consp entry) (plist-member (cdr entry) :value))
        (plist-get (cdr entry) :value)
      selected)))

(defun ellm--config-read-multiple (prompt candidates default require-match)
  "Read multiple CANDIDATES with PROMPT and DEFAULT."
  (let* ((names (mapcar #'ellm--frontmatter-capf--candidate-name candidates))
         (selected (completing-read-multiple
                    prompt names nil require-match nil nil default)))
    (mapcar (lambda (value)
              (ellm--config-candidate-value value candidates))
            selected)))

(defun ellm--config-read-value (provider setting frontmatter)
  "Interactively read a typed value for SETTING."
  (let* ((path (plist-get setting :path))
         (spec (plist-get setting :spec))
         (type (or (plist-get spec :type) 'string))
         (current (ellm--config-current provider setting frontmatter))
         (default (and current (ellm--config-value-label type (cdr current))))
         (prompt (format "%s%s: "
                         (ellm--config-path-string path)
                         (if default (format " (current: %s)" default) "")))
         (values (ellm--config-resolve-candidates spec :values))
         (items (ellm--config-resolve-candidates spec :items)))
    (pcase type
      ('boolean
       (if (equal (completing-read prompt '("true" "false") nil t
                                   nil nil default)
                  "true")
           t
         :false))
      ('enum
       (let* ((candidates values)
              (selected (completing-read
                         prompt
                         (mapcar #'ellm--frontmatter-capf--candidate-name
                                 candidates)
                         nil (and candidates t) nil nil default)))
         (ellm--config-candidate-value selected candidates)))
      ('number (read-number prompt (and current (cdr current))))
      ('integer (truncate (read-number prompt (and current (cdr current)))))
      ('directory (read-directory-name prompt nil default nil))
      ('directories
       (ellm--config-read-multiple prompt nil default nil))
      ('list
       (ellm--config-read-multiple prompt items default (and items t)))
      ('mcp
       (let ((selected (ellm--config-read-multiple
                        prompt (append values items) default nil)))
         (cond
          ((equal selected '(t)) t)
          ((memq t selected)
           (user-error "ellm: `mcp: true' cannot be combined with server names"))
          (t selected))))
      (_ (read-string prompt nil nil default)))))

(defun ellm--config-error-message (error-object)
  "Return readable text for config ERROR-OBJECT."
  (or (and (listp error-object) (plist-get error-object :message))
      (condition-case nil
          (error-message-string error-object)
        (error (format "%s" error-object)))))

(defun ellm--config-finish-message (path status)
  "Report that PATH was persisted with application STATUS."
  (message
   (pcase status
     ('live "ellm: %s applied and saved")
     ('new-session "ellm: %s saved; start a new session to apply it")
     (_ "ellm: %s saved; it will apply on the next send"))
   (ellm--config-path-string path)))

(defun ellm-set-config (&optional remove)
  "Interactively edit a supported setting in the current ellm buffer.
The setting is persisted in frontmatter.  Live backend settings are applied
before persistence; other settings apply on the next send or a new session.
With prefix argument REMOVE, remove the selected frontmatter setting instead."
  (interactive "P")
  (unless (derived-mode-p 'ellm-mode)
    (user-error "ellm: this command requires an ellm buffer"))
  (when ellm--active-request
    (user-error "ellm: cannot change configuration while a request is active"))
  (ellm--ensure-no-config-in-flight)
  (let* ((buffer (current-buffer))
         (frontmatter (ellm--parse-frontmatter)))
    (when ellm--frontmatter-cache-error
      (user-error "ellm: cannot edit malformed frontmatter"))
    (let ((provider (ellm--resolve-provider frontmatter)))
      (when (and (not remove)
                 (ellm-provider-config-metadata-session-start-p provider buffer)
                 (y-or-n-p "Start provider session to load configuration options? "))
        (ellm-provider-prepare-config-metadata provider frontmatter buffer)
        (setq frontmatter (ellm--parse-frontmatter)
              provider (ellm--resolve-provider frontmatter)))
      (let* ((settings (ellm--config-settings provider buffer remove))
           (choices
            (mapcar (lambda (setting)
                      (cons (ellm--config-choice-label
                             provider setting frontmatter)
                            setting))
                    settings)))
      (unless choices
        (user-error "ellm: provider exposes no editable settings"))
      (let* ((selected (completing-read "Setting: " choices nil t))
             (setting (cdr (assoc selected choices)))
             (path (plist-get setting :path))
             (effect (plist-get setting :effect)))
        (if remove
            (progn
              (ellm--delete-frontmatter-value path)
              (message (if (eq effect 'live)
                           "ellm: %s removed; the existing live session is unchanged"
                         "ellm: %s removed")
                       (ellm--config-path-string path)))
          (let ((value (ellm--config-read-value
                        provider setting frontmatter)))
            (when (eq effect 'live)
              (setq ellm--config-in-flight path))
            (condition-case err
                (ellm-provider-apply-config
                 provider path value frontmatter buffer
                 (lambda (status)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (setq ellm--config-in-flight nil)
                       (ellm--set-frontmatter-value path value)
                       (ellm--config-finish-message path (or status effect)))))
                 (lambda (error-object)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (setq ellm--config-in-flight nil)))
                   (message "ellm: failed to set %s: %s"
                            (ellm--config-path-string path)
                            (ellm--config-error-message error-object))))
              (error
               (setq ellm--config-in-flight nil)
               (signal (car err) (cdr err)))))))))))

(defun ellm--command-frontmatter ()
  "Return frontmatter for the current command context, if available."
  (if (derived-mode-p 'ellm-mode)
      (ellm--parse-frontmatter)
    nil))

(defun ellm--command-provider (frontmatter)
  "Return provider for command FRONTMATTER context."
  (let ((provider (if (or frontmatter ellm-provider)
                      (ellm--resolve-provider frontmatter)
                    (and ellm-provider-alist
                         (ellm--provider-entry-provider
                          (cdar ellm-provider-alist))))))
    (unless provider
      (user-error "ellm: no provider configured"))
    provider))

(defun ellm-load-session ()
  "Select a backend session with completion and open it in a new buffer."
  (interactive)
  (ellm--ensure-no-config-in-flight)
  (let* ((fm (ellm--command-frontmatter))
         (provider (ellm--command-provider fm)))
    (ellm-provider-load-session provider fm)))

(defun ellm-start-session ()
  "Start/login the backend session without sending a prompt."
  (interactive)
  (ellm--ensure-no-config-in-flight)
  (when ellm--active-request
    (user-error "ellm: a request is already in flight; M-x ellm-cancel"))
  (let* ((fm (ellm--command-frontmatter))
         (provider (ellm--command-provider fm)))
    (ellm-provider-start-session provider fm (current-buffer))
    (message "ellm: session ready")))

(defun ellm-close-session (&optional prompt-to-clear)
  "Close the backend session associated with the current ellm buffer.
When PROMPT-TO-CLEAR is non-nil, ask whether to clear the conversation while
keeping frontmatter and an empty user prompt."
  (interactive (list t))
  (ellm--ensure-no-config-in-flight)
  (let* ((fm (ellm--command-frontmatter))
         (provider (ellm--command-provider fm)))
    (ellm-provider-close-session provider fm (current-buffer))
    (when (and prompt-to-clear
               (derived-mode-p 'ellm-mode)
               (y-or-n-p
                "Clear buffer, keeping frontmatter? "))
      (ellm--clear-buffer-keeping-frontmatter))))

(defun ellm--close-session-on-kill ()
  "Best-effort session cleanup for `kill-buffer-hook'."
  (let ((ellm--config-in-flight nil))
    (condition-case err
        (ellm-close-session)
      (user-error nil)
      (error
       (message "ellm: session cleanup failed: %s" (error-message-string err))))))

(defun ellm-delete-session (&optional select)
  "Delete an ACP/backend session from session history.
With prefix argument SELECT, choose a session from the backend when supported.
Without SELECT, delete the current buffer's session when it has one."
  (interactive "P")
  (ellm--ensure-no-config-in-flight)
  (let* ((fm (ellm--command-frontmatter))
         (provider (ellm--command-provider fm)))
    (ellm-provider-delete-session provider fm (current-buffer) select)))

;;;; Backend interface

(cl-defgeneric ellm-provider-current-model (provider)
  "Return PROVIDER's current model name, or nil when unknown.")

(cl-defmethod ellm-provider-current-model (_provider)
  "Default model lookup for unknown PROVIDER types."
  nil)

(cl-defgeneric ellm-provider-model-candidates (provider)
  "Return model completion candidates for PROVIDER, or nil when unknown.")

(cl-defmethod ellm-provider-model-candidates (_provider)
  "Default model candidates for unknown PROVIDER types."
  nil)

(cl-defgeneric ellm-provider-reasoning-candidates (provider model buffer)
  "Return reasoning effort candidates for PROVIDER's MODEL in BUFFER.")

(cl-defmethod ellm-provider-reasoning-candidates (_provider _model _buffer)
  "Default reasoning candidates for providers without model metadata."
  nil)

(cl-defgeneric ellm-provider-buffer-model-candidates (provider buffer)
  "Return model completion candidates for PROVIDER in BUFFER.
Backends with session-scoped model lists can use BUFFER to prefer live
session metadata over static provider configuration.")

(cl-defmethod ellm-provider-buffer-model-candidates (provider _buffer)
  "Default buffer model candidates for providers without session metadata."
  (ellm-provider-model-candidates provider))

(cl-defgeneric ellm-provider-with-model (provider model)
  "Return PROVIDER configured to use MODEL where supported.")

(cl-defmethod ellm-provider-with-model (provider _model)
  "Default model setter for unknown PROVIDER types."
  provider)

(cl-defgeneric ellm-provider-prepare-new-buffer
    (provider frontmatter buffer on-ready on-error)
  "Asynchronously prepare PROVIDER for interactive setup in BUFFER.
Call ON-READY when model candidates are available, or ON-ERROR on failure.")

(cl-defmethod ellm-provider-prepare-new-buffer
    (_provider _frontmatter _buffer on-ready _on-error)
  "Default preparation for providers without session setup."
  (funcall on-ready))

(cl-defgeneric ellm-provider-configure-new-buffer
    (provider frontmatter buffer on-ready on-error)
  "Interactively configure PROVIDER after model selection in a new BUFFER.
FRONTMATTER is the parsed YAML frontmatter after the selected model was saved.
Implementations call ON-READY when complete, or ON-ERROR on failure.")

(cl-defmethod ellm-provider-configure-new-buffer
    (_provider _frontmatter _buffer on-ready _on-error)
  "Default new-buffer configuration for providers without dynamic options."
  (funcall on-ready))

(cl-defgeneric ellm-provider-slash-command-candidates (provider buffer)
  "Return slash command completion candidates for PROVIDER and BUFFER.
Candidates may be strings or `(STRING :ann ANN :desc DESC)' entries.")

(cl-defmethod ellm-provider-slash-command-candidates (_provider _buffer)
  "Default slash command candidates for providers without command support."
  nil)

(cl-defgeneric ellm-provider-frontmatter-entries (provider path buffer)
  "Return dynamic frontmatter key entries for PROVIDER under PATH in BUFFER.
PATH is nil for the top level, or a list of frontmatter keys naming a nested
map.  Entries use the same shape as `ellm--frontmatter-keys'.")

(cl-defmethod ellm-provider-frontmatter-entries (_provider _path _buffer)
  "Default dynamic frontmatter entries for providers without extensions."
  nil)

(cl-defgeneric ellm-provider-reasoning-state (provider result)
  "Return durable reasoning state extracted from provider RESULT, or nil.")

(cl-defmethod ellm-provider-reasoning-state (_provider _result)
  "Default reasoning state extractor for providers without opaque state."
  nil)

(cl-defgeneric ellm-provider-restore-reasoning
    (provider prompt summary state)
  "Restore a reasoning turn into PROMPT for PROVIDER.
SUMMARY is the editable turn body and STATE is its validated sidecar plist, or
nil when the state reference is unavailable.")

(cl-defmethod ellm-provider-restore-reasoning
    (_provider _prompt _summary _state)
  "Ignore reasoning turns for providers without restoration support."
  nil)

(cl-defgeneric ellm-provider-config-effect (provider path buffer)
  "Return config application timing for PROVIDER's PATH in BUFFER.
The result is one of `live', `next-send', `new-session', or nil when PATH is
not supported by PROVIDER.")

(cl-defmethod ellm-provider-config-effect (_provider _path _buffer)
  "Default config support for unknown providers."
  nil)

(cl-defgeneric ellm-provider-config-metadata-session-start-p (provider buffer)
  "Return non-nil when PROVIDER needs a session for config metadata in BUFFER.")

(cl-defmethod ellm-provider-config-metadata-session-start-p (_provider _buffer)
  "Default config metadata session predicate."
  nil)

(cl-defgeneric ellm-provider-prepare-config-metadata (provider frontmatter buffer)
  "Prepare PROVIDER's dynamic config metadata for BUFFER synchronously.
FRONTMATTER is BUFFER's parsed frontmatter before preparation.")

(cl-defmethod ellm-provider-prepare-config-metadata
  (_provider _frontmatter _buffer)
  "Default preparation for providers with static config metadata."
  nil)

(cl-defgeneric ellm-provider-apply-config
    (provider path value frontmatter buffer on-ready on-error)
  "Apply VALUE at config PATH for PROVIDER in BUFFER.
FRONTMATTER is the pre-change parsed frontmatter.  Call ON-READY with one of
`live', `next-send', or `new-session' after successful application, or call
ON-ERROR with an error object on failure.")

(cl-defmethod ellm-provider-apply-config
  (provider path _value _frontmatter buffer on-ready _on-error)
  "Report PROVIDER's declared config effect for PATH through ON-READY."
  (funcall on-ready
           (or (ellm-provider-config-effect provider path buffer)
               'next-send)))

(cl-defgeneric ellm-provider-start-session (provider frontmatter buffer)
  "Start PROVIDER's session for BUFFER without sending a prompt.
FRONTMATTER is the parsed YAML frontmatter alist for BUFFER.")

(cl-defmethod ellm-provider-start-session (_provider _frontmatter _buffer)
  "Default session start implementation for providers without sessions."
  (user-error "ellm: provider does not support explicit session start"))

(cl-defgeneric ellm-provider-model-completion-session-start-p (provider buffer)
  "Return non-nil if model completion should offer starting PROVIDER for BUFFER.")

(cl-defmethod ellm-provider-model-completion-session-start-p (_provider _buffer)
  "Default model-completion session prompt predicate."
  nil)

(cl-defgeneric ellm-provider-start-session-for-model-completion
    (provider frontmatter buffer)
  "Start PROVIDER's session for model completion in BUFFER.
Implementations should avoid frontmatter rewrites that would invalidate the
completion-at-point bounds when possible.")

(cl-defmethod ellm-provider-start-session-for-model-completion
    (_provider _frontmatter _buffer)
  "Default model-completion session start implementation."
  nil)

(cl-defgeneric ellm-provider-load-session (provider frontmatter)
  "Interactively select and load a PROVIDER session using FRONTMATTER context.")

(cl-defmethod ellm-provider-load-session (_provider _frontmatter)
  "Default session loading implementation for providers without sessions."
  (user-error "ellm: provider does not support session listing/loading"))

(cl-defgeneric ellm-provider-close-session (provider frontmatter buffer)
  "Close PROVIDER's active session for BUFFER using FRONTMATTER context.")

(cl-defmethod ellm-provider-close-session (_provider _frontmatter _buffer)
  "Default session close implementation for providers without sessions."
  (user-error "ellm: provider does not support session close"))

(cl-defgeneric ellm-provider-delete-session (provider frontmatter buffer &optional select)
  "Delete a PROVIDER session using FRONTMATTER and BUFFER context.
When SELECT is non-nil, implementations may prompt for the session to delete.")

(cl-defmethod ellm-provider-delete-session (_provider _frontmatter _buffer &optional _select)
  "Default session delete implementation for providers without sessions."
  (user-error "ellm: provider does not support session delete"))

(cl-defgeneric ellm-backend-send (provider frontmatter buffer)
  "Send BUFFER's trailing user turn through PROVIDER.
FRONTMATTER is the parsed YAML frontmatter alist for BUFFER.
Implementations should stream into the assistant turn already appended by
`ellm-send' and return a backend-specific request handle suitable for
`ellm-backend-cancel'.")

(cl-defgeneric ellm-backend-cancel (request)
  "Cancel backend-specific REQUEST created by `ellm-backend-send'.")

;;;; Major mode

;;;;; State

(cl-defstruct (ellm-buffer-state (:constructor ellm--make-buffer-state))
  "Buffer state used by `ellm-mode' displays."
  todos
  context-size context-usage
  cost-amount cost-currency)

(defvar-local ellm-buffer-state (ellm--make-buffer-state)
  "State used by the current ellm buffer's displays.")

;;;;; Todos

(defconst ellm--todo-statuses
  '("pending" "in_progress" "completed" "cancelled")
  "Todo statuses understood by `ellm-update-todos'.")

(defconst ellm--todo-priorities '("high" "medium" "low")
  "Todo priorities understood by `ellm-update-todos'.")

(defun ellm--todo-field (todo field)
  "Return FIELD from TODO represented as a plist, alist, or hash table."
  (let ((keyword (intern (concat ":" (symbol-name field))))
        (string-name (symbol-name field)))
    (cond
     ((hash-table-p todo)
      (or (gethash field todo)
          (gethash keyword todo)
          (gethash string-name todo)))
     ((and (listp todo) (keywordp (car todo)))
      (plist-get todo keyword))
     ((listp todo)
      (or (alist-get field todo)
          (alist-get keyword todo)
          (alist-get string-name todo nil nil #'equal))))))

(defun ellm--todo-string (value)
  "Return VALUE as a string suitable for a normalized todo field."
  (cond
   ((stringp value) value)
   ((null value) nil)
   ((symbolp value) (symbol-name value))
   (t (format "%s" value))))

(defun ellm--normalize-todo (todo index)
  "Normalize TODO at INDEX into a plist."
  (let* ((id (ellm--todo-string (ellm--todo-field todo 'id)))
         (content (ellm--todo-string (ellm--todo-field todo 'content)))
         (status (ellm--todo-string (ellm--todo-field todo 'status)))
         (priority (or (ellm--todo-string
                        (ellm--todo-field todo 'priority))
                       "medium")))
    (when (or (not content)
              (string-match-p "\\`[[:space:]]*\\'" content))
      (error "ellm: todo item %d has no content" index))
    (unless (member status ellm--todo-statuses)
      (error "ellm: todo item %d has invalid status: %S" index status))
    (unless (member priority ellm--todo-priorities)
      (error "ellm: todo item %d has invalid priority: %S" index priority))
    (append (when id (list :id id))
            (list :content content :status status :priority priority))))

(defun ellm--normalize-todos (todos)
  "Return TODOS as a list of normalized todo plists."
  (let ((items (cond
                ((vectorp todos) (append todos nil))
                ((listp todos) todos)
                (t (error "ellm: todos must be an array")))))
    (cl-loop for todo in items
             for index from 1
             collect (ellm--normalize-todo todo index))))

(defun ellm--merge-todos (current updates)
  "Merge normalized UPDATES by id into normalized CURRENT todos.
Existing positions are preserved and todos with new or missing ids are
appended in update order."
  (let ((updates-by-id (make-hash-table :test #'equal))
        (current-ids (make-hash-table :test #'equal)))
    (dolist (todo updates)
      (when-let* ((id (plist-get todo :id)))
        (puthash id todo updates-by-id)))
    (dolist (todo current)
      (when-let* ((id (plist-get todo :id)))
        (puthash id t current-ids)))
    (append
     (mapcar (lambda (todo)
               (or (and-let* ((id (plist-get todo :id)))
                     (gethash id updates-by-id))
                   todo))
             current)
     (cl-loop for todo in updates
              for id = (plist-get todo :id)
              unless (and id (gethash id current-ids))
              collect todo))))

(defun ellm-update-todos (todos &optional merge)
  "Update the current ellm buffer's TODOS and refresh its header line.
TODOS may be a vector or list of plists, alists, or hash tables.  Each item
requires `content' and one of the statuses in `ellm--todo-statuses'; `id' is
optional and `priority' defaults to `medium'.

By default TODOS replaces the current list.  When MERGE is non-nil, items
with ids replace matching items in place and new items are appended.  Return
the resulting normalized list."
  (let* ((normalized (ellm--normalize-todos todos))
         (updated (if merge
                      (ellm--merge-todos
                       (ellm-buffer-state-todos ellm-buffer-state)
                       normalized)
                    normalized)))
    (setf (ellm-buffer-state-todos ellm-buffer-state) updated)
    (force-mode-line-update)
    updated))

;;;;; Header line

(defconst ellm--currency-symbols
  '(("USD" . "$")
    ("EUR" . "€")
    ("GBP" . "£")
    ("JPY" . "¥")
    ("CNY" . "¥")
    ("KRW" . "₩")
    ("INR" . "₹")
    ("TRY" . "₺")
    ("RUB" . "₽")
    ("BTC" . "₿"))
  "Currency symbols used in `ellm-mode' header-line status.")

(defun ellm--format-compact-number (number)
  "Return NUMBER in a compact human-readable form."
  (when (numberp number)
    (let* ((abs-number (abs (float number)))
           (formatted
            (cond
             ((< abs-number 1000)
              (format "%.0f" number))
             ((< abs-number 1000000)
              (format "%.1fK" (/ number 1000.0)))
             ((< abs-number 1000000000)
              (format "%.1fM" (/ number 1000000.0)))
             (t
              (format "%.1fB" (/ number 1000000000.0))))))
      (replace-regexp-in-string "\\.0\\([KMB]\\)\\'" "\\1" formatted))))

(defun ellm--format-context-usage (used size)
  "Return a compact context usage string for USED and SIZE tokens."
  (cond
   ((and (numberp used) (numberp size) (> size 0))
    (format "%s/%s (%.1f%%%%)"
            (ellm--format-compact-number used)
            (ellm--format-compact-number size)
            (* (/ (float used) size) 100)))
   ((numberp used)
    (format "%s used" (ellm--format-compact-number used)))))

(defun ellm--currency-symbol (currency)
  "Return display symbol for CURRENCY code, or nil when unknown."
  (and currency
       (cdr (assoc (upcase (format "%s" currency)) ellm--currency-symbols))))

(defun ellm--format-cost (amount currency)
  "Return a compact cost string for AMOUNT and CURRENCY."
  (when (numberp amount)
    (if-let* ((symbol (ellm--currency-symbol currency)))
        (format "%s%.2f" symbol amount)
      (string-join (delq nil (list (format "%.2f" amount)
                                   (and currency (format "%s" currency))))
                    " "))))

(defun ellm--format-todo-progress (todos)
  "Return compact header-line progress and current task for TODOS."
  (when todos
    (let* ((current (or (cl-find "in_progress" todos
                                 :key (lambda (todo) (plist-get todo :status))
                                 :test #'equal)
                        (cl-find "pending" todos
                                 :key (lambda (todo) (plist-get todo :status))
                                 :test #'equal)
                        (car (last
                              (cl-remove-if-not
                               (lambda (todo)
                                 (equal (plist-get todo :status) "completed"))
                               todos)))
                        (car todos)))
           (completed (cl-count "completed" todos
                                :key (lambda (todo) (plist-get todo :status))
                                :test #'equal)))
      (format "[%d/%d] %s" completed (length todos)
              (replace-regexp-in-string
               "%" "%%"
               (replace-regexp-in-string
                "[\n\r\t]+" " " (plist-get current :content))
               t t)))))

(defun ellm--header-line-right-status (text)
  "Return header-line TEXT aligned against the right edge."
  (concat
   (propertize " " 'display
               (if (and (fboundp 'string-pixel-width)
                        (display-graphic-p))
                   `(space :align-to (- right (,(string-pixel-width text))))
                 `(space :align-to (- right ,(+ 1 (string-width text))))))
   text))

(defun ellm--header-line-status ()
  "Return `ellm-mode' header-line status text."
  (let* ((todos (ellm--format-todo-progress
                 (ellm-buffer-state-todos ellm-buffer-state)))
         (usage (ellm--format-context-usage
                  (ellm-buffer-state-context-usage ellm-buffer-state)
                  (ellm-buffer-state-context-size ellm-buffer-state)))
         (cost (ellm--format-cost
                (ellm-buffer-state-cost-amount ellm-buffer-state)
                (ellm-buffer-state-cost-currency ellm-buffer-state)))
         (rhs (string-join (delq nil (list usage cost)) " ")))
    (cond
     ((and todos (not (string-empty-p rhs)))
      (concat todos (ellm--header-line-right-status rhs)))
     (todos todos)
     ((not (string-empty-p rhs))
      (ellm--header-line-right-status rhs)))))

;;;;; Major mode

(defvar ellm-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap outline-cycle] #'ellm-outline-cycle)
    (define-key map [remap outline-cycle-buffer] #'ellm-outline-cycle-buffer)
    (define-key map (kbd "<tab>")
                '(menu-item "" ellm-outline-cycle
                            :filter (lambda (command)
                                      (and (ellm--heading-at-point-p)
                                           command))))
    (define-key map (kbd "<backtab>") #'ellm-outline-cycle-buffer)
    (define-key map (kbd "C-c C-c")   #'ellm-send)
    (define-key map (kbd "C-c C-k")   #'ellm-cancel)
    (define-key map (kbd "C-c C-s")   #'ellm-start-session)
    (define-key map (kbd "C-c C-l")   #'ellm-load-session)
    (define-key map (kbd "C-c C-o")   #'ellm-open-session)
    map)
  "Keymap for `ellm-mode'.")

;;;###autoload
(define-derived-mode ellm-mode text-mode "eLLM"
  "Major mode for LLM interaction buffers."
  (setq-local ellm-buffer-state (ellm--make-buffer-state))
  (unless ellm--base-default-directory
    (setq-local ellm--base-default-directory default-directory))
  (setq-local font-lock-defaults '(ellm-font-lock-keywords t))
  (setq-local font-lock-multiline t)
  (setq-local font-lock-fontify-region-function #'ellm--fontify-region)
  (setq-local font-lock-extend-after-change-region-function
              #'ellm--extend-after-change-region)
  (setq-local header-line-format '((:eval (ellm--header-line-status))))
  (add-hook 'before-change-functions #'ellm--before-change-function nil t)
  (add-hook 'after-change-functions #'ellm--after-change-function nil t)
  (ellm--configure-turn-rules t)
  (add-hook 'post-command-hook #'ellm--reveal-separator-at-point nil t)
  (add-hook 'completion-at-point-functions #'ellm--frontmatter-capf nil t)
  (add-hook 'completion-at-point-functions #'ellm--slash-command-capf nil t)
  (add-hook 'kill-buffer-hook #'ellm--close-session-on-kill nil t)
  (add-hook 'kill-buffer-hook #'ellm--persistence-before-kill nil t)
  (add-hook 'kill-buffer-hook #'ellm--notify-request-finished nil t)
  (setq-local outline-regexp (ellm--outline-regexp))
  (setq-local outline-search-function #'ellm--outline-search-function)
  (setq-local outline-level #'ellm--outline-level)
  (setq-local outline-minor-mode-cycle t)
  ;; Treat every heading (turn delimiter or Markdown heading) as a defun,
  ;; so `beginning-of-defun'/`end-of-defun', `mark-defun',
  ;; `narrow-to-defun', `bounds-of-thing-at-point' with `defun', and
  ;; Evil's section motions all navigate turn-by-turn / heading-by-heading.
  (setq-local beginning-of-defun-function #'ellm-beginning-of-defun)
  (setq-local end-of-defun-function #'ellm-end-of-defun)
  ;; Treat top-level turn delimiters (the lines rendered with a
  ;; horizontal rule above them) as page boundaries so `forward-page' /
  ;; `backward-page' navigate turn-by-turn.
  (setq-local page-delimiter ellm-page-delimiter-regexp)
  (outline-minor-mode 1)
  ;; Cache
  (ellm--rebuild-turn-body-cache)
  (ellm--rebuild-fence-cache)
  ;; Collapse configured turns (tool calls / reasoning) in loaded
  ;; conversations.  Safe here because every turn is already complete.
  (ellm--fold-configured-turns)
  (ellm--persistence-recognize-buffer)
  (ellm--persistence-checkpoint))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.ellm\\'" . ellm-mode))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.elelem\\'" . ellm-mode))

;;;; Footer

(provide 'ellm)
;;; ellm.el ends here
