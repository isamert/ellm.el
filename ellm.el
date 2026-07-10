;;; ellm.el --- Homoiconic agent  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (yaml "0.5.5"))
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
  '((ellm-heading-1 1.6 outline-1)
    (ellm-heading-2 1.4 outline-2)
    (ellm-heading-3 1.25 outline-3)
    (ellm-heading-4 1.15 outline-4)
    (ellm-heading-5 1.1 outline-5)
    (ellm-heading-6 1.05 outline-6))
  "List of (FACE HEIGHT INHERIT) specs for heading faces.")

(defun ellm--apply-heading-rescale (val)
  "Apply heading rescale setting VAL to the heading faces.
No-op for any face that hasn't been defined yet (so this is safe to
call from a defcustom :set before the faces' `defface' forms have run)."
  (pcase-dolist (`(,face ,height ,inherit) ellm--heading-specs)
    (when (facep face)
      (set-face-attribute face nil
                          :height (if val height 'unspecified)
                          :inherit inherit :weight 'bold))))

(defcustom ellm-heading-rescale nil
  "When non-nil, heading faces use different sizes for each level.
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

(defcustom ellm-reveal-separator-at-point t
  "If non-nil, temporarily show the raw delimiter line when point enters it."
  :type 'boolean
  :group 'ellm-visuals)

(defcustom ellm-fold-tool-calls t
  "If non-nil, insert `tool-call' turns folded (collapsed)."
  :type 'boolean
  :group 'ellm-visuals)

(defcustom ellm-fold-reasoning-blocks t
  "If non-nil, insert reasoning turns folded (collapsed).
It can also be the symbol `after', which folds after reasoning is finished."
  :type '(choice (const :tag "Off" nil)
                 (const :tag "On" t)
                 (const :tag "After" after))
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

(defconst ellm-turn-regexp
  (concat "^\\("
          ;; Order matters: longest first so the regex engine prefers
          ;; the most-specific header (`>>>-|') over its prefixes.
          (regexp-quote ellm-turn-header-3) "\\|"
          (regexp-quote ellm-turn-header-2) "\\|"
          (regexp-quote ellm-turn-header-1)
          "\\) \\([a-zA-Z-]+\\)\\(?: | \\)?\\(.*\\)$")
  "Regexp matching turn delimiter lines.
Group 1: header (`ellm-turn-header-1', `ellm-turn-header-2', or
`ellm-turn-header-3'), Group 2: role, Group 3: rest of attributes.")

(defconst ellm-page-delimiter-regexp
  (concat "^"
          (regexp-quote ellm-turn-header-1)
          " ")
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
  "Run BODY without disturbing user point/window positions.
This is intended for asynchronous backend insertions into the current
buffer.  BODY may move point and edit the buffer; visible windows showing
the buffer are restored to the same logical point and window start after
the edit.  BODY runs with `inhibit-read-only' so backend insertions can
update request-locked buffers."
  (declare (indent 0) (debug t))
  `(let* ((ellm--preserve-buffer (current-buffer))
          (ellm--preserve-point (copy-marker (point) nil))
          (ellm--preserve-window-states
           (mapcar (lambda (window)
                     (list window
                           (copy-marker (window-point window) nil)
                           (copy-marker (window-start window) nil)
                           (window-hscroll window)))
                   (get-buffer-window-list (current-buffer) nil t))))
     (unwind-protect
         (let ((inhibit-read-only t))
           (save-current-buffer
             (save-excursion
               ,@body)))
       (unwind-protect
           (when (buffer-live-p ellm--preserve-buffer)
             (with-current-buffer ellm--preserve-buffer
               (when-let* ((pos (marker-position ellm--preserve-point)))
                 (goto-char pos))
               (dolist (state ellm--preserve-window-states)
                 (let ((window (nth 0 state))
                       (point-marker (nth 1 state))
                       (start-marker (nth 2 state))
                       (hscroll (nth 3 state)))
                   (when (and (window-live-p window)
                              (eq (window-buffer window)
                                  ellm--preserve-buffer))
                     (when-let* ((start (marker-position start-marker)))
                       (set-window-start window start t))
                     (when-let* ((point (marker-position point-marker)))
                       (set-window-point window point))
                     (set-window-hscroll window hscroll))))))
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
    (goto-char beg)
    (while (re-search-forward ellm-code-block-regexp end t)
      (let* ((lang (match-string 1))
             (body-beg (match-beginning 2))
             (body-end (match-end 2))
             (mode (ellm--lang-mode lang)))
        (when mode
          (ellm--fontify-region-as mode body-beg body-end))
        (font-lock-append-text-property body-beg body-end 'face 'ellm-block)))))

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
        (let ((mb (match-beginning 0))
              (md (match-data)))
          (cond
           ((ellm--in-code-block-p mb)
            ;; Skip this match and continue searching.
            nil)
           ((when-let* ((bounds (ellm--markdown-disabled-bounds-at mb)))
              (goto-char (min limit (max (point) (cdr bounds))))
              t))
           (t
            (set-match-data md)
            (setq found t)))))
      found)))

(defconst ellm-font-lock-keywords
  `(;; Turn delimiters
    (,ellm-turn-regexp
     (0 'ellm-turn-delimiter t)
     (2 (ellm--role-face (match-string 2)) t))
    ;; Frontmatter delimiter lines (`---' open and close) and YAML body
    ;; are handled by `ellm--fontify-code-blocks'.
    ;; Code block delimiters
    (,ellm-code-block-header-regexp (0 'ellm-code-block-delimiter t))
    (,ellm-code-block-end-regexp (0 'ellm-code-block-delimiter t))
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
;; vector of positions where each ``` fence line begins. The cache lets
;; us:
;;   - decide cheaply whether a change actually touched a fence;
;;   - extend font-lock's region to the surrounding fence pair when it
;;     did, so flipped block-membership is reflected immediately on the
;;     lines below the change.

(defvar-local ellm--fence-positions nil
  "Sorted list of buffer positions (line beginnings) of ``` fence lines.
Maintained by `ellm--update-fences-after-change'.  A nil value means the
cache is uninitialized; call `ellm--rebuild-fence-cache' to populate it.")

(defvar-local ellm--fence-positions-vector []
  "Vector copy of `ellm--fence-positions' for binary-search lookups.")

(defvar-local ellm--fence-cache-valid nil
  "Non-nil when `ellm--fence-positions' is up to date with the buffer.")

(defun ellm--rebuild-fence-cache ()
  "Rebuild `ellm--fence-positions' from buffer contents."
  (save-excursion
    (save-match-data
      (goto-char (point-min))
      (let (positions)
        (while (re-search-forward ellm-code-block-fence-regexp nil t)
          (push (line-beginning-position) positions)
          (forward-line 1))
        (setq ellm--fence-positions (nreverse positions)
              ellm--fence-cache-valid t)
        (ellm--sync-fence-vector)))))

(defvar-local ellm--fence-parity-flipped nil
  "Set non-nil by `ellm--update-fences-after-change' when the most
recent change altered fence count by an odd number.  Read (and cleared)
by `ellm--extend-after-change-region' to decide whether to extend
fontification all the way to `point-max'.")

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
fence count is odd (i.e. the parity of every fence past the change
flipped, swapping code-block membership of every following line)."
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
              (push (line-beginning-position) new-fences)
              (cl-incf added)
              (forward-line 1))
            (when new-fences
              (setq ellm--fence-positions
                    (sort (nconc (nreverse new-fences) ellm--fence-positions)
                          #'<)))
            (ellm--sync-fence-vector)
            (setq ellm--fence-parity-flipped
                  (cl-oddp (+ dropped added)))))))))

(defun ellm--fence-before (pos)
  "Return the largest fence position <= POS, or nil.
Assumes `ellm--fence-positions' is sorted ascending."
  (car (last (seq-take-while (lambda (p) (<= p pos)) ellm--fence-positions))))

(defun ellm--in-code-block-p (&optional pos)
  "Return non-nil if POS (or point) is inside a fenced code block."
  (let* ((target (or pos (point)))
         (vec ellm--fence-positions-vector)
         (lo 0)
         (hi (length vec)))
    (while (< lo hi)
      (let ((mid (/ (+ lo hi) 2)))
        (if (< (aref vec mid) target)
            (setq lo (1+ mid))
            (setq hi mid))))
    (cl-oddp lo)))

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
         (old-end (+ beg old-len)))
    (unless (zerop delta)
      (setq ellm--turn-body-cache
            (mapcar
             (lambda (entry)
               (vector (let ((pos (aref entry 0)))
                         (if (>= pos old-end) (+ pos delta) pos))
                       (let ((pos (aref entry 1)))
                         (if (>= pos old-end) (+ pos delta) pos))
                       (aref entry 2)
                       (aref entry 3)))
             ellm--turn-body-cache))
      (ellm--sync-turn-body-cache-vector))))

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
\(no extension) in the common case where the change didn't touch a ```
fence; otherwise a (BEG . END) cons.

Extension policy:
  - Cache up to date: assumed; `ellm--update-fences-after-change' has
    already run from `after-change-functions' before us.
  - If the change kept the total fence count's parity (added/removed an
    even number of fences), only the local block surrounding the change
    can have flipped: extend to the previous fence (or `point-min') and
    past the next fence (or `point-max').
  - If parity flipped (odd number of fences added/removed), every
    following line's code-block membership flipped too: extend END all
    the way to `point-max'."
  (let* ((line-beg (save-excursion (goto-char beg) (line-beginning-position)))
         (line-end (save-excursion (goto-char end) (line-end-position)))
         ;; Touched a fence line iff:
         ;; - some cached fence is currently on the affected line range
         ;;   (i.e. either survived as-is or was just inserted), or
         ;; - the parity flag is set (we removed one without adding one).
         (touched-fence
          (or ellm--fence-parity-flipped
              (cl-some (lambda (p) (and (>= p line-beg) (<= p line-end)))
                       ellm--fence-positions))))
    (when touched-fence
      (let* ((parity-flipped ellm--fence-parity-flipped)
             (prev (ellm--fence-before (1- line-beg)))
             (next (and (not parity-flipped)
                        (cl-find-if (lambda (p) (> p line-end))
                                    ellm--fence-positions)))
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
          (cons (min new-beg beg) (max new-end end)))))))

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
  (when (and (not ellm--pending-delimiter-deletion)
             (/= beg end))
    (when (ellm--turn-delimiter-in-region-p beg end)
      (setq ellm--pending-delimiter-deletion (cons beg end)))))

(defun ellm--refresh-rules-around (pos &optional window)
  "Rebuild rule overlays in the local neighborhood of POS.
The neighborhood spans from the previous turn delimiter line (or
`point-min') to the next one (or `point-max'), so any merging or
splitting of turns caused by an edit at POS is reflected.

Optional WINDOW determines the rule width."
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
    (ellm--put-turn-rules rb re window)))

(defun ellm--after-change-function (beg end old-len)
  "Update fence cache and rule overlays after a buffer change.
BEG END OLD-LEN are passed by `after-change'."
  (ellm--update-fences-after-change beg end old-len)
  (ellm--update-turn-body-cache-after-change beg end old-len)
  ;; If the deletion intersected a delimiter line, every rule overlay
  ;; that lived inside the deleted range has now collapsed to the
  ;; single post-change point.  Sweep just that point for orphans and
  ;; refresh the local neighborhood.  Insertions, and deletions that
  ;; don't touch a delimiter line, are handled by the normal font-lock
  ;; pass via `ellm--fontify-region'.
  (when ellm--pending-delimiter-deletion
    (setq ellm--pending-delimiter-deletion nil)
    ;; All collapsed rule overlays sit at BEG (== END after deletion).
    ;; `remove-overlays' on a zero-length range still catches overlays
    ;; touching that point.
    (remove-overlays beg (min (1+ end) (point-max)) 'ellm-rule t)
    (ellm--refresh-rules-around beg)))

(defun ellm--code-block-scan-bounds (beg end)
  "Return a (SCAN-BEG . SCAN-END) cons covering whole code blocks for BEG..END.
To avoid that ambiguity we snap the scan range to real block
boundaries using the parity-aware fence cache (`ellm--fence-positions'):
a position is inside a block iff an odd number of fence lines precede
it.
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
              ;; fence so the whole block is scanned in one piece.
              (if (ellm--in-code-block-p end)
                  (let ((closer (cl-find-if (lambda (p) (> p end))
                                            ellm--fence-positions)))
                    (if closer
                        (save-excursion
                          (goto-char closer)
                          (forward-line 1)
                          (point))
                      (point-max)))
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
    (ellm--put-turn-rules beg end)
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
  (remove-overlays beg end 'ellm-rule t)
  (let ((win (or window (ellm--rule-window))))
    (save-excursion
      (goto-char beg)
      (while (re-search-forward ellm-turn-regexp end t)
        (let ((bol (line-beginning-position))
              (header (match-string-no-properties 1)))
          (unless (or (= bol (point-min))
                      (ellm--continuation-header-p header))
            (ellm--make-rule-overlay bol win)))))))

(defun ellm--rebuild-turn-rules (&optional window)
  "Rebuild all rule overlays in the current buffer from scratch.
Used on window resize, where every rule needs its width refreshed.
Cost is O(buffer overlays + buffer size); rule overlays are sparse
(one per top-level turn).

Optional WINDOW determines the rule width; defaults to a window
displaying the current buffer."
  (remove-overlays (point-min) (point-max) 'ellm-rule t)
  (let ((win (or window (ellm--rule-window))))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward ellm-turn-regexp nil t)
        (let ((bol (line-beginning-position))
              (header (match-string-no-properties 1)))
          (unless (or (= bol (point-min))
                      (ellm--continuation-header-p header))
            (ellm--make-rule-overlay bol win)))))))

(defun ellm--update-rules (&optional frame-or-window)
  "Refresh all turn rule widths in ellm buffers visible on FRAME-OR-WINDOW.
Each buffer's rules are sized for the window currently displaying it,
not for the selected window (which may be on an unrelated buffer)."
  (let ((frame (cond
                ((framep frame-or-window) frame-or-window)
                ((windowp frame-or-window) (window-frame frame-or-window))
                (t (selected-frame)))))
    (dolist (win (window-list frame 'no-minibuf))
      (with-current-buffer (window-buffer win)
        (when (derived-mode-p 'ellm-mode)
          (ellm--rebuild-turn-rules win))))))

;;;;;; Pretty separators

(defvar-local ellm--revealed-separator-overlay nil
  "Currently revealed pretty-separator overlay, if any.")

(defun ellm--blank-separator-p (role continuation)
  "Return non-nil if the pretty separator for ROLE/CONTINUATION should be blank.
A continuation `assistant' line collapses to a blank row so it flows
visually from the preceding turn.  All other roles display their glyph."
  (and continuation (equal role "assistant")))

(defun ellm--apply-pretty-separator (ov role continuation)
  "Configure overlay OV as a pretty separator for ROLE.
CONTINUATION is non-nil when the delimiter line uses
`ellm-turn-header-2' (i.e. the turn is a continuation of the preceding
top-level turn).

For continuation `assistant' lines, the overlay blanks the line text by
displaying the empty string, but leaves the trailing newline intact so
the delimiter line still occupies one (blank) row.  The user can move
point onto that row to trigger `ellm-reveal-separator-at-point' and edit
it.  For other roles, the overlay covers just the line text and displays
the role's glyph."
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
             (face (ellm--role-face role)))
        (overlay-put ov 'display (propertize glyph 'face face))))))

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
                     (continuation (ellm--continuation-header-p header))
                     (ov (make-overlay line-beg line-end nil t nil)))
                (ellm--apply-pretty-separator ov role continuation)))))))))

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
                    (match-string-no-properties 1)))
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
            (let ((value (yaml-parse-string body
                                            :object-type 'alist
                                            :sequence-type 'list
                                            :null-object nil
                                            :false-object nil)))
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

(defun ellm--frontmatter-value (key)
  "Return frontmatter KEY from the current buffer.
KEY may be a symbol/string or a list naming a nested path."
  (ellm--alist-get-nested (ellm--parse-frontmatter) key))

(defun ellm--set-frontmatter-value (key &optional value)
  "Set scalar frontmatter KEY to VALUE in the current buffer.
When the buffer has no frontmatter, create one at the beginning.  VALUE is
written as a YAML scalar string.  Nil VALUE deletes KEY.  This ignores
request-time read-only protection."
  (let ((inhibit-read-only t))
    (pcase-let ((fm (ellm--parse-frontmatter))
                (`(_ _ ,beg ,end _) (ellm--frontmatter-bounds)))
      (replace-region-contents
       (or beg (point-min)) (or end (point-min))
       (lambda ()
         (concat (unless beg "---\n")
                 (yaml-encode (ellm--alist-set-nested fm key value))
                 (unless beg "\n---\n\n")))))))

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
     ((null entries)
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

(defconst ellm--frontmatter-keys
  '(("provider"    :ann "provider"
     :desc "Provider name from `ellm-provider-alist'."
     :values ellm--capf-provider-candidates)
    ("model"       :ann "model"
     :desc "Chat model name."
     :values ellm--capf-model-candidates)
    ("system"      :ann "string"
     :desc "System prompt (used when no `system' turn present).")
    ("temperature" :ann "number"
     :desc "Sampling temperature (number).")
    ("max-tokens"  :ann "integer"
     :desc "Max output tokens (integer).")
    ("reasoning"   :ann "level"
     :desc "Reasoning level: light, medium, maximum, none."
     :values (("light" :desc "Prefer a small reasoning budget.")
              ("medium" :desc "Prefer a moderate reasoning budget.")
              ("maximum" :desc "Prefer the largest reasoning budget.")
              ("none" :desc "Disable reasoning when supported.")))
    ("tools"       :ann "list"
     :desc "Tools enabled for this buffer; names from `ellm-tools-list' or `@CATEGORY'."
     :items ellm--capf-tool-candidates)
    ("mcp"         :ann "list|true"
     :desc "MCP servers enabled for this buffer; true means all, names come from `ellm-mcp-servers', and `@CATEGORY' expands categories."
     :values (("true" :desc "Enable every MCP server in `ellm-mcp-servers'."))
     :items ellm--capf-mcp-candidates)
    ("acp" :ann "acp"
     :desc "ACP related configurations."
     :children (("session-id" :ann "string"
                 :desc "ACP session id used to continue an existing session.")
                ("additional-directories" :ann "list"
                 :desc "Additional ACP workspace roots sent on session lifecycle requests.")
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

Candidate lists may contain plain strings or entries of the form
  `(STRING :ann ANN :desc DESC)'.  ANN and DESC are optional.
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
  (pcase-let ((`(_ _ ,contents-beg ,contents-end _) (ellm--frontmatter-bounds)))
    (save-excursion
      (goto-char contents-beg)
      (when (re-search-forward
             "^[ \t]*provider:[ \t]*\\([^#\n]+\\)" contents-end t)
        (string-trim (match-string-no-properties 1) "[ \t\"']+" "[ \t\"']+")))))

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

(defun ellm-new-buffer ()
  "Create a new ellm conversation buffer with optional MODEL."
  (interactive)
  (let ((buf (generate-new-buffer "*ellm*"))
        (provider-name (caar ellm-provider-alist))
        (provider (cdar ellm-provider-alist)))
    (with-current-buffer buf
      (insert (format "---\nprovider: %s\nmodel: %s\ncreated: %s\n---\n\n"
                      (or provider-name "null")
                      (or (ellm-provider-current-model
                           (ellm--provider-entry-provider provider))
                          "null")
                      (ellm--timestamp)))
      (ellm--insert-turn "user" :ts (ellm--timestamp))
      (ellm-mode))
    (switch-to-buffer buf)
    buf))

(defun ellm--timestamp ()
  "Return current ISO 8601 timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%S"))

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

(defun ellm--clear-buffer-keeping-frontmatter ()
  "Clear the conversation, preserving frontmatter and adding an empty user turn."
  (let* ((bounds (ellm--frontmatter-bounds))
         (frontmatter (and bounds
                           (buffer-substring-no-properties
                            (point-min) (nth 1 bounds)))))
    (delete-region (point-min) (point-max))
    (when frontmatter
      (insert frontmatter "\n\n"))
    (ellm--insert-turn "user")))

(defun ellm--format-tool-param-value (value)
  "Return a stable buffer representation for tool parameter VALUE."
  (cond
   ((null value) "")
   ((stringp value) value)
   (t (json-serialize value :false-object :json-false :null-object nil))))

(defun ellm--insert-tool-call-with-params (name id params)
  "Insert a `tool-call' turn for NAME and ID with PARAMS.
PARAMS is an alist of (PARAM-NAME . VALUE).  Each parameter is inserted
as a nested `tool-param' turn so values remain visible and parseable."
  (ellm--insert-turn "tool-call" :pipe-arg name :id id)
  (dolist (param params)
    (ellm--insert-turn "tool-param" :pipe-arg (format "%s" (car param)))
    (insert (ellm--ensure-newline
             (ellm--format-tool-param-value (cdr param))))))

;;;;;; Outline / folding

;; `outline-regexp' is not used when `outline-search-function' is set, but
;; `outline-level' still reads the current match via `match-string', so we
;; need both the regexp (for the search function to match against) and the
;; level function.

(defun ellm--outline-regexp ()
  "Return the outline heading regexp for `ellm-mode'.
Matches turn delimiter lines (longest first) and Markdown heading lines.
Used unanchored — outline prepends \"^\" internally."
  (concat "\\(?:"
          (regexp-quote ellm-turn-header-3) "\\|"
          (regexp-quote ellm-turn-header-2) "\\|"
          (regexp-quote ellm-turn-header-1)
          "\\) .*\\|#+\\ .*$"))

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
       ((string-prefix-p (concat ellm-turn-header-3 " ") text) 3)
       ((string-prefix-p (concat ellm-turn-header-2 " ") text) 2)
       ((string-prefix-p (concat ellm-turn-header-1 " ") text) 1)
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
  (let ((blank-heading (save-excursion
                         (when (mouse-event-p event)
                           (mouse-set-point event))
                         (ellm--blank-separator-heading-at-point-p))))
    (outline-cycle event)
    (unless blank-heading
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
            (outline-flag-region heading-end subtree-end t)))))))

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
  (when ellm--active-request
    (user-error "ellm: a request is already in flight; M-x ellm-cancel"))
  (ellm--ensure-trailing-user-turn)
  (let* ((fm       (ellm--parse-frontmatter))
         (provider (ellm--resolve-provider fm))
         (buf      (current-buffer))
         request)
    (ellm--insert-turn "assistant")
    (ellm--set-active-request ellm--request-starting)
    (condition-case err
        (progn
          (setq request (ellm-backend-send provider fm buf))
          ;; Some backends can complete synchronously while `ellm-backend-send' is
          ;; still on the stack.  In that case completion already cleared
          ;; `ellm--active-request'; do not resurrect a stale request handle here.
          (when (eq ellm--active-request ellm--request-starting)
            (ellm--set-active-request request)))
      (error
       (ellm--set-active-request nil)
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
    (unless quiet
      (message "ellm: request cancelled"))))

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
  (let* ((fm (ellm--command-frontmatter))
         (provider (ellm--command-provider fm)))
    (ellm-provider-load-session provider fm)))

