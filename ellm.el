;;; ellm.el --- Homoiconic agent  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (llm "0.30") (yaml "0.5.5"))
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
(require 'outline)
(require 'llm)
(require 'llm-provider-utils)
(require 'llm-models)
(require 'yaml)

;; `llm.el' signals `(not-implemented)' from generic fall-through methods
;; \(see e.g. `llm-chat-streaming' default method) but never registers
;; `not-implemented' as an error symbol via `define-error'.  As a result
;; Emacs reports the cryptic "Invalid error symbol: not-implemented"
;; instead of letting the signal propagate properly.  Register it here
;; so users get a real error message and a usable backtrace.
(unless (get 'not-implemented 'error-conditions)
  (define-error 'not-implemented "Operation is not implemented for this LLM provider"))

;;;; Customization

(defgroup ellm nil
  "LLM interaction buffer."
  :group 'applications)

(defcustom ellm-provider nil
  "Default provider used by `ellm-send'.
A provider object supported by one of ellm's backends.  Built-in support
includes `llm.el' provider objects, e.g. `(make-llm-openai :key \"sk-...\")',
`(make-llm-claude :key ...)', `(make-llm-ollama :chat-model \"llama3\")'.

Used as a fallback when the buffer's frontmatter does not specify a
`provider:' key (resolved through `ellm-provider-alist').  Can also be
set buffer-locally."
  :type '(restricted-sexp :match-alternatives (null recordp))
  :group 'ellm)

(defcustom ellm-provider-alist nil
  "Alist mapping symbolic provider names to provider objects.
The car is a symbol usable from frontmatter as `provider: NAME'.  The
cdr is either:

  - a provider object directly, e.g. `(make-llm-openai :key …)', or
  - a plist `(:provider PROV :models (\"m1\" \"m2\" …))' where the
    optional `:models' list constrains the candidates offered by
    frontmatter `model:' completion.

Example:

  ((openai  . ,(make-llm-openai :key …))
   (claude  . (:provider ,(make-llm-claude :key …)
               :models (\"claude-opus-4\" \"claude-sonnet-4\")))
   (local   . ,(make-llm-ollama :chat-model \"llama3\")))

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

(cl-defstruct (ellm-tool (:include llm-tool)
                         (:constructor ellm-make-tool))
  "An `llm-tool' with an extra CATEGORY slot for grouping in `ellm-tools-list'.
Inherits all `llm-tool' slots; passes `llm-tool-p' so it flows
unchanged into `llm-make-chat-prompt's `:tools' argument."
  category)

(defcustom ellm-tools-list nil
  "List of `ellm-tool' (or `llm-tool') objects available to ellm buffers.

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
  :type '(repeat (restricted-sexp :match-alternatives (llm-tool-p)))
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
  "^[ \t]*``` ?\\([a-zA-Z-]+\\)?\n"
  "Regexp matching the opening line of a fenced code block.
Group 1: language.")

(defconst ellm-code-block-end-regexp
  "^[ \t]*```\n"
  "Regexp matching the closing line of a fenced code block.")

(defconst ellm-code-block-fence-regexp
  "^[ \t]*```"
  "Regexp matching any fenced code block line (open or close).
Anchored at beginning of line; the line may have a language tag after it
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
    (tool-call   :face ellm-role-tool      :glyph "❮ CALL"     :tool t :shade ellm-block)
    (tool-result :face ellm-role-tool      :glyph "❯ RESULT"   :tool t :shade ellm-block)
    (tool-param  :face ellm-role-tool      :glyph "  ↳ PARAM"  :tool t :shade ellm-block)
    (reasoning   :face ellm-role-assistant :glyph "❮ REASONING"        :shade ellm-reasoning))
  "Single source of truth for role metadata.
Each entry is `(ROLE-SYM . PLIST)' where PLIST may include:
  :face   FACE-SYMBOL  Face used for the role's keyword on the delimiter line.
  :glyph  STRING       Display string used in pretty turn separators.
  :tool   BOOL         Non-nil for `tool-call'/`tool-result'/`tool-param'
                       roles, whose bodies are shaded with `ellm-block'.
  :shade  FACE-SYMBOL  Face appended to the role's turn body (see
                       `ellm--fontify-shaded-turns').")

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

(defface ellm-role-system
  '((t :inherit font-lock-warning-face :weight bold))
  "Face for system role."
  :group 'ellm)

(defface ellm-role-tool
  '((t :inherit font-lock-constant-face :weight bold))
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
  "Same as `ellm--lang-mode-cache' but for language names requiring special handling.
Also with this, you can override the default language mode inference logic.")

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

(defun ellm--make-skip-code-matcher (regexp)
  "Return a font-lock matcher function for REGEXP that skips code blocks."
  (lambda (limit)
    (let (found)
      (while (and (not found)
                  (re-search-forward regexp limit t))
        (let ((mb (match-beginning 0))
              (md (match-data)))
          (if (ellm--in-code-block-p mb)
              ;; Skip this match and continue searching.
              nil
            (set-match-data md)
            (setq found t))))
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
    (,(ellm--make-skip-code-matcher "\\*\\*\\([^*]+\\)\\*\\*") (0 'ellm-bold t))
    ;; Italic *text* (not bold)
    (,(ellm--make-skip-code-matcher "\\(?:^\\|[^*]\\)\\(\\*\\([^*]+\\)\\*\\)[^*]") (1 'ellm-italic t))
    ;; Inline code `text`
    (,(ellm--make-skip-code-matcher "`\\([^`\n]+\\)`") (0 'ellm-inline-code t))
    ;; Headings
    (,(ellm--make-skip-code-matcher "^# .*$") (0 'ellm-heading-1 t))
    (,(ellm--make-skip-code-matcher "^## .*$") (0 'ellm-heading-2 t))
    (,(ellm--make-skip-code-matcher "^### .*$") (0 'ellm-heading-3 t))
    (,(ellm--make-skip-code-matcher "^#### .*$") (0 'ellm-heading-4 t))
    (,(ellm--make-skip-code-matcher "^##### .*$") (0 'ellm-heading-5 t))
    (,(ellm--make-skip-code-matcher "^###### .*$") (0 'ellm-heading-6 t))
    ;; Blockquotes
    (,(ellm--make-skip-code-matcher "^> .*$") (0 'ellm-blockquote t))
    ;; List markers
    (,(ellm--make-skip-code-matcher "^\\s-*\\([-*]\\|[0-9]+\\.\\) ") (1 'ellm-list-marker t)))
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
              ellm--fence-cache-valid t)))))

(defvar-local ellm--fence-parity-flipped nil
  "Set non-nil by `ellm--update-fences-after-change' when the most
recent change altered fence count by an odd number.  Read (and cleared)
by `ellm--extend-after-change-region' to decide whether to extend
fontification all the way to `point-max'.")

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
            (setq ellm--fence-parity-flipped
                  (cl-oddp (+ dropped added)))))))))

(defun ellm--fence-before (pos)
  "Return the largest fence position <= POS, or nil.
Assumes `ellm--fence-positions' is sorted ascending."
  (car (last (seq-take-while (lambda (p) (<= p pos)) ellm--fence-positions))))

(defun ellm--in-code-block-p (&optional pos)
  "Return non-nil if POS (or point) is inside a fenced code block."
  (cl-oddp (cl-count-if (lambda (p) (< p (or pos (point)))) ellm--fence-positions)))

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
  (when (and (not ellm--pending-delimiter-deletion)
             (/= beg end))
    (save-excursion
      (goto-char beg)
      (when (re-search-forward ellm-turn-regexp end t)
        (setq ellm--pending-delimiter-deletion (cons beg end))))))

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
            ;; clobbered by font-lock re-runs.
            (unless (and revealed-beg revealed-end
                         (<= revealed-beg line-beg)
                         (<= line-beg revealed-end))
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

;;;;; Frontmatter

(defun ellm--frontmatter-bounds ()
  "Return (BEG . END) of YAML frontmatter, or nil if absent.
BEG is `point-min'; END is the position just after the closing `---'
delimiter line (i.e. the end of the match against
`ellm-frontmatter-regexp')."
  (save-excursion
    (save-match-data
      (goto-char (point-min))
      (when (looking-at ellm-frontmatter-regexp)
        (cons (match-beginning 0) (match-end 0))))))

(defun ellm--parse-frontmatter ()
  "Return alist parsed from the buffer's YAML frontmatter, or nil.
Keys are symbols.  Returns nil when there is no frontmatter or when
parsing fails (a `lwarn' is issued in the latter case)."
  (when-let* ((bounds (ellm--frontmatter-bounds))
              (body   (save-excursion
                        (save-match-data
                          (goto-char (car bounds))
                          (looking-at ellm-frontmatter-regexp)
                          (match-string-no-properties 1)))))
    (condition-case err
        (yaml-parse-string body
                           :object-type 'alist
                           :sequence-type 'list
                           :null-object nil
                           :false-object nil)
      (error
       (lwarn 'ellm :warning "Failed to parse frontmatter: %S" err)
       nil))))

;;;;; LLM chat prompt assembly

(defun ellm--collect-tool-call-args (tool-call-turn following-turns base-prompt)
  "Return (ARGS . TURNS-CONSUMED) for TOOL-CALL-TURN.

Walks FOLLOWING-TURNS for immediately-adjacent depth-3 `tool-param'
turns and turns them into an alist of (ARG-SYMBOL . VALUE).  If no
`tool-param' children are present, falls back to the single-arg form:
the tool-call body is the value of the tool's first declared arg
\(looked up via BASE-PROMPT's `tools' slot, falling back to
`ellm-tools-list').

TURNS-CONSUMED is the count of trailing depth-3 `tool-param' turns that
were consumed."
  (let ((params nil)
        (consumed 0)
        (rest following-turns))
    (while (and rest
                (let ((nx (car rest)))
                  (and (equal (ellm-turn-role nx) "tool-param")
                       (eql (ellm-turn-depth nx) 3))))
      (let* ((p (car rest))
             (pname (alist-get "arg" (ellm-turn-attrs p) nil nil #'equal)))
        (push (cons (intern (or pname "_")) (ellm-turn-content p))
              params))
      (setq rest (cdr rest))
      (cl-incf consumed))
    (let ((args
           (cond
            (params (nreverse params))
            ((not (string-empty-p
                   (string-trim (ellm-turn-content tool-call-turn))))
             (let* ((name (alist-get "arg"
                                     (ellm-turn-attrs tool-call-turn)
                                     nil nil #'equal))
                    (tool (or (cl-find name
                                       (llm-chat-prompt-tools base-prompt)
                                       :key #'llm-tool-name
                                       :test #'equal)
                              (cl-find name ellm-tools-list
                                       :key #'llm-tool-name
                                       :test #'equal)))
                    (arg-name (and tool (llm-tool-args tool)
                                   (plist-get (car (llm-tool-args tool))
                                              :name))))
               (when arg-name
                 (list (cons (intern arg-name)
                             (ellm-turn-content tool-call-turn))))))
            (t nil))))
      (cons args consumed))))

(defun ellm--apply-turns-to-prompt (provider turns prompt)
  "Walk TURNS and append corresponding interactions onto PROMPT.

PROVIDER is required so its `llm-provider-populate-tool-uses' method can
record tool calls in the prompt's provider-specific shape (e.g. Claude
expects a vector of plists with `:type \"tool_use\"' inside the assistant
interaction's content; OpenAI uses a different shape).  Plain text
turns become regular interactions.  Contiguous runs of `tool-call'
turns (each optionally followed by depth-3 `tool-param' children) are
batched into one provider populate call.  Contiguous `tool-result'
turns are batched into one `tool-results' interaction.  Orphan
`tool-param' turns are skipped.

Returns PROMPT (mutated)."
  (let ((rest turns))
    (while rest
      (let* ((turn (car rest))
             (role (ellm-turn-role turn)))
        (cond
         ;; tool-call run
         ((equal role "tool-call")
          (let (tool-uses)
            (while (and rest (equal (ellm-turn-role (car rest)) "tool-call"))
              (let* ((tc (car rest))
                     (attrs (ellm-turn-attrs tc))
                     (name (alist-get "arg" attrs nil nil #'equal))
                     (id (alist-get "id" attrs nil nil #'equal))
                     (collected (ellm--collect-tool-call-args
                                 tc (cdr rest) prompt))
                     (args (car collected))
                     (consumed (cdr collected)))
                (push (make-llm-provider-utils-tool-use
                       :id id :name name :args args)
                      tool-uses)
                ;; Advance past the tool-call and any consumed tool-param children.
                (setq rest (nthcdr (1+ consumed) rest))))
            (llm-provider-populate-tool-uses
             provider prompt (nreverse tool-uses))))
         ;; tool-result run
         ((equal role "tool-result")
          (let (results)
            (while (and rest (equal (ellm-turn-role (car rest)) "tool-result"))
              (let* ((tr (car rest))
                     (attrs (ellm-turn-attrs tr))
                     (id (alist-get "id" attrs nil nil #'equal))
                     (name (alist-get "arg" attrs nil nil #'equal)))
                (push (make-llm-chat-prompt-tool-result
                       :call-id id :tool-name name
                       :result (ellm-turn-content tr))
                      results)
                (setq rest (cdr rest))))
            (llm-provider-utils-append-to-prompt
             prompt nil (nreverse results))))
         ;; orphan tool-param: skip
         ((equal role "tool-param")
          (setq rest (cdr rest)))
         ;; everything else: append a regular interaction
         (t
          (setf (llm-chat-prompt-interactions prompt)
                (append (llm-chat-prompt-interactions prompt)
                        (list (make-llm-chat-prompt-interaction
                               :role (intern role)
                               :content (ellm-turn-content turn)))))
          (setq rest (cdr rest)))))))
  prompt)

(defun ellm--parse-buffer-as-llm-chat (provider)
  "Build an `llm-chat-prompt' from the current buffer for PROVIDER.

PROVIDER's `llm-provider-populate-tool-uses' method is used to record
tool calls in the provider-specific shape it expects on subsequent
sends.

The system prompt is conveyed as an interaction with role `system' at
the front of the interactions list (this is the canonical
representation; `:context' is reserved for plain string context that
providers synthesise into a system prompt themselves).  The system
prompt comes from the first `system' turn in the buffer if present,
else from the frontmatter `system:' value.

Frontmatter keys consumed: `temperature', `max-tokens', `reasoning',
`system', `tools'."
  (let* ((fm          (ellm--parse-frontmatter))
         (turns       (cl-loop for turn in (ellm--parse-turns)
                               unless (equal "reasoning" (ellm-turn-role turn))
                               collect turn))
         (fm-system   (alist-get 'system fm))
         (has-system  (and turns
                           (equal (ellm-turn-role (car turns)) "system")))
         (reasoning   (alist-get 'reasoning fm))
         (tools       (ellm--resolve-tools fm))
         (initial     (and (not has-system) fm-system
                           (list (make-llm-chat-prompt-interaction
                                  :role 'system
                                  :content fm-system))))
         (prompt      (make-llm-chat-prompt
                       :interactions initial
                       :tools        tools
                       :temperature  (alist-get 'temperature fm)
                       :max-tokens   (alist-get 'max-tokens fm)
                       :reasoning    (and reasoning
                                          (intern (format "%s" reasoning))))))
    (ellm--apply-turns-to-prompt provider turns prompt)
    prompt))

;;;;; Provider resolution

(defun ellm--provider-with-model (provider model)
  "Return a copy of PROVIDER with its `chat-model' slot set to MODEL.

The slot is set by attempting `cl-struct-slot-value' on the live
struct rather than by inspecting class metadata, because the latter
can be unreliable across different Emacs/cl-generic load orders
\(e.g. when a parent struct's slots are inherited via `:include').

If PROVIDER doesn't have a `chat-model' slot, the model is silently
ignored and PROVIDER is returned unchanged."
  (ellm-provider-with-model provider model))

(defun ellm--resolve-provider (frontmatter)
  "Return the `llm' provider to use for the current buffer.
Lookup order:
  1. `provider' in FRONTMATTER, looked up in `ellm-provider-alist'.
  2. `ellm-provider' (buffer-local or global).

When FRONTMATTER specifies a `model:', the resolved provider is
shallow-copied with its chat-model slot updated.

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

  - A bare string is matched against `llm-tool-name' equality.
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
                           :key #'llm-tool-name
                           :test #'equal)))
        (if tool (list tool)
          (warn "ellm: tool `%s' not found in `ellm-tools-list'" spec)))))))

;;;;; Frontmatter completion

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
     :values ("light" "medium" "maximum" "none"))
    ("tools"       :ann "list"
     :desc "Tools enabled for this buffer; names from `ellm-tools-list' or `@CATEGORY'."
     :values ellm--capf-tool-candidates))
  "Alist of (KEY . SPEC) for known YAML frontmatter keys.
SPEC is a plist with:
  :ann     Short annotation string, shown inline next to the candidate
           (via `:annotation-function').
  :desc    Longer description, exposed via `:company-doc-buffer' for
           rich documentation popups.
  :values  Either a list of strings (static candidates) or a function
           returning either a list of strings or `(STRINGS . SOURCE)'
           where SOURCE is appended to the value annotation.
Keys without `:values' get only key-side completion.")

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

(defun ellm--extract-chat-model-from-provider (provider)
  (ellm-provider-current-model provider))

(defun ellm--capf-model-candidates ()
  "Return (MODELS . SOURCE) for `model:' frontmatter completion.
MODELS is a list of model name strings.  SOURCE is one of:
  `explicit'   - taken from the alist entry's `:models' list,
  `chat-model' - the resolved provider's `chat-model' slot,
  `generic'    - fallback list of all symbols from `llm-models'."
  (let* ((fm (ignore-errors (ellm--parse-frontmatter)))
         (named (alist-get 'provider fm))
         (sym (and named (if (stringp named) (intern named) named)))
         (entry (and sym (alist-get sym ellm-provider-alist)))
         (explicit (and entry (ellm--provider-entry-models entry)))
         (provider (and entry (ellm--provider-entry-provider entry)))
         (chat-model (ellm--extract-chat-model-from-provider provider)))
    (cond
     (explicit (cons explicit 'explicit))
     (chat-model (cons (list chat-model) 'chat-model))
     (t (cons (mapcar (lambda (m) (symbol-name (llm-model-symbol m)))
                      llm-models)
              'generic)))))

(defun ellm--capf-tool-candidates ()
  "Return list of completion strings for `tools:' frontmatter.
Combines every tool name in `ellm-tools-list' with `@CATEGORY' for each
distinct `category' slot of `ellm-tool' entries."
  (append
   (mapcar #'llm-tool-name ellm-tools-list)
   (mapcar (lambda (cat) (concat "@" cat))
           (delete-dups
            (delq nil (mapcar #'ellm-tool-category ellm-tools-list))))))

(defun ellm--capf-resolve-values (values-spec)
  "Resolve VALUES-SPEC from a `ellm--frontmatter-keys' entry.
Returns (CANDIDATES . SOURCE) where SOURCE may be nil."
  (let ((raw (cond ((functionp values-spec) (funcall values-spec))
                   (t values-spec))))
    (if (and (consp raw) (not (stringp (car raw))) (symbolp (cdr raw)))
        raw
      (cons raw nil))))

(defun ellm--frontmatter-capf--token-bounds-at (pos)
  "Return (BEG . END) of the YAML/JSON-array token at POS.
A token is a run of non-delimiter characters: anything except
whitespace, brackets `[]', braces `{}', commas `,', colons `:',
and double-quotes `\"'.  Double-quoted strings are treated as a
single token (BEG points at the opening `\"', END past the closing
`\"').  Returns nil when POS is not inside any token."
  (save-excursion
    (goto-char pos)
    ;; If point is right on a quote, treat the whole quoted string as the token.
    (cond
     ((eq (char-after) ?\")
      (let ((beg (point)))
        (forward-char 1)
        (when (search-forward "\"" (line-end-position) t)
          (cons beg (point)))))
     ;; Inside a quoted string — back up to the opening quote.
     ((save-excursion
        (let ((q (search-backward "\"" (line-beginning-position) t)))
          (and q
               (not (search-forward "\"" pos t))
               q)))
      (let ((beg (save-excursion
                   (search-backward "\"" (line-beginning-position) t))))
        (goto-char beg)
        (forward-char 1)
        (when (search-forward "\"" (line-end-position) t)
          (cons beg (point)))))
     ;; Bare token (no quotes): a token exists at POS if there is a valid
     ;; token char immediately after OR immediately before point (the latter
     ;; covers the common case of point sitting at the end of the token).
     (t
      (let* ((token-char "^ \t\[\]{},:\"\n")
             (after-tok (and (not (eolp))
                             (not (string-match-p "[ \t\[\]{},:\"\n]"
                                                  (char-to-string (char-after))))))
             (before-tok (and (not (bolp))
                              (not (string-match-p "[ \t\[\]{},:\"\n]"
                                                   (char-to-string (char-before)))))))
        (when (or after-tok before-tok)
          (let ((end (save-excursion
                       (skip-chars-forward token-char)
                       (point)))
                (beg (save-excursion
                       (skip-chars-backward token-char)
                       (point))))
            (cons beg end))))))))

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
        (ellm--frontmatter-capf--token-bounds-at pos)))))

(defun ellm--frontmatter-capf--find-list-key ()
  "Search backward from point for a `KEY:' line that owns the current block list.
A block list item is a line starting with optional whitespace then `- '.
Walk backward past contiguous such lines plus blank lines and return the
key string when a `KEY:' (empty-value) line is found immediately above,
or nil otherwise."
  (save-excursion
    (forward-line 0)
    ;; We are called only when the current line matches `  - ...'.
    ;; Walk backward looking for the owning key.
    (while (and (not (bobp))
                (progn (forward-line -1)
                       (looking-at-p "^[ \t]*-\\|^[ \t]*$"))))
    ;; Now we should be on the `KEY:' line (possibly with trailing spaces).
    (when (looking-at "^[ \t]*\\([a-zA-Z_-]+\\):[ \t]*$")
      (match-string-no-properties 1))))

(defun ellm--frontmatter-capf ()
  "Completion-at-point function for ellm YAML frontmatter.
Completes:
  - YAML keys (from `ellm--frontmatter-keys') at the start of a line
    that does not yet contain a `:',
  - per-key value candidates (see `:values' in `ellm--frontmatter-keys')
    after `KEY: VALUE' (inline, including inside `[...]' arrays),
  - per-key value candidates on block-list item lines (`  - ITEM')
    when the owning `KEY:' line is found immediately above."
  (when (ellm--in-frontmatter-p)
    (let ((orig (point)))
      (save-excursion
        (beginning-of-line)
        (cond
         ((looking-at "^[ \t]*-[ \t]*\\(.*\\)$") ; - <something>
          (let* ((item-beg (match-beginning 1))
                 (item-end (match-end 1))
                 (key (ellm--frontmatter-capf--find-list-key))
                 (spec (and key (cdr (assoc key ellm--frontmatter-keys))))
                 (values-spec (and spec (plist-get spec :values))))
            (when (and values-spec (>= orig item-beg) (<= orig item-end))
              ;; Find the precise token bounds at point so completion replaces
              ;; only the word being typed, not the whole line suffix.
              (let* ((tok (ellm--frontmatter-capf--token-bounds-at orig))
                     (tbeg (or (car tok) orig))
                     (tend (or (cdr tok) orig)))
                (pcase-let ((`(,cands . ,source)
                             (ellm--capf-resolve-values values-spec)))
                  (list tbeg tend cands
                        :exclusive 'no
                        :annotation-function
                        (lambda (_)
                          (if source
                              (format " %s (%s)" key source)
                            (concat " " key)))))))))
         ;; KEY: VALUE (inline) — value-side completion.
         ;; Handles both bare values and inline arrays like ["a", "b"].
         ((looking-at "^[ \t]*\\([a-zA-Z_-]+\\):[ \t]*\\(.*?\\)[ \t]*$")
          (let* ((key (match-string-no-properties 1))
                 (vbeg (match-beginning 2))
                 (vend (match-end 2))
                 (spec (cdr (assoc key ellm--frontmatter-keys)))
                 (values-spec (plist-get spec :values)))
            (when values-spec
              (let* ((tok (ellm--frontmatter-capf--inline-token-at orig vbeg vend))
                     (tbeg (or (car tok) orig))
                     (tend (or (cdr tok) orig)))
                (when (and (>= orig vbeg) (<= orig vend))
                  (pcase-let ((`(,cands . ,source)
                               (ellm--capf-resolve-values values-spec)))
                    (list tbeg tend cands
                          :exclusive 'no
                          :annotation-function
                          (lambda (_)
                            (if source
                                (format " %s (%s)" key source)
                              (concat " " key))))))))))
         ;; No `:' yet — key-side completion.
         ((looking-at "^[ \t]*\\([a-zA-Z_-]*\\)[ \t]*$")
          (let ((kbeg (match-beginning 1))
                (kend (match-end 1)))
            (when (and (>= orig kbeg) (<= orig kend))
              (list kbeg kend
                    (mapcar #'car ellm--frontmatter-keys)
                    :exclusive 'no
                    :annotation-function
                    (lambda (cand)
                      (when-let* ((spec (cdr (assoc cand ellm--frontmatter-keys)))
                                  (ann (plist-get spec :ann)))
                        (concat " " ann)))
                    :company-doc-buffer
                    (lambda (cand)
                      (when-let* ((spec (cdr (assoc cand ellm--frontmatter-keys)))
                                  (desc (plist-get spec :desc)))
                        (with-current-buffer (get-buffer-create " *ellm-doc*")
                          (erase-buffer)
                          (insert desc)
                          (current-buffer))))
                    :exit-function
                    (lambda (_string status)
                      (when (and (memq status '(finished sole exact))
                                 (not (looking-at-p ":")))
                        (insert ": "))))))))))))

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
                      (or (ellm--extract-chat-model-from-provider provider) "null")
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

(defun ellm--get-turn (role &rest attrs)
  (let* ((continuation (or (plist-get attrs :continuation)
                           (ellm--tool-role-p role)))
         (header (cond
                  ((equal role "tool-param") ellm-turn-header-3)
                  (continuation ellm-turn-header-2)
                  (t ellm-turn-header-1)))
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
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  (insert (apply #'ellm--get-turn role attrs) "\n"))

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
          "\\) \\|#+\\ "))

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

(defun ellm--outline-search-function (&optional bound move backward looking-at)
  "Code-block-aware heading search for `outline-search-function'.
Searches for turn delimiters and Markdown headings while skipping any
matches that fall inside a fenced code block.

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
                     (not (ellm--in-code-block-p)))
            (set-match-data (match-data))
            t))
      ;; Search mode: find the next/previous heading outside code blocks.
      (let ((search (if backward #'re-search-backward #'re-search-forward))
            found)
        (while (and (not found)
                    (funcall search re bound (if move t 'move)))
          (unless (ellm--in-code-block-p (match-beginning 0))
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

(defun ellm--fold-subtree-at (pos)
  "Collapse the outline subtree of the heading containing POS."
  (save-excursion
    (goto-char pos)
    (when (ignore-errors (outline-back-to-heading t) t)
      (let ((heading-end (line-end-position))
            (subtree-end (progn (outline-end-of-subtree) (point))))
        ;; When this is the last subtree in the buffer, `outline-end-of-
        ;; subtree' runs all the way to `point-max'.  Folding through the
        ;; final position would swallow anything later appended there
        ;; (e.g. the next streamed turn inserted at `point-max'), which
        ;; is exactly the "results not folded / next turn hidden"
        ;; failure.  Keep the trailing newline outside the fold so new
        ;; content lands in visible territory.
        (when (and (= subtree-end (point-max))
                   (> subtree-end heading-end)
                   (eq (char-before subtree-end) ?\n))
          (setq subtree-end (1- subtree-end)))
        (when (> subtree-end heading-end)
          (outline-flag-region heading-end subtree-end t))))))

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
  (when (and (ellm--role-should-fold-p role)
             (save-excursion
               (goto-char pos)
               (ignore-errors (outline-back-to-heading t))
               (< (line-end-position) (save-excursion
                                        (outline-end-of-subtree)
                                        (point)))))
    (ellm--fold-subtree-at pos)))

(defun ellm--fold-configured-turns ()
  "Fold every turn in the buffer that is configured to be folded.
Walks the parsed turns and folds each `tool-call' / `reasoning' turn
according to `ellm-fold-tool-calls' / `ellm-fold-reasoning-blocks'."
  (dolist (turn (ellm--parse-turns))
    (let ((role (ellm-turn-role turn)))
      (when (and (ellm--role-should-fold-p role)
                 ;; Skip continuation-nested params etc.; only fold the
                 ;; top of a foldable subtree.
                 (not (equal role "tool-param")))
        (ellm--fold-subtree-at (ellm-turn-beg turn))))))

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

(defvar-local ellm--active-request nil
  "Active backend request handle for this buffer, or nil.
Set by `ellm-send' to the object returned by `ellm-backend-send'.
Cleared on completion, error, or cancellation.")

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
results are handled.  The built-in `llm.el' backend preserves the original
tool-call loop: tool calls and results are written into the buffer as
`tool-call' / `tool-result' turns, then ellm re-sends so the model can
react to the results.

Errors during streaming are signalled normally."
  (interactive)
  (when ellm--active-request
    (user-error "ellm: a request is already in flight; M-x ellm-cancel"))
  (ellm--ensure-trailing-user-turn)
  (let* ((fm       (ellm--parse-frontmatter))
         (provider (ellm--resolve-provider fm))
         (buf      (current-buffer)))
    (ellm--insert-turn "assistant")
    (setq ellm--active-request (ellm-backend-send provider fm buf))))

(defun ellm-cancel ()
  "Cancel the in-flight LLM request for this buffer, if any."
  (interactive)
  (if (not ellm--active-request)
      (message "ellm: no active request")
    (ellm-backend-cancel ellm--active-request)
    (setq ellm--active-request nil)
    (message "ellm: request cancelled")))

;;;; Backend interface

(cl-defgeneric ellm-provider-current-model (provider)
  "Return PROVIDER's current model name, or nil when unknown.")

(cl-defmethod ellm-provider-current-model (provider)
  "Default model lookup for providers with a `chat-model' struct slot."
  (let* ((resolved-provider (if (recordp provider)
                                provider
                              (ignore-errors
                                (plist-get provider :provider))))
         (chat-model (and resolved-provider
                          (recordp resolved-provider)
                          (condition-case nil
                              (cl-struct-slot-value
                               (type-of resolved-provider)
                               'chat-model resolved-provider)
                            (error nil)))))
    (when (and (stringp chat-model)
               (not (string-empty-p chat-model))
               (not (equal "unset" chat-model)))
      chat-model)))

(cl-defgeneric ellm-provider-with-model (provider model)
  "Return PROVIDER configured to use MODEL where supported.")

(cl-defmethod ellm-provider-with-model (provider model)
  "Default model setter for providers with a `chat-model' struct slot."
  (if (not (recordp provider))
      provider
    (let ((copy (copy-sequence provider)))
      (condition-case nil
          (progn
            (setf (cl-struct-slot-value (type-of copy) 'chat-model copy) model)
            copy)
        (error provider)))))

(cl-defgeneric ellm-backend-send (provider frontmatter buffer)
  "Send BUFFER's trailing user turn through PROVIDER.
FRONTMATTER is the parsed YAML frontmatter alist for BUFFER.
Implementations should stream into the assistant turn already appended by
`ellm-send' and return a backend-specific request handle suitable for
`ellm-backend-cancel'.")

(cl-defgeneric ellm-backend-cancel (request)
  "Cancel backend-specific REQUEST created by `ellm-backend-send'.")

;;;; Major mode

(defvar ellm-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB")       #'outline-cycle)
    (define-key map (kbd "<backtab>") #'outline-cycle-buffer)
    (define-key map (kbd "C-c C-c")   #'ellm-send)
    (define-key map (kbd "C-c C-k")   #'ellm-cancel)
    map)
  "Keymap for `ellm-mode'.")

;;;###autoload
(define-derived-mode ellm-mode text-mode "eLLM"
  "Major mode for LLM interaction buffers."
  (setq-local font-lock-defaults '(ellm-font-lock-keywords t))
  (setq-local font-lock-multiline t)
  (setq-local font-lock-fontify-region-function #'ellm--fontify-region)
  (setq-local font-lock-extend-after-change-region-function
              #'ellm--extend-after-change-region)
  (add-hook 'before-change-functions #'ellm--before-change-function nil t)
  (add-hook 'after-change-functions #'ellm--after-change-function nil t)
  (add-hook 'window-size-change-functions #'ellm--update-rules nil t)
  (add-hook 'post-command-hook #'ellm--reveal-separator-at-point nil t)
  (add-hook 'completion-at-point-functions #'ellm--frontmatter-capf nil t)
  (setq-local outline-search-function #'ellm--outline-search-function)
  (setq-local outline-level #'ellm--outline-level)
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
  (ellm--rebuild-fence-cache)
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