(defun ellm-start-session ()
  "Start/login the backend session without sending a prompt."
  (interactive)
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
  (condition-case err
      (ellm-close-session)
    (user-error nil)
    (error
     (message "ellm: session cleanup failed: %s" (error-message-string err)))))

(defun ellm-delete-session (&optional select)
  "Delete an ACP/backend session from session history.
With prefix argument SELECT, choose a session from the backend when supported.
Without SELECT, delete the current buffer's session when it has one."
  (interactive "P")
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
  "Buffer stats."
  context-size context-usage
  cost-amount cost-currency)

(defvar-local ellm-buffer-state (ellm--make-buffer-state)
  "Buffer stats.")

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

(defun ellm--header-line-status ()
  "Return `ellm-mode' header-line status text."
  (let* ((usage (ellm--format-context-usage
                 (ellm-buffer-state-context-usage ellm-buffer-state)
                 (ellm-buffer-state-context-size ellm-buffer-state)))
         (cost (ellm--format-cost
                (ellm-buffer-state-cost-amount ellm-buffer-state)
                (ellm-buffer-state-cost-currency ellm-buffer-state)))
         (rhs (string-join (delq nil (list usage cost)) " ")))
    (when (and rhs (not (string-empty-p rhs)))
      (concat
       (propertize " " 'display
                   (if (and (fboundp 'string-pixel-width)
                            (display-graphic-p))
                       `(space :align-to (- right (,(string-pixel-width rhs))))
                     `(space :align-to (- right ,(+ 1 (string-width rhs))))))
       rhs))))

;;;;; Major mode

(defvar ellm-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap outline-cycle] #'ellm-outline-cycle)
    (define-key map [remap outline-cycle-buffer] #'ellm-outline-cycle-buffer)
    (define-key map (kbd "<backtab>") #'ellm-outline-cycle-buffer)
    (define-key map (kbd "C-c C-c")   #'ellm-send)
    (define-key map (kbd "C-c C-k")   #'ellm-cancel)
    (define-key map (kbd "C-c C-s")   #'ellm-start-session)
    (define-key map (kbd "C-c C-l")   #'ellm-load-session)
    map)
  "Keymap for `ellm-mode'.")

;;;###autoload
(define-derived-mode ellm-mode text-mode "eLLM"
  "Major mode for LLM interaction buffers."
  (setq-local ellm-buffer-state (ellm--make-buffer-state))
  (setq-local font-lock-defaults '(ellm-font-lock-keywords t))
  (setq-local font-lock-multiline t)
  (setq-local font-lock-fontify-region-function #'ellm--fontify-region)
  (setq-local font-lock-extend-after-change-region-function
              #'ellm--extend-after-change-region)
  (setq-local header-line-format '((:eval (ellm--header-line-status))))
  (add-hook 'before-change-functions #'ellm--before-change-function nil t)
  (add-hook 'after-change-functions #'ellm--after-change-function nil t)
  (add-hook 'window-size-change-functions #'ellm--update-rules nil t)
  (add-hook 'post-command-hook #'ellm--reveal-separator-at-point nil t)
  (add-hook 'completion-at-point-functions #'ellm--frontmatter-capf nil t)
  (add-hook 'completion-at-point-functions #'ellm--slash-command-capf nil t)
  (add-hook 'kill-buffer-hook #'ellm--close-session-on-kill nil t)
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
  (ellm--rebuild-fence-cache)
  (ellm--rebuild-turn-body-cache)
  ;; Collapse configured turns (tool calls / reasoning) in loaded
  ;; conversations.  Safe here because every turn is already complete.
  (ellm--fold-configured-turns))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.ellm\\'" . ellm-mode))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.elelem\\'" . ellm-mode))

;;;; Footer

(provide 'ellm)
;;; ellm.el ends here
