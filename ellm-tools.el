;;; ellm-tools.el --- Tool definitions for ellm  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.2
;; Package-Requires: ((emacs "27.1") (async "1.9.9"))
;; Keywords: tools

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

;; Some of the tools and ideas are taken from
;; skissue/llm-tool-collection and adapted.

;;; Code:

(require 'ellm)
(require 'async)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;;;; Customization

(defgroup ellm-tools nil
  "Settings for `ellm-tools'."
  :group 'ellm
  :link '(url-link "https://github.com/isamert/ellm.el"))

(defconst ellm-tools-maximum-timeout (* 15 60)
  "Maximum duration in seconds for a tool call.")

(defcustom ellm-tools-default-timeout ellm-tools-maximum-timeout
  "Default timeout in seconds for asynchronous ellm tools."
  :type 'number
  :group 'ellm-tools)

(defcustom ellm-tools-bash-program "bash"
  "Bash executable used by the `bash' tool."
  :type 'string
  :group 'ellm-tools)

(defcustom ellm-tools-bash-output-character-limit 30000
  "Maximum characters of command output returned by the `bash' tool.
When output exceeds this limit, its beginning and end are retained and the
omitted middle is replaced with a truncation marker."
  :type 'natnum
  :group 'ellm-tools)

(defcustom ellm-tools-git-program "git"
  "Git executable used by the read-only `git' tool."
  :type 'string
  :group 'ellm-tools)

(defconst ellm-tools--default-glob-options
  '("--hidden" "--follow" "--exclude" ".git" "--exclude" "node_modules" "--glob")
  "Default value for `ellm-tools-glob-options'.")

(defcustom ellm-tools-glob-program "fd"
  "Executable used by the `glob' tool."
  :type 'string
  :group 'ellm-tools)

(defcustom ellm-tools-glob-options ellm-tools--default-glob-options
  "Command line options used by the `glob' tool.
By default these are options for fd.  If an option contains `%p' or `%d',
they are replaced with the search pattern and path, respectively, and no
implicit pattern/path arguments are appended.  This makes non-fd commands
possible, for example:

  (setq ellm-tools-glob-program \"find\"
        ellm-tools-glob-options \='(\"%d\" \"-name\" \"%p\" \"-type\" \"f\"))"
  :type '(repeat string)
  :group 'ellm-tools)

(defcustom ellm-tools-grep-program "rg"
  "Executable used by the `grep' tool."
  :type 'string
  :group 'ellm-tools)

(defcustom ellm-tools-grep-glob-options '("--glob" "%s")
  "Arguments used to restrict `grep' to an optional path glob.
Each `%s' in an argument is replaced with the requested glob.  The default is
for ripgrep; GNU grep can use `(\"--include=%s\")'.  Set this to nil when the
configured grep implementation does not support path globs, in which case a
tool call requesting one reports an error."
  :type '(choice (const :tag "Unsupported" nil) (repeat string))
  :group 'ellm-tools)

(defcustom ellm-tools-grep-options
  '("--vimgrep" "--hidden"
    "--glob" "!.git" "--glob" "!node_modules"
    "--glob" "!.cache" "--glob" "!.venv" "--glob" "!venv"
    "--glob" "!.direnv" "--glob" "!.next" "--glob" "!.terraform"
    "--glob" "!__pycache__"
    "--color=never" "--max-columns=2000" "--max-columns-preview")
  "Command line options used by the `grep' tool.
The defaults are for ripgrep.  They search hidden files but exclude common
repository metadata, dependency, cache, and generated-environment directories
so searches remain useful even without ignore files.  `--vimgrep' produces
file:line:column:text output, while `--max-columns=2000' and
`--max-columns-preview' prevent a single very long matching line from
flooding the model context.  If you replace ripgrep or these options, retain
an equivalent per-line output cap in the replacement command.

If an option contains `%p' or `%d', they are replaced with the regex pattern
and path, respectively, and no implicit pattern/path arguments are appended."
  :type '(repeat string)
  :group 'ellm-tools)

(defcustom ellm-tools-file-info-program "file"
  "Executable used to identify file contents before reading them."
  :type 'string
  :group 'ellm-tools)

(defcustom ellm-tools-file-read-program "sed"
  "Executable used to read requested lines from text files."
  :type 'string
  :group 'ellm-tools)

(defcustom ellm-tools-search-result-limit 200
  "Default maximum number of lines returned by file search tools."
  :type 'integer
  :group 'ellm-tools)

(defcustom ellm-tools-websearch-url "https://html.duckduckgo.com/html/"
  "DuckDuckGo HTML endpoint used by the `web_search' tool."
  :type 'string
  :group 'ellm-tools)

(defcustom ellm-tools-websearch-result-limit 5
  "Default maximum number of results returned by the `web_search' tool."
  :type 'integer
  :group 'ellm-tools)

(defcustom ellm-tools-webfetch-user-agent
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36"
  "User-Agent header sent by the `web_fetch' tool."
  :type 'string
  :group 'ellm-tools)

(defcustom ellm-tools-webfetch-character-limit 40000
  "Maximum number of rendered characters returned by `web_fetch'.
The default is roughly 10,000 tokens of typical English text."
  :type 'integer
  :group 'ellm-tools)

(defcustom ellm-tools-webfetch-response-byte-limit 2000000
  "Maximum response body size processed by `web_fetch', in bytes.
This bounds the memory and CPU used to download, decode, parse, and render an
untrusted response before its rendered text can be subject to
`ellm-tools-webfetch-character-limit'.  Larger bodies are truncated before
rendering."
  :type 'integer
  :group 'ellm-tools)

(defcustom ellm-tools-elisp-search-result-limit 50
  "Default maximum number of results returned by the `elisp_search' tool."
  :type 'integer
  :group 'ellm-tools)

(defcustom ellm-tools-elisp-eval-result-character-limit 20000
  "Maximum characters returned for each Elisp evaluation value or output."
  :type 'natnum
  :group 'ellm-tools)

(defcustom ellm-tools-file-edit-shell-program "bash"
  "Shell executable used by `ellm-tools-file-edit-check-shell-syntax'."
  :type 'string
  :group 'ellm-tools)

(defcustom ellm-tools-file-edit-python-program "python"
  "Python executable used by `ellm-tools-file-edit-check-python-syntax'."
  :type 'string
  :group 'ellm-tools)

(defcustom ellm-tools-file-edit-checkers
  '(ellm-tools-file-edit-check-elisp-parens
    ellm-tools-file-edit-check-json)
  "Functions that check files after `files/edit' changes them.

Each function is called with FILE-PATH, BUFFER, and CALLBACK.  FILE-PATH is
an absolute file name, or nil for an unvisited buffer, and BUFFER contains the
edited contents.  A checker
must call CALLBACK with nil when it finds no problem, or a concise diagnostic
string otherwise.  It may do this synchronously or asynchronously, and may
return a cancellation function, timer, or process.  The buffer remains live
until CALLBACK is called.

The default checkers validate Emacs Lisp delimiters and JSON syntax.  The
following opt-in checkers are also provided:

- `ellm-tools-file-edit-check-shell-syntax' runs
  `ellm-tools-file-edit-shell-program' with `-n' for .sh files and files with
  a shell shebang.
- `ellm-tools-file-edit-check-python-syntax' runs
  `ellm-tools-file-edit-python-program -m py_compile' for .py files.

For example, add both optional checkers with:

  (add-to-list \='ellm-tools-file-edit-checkers
               \='ellm-tools-file-edit-check-shell-syntax)
  (add-to-list \='ellm-tools-file-edit-checkers
               \='ellm-tools-file-edit-check-python-syntax)"
  :type '(repeat function)
  :group 'ellm-tools)

;;;; Variables

(defvar ellm-tools-refs '()
  "List of all ellm tools definitions.
This contains a list of symbols that points to tool definition plists.
This is provided so that you can use these tools with `gptel-make-tool'
or `llm-make-tool' etc. via doing something like:

  (mapcar
    (lambda (tool) (apply #\\='gptel-make-tool (symbol-value tool)))
    \='ellm-tools-refs)")

(defcustom ellm-tools-tool-call-start-hook nil
  "Hook run before an ellm tool body starts.
Each function is called with TOOL and ARGS, where TOOL is the tool
definition symbol and ARGS is the positional argument list passed to it."
  :type 'hook
  :group 'ellm-tools)

(defcustom ellm-tools-tool-call-end-hook nil
  "Hook run after an ellm tool finishes.
Each function is called with TOOL, ARGS, ERROR, RAW and RESULT.  RAW is
the pre-transform result; RESULT is the value returned to the model."
  :type 'hook
  :group 'ellm-tools)

(defcustom ellm-subagent-buffer-name-format "*ellm subagent:%s*"
  "Format string used for generated subagent buffer names.
It receives one `%s' argument: the subagent display name or id."
  :type 'string
  :group 'ellm-tools)

(defcustom ellm-subagent-max-depth 2
  "Maximum number of subagent levels below a root conversation.

A root conversation has depth zero.  When a child reaches this depth,
its agent-management tools are removed.  Nil permits unlimited nesting."
  :type '(choice (const :tag "Unlimited" nil)
                 (integer :tag "Levels" 0))
  :group 'ellm-tools)

(defvar-local ellm-subagent-history nil
  "Buffer-local history of subagents launched from this ellm buffer.
Each entry is a plist with serializable values such as `:id',
`:buffer-name', `:name', `:created', `:profile', and `:prompt'.")

(defvar-local ellm-subagent-counter 0
  "Buffer-local counter used to allocate subagent ids.")

(defvar-local ellm-subagent-id nil
  "Subagent id for this ellm buffer, or nil when this buffer is not a subagent.")

(defvar-local ellm-subagent-parent-buffer nil
  "Name of the parent buffer that launched this subagent, or nil.")

(put 'ellm-subagent-id 'permanent-local t)
(put 'ellm-subagent-parent-buffer 'permanent-local t)

(defun ellm-tools--subagent-buffers (&optional descendants)
  "Return live subagent buffers belonging to the current buffer.
When DESCENDANTS is non-nil, include subagents at every depth."
  (let ((pending (list (current-buffer)))
        (seen (list (current-buffer)))
        buffers)
    (while pending
      (let ((parent-name (buffer-name (pop pending))))
        (dolist (buffer (buffer-list))
          (when (and (not (memq buffer seen))
                     (with-current-buffer buffer
                       (equal ellm-subagent-parent-buffer parent-name)))
            (push buffer seen)
            (push buffer buffers)
            (when descendants
              (push buffer pending))))))
    (nreverse buffers)))

(defun ellm-tools--cancel-subagent-requests (_request)
  "Cancel active requests in all descendant subagent buffers."
  (dolist (buffer (ellm-tools--subagent-buffers t))
    (with-current-buffer buffer
      (when ellm--active-request
        (ellm-cancel t)))))

;;;###autoload
(defun ellm-switch-to-subagent-buffer (&optional all-children)
  "Switch to a subagent buffer belonging to the current buffer.
With prefix argument ALL-CHILDREN, offer all descendants, including
children of children.  Without it, offer only direct children."
  (interactive "P")
  (let* ((buffers (ellm-tools--subagent-buffers all-children))
         (names (mapcar #'buffer-name buffers)))
    (unless names
      (user-error "No subagent buffers found"))
    (switch-to-buffer
     (read-buffer
      "Switch to subagent buffer: " nil t
      (lambda (candidate)
        (member (if (consp candidate) (car candidate) candidate)
                names))))))

(cl-defstruct (ellm-tools--elisp-session
               (:constructor ellm-tools--make-elisp-session))
  "One persistent child Emacs owned by an ellm buffer."
  name process pending next-id)

(defvar-local ellm-tools--elisp-sessions nil
  "Map persistent Elisp session names to child session objects.")

;;;; Timeouts

(defun ellm-tools--normalize-timeout (timeout &optional default)
  "Return TIMEOUT or DEFAULT as a permitted tool duration."
  (let ((value (or timeout default ellm-tools-default-timeout)))
    (unless (and (numberp value) (>= value 0))
      (ellm-tools--error "Timeout must be a non-negative number"))
    (when (> value ellm-tools-maximum-timeout)
      (ellm-tools--error "I can't run a tool for more than %d seconds"
                         ellm-tools-maximum-timeout))
    value))

;;;; Retained tool output

(defun ellm-tools--truncation-marker (kind content &optional detail)
  "Retain truncated CONTENT of KIND and return a concise marker.
DETAIL describes the displayed preview when it is useful to the model."
  (if (derived-mode-p 'ellm-mode)
      (let ((id (ellm-tool-output-store kind content)))
        (format "\n[... output truncated%s; full output available with output-id=%S ...]"
                (if detail (concat ": " detail) "") id))
    (format "\n[... output truncated%s ...]"
            (if detail (concat ": " detail) ""))))

;;;; `ellm-deftool' macro

(eval-and-compile
  (defun ellm-tools--blank-p (string)
    "Return non-nil when STRING is nil or empty."
    (or (null string) (string= "" string)))

  (defun ellm-tools--replace-all (replacements string)
    "Replace literal strings in STRING according to REPLACEMENTS.
REPLACEMENTS is an alist of strings."
    (let ((case-fold-search nil))
      (replace-regexp-in-string
       (regexp-opt (mapcar #'car replacements))
       (lambda (match) (cdr (assoc-string match replacements t)))
       string t t)))

  (defun ellm-tools--normalize-name (s)
    (string-replace "-" "_" s))

  (defun ellm-tools--argument-optional-p (arg)
    "Return non-nil when tool argument specification ARG is optional."
    (let ((tail (nthcdr 3 arg)))
      (or (eq (car tail) '&optional)
          (and (eq (car tail) :optional)
               (or (null (cdr tail))
                   (not (memq (cadr tail) '(nil t)))))
          (plist-get tail :optional))))

  (defun ellm-tools--argument-schema-metadata (arg)
    "Return JSON Schema metadata from tool argument specification ARG."
    (let ((tail (nthcdr 3 arg)))
      (when (or (eq (car tail) '&optional)
                (and (eq (car tail) :optional)
                     (or (null (cdr tail))
                         (not (memq (cadr tail) '(nil t))))))
        (setq tail (cdr tail)))
      (cl-loop for (key value) on tail by #'cddr
               unless (eq key :optional)
               append (list key value)))))

(defmacro ellm-deftool (name specs arglist doc &rest body)
  (declare (indent 2))
  (pcase-let* ((`(,category ,tool-name-def) (string-split (symbol-name name) "/"))
               (tool-name (ellm-tools--normalize-name tool-name-def))
               (const-sym (intern (format "ellm-tools/%s-tool" tool-name-def)))
               (arg-names (mapcar #'car arglist))
               (lambda-args
                (let (args optional)
                  (dolist (arg arglist (nreverse args))
                    (when (and (ellm-tools--argument-optional-p arg)
                               (not optional))
                      (push '&optional args)
                      (setq optional t))
                    (push (car arg) args))))
               (async? (plist-get specs :async))
               (timeout-expr
                (cond
                 ((not (plist-member specs :timeout))
                  '(ellm-tools--normalize-timeout ellm-tools-default-timeout))
                 ((plist-get specs :timeout)
                  `(ellm-tools--normalize-timeout ,(plist-get specs :timeout)))
                 (nil)))
               (callback-sym (gensym "callback-"))
               (tool-sym (gensym "tool-"))
               (tool-args-sym (gensym "tool-args-"))
               (raw-sym (gensym "raw-"))
               (result-sym (gensym "result-"))
               (error-sym (gensym "error-"))
               (err-sym (gensym "err-"))
               (timer-sym (gensym "timer-"))
               (timeout-sym (gensym "timeout-"))
               (done-sym (gensym "done-"))
               (cancel-sym (gensym "cancel-"))
               (param-name-replacements
                (seq-mapn
                 #'cons
                 (mapcar (lambda (it) (upcase (symbol-name (nth 0 it)))) arglist)
                 (mapcar (lambda (it) (format
                                       "`%s`"
                                       (ellm-tools--normalize-name (symbol-name (nth 0 it))))) arglist))))
    `(progn
       (defconst ,const-sym
         (list :name ,tool-name
               :description ,(ellm-tools--replace-all
                              param-name-replacements
                              doc)
               :async ,async?
               :args ',(mapcar
                        (lambda (it)
                          (append
                           (list :name (ellm-tools--normalize-name (symbol-name (nth 0 it)))
                                 :type  (intern (string-trim-left (symbol-name (nth 1 it)) ":"))
                                 :optional (ellm-tools--argument-optional-p it)
                                 :description
                                 (ellm-tools--replace-all
                                  param-name-replacements
                                  (nth 2 it)))
                           (ellm-tools--argument-schema-metadata it)))
                        arglist)
               :function #',const-sym
               :category ,category)
         ,(format "Tool definition plist for %s.\n%s" name doc))
       ,(if async?
            `(defun ,const-sym (,callback-sym ,@lambda-args)
               ,doc
               (let* ((,tool-sym ',const-sym)
                      (,tool-args-sym (list ,@arg-names))
                      (,timeout-sym nil)
                      (,done-sym nil)
                      (,timer-sym nil)
                      (,cancel-sym nil)
                      (callback
                       (lambda (,raw-sym &optional ,error-sym)
                         (unless ,done-sym
                           (let ((,result-sym
                                  (ellm-tools--transform-tool-result
                                   ,tool-sym ,tool-args-sym ,error-sym ,raw-sym)))
                             (setq ,done-sym t)
                             (when ,timer-sym
                               (cancel-timer ,timer-sym))
                             (ellm-tools--tool-call-end-hook
                              ,tool-sym ,tool-args-sym ,error-sym
                              ,raw-sym ,result-sym)
                             (funcall ,callback-sym ,result-sym))))))
                 (condition-case ,err-sym
                     (progn
                       (ellm-tools--tool-call-start-hook
                        ,tool-sym ,tool-args-sym)
                       (setq ,timeout-sym ,timeout-expr)
                       (when ,timeout-sym
                         (setq ,timer-sym
                               (run-at-time
                                ,timeout-sym nil
                                (lambda ()
                                  (ellm-tools--cancel-async-handle
                                   ,cancel-sym)
                                  (funcall
                                   callback
                                   (format "Error while calling the tool: timed out after %s seconds"
                                           ,timeout-sym)
                                   t)))))
                       (cl-flet ((callback (,raw-sym)
                                           (funcall callback ,raw-sym)))
                         (setq ,cancel-sym (progn ,@body))))
                   (error
                    (funcall callback
                             (format "Error while calling the tool: %s"
                                     ,err-sym)
                             t)))
                 ,cancel-sym))
          `(defun ,const-sym ,lambda-args
             ,doc
             (let ((,tool-sym ',const-sym)
                   (,tool-args-sym (list ,@arg-names)))
               (condition-case ,err-sym
                   (progn
                     (ellm-tools--tool-call-start-hook
                      ,tool-sym ,tool-args-sym)
                     (let* ((,error-sym nil)
                            (,raw-sym (progn ,@body))
                            (,result-sym
                             (ellm-tools--transform-tool-result
                              ,tool-sym ,tool-args-sym ,error-sym ,raw-sym)))
                       (ellm-tools--tool-call-end-hook
                        ,tool-sym ,tool-args-sym ,error-sym
                        ,raw-sym ,result-sym)
                       ,result-sym))
                 (error
                  (let* ((,error-sym t)
                         (,raw-sym
                          (format "Error while calling the tool: %s"
                                  ,err-sym))
                         (,result-sym
                          (ellm-tools--transform-tool-result
                           ,tool-sym ,tool-args-sym ,error-sym ,raw-sym)))
                    (ellm-tools--tool-call-end-hook
                     ,tool-sym ,tool-args-sym ,error-sym
                     ,raw-sym ,result-sym)
                    ,result-sym))))))
       (cl-pushnew ',const-sym ellm-tools-refs)
       (setq ellm-tools-list
             (cl-remove-if (lambda (it) (equal (ellm-tool-name it) ,tool-name))
                           ellm-tools-list))
       (push (apply #'ellm-make-tool ,const-sym) ellm-tools-list))))

;;;; Tool lifecycle

(defun ellm-tools--tool-call-start-hook (tool args)
  "Run `ellm-tools-tool-call-start-hook' for TOOL with ARGS."
  (run-hook-with-args 'ellm-tools-tool-call-start-hook tool args))

(defun ellm-tools--tool-call-end-hook (tool args error? raw result)
  "Run `ellm-tools-tool-call-end-hook' for TOOL completion."
  (condition-case err
      (run-hook-with-args
       'ellm-tools-tool-call-end-hook tool args error? raw result)
    (error
     (message "ellm-tools: tool end hook error: %s"
              (error-message-string err)))))

(defun ellm-tools--cancel-async-handle (handle)
  "Best-effort cancellation for async tool HANDLE."
  (condition-case nil
      (cond
       ((processp handle)
        (when (process-live-p handle)
          (kill-process handle)))
       ((timerp handle)
        (cancel-timer handle))
       ((functionp handle)
        (funcall handle)))
    (error nil)))

(defun ellm-tools--error (reason &rest args)
  (if args
      (apply #'error reason args)
    (error reason))
  )

(defun ellm-tools--success (result &rest args)
  (if args
      (apply #'format result args)
    result))

;;;; Tools

;;;;; User input

(defun ellm-tools--ask-question (question)
  "Normalize one `ask' QUESTION specification."
  (let* ((text (ellm--plistish-get question :question))
         (raw-options (ellm--plistish-get question :options))
         (options (cond ((vectorp raw-options) (append raw-options nil))
                        ((listp raw-options) raw-options)
                        ((null raw-options) nil)
                        (t (ellm-tools--error "Ask options must be an array"))))
         (multiple (not (ellm--false-value-p
                         (ellm--plistish-get question :multiple))))
         (custom-value (ellm--plistish-get question :custom))
         (custom (if (null custom-value)
                     t
                   (not (ellm--false-value-p custom-value)))))
    (unless (and (stringp text) (not (string-empty-p text)))
      (ellm-tools--error "Ask question must be a non-empty string"))
    (unless (cl-every #'stringp options)
      (ellm-tools--error "Ask options must contain only strings"))
    (when (and multiple (null options))
      (ellm-tools--error "Ask multiple selection requires options"))
    (list :question text :options options :multiple multiple :custom custom)))

(defun ellm-tools--format-ask-result (questions answers)
  "Format QUESTIONS and their ANSWERS as plain text for the model."
  (mapconcat
   #'identity
   (cl-mapcar (lambda (question answer)
                (format "Question: %s\nAnswer: %s"
                        (plist-get question :question)
                        (string-join answer ", ")))
              questions answers)
   "\n\n"))

(ellm-deftool user/ask (:async t :timeout nil)
  ((questions
    :array "Questions to ask."
    :items
    (:type object
     :properties
     (:question (:type string
                 :description "The question to ask the user.")
      :options (:type array
                :items (:type string)
                :description "Suggested answers.")
      :multiple (:type boolean
                 :description "Whether more than one answer may be selected.")
      :custom (:type boolean
               :description "Whether input outside `options` is accepted."))
     :required ["question"])))
  "Ask the user one or more QUESTIONS and return their answers.

Each question has a required non-empty `question` string.  It may have an
`options` array of strings, `multiple` to allow more than one selection, and
`custom` to allow input outside the options (default true).  Omit `options`
for free-form text.  Do not add an \"Other\" option: custom input is handled
by the user interface."
  (unless (derived-mode-p 'ellm-mode)
    (ellm-tools--error "Ask must run in an ellm conversation buffer"))
  (unless ellm--active-request
    (ellm-tools--error "Ask requires an active ellm request"))
  (let* ((raw-questions (if (vectorp questions) (append questions nil) questions))
         (normalized (mapcar #'ellm-tools--ask-question raw-questions))
         (answers (make-vector (length normalized) nil))
         (remaining (length normalized))
         cancelled)
    (unless normalized
      (ellm-tools--error "Ask requires at least one question"))
    (let ((ellm--inhibit-user-prompt-activation t))
      (cl-loop for question in normalized
               for index from 0
               do (let ((index index))
                    (ellm--request-user-prompt
                     ellm--active-request
                     (list :kind 'question
                           :title "Agent question"
                           :message (plist-get question :question)
                           :options (mapcar (lambda (option)
                                              (list :id option :label option))
                                            (plist-get question :options))
                           :multiple (plist-get question :multiple)
                           :custom (plist-get question :custom))
                     (lambda (outcome)
                       (when (eq (plist-get outcome :status) 'cancelled)
                         (setq cancelled t))
                       (aset answers index
                             (let ((value (plist-get outcome :value)))
                               (if (listp value) value (list value))))
                       (cl-decf remaining)
                       (when (zerop remaining)
                         (funcall callback
                                  (if cancelled
                                      "The user cancelled the questions."
                                    (ellm-tools--format-ask-result
                                     normalized (append answers nil)))))))))
      (ellm--activate-next-user-prompt))
    nil))

;;;;; Shell

(ellm-deftool shell/bash (:async t :timeout timeout)
  ((command :string "The Bash command to run.")
   (timeout :number "Maximum seconds to allow the command to run. Omit to use the standard limit." &optional))
  "Run COMMAND with Bash and return its exit code and output.
Standard output and standard error are combined.  The command runs with no
standard input in the conversation working directory."
  (let* ((default-directory (ellm-tools--default-directory))
         (limit ellm-tools-bash-output-character-limit)
         (full-buffer (generate-new-buffer " *ellm bash output*"))
         (conversation (current-buffer))
         (head-limit (/ (+ limit 1) 2))
         (tail-limit (/ limit 2))
         (proc
          (make-process
           :name "ellm-tools-bash"
           :command (list ellm-tools-bash-program "-c" command)
           :connection-type 'pipe
           :noquery t
           :filter
           (lambda (process chunk)
             (with-current-buffer full-buffer
               (insert chunk))
             (let* ((total (+ (or (process-get process 'ellm-total) 0)
                              (length chunk)))
                    (output (concat (or (process-get process 'ellm-output) "")
                                    chunk)))
               (process-put process 'ellm-total total)
               (if (process-get process 'ellm-truncated)
                   (process-put process 'ellm-output
                                (substring output (max 0 (- (length output)
                                                            tail-limit))))
                 (if (<= total limit)
                     (process-put process 'ellm-output output)
                   (process-put process 'ellm-truncated t)
                   (process-put process 'ellm-head
                                (substring output 0 head-limit))
                   (process-put process 'ellm-output
                                (substring output (- tail-limit)))))))
           :sentinel
           (lambda (process _event)
             (with-current-buffer conversation
               (when (memq (process-status process) '(exit signal))
                 (let* ((tail (or (process-get process 'ellm-output) ""))
                        (total (or (process-get process 'ellm-total) 0))
                        (output
                         (if (process-get process 'ellm-truncated)
                             (let ((marker
                                    (ellm-tools--truncation-marker
                                     "bash"
                                     (with-current-buffer full-buffer (buffer-string))
                                     (format "%d characters omitted; showing beginning and end"
                                             (- total head-limit tail-limit)))))
                               (kill-buffer full-buffer)
                               (concat (process-get process 'ellm-head) marker "\n" tail))
                           (kill-buffer full-buffer)
                           tail)))
                   (funcall callback
                            (format "Exit code: %d\n%s"
                                    (process-exit-status process) output)))))))))
    (lambda ()
      (when (process-live-p proc)
        (kill-process proc))
      (when (buffer-live-p full-buffer)
        (kill-buffer full-buffer)))))

;;;;; Git

(defun ellm-tools--git-string (value name)
  "Return VALUE as a safe Git argument named NAME."
  (unless (and (stringp value)
               (not (ellm-tools--blank-p value))
               (not (string-prefix-p "-" value))
               (not (string-match-p "\0" value)))
    (ellm-tools--error "%s must be a non-empty argument that does not start with -" name))
  value)

(defun ellm-tools--git-paths (paths)
  "Return PATHS as safe Git path arguments."
  (let ((paths (cond ((null paths) nil)
                     ((vectorp paths) (append paths nil))
                     ((listp paths) paths)
                     (t (ellm-tools--error "paths must be an array")))))
    (mapcar (lambda (path) (ellm-tools--git-string path "path")) paths)))

(defun ellm-tools--git-unused-arguments (operation arguments)
  "Signal when OPERATION was given unsupported ARGUMENTS."
  (when arguments
    (ellm-tools--error "%s does not accept: %s"
                       operation (string-join arguments ", "))))

(defun ellm-tools--git-command
    (operation revision base paths start-line end-line limit)
  "Return Git arguments for the validated read-only OPERATION."
  (let* ((revision (and revision (ellm-tools--git-string revision "revision")))
         (base (and base (ellm-tools--git-string base "base")))
         (paths (ellm-tools--git-paths paths))
         (limit (ellm-tools--normalized-limit limit ellm-tools-search-result-limit))
         (path-arguments (and paths (append (list "--") paths))))
    (pcase operation
      ("status"
       (ellm-tools--git-unused-arguments
        operation (delq nil (list (and revision "revision") (and base "base")
                                  (and paths "paths") (and start-line "start-line")
                                  (and end-line "end-line"))))
       (cons limit '("status" "--porcelain=v1" "--branch" "--untracked-files=normal")))
      ("diff"
       (ellm-tools--git-unused-arguments
        operation (delq nil (list (and start-line "start-line")
                                  (and end-line "end-line"))))
       (cons limit
             (append '("diff" "--no-ext-diff" "--no-textconv")
                     (cond ((and base revision) (list base revision))
                           (base (list base))
                           (revision (list revision))
                           (t '("HEAD")))
                     path-arguments)))
      ("log"
       (ellm-tools--git-unused-arguments
        operation (delq nil (list (and base "base") (and start-line "start-line")
                                  (and end-line "end-line"))))
       (cons limit
             (append (list "log" "--no-decorate" (format "--max-count=%d" limit))
                     (and revision (list revision)) path-arguments)))
      ("show"
       (ellm-tools--git-unused-arguments
        operation (delq nil (list (and base "base") (and start-line "start-line")
                                  (and end-line "end-line"))))
       (cons limit
             (append '("show" "--no-ext-diff" "--no-textconv" "--format=fuller")
                     (list (or revision "HEAD")) path-arguments)))
      ("blame"
       (ellm-tools--git-unused-arguments
        operation (delq nil (list (and base "base"))))
       (unless (and (= (length paths) 1)
                    (integerp start-line) (integerp end-line)
                    (> start-line 0) (>= end-line start-line))
         (ellm-tools--error
          "blame requires one path and positive start-line and end-line values"))
       (cons limit
             (append (list "blame" (format "-L%d,%d" start-line end-line))
                     (and revision (list revision))
                     (list "--" (car paths)))))
      ("ls-files"
       (ellm-tools--git-unused-arguments
        operation (delq nil (list (and revision "revision") (and base "base")
                                  (and start-line "start-line")
                                  (and end-line "end-line"))))
       (cons limit (append '("ls-files") path-arguments)))
      (_ (ellm-tools--error "Unsupported git operation: %s" operation)))))

(defun ellm-tools--format-git-result (operation limit exit-code stdout stderr)
  "Format a bounded result from Git OPERATION."
  (if (not (zerop exit-code))
      (ellm-tools--format-command-error "Git" exit-code stdout stderr)
    (let* ((lines (split-string (string-trim-right stdout) "\n" t))
           (total (length lines))
           (shown (seq-take lines limit)))
      (concat
       (format "<git operation=%S lines=%d%s>\n" operation total
               (if (> total limit) " truncated=true" ""))
       (string-join shown "\n")
       (when (> total limit)
         (ellm-tools--truncation-marker
          "git" stdout (format "showing first %d of %d lines" limit total)))
       (unless (string-empty-p (string-trim stderr))
         (format "\n<warnings>\n%s\n</warnings>" (string-trim-right stderr)))
       "\n</git>"))))

(ellm-deftool git/git (:async t)
  ((operation :string "Read-only operation: status, diff, log, show, blame, or ls-files."
              :enum ["status" "diff" "log" "show" "blame" "ls-files"])
   (revision :string "Optional revision for diff, log, show, or blame." &optional)
   (base :string "Optional base revision for diff." &optional)
   (paths :array "Optional paths for diff, log, show, or ls-files." &optional)
   (start-line :integer "Required first line for blame." &optional)
   (end-line :integer "Required last line for blame." &optional)
   (max-results :integer "Maximum output lines. Omit to use the standard limit." &optional))
  "Inspect Git state and history using a fixed read-only operation.
The tool rejects unsupported operations and arbitrary Git arguments."
  (unless (member operation '("status" "diff" "log" "show" "blame" "ls-files"))
    (ellm-tools--error "Unsupported git operation: %s" operation))
  (pcase-let* ((`(,limit . ,arguments)
                (ellm-tools--git-command operation revision base paths start-line end-line
                                         max-results))
               (process-environment
                (cons "GIT_TERMINAL_PROMPT=0"
                      (cons "GIT_OPTIONAL_LOCKS=0" process-environment))))
    (ellm-tools--start-command
     "ellm-tools-git" ellm-tools-git-program
     (append '("--no-pager" "-c" "core.pager=cat" "-c" "color.ui=false"
               "-c" "core.fsmonitor=false")
             arguments)
     (apply-partially #'ellm-tools--format-git-result operation limit)
     callback)))

;;;;; Files

(ellm-deftool files/glob (:async t)
  ((pattern :string "File glob pattern to match, for example `*.el' or `src/**/*.ts'.")
   (path :string "Directory to search. Relative paths are resolved from the conversation working directory. Omit for that directory." &optional)
   (max-results :integer "Maximum number of matching paths to return. Omit to use the standard limit." &optional))
  "Find files matching PATTERN under PATH.
Hidden files are included, while common dependency and repository directories
are excluded."
  (ellm-tools--validate-pattern pattern "pattern")
  (let* ((default-directory (ellm-tools--default-directory))
         (search-path (ellm-tools--search-path path))
         (limit (ellm-tools--normalized-limit
                 max-results ellm-tools-search-result-limit))
         (command (ellm-tools--glob-command pattern search-path)))
    (ellm-tools--start-command
     "ellm-tools-glob" (car command) (cdr command)
     (lambda (exit-code stdout stderr)
       (ellm-tools--format-line-command-result
        "glob" pattern search-path exit-code stdout stderr limit
        "No files matched"))
     callback)))

(ellm-deftool files/grep (:async t)
  ((pattern :string "Regular expression pattern to search for.")
   (path :string "File or directory to search. Relative paths are resolved from the conversation working directory. Omit for that directory." &optional)
   (max-results :integer "Maximum number of matching lines to return. Omit to use the standard limit." &optional)
   (glob :string "Optional path glob restricting searched files, for example `*.el' or `src/**'." &optional))
  "Search file contents for PATTERN under PATH.
Matches are returned as file:line:column:text lines.  GLOB restricts the
files searched."
  (ellm-tools--validate-pattern pattern "pattern")
  (when glob
    (ellm-tools--validate-pattern glob "glob")
    (unless ellm-tools-grep-glob-options
      (ellm-tools--error "The configured grep program does not support path globs")))
  (let* ((default-directory (ellm-tools--default-directory))
         (search-path (ellm-tools--search-path path))
         (limit (ellm-tools--normalized-limit
                 max-results ellm-tools-search-result-limit))
         (command (ellm-tools--grep-command pattern search-path glob)))
    (ellm-tools--start-command
     "ellm-tools-grep" (car command) (cdr command)
     (lambda (exit-code stdout stderr)
       (ellm-tools--format-line-command-result
        "grep" pattern search-path exit-code stdout stderr limit
        "No matches found" 1))
     callback)))

(ellm-deftool files/edit (:async t)
  ((file-path :string "The absolute or relative path to the file to edit.")
   (old-string :string "The exact text to replace, or an empty string to create a new file.")
   (new-string :string "The text to replace OLD-STRING with.")
   (replace-all :boolean "If non-nil, replace all occurrences of OLD-STRING. Otherwise replace only the first occurrence, erroring if it is not unique." &optional))
  "Edit a file by replacing OLD-STRING with NEW-STRING.
OLD-STRING must appear exactly once in the file unless REPLACE-ALL
is non-nil, in which case all occurrences are replaced.  To create a
new file, pass an empty OLD-STRING; parent directories are created and
the operation fails if the target already exists."
  (let ((default-directory (ellm-tools--default-directory)))
    (ellm-tools--edit-tool file-path old-string new-string callback replace-all)))

(ellm-deftool files/read (:async t)
  ((file-path :string "Path to the file. Relative paths are resolved from the conversation working directory.")
   (start-line :integer "Starting line number.")
   (end-line :integer "Ending line number."))
  "Return text from START-LINE to END-LINE (inclusive).
For a non-text file, return metadata without reading its contents."
  (when (or (ellm-tools--blank-p file-path)
            (not (and (numberp start-line) (numberp end-line)))
            (< start-line 1)
            (< end-line start-line))
    (ellm-tools--error "Invalid input"))
  (let ((default-directory (ellm-tools--default-directory)))
    (ellm-tools--start-read-file-lines
     (expand-file-name file-path) start-line end-line callback)))

;;;;; Buffers

(ellm-deftool buffers/edit-buffer (:async t)
  ((buffer-name :string "The name of the buffer to edit.")
   (old-string :string "The exact text to search for and replace in the buffer.")
   (new-string :string "The text to replace OLD-STRING with.")
   (replace-all :boolean "If non-nil, replace all occurrences of OLD-STRING. Otherwise replace only the first occurrence, erroring if it is not unique." &optional))
  "Edit a buffer by replacing OLD-STRING with NEW-STRING.
OLD-STRING must appear exactly once in the buffer unless REPLACE-ALL
is non-nil, in which case all occurrences are replaced."
  (when (or (not (stringp buffer-name))
            (string-empty-p buffer-name)
            (not (get-buffer buffer-name)))
    (ellm-tools--error "Invalid buffer name"))
  (ellm-tools--edit-tool (get-buffer buffer-name)
                         old-string new-string callback replace-all))

(ellm-deftool buffers/buffers ()
  ()
  "List names of open buffers.
Act directly on buffers if you know the name already, without listing."
  (ellm-tools--success
   (concat
    "<buffers>\n"
    (mapconcat
     (lambda (n) n)
     (cl-loop for b in (buffer-list)
              for n = (buffer-name b)
              when (and n (not (string-prefix-p " " n)))
              collect n)
     "\n")
    "\n</buffers>")))

(defun ellm-tools--read-buffer-lines (buffer start-line end-line)
  "Return BUFFER contents in the optional inclusive line range."
  (unless (buffer-live-p buffer)
    (ellm-tools--error "Operation failed: invalid input"))
  (when (or (and start-line (or (not (integerp start-line)) (< start-line 1)))
            (and end-line (or (not (integerp end-line)) (< end-line 1)))
            (and start-line end-line (< end-line start-line)))
    (ellm-tools--error "Operation failed: invalid input"))
  (with-current-buffer buffer
    (let* ((start-pos (if start-line
                          (save-excursion (goto-char (point-min))
                                          (forward-line (1- start-line)) (point))
                        (point-min)))
           (end-pos (if end-line
                        (save-excursion (goto-char (point-min))
                                        (forward-line end-line) (point))
                      (point-max)))
           (content (buffer-substring-no-properties start-pos end-pos))
           (lines (split-string content "\n"))
           (limited-lines (seq-take lines 500))
           (truncated (> (length lines) 500)))
      (concat
       (format "<buffer name=%S%s%s>\n" (buffer-name buffer)
               (if start-line (format " start-line=%d" start-line) "")
               (if end-line (format " end-line=%d" end-line) ""))
       (string-join limited-lines "\n")
       (if truncated
           (ellm-tools--truncation-marker
            "buffer" content (format "showing first 500 of %d lines" (length lines)))
         "")
       "\n</buffer>"))))

(ellm-deftool buffers/read-buffer ()
  ((buffer-name :string "Name of the buffer to read.")
   (start-line :integer "Starting line number (1-indexed). Optional." &optional)
   (end-line :integer "Ending line number (1-indexed). Optional." &optional))
  "Return the contents of BUFFER-NAME, optionally limited to a line range."
  (when (or (not (stringp buffer-name)) (string-empty-p buffer-name))
    (ellm-tools--error "Operation failed: invalid input"))
  (ellm-tools--read-buffer-lines (get-buffer buffer-name) start-line end-line))

(ellm-deftool tool-outputs/output ()
  ((output-id :string "Identifier named by a truncated tool result.")
   (start-line :integer "Starting line number (1-indexed). Optional." &optional)
   (end-line :integer "Ending line number (1-indexed). Optional." &optional))
  "Read retained output from this conversation only."
  (ellm-tools--read-buffer-lines
   (ellm-tool-output-buffer output-id) start-line end-line))

(defun ellm-tools--search-buffer (buffer pattern regexp case-sensitive)
  "Return bounded matches for PATTERN in BUFFER."
  (unless (buffer-live-p buffer)
    (ellm-tools--error "Invalid buffer"))
  (when (ellm-tools--blank-p pattern)
    (ellm-tools--error "search pattern is empty"))
  (with-current-buffer buffer
    (let ((case-fold-search (not case-sensitive))
          (search-fn (if regexp #'re-search-forward #'search-forward))
          (matches '()) (done nil) (max-matches 50))
      (save-excursion
        (goto-char (point-min))
        (while (and (not done) (< (length matches) max-matches)
                    (funcall search-fn pattern nil t))
          (let* ((match-beg (match-beginning 0))
                 (match-end (match-end 0))
                 (line-num (line-number-at-pos match-beg))
                 (line-content (buffer-substring-no-properties
                                (line-beginning-position) (line-end-position))))
            (push (format "%d: %s" line-num line-content) matches)
            (when (= match-beg match-end)
              (if (eobp) (setq done t) (forward-char 1))))))
      (if matches
          (concat
           (format "<search_results buffer=%S pattern=%S matches=%d%s>\n"
                   (buffer-name buffer) pattern (length matches)
                   (if (= (length matches) max-matches) " truncated=true" ""))
           (string-join (nreverse matches) "\n") "\n</search_results>")
        (format "No matches found for %S in buffer %S." pattern (buffer-name buffer))))))

(ellm-deftool buffers/search-buffer ()
  ((buffer-name :string "Name of the buffer to search in.")
   (pattern :string "The search pattern to look for.")
   (regexp :boolean "If true, treat pattern as a regular expression. Default is false." &optional)
   (case-sensitive :boolean "If true, search is case-sensitive. By default does a case-insensitive search." &optional))
  "Return matching lines with line numbers."
  (when (or (not (stringp buffer-name)) (string-empty-p buffer-name))
    (ellm-tools--error "Invalid buffer name"))
  (ellm-tools--search-buffer (get-buffer buffer-name) pattern regexp case-sensitive))

(ellm-deftool tool-outputs/search-output ()
  ((output-id :string "Identifier named by a truncated tool result.")
   (pattern :string "The search pattern to look for.")
   (regexp :boolean "If true, treat pattern as a regular expression. Default is false." &optional)
   (case-sensitive :boolean "If true, search is case-sensitive. By default does a case-insensitive search." &optional))
  "Search retained output from this conversation only."
  (ellm-tools--search-buffer
   (ellm-tool-output-buffer output-id) pattern regexp case-sensitive))

(declare-function flymake-diagnostic-beg "flymake")
(declare-function flymake-diagnostic-end "flymake")
(declare-function flymake-diagnostic-type "flymake")
(declare-function flymake-diagnostic-text "flymake")

;; TODO: Make the issue backend configurable: flymake, flycheck, ...?
(ellm-deftool buffers/buffer-issues ()
  ((buffer :string "Name of the buffer to get flymake diagnostics for."))
  "List current Flymake diagnostics for BUFFER.
Each issue is returned as line-range:type:message."
  (when (or (not (stringp buffer))
            (string-empty-p buffer)
            (not (get-buffer buffer)))
    (ellm-tools--error "Invalid buffer name"))
  (require 'flymake)
  (with-current-buffer (get-buffer buffer)
    (let ((issues (flymake-diagnostics)))
      (if issues
          (mapconcat
           (lambda (diag)
             (format "%d-%d:%s: %s"
                     (line-number-at-pos (flymake-diagnostic-beg diag))
                     (line-number-at-pos (flymake-diagnostic-end diag))
                     (flymake-diagnostic-type diag)
                     (flymake-diagnostic-text diag)))
           issues
           "\n")
        "No flymake issues found."))))

;;;;; Emacs

(ellm-deftool emacs/elisp-info ()
  ((symbols :array "Names of Emacs Lisp functions or variables to describe."))
  "Return Emacs help for each requested function or variable in SYMBOLS."
  (ellm-tools--elisp-info
   (ellm-tools--normalize-symbol-names symbols)))

(ellm-deftool emacs/elisp-search ()
  ((query :string "Text to fuzzy-match against Emacs Lisp function and variable names.")
   (search-documentation :boolean "If true, also search function and variable documentation." &optional)
   (max-results :integer "Maximum number of results to return. Omit to use the standard limit." &optional))
  "Fuzzy-search Emacs Lisp functions and variables for QUERY.
When SEARCH-DOCUMENTATION is non-nil, also find symbols whose
documentation contains the query words."
  (ellm-tools--validate-pattern query "query")
  (let ((limit (ellm-tools--normalized-limit
                max-results ellm-tools-elisp-search-result-limit)))
    (ellm-tools--elisp-search query search-documentation limit)))

(ellm-deftool emacs/elisp-eval (:async t)
  ((code :string "Emacs Lisp forms to evaluate as an implicit `progn'.")
   (session :string "Execution session: `temp' (default) is isolated; `current' uses the running Emacs; any other name preserves an isolated session for later calls." &optional)
   (features :array "Feature names to load before evaluating CODE." &optional))
  "Evaluate Emacs Lisp CODE and return its final value and printed output.
Use SESSION `temp' (the default) for isolated evaluation, `current' to inspect
or modify the running Emacs, or another session name to preserve state for
later calls in this conversation."
  (ellm-tools--start-elisp-eval
   code session features callback))

;;;;; Tasks

(ellm-deftool tasks/todowrite ()
  ((todos :array "The complete todo list. Each item must have `content' and `status' (`pending', `in_progress', `completed', or `cancelled'); `priority' may be `high', `medium', or `low'."))
  "Replace the current conversation's todo list with TODOS.
Always pass the full current list, not just incremental changes."
  (ellm-tools--format-todos (ellm-update-todos todos)))

;;;;; Agents

(ellm-deftool agents/profiles ()
  ()
  "List effective named profiles available to this conversation."
  (ellm-tools--format-profiles (ellm--parse-frontmatter)))

(ellm-deftool agents/launch-subagent ()
  ((prompt :string "Prompt to put in the new subagent's initial user turn.")
   (profile :string "Optional active profile name for the child. Call `profiles' before selecting one; omit it to inherit the current effective configuration. Do not invent profile names." &optional)
   (name :string "Optional display name for the subagent and its conversation." &optional)
   (cwd :string "Optional working directory for the subagent. Overrides the inherited or profile directory." &optional))
  "Launch a subagent in a new conversation and start it.
When PROFILE is supplied, it is the child's active profile.  Otherwise the
child inherits the current effective configuration."
  (ellm-tools--launch-subagent prompt profile name cwd))

(ellm-deftool agents/subagents ()
  ()
  "List subagents launched from the current ellm buffer."
  (ellm-tools--format-subagent-history ellm-subagent-history))

(ellm-deftool agents/wait-subagent (:async t)
  ((subagent :string "Subagent id from `subagents' or its conversation name."))
  "Wait for SUBAGENT to finish and return its latest result."
  (ellm-tools--wait-subagent subagent callback))

(ellm-deftool agents/send-subagent ()
  ((subagent :string "Subagent id from `subagents' or its conversation name.")
   (prompt :string "Prompt to add as a new user turn before sending."))
  "Send PROMPT to SUBAGENT."
  (ellm-tools--send-subagent subagent prompt))

;;;;; Web

(ellm-deftool web/web-search (:async t)
  ((query :string "Search query.")
   (max-results :integer "Maximum number of web results to return. Omit to use the standard limit." &optional))
  "Search the web for pages relevant to QUERY."
  (ellm-tools--validate-pattern query "query")
  (let ((limit (ellm-tools--normalized-limit
                max-results ellm-tools-websearch-result-limit)))
    (ellm-tools--start-websearch query limit callback)))

(ellm-deftool web/web-fetch (:async t)
  ((url :string "HTTP or HTTPS URL to fetch."))
  "Fetch a URL and return its readable text.
Use this to read a specific web page, document, or text resource."
  (ellm-tools--validate-webfetch-url url)
  (ellm-tools--start-webfetch
   url
   ellm-tools-webfetch-character-limit
   callback))

;;;; Tool helpers

(defun ellm-tools--default-directory ()
  "Return the directory custom tools should use for relative paths."
  (ellm--working-directory))

;;;;; Internal

;;;;;; General validation

(defun ellm-tools--validate-pattern (pattern name)
  "Signal an error unless PATTERN is a non-blank string named NAME."
  (when (or (not (stringp pattern))
            (ellm-tools--blank-p pattern))
    (ellm-tools--error "%s must be a non-empty string" name)))

(defun ellm-tools--search-path (path)
  "Return PATH or `.' for file search tools."
  (if (and (stringp path) (not (ellm-tools--blank-p path)))
      path
    "."))

(defun ellm-tools--normalized-limit (limit default)
  "Return LIMIT normalized against DEFAULT."
  (let ((value (or limit default)))
    (unless (and (integerp value) (> value 0))
      (ellm-tools--error "limit must be a positive integer"))
    value))

(defun ellm-tools--normalize-symbol-names (symbols)
  "Return validated function or variable names from SYMBOLS."
  (let ((names (if (vectorp symbols) (append symbols nil) symbols)))
    (unless (and (consp names)
                 (cl-every (lambda (name)
                             (and (stringp name) (not (ellm-tools--blank-p name))))
                           names))
      (ellm-tools--error
       "symbols must be a non-empty array of non-empty strings"))
    names))

(defun ellm-tools--elisp-symbol-p (symbol)
  "Return non-nil when SYMBOL is a function or variable."
  (or (fboundp symbol) (boundp symbol)))

(defun ellm-tools--elisp-info (names)
  "Return `describe-symbol' help for function or variable NAMES."
  (require 'help-fns)
  (mapconcat
   (lambda (name)
     (let ((symbol (intern-soft name)))
       (if (and symbol (ellm-tools--elisp-symbol-p symbol))
           (progn
             (save-window-excursion
               (describe-symbol symbol))
             (format "<elisp_info symbol=%S>\n%s\n</elisp_info>"
                     name
                     (with-current-buffer (help-buffer)
                       (string-trim-right
                        (buffer-substring-no-properties
                         (point-min) (point-max))))))
         (format "No function or variable named %S is defined." name))))
   names
   "\n\n"))

(defun ellm-tools--elisp-documentation (symbol)
  "Return the combined function and variable documentation for SYMBOL."
  (string-join
   (delq nil
         (list
          (when (fboundp symbol)
            (condition-case nil
                (documentation symbol t)
              (error nil)))
          (when (boundp symbol)
            (condition-case nil
                (documentation-property
                 symbol 'variable-documentation t)
              (error nil)))))
   "\n"))

(defun ellm-tools--elisp-matching-documentation (symbol regexps)
  "Return SYMBOL documentation when it matches every regexp in REGEXPS."
  (let ((case-fold-search t)
        (documentation (ellm-tools--elisp-documentation symbol)))
    (and (not (string-empty-p documentation))
         (cl-every
          (lambda (regexp)
            (string-match-p regexp documentation))
          regexps)
         documentation)))

(defun ellm-tools--elisp-symbol-kind (symbol)
  "Return a display string describing the kind of SYMBOL."
  (string-join
   (delq nil (list (and (fboundp symbol) "function")
                   (and (boundp symbol) "variable")))
   ", "))

(defun ellm-tools--elisp-symbol-summary (symbol &optional documentation)
  "Return the first documentation line for SYMBOL.
Use DOCUMENTATION when supplied instead of retrieving it again."
  (when-let* ((documentation (or documentation
                                 (ellm-tools--elisp-documentation symbol)))
              ((not (string-empty-p documentation))))
    (car (split-string documentation "\n" t "[[:space:]]+"))))

(defun ellm-tools--elisp-search (query search-documentation limit)
  "Return up to LIMIT function and variable matches for QUERY.
Names are flex-matched.  When SEARCH-DOCUMENTATION is non-nil, symbols
whose documentation contains all QUERY words are included as well."
  (let* ((completion-ignore-case t)
         (completion-styles '(flex))
         (name-query (replace-regexp-in-string
                      "[-_[:space:]]+" "" query))
         (completion-result
          (completion-all-completions
           name-query obarray #'ellm-tools--elisp-symbol-p
           (length name-query)))
         (name-matches nil)
         (seen (make-hash-table :test #'eq))
         (documentation-by-symbol (make-hash-table :test #'eq))
         documentation-matches
         documentation-truncated
         name-match-count)
    (while (consp completion-result)
      (let ((symbol (intern-soft
                     (substring-no-properties (pop completion-result)))))
        (when (and symbol (not (gethash symbol seen)))
          (puthash symbol t seen)
          (push symbol name-matches))))
    (setq name-matches (nreverse name-matches))
    (setq name-match-count (length name-matches))
    (when search-documentation
      (let ((needed (1+ (- limit name-match-count)))
            (regexps
             (mapcar #'regexp-quote
                     (split-string query "[[:space:]]+" t))))
        (if (>= name-match-count limit)
            (setq documentation-truncated t)
          (catch 'enough-matches
            (mapatoms
             (lambda (symbol)
               (when (and (ellm-tools--elisp-symbol-p symbol)
                          (not (gethash symbol seen)))
                 (when-let*
                     ((documentation
                       (ellm-tools--elisp-matching-documentation
                        symbol regexps)))
                   (puthash symbol t seen)
                   (puthash symbol documentation documentation-by-symbol)
                   (push symbol documentation-matches)
                   (when (= (length documentation-matches) needed)
                     (setq documentation-truncated t)
                     (throw 'enough-matches nil)))))))))
      (setq documentation-matches
            (sort documentation-matches
                  (lambda (left right)
                    (string-lessp (symbol-name left)
                                  (symbol-name right))))))
    (let* ((shown-names (seq-take name-matches limit))
           (shown
            (append shown-names
                    (seq-take documentation-matches
                              (- limit (length shown-names)))))
           (truncated
            (or (> name-match-count limit)
                documentation-truncated)))
      (if (null shown)
          (format "No Emacs Lisp functions or variables matched %S." query)
        (concat
         (format "<elisp_search query=%S search_documentation=%s results=%d%s>\n"
                 query
                 (if search-documentation "true" "false")
                 (length shown)
                 (if truncated " truncated=true" ""))
         (mapconcat
          (lambda (symbol)
            (concat
             (format "%s [%s]"
                     symbol (ellm-tools--elisp-symbol-kind symbol))
             (when-let*
                 ((summary
                   (ellm-tools--elisp-symbol-summary
                    symbol (gethash symbol documentation-by-symbol))))
               (concat " — " summary))))
          shown
          "\n")
         "\n</elisp_search>")))))

;;;;;; Elisp evaluation

(defconst ellm-tools--elisp-evaluator
  '(lambda (code features)
     (let ((output-buffer (generate-new-buffer " *ellm-elisp-output*")))
       (unwind-protect
           (let ((standard-output output-buffer))
             (condition-case err
                 (progn
                   (dolist (feature features)
                     (require (intern feature)))
                   (let* ((source (concat "(progn\n" code "\n)"))
                          (parsed (read-from-string source))
                          (_
                           (unless (= (cdr parsed) (length source))
                             (error "Unexpected input after Elisp forms")))
                          (form (car parsed))
                          (value (eval form t))
                          (print-circle t)
                          print-level
                          print-length)
                     (list :ok t
                           :value (prin1-to-string value)
                           :output
                           (with-current-buffer output-buffer
                             (buffer-string)))))
               ((error quit)
                (list :ok nil
                      :error-symbol (car err)
                      :error-message (error-message-string err)
                      :output
                      (with-current-buffer output-buffer
                        (buffer-string))))))
         (when (buffer-live-p output-buffer)
           (kill-buffer output-buffer)))))
  "Serializable evaluator used by current and child Emacs sessions.")

(defun ellm-tools--normalize-elisp-session (session)
  "Return a validated Elisp SESSION name."
  (let ((name (or session "temp")))
    (unless (and (stringp name) (not (ellm-tools--blank-p name)))
      (ellm-tools--error "session must be a non-empty string"))
    name))

(defun ellm-tools--normalize-elisp-features (features)
  "Return validated feature names from FEATURES."
  (let ((names (cond
                ((null features) nil)
                ((vectorp features) (append features nil))
                ((listp features) (copy-sequence features))
                (t :invalid))))
    (unless (and (not (eq names :invalid))
                 (cl-every (lambda (name)
                             (and (stringp name) (not (ellm-tools--blank-p name))))
                           names))
      (ellm-tools--error
       "features must be an array of non-empty strings"))
    (delete-dups names)))

(defun ellm-tools--truncate-elisp-result (text)
  "Return TEXT capped by `ellm-tools-elisp-eval-result-character-limit'."
  (let ((limit ellm-tools-elisp-eval-result-character-limit))
    (if (or (not (integerp limit))
            (< limit 0)
            (<= (length text) limit))
        (cons text nil)
      (cons (substring text 0 limit) t))))

(defun ellm-tools--format-elisp-eval-result (session result)
  "Format Elisp evaluation RESULT from SESSION for the model."
  (let* ((output
          (ellm-tools--truncate-elisp-result
           (or (plist-get result :output) "")))
         (value
          (and (plist-get result :ok)
               (ellm-tools--truncate-elisp-result
                (or (plist-get result :value) "nil")))))
    (concat
     (format "<elisp_eval session=%S status=%S>\n"
             session (if (plist-get result :ok) "ok" "error"))
     (if (plist-get result :ok)
         (format "<value%s>\n%s%s\n</value>"
                 (if (cdr value) " truncated=true" "")
                 (car value)
                 (if (cdr value)
                     (ellm-tools--truncation-marker
                      "elisp-value" (or (plist-get result :value) "nil"))
                   ""))
       (format "<error type=%S>\n%s\n</error>"
               (plist-get result :error-symbol)
               (or (plist-get result :error-message)
                   "Unknown evaluation error")))
     (unless (string-empty-p (car output))
       (format "\n<output%s>\n%s%s\n</output>"
               (if (cdr output) " truncated=true" "")
               (car output)
               (if (cdr output)
                   (ellm-tools--truncation-marker
                    "elisp-output" (or (plist-get result :output) ""))
                 "")))
     "\n</elisp_eval>")))

(defun ellm-tools--elisp-child-form
    (body load-path-value exec-path-value directory)
  "Return a child Emacs form evaluating BODY with captured environment."
  `(lambda ()
     (setq load-path ',load-path-value
           exec-path ',exec-path-value
           default-directory ,directory
           load-prefer-newer t)
     ,body))

(defun ellm-tools--cancel-elisp-process (process)
  "Kill Elisp child PROCESS and its output buffer."
  (let ((buffer (and (processp process) (process-buffer process))))
    (when (process-live-p process)
      (delete-process process))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defun ellm-tools--start-temp-elisp-eval
    (code features directory callback)
  "Evaluate CODE with FEATURES in a temporary child rooted at DIRECTORY."
  (let* ((owner (current-buffer))
         (async-process-noquery-on-exit t)
         (completed nil)
         (cancelled nil)
         (process
          (async-start
           (ellm-tools--elisp-child-form
            `(funcall ',ellm-tools--elisp-evaluator ,code ',features)
            load-path exec-path directory)
           (lambda (result)
             (unless (async-message-p result)
               (setq completed t)
               (funcall callback
                        (with-current-buffer owner
                          (ellm-tools--format-elisp-eval-result
                           "temp"
                           (if (and (listp result)
                                    (plist-member result :ok))
                               result
                             (list :ok nil
                                   :error-symbol 'child-exit
                                   :error-message
                                   "Temporary Emacs exited without a result"))))))))))
    (let ((async-sentinel (process-sentinel process)))
      (set-process-sentinel
       process
       (lambda (proc event)
         (condition-case err
             (when async-sentinel
               (funcall async-sentinel proc event))
           (error
            (unless (or completed cancelled)
              (setq completed t)
              (funcall callback
                       (format "Temporary Emacs failed: %s"
                               (error-message-string err))))))
         (when (and (not completed)
                    (not cancelled)
                    (memq (process-status proc) '(exit signal)))
           (setq completed t)
           (funcall callback
                    (format "Temporary Emacs exited unexpectedly (%s)"
                            (string-trim event)))))))
    (lambda ()
      (setq cancelled t)
      (ellm-tools--cancel-elisp-process process))))

(defun ellm-tools--start-current-elisp-eval
    (owner code features callback)
  "Evaluate CODE with FEATURES in live OWNER buffer."
  (run-at-time
   0 nil
   (lambda ()
     (if (buffer-live-p owner)
         (with-current-buffer owner
           (let ((result
                  (save-current-buffer
                    (funcall ellm-tools--elisp-evaluator code features))))
             (funcall
              callback
              (ellm-tools--format-elisp-eval-result
               "current" result))))
       (funcall callback
                "Error while calling the tool: owning ellm buffer was killed")))))

(defun ellm-tools--elisp-session-live-p (session)
  "Return non-nil when persistent Elisp SESSION has a live process."
  (and (ellm-tools--elisp-session-p session)
       (process-live-p (ellm-tools--elisp-session-process session))))

(defun ellm-tools--elisp-session-callbacks (session)
  "Return callbacks currently pending in Elisp SESSION."
  (let (callbacks)
    (maphash (lambda (_id callback)
               (push callback callbacks))
             (ellm-tools--elisp-session-pending session))
    callbacks))

(defun ellm-tools--kill-elisp-session (session &optional reason)
  "Kill persistent Elisp SESSION and fail pending calls with REASON."
  (when (ellm-tools--elisp-session-p session)
    (let ((process (ellm-tools--elisp-session-process session))
          (callbacks (ellm-tools--elisp-session-callbacks session)))
      (when (hash-table-p ellm-tools--elisp-sessions)
        (remhash (ellm-tools--elisp-session-name session)
                 ellm-tools--elisp-sessions))
      (clrhash (ellm-tools--elisp-session-pending session))
      (ellm-tools--cancel-elisp-process process)
      (when reason
        (dolist (callback callbacks)
          (funcall callback reason))))))

(defun ellm-tools--kill-elisp-sessions ()
  "Kill all persistent Elisp sessions owned by the current buffer."
  (when (hash-table-p ellm-tools--elisp-sessions)
    (let (sessions)
      (maphash (lambda (_name session)
                 (push session sessions))
               ellm-tools--elisp-sessions)
      (dolist (session sessions)
        (ellm-tools--kill-elisp-session session)))
    (setq ellm-tools--elisp-sessions nil)))

(defun ellm-tools--elisp-session-exited (owner name process)
  "Handle unexpected PROCESS exit for named session NAME owned by OWNER."
  (when (buffer-live-p owner)
    (with-current-buffer owner
      (when-let* ((session
                   (and (hash-table-p ellm-tools--elisp-sessions)
                        (gethash name ellm-tools--elisp-sessions)))
                  ((eq process
                       (ellm-tools--elisp-session-process session))))
        (ellm-tools--kill-elisp-session
         session
         (format "Persistent Elisp session %S exited unexpectedly" name))))))

(defun ellm-tools--handle-elisp-session-result
    (owner name process result)
  "Dispatch RESULT from named session NAME and PROCESS owned by OWNER."
  (if (not (async-message-p result))
      (ellm-tools--elisp-session-exited owner name process)
    (when (buffer-live-p owner)
      (with-current-buffer owner
        (when-let* ((session
                     (and (hash-table-p ellm-tools--elisp-sessions)
                          (gethash name ellm-tools--elisp-sessions)))
                    ((eq process
                         (ellm-tools--elisp-session-process session)))
                    (id (plist-get result :id))
                    (callback
                     (gethash id
                              (ellm-tools--elisp-session-pending session))))
          (remhash id (ellm-tools--elisp-session-pending session))
          (funcall
           callback
           (ellm-tools--format-elisp-eval-result
            name (plist-get result :result))))))))

(defun ellm-tools--install-elisp-session-sentinel
    (owner name process)
  "Install exit cleanup for named PROCESS NAME owned by OWNER."
  (let ((async-sentinel (process-sentinel process)))
    (set-process-sentinel
     process
     (lambda (proc event)
       (when async-sentinel
         (funcall async-sentinel proc event))
       (when (memq (process-status proc) '(exit signal))
         (ellm-tools--elisp-session-exited owner name proc))))))

(defun ellm-tools--create-elisp-session (owner name directory)
  "Create persistent child session NAME for OWNER rooted at DIRECTORY."
  (let ((async-process-noquery-on-exit t)
        process
        session)
    (setq
     process
     (async-start
      (ellm-tools--elisp-child-form
       `(let ((evaluator ',ellm-tools--elisp-evaluator))
          (catch 'shutdown
            (while t
              (let ((request (async-receive)))
                (if (plist-get request :shutdown)
                    (throw 'shutdown nil)
                  (async-send
                   :id (plist-get request :id)
                   :result
                   (funcall evaluator
                            (plist-get request :code)
                            (plist-get request :features))))))))
       load-path exec-path directory)
      (lambda (result)
        (ellm-tools--handle-elisp-session-result
         owner name process result))))
    (setq session
          (ellm-tools--make-elisp-session
           :name name
           :process process
           :pending (make-hash-table :test #'eql)
           :next-id 0))
    (ellm-tools--install-elisp-session-sentinel owner name process)
    session))

(defun ellm-tools--get-elisp-session (owner name directory)
  "Return live named session NAME for OWNER, creating it in DIRECTORY."
  (with-current-buffer owner
    (unless (hash-table-p ellm-tools--elisp-sessions)
      (setq ellm-tools--elisp-sessions
            (make-hash-table :test #'equal)))
    (let ((session (gethash name ellm-tools--elisp-sessions)))
      (unless (ellm-tools--elisp-session-live-p session)
        (when session
          (ellm-tools--kill-elisp-session session))
        (setq session
              (ellm-tools--create-elisp-session owner name directory))
        (puthash name session ellm-tools--elisp-sessions))
      session)))

(defun ellm-tools--start-named-elisp-eval
    (owner name code features directory callback)
  "Evaluate CODE in persistent session NAME owned by OWNER."
  (let* ((session
          (ellm-tools--get-elisp-session owner name directory))
         (id (1+ (ellm-tools--elisp-session-next-id session)))
         (pending (ellm-tools--elisp-session-pending session))
         (process (ellm-tools--elisp-session-process session)))
    (setf (ellm-tools--elisp-session-next-id session) id)
    (puthash id callback pending)
    (async-send process
                :id id
                :code code
                :features features)
    (lambda ()
      (when (buffer-live-p owner)
        (with-current-buffer owner
          (when-let* ((current
                       (and (hash-table-p ellm-tools--elisp-sessions)
                            (gethash name ellm-tools--elisp-sessions)))
                      ((eq current session)))
            (remhash id pending)
            (ellm-tools--kill-elisp-session
             session
             (format "Persistent Elisp session %S was cancelled" name))))))))

(defun ellm-tools--start-elisp-eval (code session features callback)
  "Dispatch CODE evaluation according to SESSION and call CALLBACK."
  (ellm-tools--validate-pattern code "code")
  (let* ((owner (current-buffer))
         (name (ellm-tools--normalize-elisp-session session))
         (feature-names (ellm-tools--normalize-elisp-features features))
         (directory (ellm-tools--default-directory)))
    (pcase name
      ("current"
       (ellm-tools--start-current-elisp-eval
        owner code feature-names callback))
      ("temp"
       (ellm-tools--start-temp-elisp-eval
        code feature-names directory callback))
      (_
       (ellm-tools--start-named-elisp-eval
        owner name code feature-names directory callback)))))

(defun ellm-tools--initialize-elisp-sessions ()
  "Install buffer-local persistent Elisp session cleanup."
  (add-hook 'ellm-session-close-hook
            #'ellm-tools--kill-elisp-sessions nil t)
  (add-hook 'kill-buffer-hook
            #'ellm-tools--kill-elisp-sessions nil t))

;;;;;; Find & grep

(defun ellm-tools--command-template-p (args)
  "Return non-nil when ARGS contain `%p' or `%d' placeholders."
  (cl-some (lambda (arg)
             (and (stringp arg)
                  (or (string-match-p "%p" arg)
                      (string-match-p "%d" arg))))
           args))

(defun ellm-tools--expand-command-template (args pattern path)
  "Replace `%p' and `%d' in ARGS with PATTERN and PATH."
  (mapcar (lambda (arg)
            (if (stringp arg)
                (string-replace "%d" path
                                (string-replace "%p" pattern arg))
              arg))
          args))

(defun ellm-tools--find-program-p (program)
  "Return non-nil when PROGRAM looks like find."
  (member (file-name-nondirectory program) '("find" "gfind")))

(defun ellm-tools--glob-command (pattern path)
  "Return command list for running the glob tool with PATTERN under PATH."
  (let ((program ellm-tools-glob-program)
        (options ellm-tools-glob-options))
    (cons program
          (cond
           ((ellm-tools--command-template-p options)
            (ellm-tools--expand-command-template options pattern path))
           ((ellm-tools--find-program-p program)
            (append (list path)
                    (unless (equal options ellm-tools--default-glob-options)
                      options)
                    (list "-name" pattern "-type" "f")))
           (t
            (append options (list "--" pattern path)))))))

(defun ellm-tools--grep-command (pattern path &optional glob)
  "Return command list for running grep for PATTERN under PATH and optional GLOB."
  (let* ((program ellm-tools-grep-program)
         (options ellm-tools-grep-options)
         (glob-options
          (when glob
            (mapcar (lambda (arg) (string-replace "%s" glob arg))
                    ellm-tools-grep-glob-options))))
    (cons program
          (if (ellm-tools--command-template-p options)
              (append glob-options
                      (ellm-tools--expand-command-template options pattern path))
            (append options glob-options (list "--" pattern path))))))

;;;;;; External command handling

(defun ellm-tools--start-command (name program args formatter callback)
  "Start PROGRAM with ARGS asynchronously.
FORMATTER is called with EXIT-CODE, STDOUT and STDERR, and its return value
is passed to CALLBACK.  Return a cancellation function."
  (unless (and (stringp program) (not (ellm-tools--blank-p program)))
    (ellm-tools--error "Invalid command program"))
  (unless (executable-find program)
    (ellm-tools--error "program not found: %s" program))
  (dolist (arg args)
    (unless (stringp arg)
      (ellm-tools--error "command argument is not a string: %S" arg)))
  (let* ((conversation (current-buffer))
         (stdout-buffer (generate-new-buffer (format " *%s-stdout*" name)))
         (stderr-buffer (generate-new-buffer (format " *%s-stderr*" name)))
         (finished nil)
         process)
    (cl-labels
        ((buffer-text (buffer)
                      (if (buffer-live-p buffer)
                          (with-current-buffer buffer
                            (buffer-string))
                        ""))
         (cleanup ()
                  (when (buffer-live-p stdout-buffer)
                    (kill-buffer stdout-buffer))
                  (when (buffer-live-p stderr-buffer)
                    (kill-buffer stderr-buffer))))
      (setq process
            (make-process
             :name name
             :buffer stdout-buffer
             :command (cons program args)
             :connection-type 'pipe
             :noquery t
             :stderr stderr-buffer
             :sentinel
             (lambda (proc _event)
               (when (and (not finished)
                          (memq (process-status proc) '(exit signal)))
                 (setq finished t)
                 (let ((exit-code (process-exit-status proc))
                       (stdout (buffer-text stdout-buffer))
                       (stderr (buffer-text stderr-buffer)))
                   (cleanup)
                   (condition-case err
                       (funcall callback
                                (with-current-buffer conversation
                                  (funcall formatter exit-code stdout stderr)))
                     (error
                      (funcall callback
                               (format "Error while processing command output: %s"
                                       err)))))))))
      (lambda ()
        (unless finished
          (setq finished t)
          (when (process-live-p process)
            (kill-process process))
          (cleanup))))))

(defun ellm-tools--format-command-error (kind exit-code stdout stderr)
  "Return a command failure string for KIND with EXIT-CODE, STDOUT and STDERR."
  (let ((stdout (string-trim-right stdout))
        (stderr (string-trim-right stderr)))
    (concat
     (format "%s command exited with code %d" kind exit-code)
     (unless (string-empty-p stderr)
       (concat "\n<stderr>\n" stderr "\n</stderr>"))
     (unless (string-empty-p stdout)
       (concat "\n<stdout>\n" stdout "\n</stdout>")))))

(defun ellm-tools--format-line-command-result
    (kind pattern path exit-code stdout stderr limit no-match-message
          &optional no-match-exit-code)
  "Format file search command output.
KIND is the XML-ish wrapper tag.  PATTERN and PATH describe the search.
EXIT-CODE, STDOUT and STDERR are process results.  LIMIT caps output lines.
NO-MATCH-MESSAGE is used when no lines are returned.  NO-MATCH-EXIT-CODE,
when non-nil, is treated as success if STDOUT is empty."
  (let* ((stdout (string-trim-right stdout))
         (stderr (string-trim-right stderr))
         (no-output (string-empty-p stdout)))
    (cond
     ((and (not (= exit-code 0))
           (not (and no-match-exit-code
                     (= exit-code no-match-exit-code)
                     no-output)))
      (ellm-tools--format-command-error kind exit-code stdout stderr))
     (no-output
      (format "%s for %S in %S." no-match-message pattern path))
     (t
      (let* ((lines (split-string stdout "\n" t))
             (total (length lines))
             (shown (seq-take lines limit))
             (truncated (> total limit)))
        (concat
         (format "<%s pattern=%S path=%S matches=%d%s>\n"
                 kind pattern path total
                 (if truncated " truncated=true" ""))
         (string-join shown "\n")
         (when truncated
           (format "\n[... output truncated: showing first %d of %d lines ...]"
                   limit total))
         (unless (string-empty-p stderr)
           (concat "\n<warnings>\n" stderr "\n</warnings>"))
         (format "\n</%s>" kind)))))))

;;;;;; File reading

(defun ellm-tools--parse-file-info (output)
  "Parse file(1) MIME OUTPUT into a plist, or return nil."
  (let ((output (string-trim output)))
    (when (string-match
           "\\`\\([[:alnum:].+-]+/[[:alnum:].+-]+\\)\\(?:;[ \t]*charset=\\([^ \t\n]+\\)\\)?\\'"
           output)
      (list :content-type (match-string 1 output)
            :charset (match-string 2 output)))))

(defun ellm-tools--text-file-info-p (info)
  "Return non-nil when file(1) INFO describes readable text."
  (let ((content-type (plist-get info :content-type))
        (charset (plist-get info :charset)))
    (or (string-prefix-p "text/" content-type)
        (equal content-type "inode/x-empty")
        (and charset (not (equal charset "binary"))))))

(defun ellm-tools--format-non-text-file-info (file-path info)
  "Format FILE-PATH and file(1) INFO without exposing file contents."
  (format
   (concat "<file_info path=%S content_type=%S charset=%S>\n"
           "Non-text file; contents were not read.\n"
           "</file_info>")
   file-path
   (plist-get info :content-type)
   (or (plist-get info :charset) "unknown")))

(defun ellm-tools--format-read-file-lines
    (start-line end-line exit-code stdout stderr)
  "Format an asynchronous file line read result."
  (if (not (= exit-code 0))
      (ellm-tools--format-command-error
       "read file" exit-code stdout stderr)
    (concat
     (format "<file_lines start_line=%s end_line=%s>\n"
             start-line end-line)
     stdout
     (unless (string-suffix-p "\n" stdout) "\n")
     "</file_lines>")))

(defun ellm-tools--start-read-file-lines
    (file-path start-line end-line callback)
  "Inspect and asynchronously read lines from FILE-PATH.
START-LINE and END-LINE are inclusive.  CALLBACK receives either text
lines or non-text file metadata.  Return a cancellation function."
  (let ((cancelled nil)
        current-cancel)
    (cl-labels
        ((set-current-cancel
          (handle)
          (if cancelled
              (ellm-tools--cancel-async-handle handle)
            (setq current-cancel handle)))
         (handle-file-info
          (command-result)
          (unless cancelled
            (condition-case err
                (pcase-let ((`(,exit-code ,stdout ,stderr) command-result))
                  (let ((info (ellm-tools--parse-file-info stdout)))
                    (cond
                     ((not (= exit-code 0))
                      (funcall callback
                               (ellm-tools--format-command-error
                                "file info" exit-code stdout stderr)))
                     ((not info)
                      (funcall callback
                               (format
                                "Error while reading file: could not determine its type\n%s"
                                (string-trim (concat stdout "\n" stderr)))))
                     ((not (ellm-tools--text-file-info-p info))
                      (funcall callback
                               (ellm-tools--format-non-text-file-info
                                file-path info)))
                     (t
                      (set-current-cancel
                       (ellm-tools--start-command
                        "ellm-tools-read-file"
                        ellm-tools-file-read-program
                        (list "-n"
                              "-e" (format "%d,%dp" start-line end-line)
                              "-e" (format "%dq" end-line)
                              file-path)
                        (lambda (read-exit-code read-stdout read-stderr)
                          (ellm-tools--format-read-file-lines
                           start-line end-line
                           read-exit-code read-stdout read-stderr))
                        callback))))))
              (error
               (funcall callback
                        (format "Error while reading file: %s" err)))))))
      (set-current-cancel
       (ellm-tools--start-command
        "ellm-tools-file-info"
        ellm-tools-file-info-program
        (list "--brief" "--dereference" "--mime" "--" file-path)
        (lambda (exit-code stdout stderr)
          (list exit-code stdout stderr))
        #'handle-file-info))
      (lambda ()
        (setq cancelled t)
        (ellm-tools--cancel-async-handle current-cancel)))))

;;;;;; TodoTool

(defun ellm-tools--todo-count (todos status)
  "Return number of TODOS with STATUS."
  (cl-count status todos :key (lambda (todo) (plist-get todo :status))
            :test #'equal))

(defun ellm-tools--format-todos (todos)
  "Return a model-readable summary of TODOS."
  (let ((total (length todos)))
    (concat
     (format "<todo_list total=%d pending=%d in_progress=%d completed=%d cancelled=%d>\n"
             total
             (ellm-tools--todo-count todos "pending")
             (ellm-tools--todo-count todos "in_progress")
             (ellm-tools--todo-count todos "completed")
             (ellm-tools--todo-count todos "cancelled"))
     (if todos
         (mapconcat
          (lambda (todo)
            (format "- [%s] (%s) %s"
                    (plist-get todo :status)
                    (plist-get todo :priority)
                    (plist-get todo :content)))
          todos
          "\n")
       "No todos.")
     "\n</todo_list>")))

;;;;;; Subagents

(defun ellm-tools--present-string (value)
  "Return VALUE as a non-blank string, or nil."
  (when (and (stringp value) (not (ellm-tools--blank-p value)))
    value))

(defun ellm-tools--key-name (key)
  "Return KEY as a normalized string."
  (cond
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   ((stringp key) key)
   (t (format "%s" key))))

(defun ellm-tools--key-symbol (key)
  "Return KEY as a symbol suitable for YAML frontmatter alists."
  (intern (ellm-tools--key-name key)))

(defun ellm-tools--same-key-p (left right)
  "Return non-nil when LEFT and RIGHT name the same frontmatter key."
  (equal (ellm-tools--key-name left)
         (ellm-tools--key-name right)))

(defun ellm-tools--alist-delete-nested (alist keys)
  "Return ALIST without nested KEYS.
KEYS may be a single key or a list of keys.  Empty parent maps are removed."
  (let ((keys (if (listp keys) keys (list keys))))
    (if (null keys)
        alist
      (let ((key (car keys)))
        (delq
         nil
         (mapcar
          (lambda (cell)
            (cond
             ((not (consp cell)) cell)
             ((not (ellm-tools--same-key-p (car cell) key)) cell)
             ((null (cdr keys)) nil)
             ((listp (cdr cell))
              (let ((child (ellm-tools--alist-delete-nested
                            (cdr cell) (cdr keys))))
                (and child (cons (car cell) child))))
             (t cell)))
          alist))))))

(defun ellm-tools--frontmatter-set (frontmatter key value)
  "Return FRONTMATTER with top-level KEY set to VALUE."
  (append (ellm-tools--alist-delete-nested frontmatter key)
          (list (cons (ellm-tools--key-symbol key) value))))

(defun ellm-tools--format-profiles (frontmatter)
  "Return a model-readable catalog of effective profiles for FRONTMATTER."
  (let* ((profiles (ellm--effective-profiles frontmatter))
         (active (alist-get 'profile frontmatter)))
    (concat
     (format "<profiles%s>\n"
             (if active
                 (format " active=%S" (ellm--profile-name active))
               ""))
     (if profiles
         (string-join
          (mapcar
           (lambda (entry)
             (let* ((name (ellm--profile-name (car entry)))
                    (profile (cdr entry))
                    (description (alist-get 'description profile))
                    (model (alist-get 'model profile))
                    (tools (alist-get 'tools profile)))
               (concat
                (format "- name=%S" name)
                (and description (format " description=%S" description))
                (and model (format " model=%S" model))
                (and tools (format " tools=%S" tools)))))
           (sort (copy-sequence profiles)
                 (lambda (left right)
                   (string< (ellm--profile-name (car left))
                            (ellm--profile-name (car right))))))
          "\n")
       "No profiles configured.")
     "\n</profiles>")))

(defun ellm-tools--provider-name (provider)
  "Return PROVIDER as a provider name string, or nil."
  (cond
   ((null provider) nil)
   ((symbolp provider) (symbol-name provider))
   ((stringp provider) (ellm-tools--present-string provider))
   (t nil)))

(defun ellm-tools--provider-entry (provider)
  "Return `ellm-provider-alist' entry for PROVIDER name, or nil."
  (when-let* ((name (ellm-tools--provider-name provider)))
    (alist-get (intern name) ellm-provider-alist)))

(defun ellm-tools--model-name (model)
  "Return MODEL as a model name string, or nil."
  (cond
   ((null model) nil)
   ((symbolp model) (symbol-name model))
   ((stringp model) (ellm-tools--present-string model))
   (t nil)))

(defun ellm-tools--validate-subagent-frontmatter (frontmatter fallback-provider)
  "Validate provider/model selections in FRONTMATTER.
FALLBACK-PROVIDER is used when FRONTMATTER has no `provider:' key."
  (let* ((provider-name (ellm-tools--provider-name
                         (ellm--plistish-get frontmatter 'provider)))
         (entry (and provider-name
                     (ellm-tools--provider-entry provider-name))))
    (when (and provider-name (not entry))
      (ellm-tools--error "subagent provider not configured: %s" provider-name))
    (let* ((provider (if entry
                         (ellm--provider-entry-provider entry)
                       fallback-provider))
           (model (ellm-tools--model-name
                   (ellm--plistish-get frontmatter 'model)))
           (candidates (car (ellm--provider-model-candidates entry provider))))
      (unless provider
        (ellm-tools--error "subagent has no provider configured"))
      (when (and model candidates
                 (not (member model
                              (mapcar #'ellm--model-candidate-name candidates))))
        (ellm-tools--error
         "subagent model `%s' is not configured for provider `%s'"
         model (or provider-name "<fallback>"))))))

(defun ellm-tools--sanitize-subagent-frontmatter (frontmatter)
  "Return FRONTMATTER copied and safe for a fresh child buffer."
  (let ((result (copy-tree frontmatter)))
    (dolist (path '((acp session-id)
                    (acp title)
                    (title)
                    (acp updated-at)
                    (ellm role)
                    (codex prompt-cache-key)
                    (subagent)))
      (setq result (ellm--alist-delete-nested result path)))
    result))

(defun ellm-tools--subagent-depth (frontmatter)
  "Return the current subagent depth from FRONTMATTER.

Older live subagent buffers may not have persisted a depth.  Derive theirs
from their live parent when possible."
  (let ((depth (ellm--alist-get-nested frontmatter '(subagent depth))))
    (cond
     ((and (integerp depth) (>= depth 0)) depth)
     ((and ellm-subagent-id ellm-subagent-parent-buffer
           (get-buffer ellm-subagent-parent-buffer))
      (with-current-buffer (get-buffer ellm-subagent-parent-buffer)
        (1+ (ellm-tools--subagent-depth (ellm--parse-frontmatter)))))
     (t 0))))

(defun ellm-tools--more-restrictive-permission (left right)
  "Return the more restrictive of tool permissions LEFT and RIGHT."
  (if (>= (alist-get left '((allow . 0) (ask . 1) (deny . 2)))
          (alist-get right '((allow . 0) (ask . 1) (deny . 2))))
      left
    right))

(defun ellm-tools--add-subagent-selector-exclusions (frontmatter key entries)
  "Add selector ENTRIES to FRONTMATTER's exclusions for KEY."
  (if (null entries)
      frontmatter
    (let* ((exclusions (ellm--frontmatter-selector-entry-list
                        key (alist-get (ellm--frontmatter-selector-key key ?-)
                                       frontmatter)))
           (updated (delete-dups (append exclusions entries))))
      (ellm-tools--frontmatter-set
       frontmatter (ellm--frontmatter-selector-key key ?-) updated))))

(defun ellm-tools--restrict-subagent-frontmatter (parent child)
  "Add minimal restrictions preventing CHILD from exceeding PARENT.

The restrictions deliberately preserve CHILD's profile reference and its
configuration.  They constrain only capabilities that are currently broader
than PARENT; profiles therefore remain live configuration baselines."
  (let* ((parent (ellm--effective-frontmatter parent))
         (child-effective (ellm--effective-frontmatter child))
         (parent-tools (ellm--resolve-tools parent))
         (child-tools (ellm--resolve-tools child-effective))
         (excluded-tools
          (mapcar #'ellm-tool-name
                  (cl-remove-if (lambda (tool) (memq tool parent-tools))
                                child-tools)))
         (parent-mcp (ellm--resolve-mcp-servers parent))
         (excluded-mcp
          (mapcar #'car
                  (cl-remove-if
                   (lambda (server)
                     (cl-find (car server) parent-mcp :key #'car :test #'equal))
                   (ellm--resolve-mcp-servers child-effective))))
         permissions)
    (setq child (ellm-tools--add-subagent-selector-exclusions
                 child 'tools excluded-tools))
    (setq child (ellm-tools--add-subagent-selector-exclusions
                 child 'mcp excluded-mcp))
    (dolist (tool child-tools)
      (let* ((parent-policy (ellm--tool-permission-policy parent tool))
             (child-policy (ellm--tool-permission-policy child-effective tool))
             (policy (ellm-tools--more-restrictive-permission
                      parent-policy child-policy)))
        (unless (eq policy child-policy)
          (push (cons (ellm-tool-name tool) (symbol-name policy)) permissions))))
    (when permissions
      (setq child
            (ellm-tools--frontmatter-set
             child 'tool-permissions
             (ellm--merge-frontmatter-maps
              (alist-get 'tool-permissions child) permissions t))))
    child))

(defun ellm-tools--disable-subagent-tools (frontmatter)
  "Remove agent-management tools from FRONTMATTER's enabled tools."
  (ellm-tools--frontmatter-set
   frontmatter 'tools-
   (delete-dups
    (append (ellm--frontmatter-selector-entry-list
             'tools (alist-get 'tools- frontmatter))
            '("@agents")))))

(defun ellm-tools--subagent-frontmatter
    (parent-frontmatter id parent-id parent-name parent-file depth name prompt profile
                        cwd fallback-provider)
  "Return (FRONTMATTER . PROFILE-NAME) for a new subagent."
  (let* ((profile-name (and (ellm-tools--present-string profile)
                            (ellm--profile-name profile)))
         (frontmatter
          (if profile-name
              ;; The selected profile is the baseline.  Keep the catalog so the
              ;; child can resolve it itself, but do not inherit parent overrides.
              ;; `fallback-provider' remains buffer-local: it is used only when
              ;; the selected profile does not choose a provider.
              (let ((base (when-let* ((profiles (alist-get 'profiles parent-frontmatter)))
                            (list (cons 'profiles (copy-tree profiles))))))
                (ellm-tools--frontmatter-set base 'profile profile-name))
            ;; Preserve the parent's profile reference instead of serializing
            ;; its resolved system prompt into every child transcript.
            (ellm-tools--sanitize-subagent-frontmatter parent-frontmatter))))
    (when-let* ((value (ellm-tools--present-string cwd)))
      (setq frontmatter (ellm-tools--frontmatter-set frontmatter 'cwd value)))
    (setq frontmatter
          (ellm-tools--frontmatter-set frontmatter 'created (ellm--timestamp)))
    (setq frontmatter
          (ellm-tools--frontmatter-set
           frontmatter 'subagent
           (delq nil
                 (list (cons 'id id)
                       (cons 'depth depth)
                       (and parent-id (cons 'parent-id parent-id))
                       (cons 'parent-buffer parent-name)
                       (and parent-file (cons 'parent-file parent-file))
                       (and (ellm-tools--present-string name) (cons 'name name))
                       (and profile-name (cons 'profile profile-name))
                       (cons 'prompt (ellm-tools--prompt-summary prompt))))))
    (setq frontmatter
          (ellm-tools--restrict-subagent-frontmatter parent-frontmatter frontmatter))
    (when (and ellm-subagent-max-depth
               (>= depth ellm-subagent-max-depth))
      (setq frontmatter (ellm-tools--disable-subagent-tools frontmatter)))
    (ellm-tools--validate-subagent-frontmatter
     (ellm--effective-frontmatter frontmatter) fallback-provider)
    (cons frontmatter profile-name)))

(defun ellm-tools--next-subagent-id ()
  "Return the next subagent id for the current parent buffer."
  (setq ellm-subagent-counter (1+ (or ellm-subagent-counter 0)))
  (format "%s_%d" (or ellm-subagent-id "subagent") ellm-subagent-counter))

(defun ellm-tools--prompt-summary (prompt)
  "Return a short one-line summary of PROMPT."
  (truncate-string-to-width
   (car (split-string (string-trim (or prompt "")) "\n"))
   120 nil nil t))

(defun ellm-tools--subagent-buffer-name (id name profile)
  "Return a generated subagent buffer name for ID, NAME and PROFILE."
  (let ((label (or (ellm-tools--present-string name)
                   (ellm-tools--present-string profile)
                   id)))
    (format ellm-subagent-buffer-name-format label)))

(defun ellm-tools--create-subagent-buffer
    (id name profile prompt frontmatter fallback-provider parent-default-directory
        parent-buffer-name parent-session-directory parent-ephemeral-p)
  "Create, initialize, and send a subagent buffer."
  (let ((buf (generate-new-buffer
              (ellm-tools--subagent-buffer-name id name profile))))
    (condition-case err
        (with-current-buffer buf
          (setq default-directory parent-default-directory)
          (setq-local ellm--session-directory parent-session-directory)
          (setq-local ellm--persistence-ephemeral-p parent-ephemeral-p)
          (setq-local ellm-subagent-id id)
          (setq-local ellm-subagent-parent-buffer parent-buffer-name)
          (insert "---\n" (ellm--ensure-newline (ellm--yaml-encode frontmatter))
                  "---\n\n")
          (ellm-mode)
          (when fallback-provider
            (setq-local ellm-provider fallback-provider))
          (setq-local ellm--session-titling-p nil)
          (ellm--insert-turn "user")
          (insert (ellm--ensure-newline prompt))
          (ellm-send)
          buf)
      (error
       (when (buffer-live-p buf)
         (kill-buffer buf))
       (signal (car err) (cdr err))))))

(defun ellm-tools--ellm-buffer-status (buffer)
  "Return BUFFER status as a short string."
  (cond
   ((not (buffer-live-p buffer)) "dead")
   ((with-current-buffer buffer ellm--active-request) "running")
   (t "idle")))

(defun ellm-tools--record-subagent
    (id buffer name profile prompt frontmatter)
  "Record a launched subagent in the current buffer's history."
  (let ((entry (list :id id
                     :buffer-name (buffer-name buffer)
                     :name (ellm-tools--present-string name)
                     :profile profile
                     :created (ellm--timestamp)
                     :prompt (ellm-tools--prompt-summary prompt)
                     :file (buffer-file-name buffer)
                     :frontmatter (copy-tree frontmatter))))
    (push entry ellm-subagent-history)
    entry))

(defun ellm-tools--format-subagent-entry (entry)
  "Return a model-readable line for subagent history ENTRY."
  (let* ((buffer-name (plist-get entry :buffer-name))
         (buffer (and buffer-name (get-buffer buffer-name)))
         (file (plist-get entry :file))
         (status (if (and (not buffer) file (file-exists-p file))
                     "saved"
                   (ellm-tools--ellm-buffer-status buffer))))
    (format "- id=%s status=%s buffer=%S file=%S name=%S profile=%S created=%S prompt=%S"
            (plist-get entry :id)
            status
            buffer-name
            file
            (plist-get entry :name)
            (plist-get entry :profile)
            (plist-get entry :created)
            (plist-get entry :prompt))))

(defun ellm-tools--format-subagent-history (history)
  "Return model-readable HISTORY for launched subagents."
  (concat
   (format "<subagents total=%d>\n" (length history))
   (if history
       (string-join
        (mapcar #'ellm-tools--format-subagent-entry (reverse history))
        "\n")
     "No subagents.")
   "\n</subagents>"))

(defun ellm-tools--format-subagent-launch-result (entry buffer)
  "Return model-readable launch result for ENTRY and BUFFER."
  (format (concat "<subagent id=%S buffer=%S status=%S>\n"
                  "Use wait_subagent to wait for its result, or send_subagent to give it another task.\n"
                  "</subagent>")
          (plist-get entry :id)
          (buffer-name buffer)
          (ellm-tools--ellm-buffer-status buffer)))

(defun ellm-tools--launch-subagent (prompt profile name cwd)
  "Implementation for the `launch_subagent' tool."
  (ellm-tools--validate-pattern prompt "prompt")
  (ellm--persistence-checkpoint)
  (let* ((parent-buffer (current-buffer))
         (parent-buffer-name (buffer-name parent-buffer))
         (parent-id ellm-subagent-id)
         (parent-session-directory ellm--session-directory)
         (parent-file
          (and buffer-file-name parent-session-directory
               (file-relative-name
                buffer-file-name
                (expand-file-name "subagents/" parent-session-directory))))
         (parent-frontmatter (if (derived-mode-p 'ellm-mode)
                                 (ellm--parse-frontmatter)
                               nil))
         (depth (1+ (ellm-tools--subagent-depth parent-frontmatter)))
         (fallback-provider
          (if parent-frontmatter
              (ellm--resolve-provider
               (ellm--effective-frontmatter parent-frontmatter))
            ellm-provider))
         (parent-default-directory default-directory)
         (parent-ephemeral-p ellm--persistence-ephemeral-p)
         (id (ellm-tools--next-subagent-id))
         (frontmatter-entry
          (ellm-tools--subagent-frontmatter
           parent-frontmatter id parent-id parent-buffer-name parent-file depth name prompt
           profile cwd fallback-provider))
         (frontmatter (car frontmatter-entry))
         (profile-name (cdr frontmatter-entry))
         (buffer (ellm-tools--create-subagent-buffer
                  id name profile-name prompt frontmatter fallback-provider
                  parent-default-directory parent-buffer-name
                  parent-session-directory parent-ephemeral-p))
         (entry (ellm-tools--record-subagent
                 id buffer name profile-name prompt frontmatter)))
    (ellm-tools--format-subagent-launch-result entry buffer)))

(defun ellm-tools--subagent-target (subagent)
  "Return plist describing SUBAGENT from current buffer history.
SUBAGENT may be a remembered id or a live buffer name."
  (let* ((key (ellm-tools--present-string subagent))
         (entry (and key
                     (cl-find-if
                      (lambda (entry)
                        (or (equal key (plist-get entry :id))
                            (equal key (plist-get entry :buffer-name))))
                      ellm-subagent-history)))
         (file (plist-get entry :file))
         (buffer-name (or (plist-get entry :buffer-name) key))
         (buffer (or (and buffer-name (get-buffer buffer-name))
                     (and file (file-readable-p file)
                          (find-file-noselect file)))))
    (unless key
      (ellm-tools--error "subagent must be a non-empty id or buffer name"))
    (unless (or entry buffer)
      (ellm-tools--error "unknown subagent: %s" key))
    (when (and entry buffer)
      (setf (plist-get entry :buffer-name) (buffer-name buffer))
      (setq buffer-name (buffer-name buffer)))
    (when buffer
      (with-current-buffer buffer
        (unless (derived-mode-p 'ellm-mode)
          (ellm-tools--error "buffer is not an ellm buffer: %s" buffer-name))))
    (list :id (or (plist-get entry :id)
                  (and buffer
                       (with-current-buffer buffer ellm-subagent-id))
                  key)
          :buffer-name buffer-name
          :buffer buffer
          :entry entry)))

(defun ellm-tools--persisted-subagent-entry (file frontmatter)
  "Return a history entry for persisted subagent FILE and FRONTMATTER."
  (list :id (ellm--alist-get-nested frontmatter '(subagent id))
        :buffer-name (and-let* ((buffer (find-buffer-visiting file)))
                       (buffer-name buffer))
        :file file
        :name (ellm--alist-get-nested frontmatter '(subagent name))
        :profile (ellm--alist-get-nested frontmatter '(subagent profile))
        :created (alist-get 'created frontmatter)
        :prompt (ellm--alist-get-nested frontmatter '(subagent prompt))
        :frontmatter frontmatter))

(defun ellm-tools--read-persisted-subagent (file session-id parent-id)
  "Return a history entry for FILE when it belongs to SESSION-ID and PARENT-ID."
  (with-temp-buffer
    (insert-file-contents file)
    (when-let* ((frontmatter (ellm--parse-frontmatter t))
                (id (ellm--alist-get-nested frontmatter '(subagent id)))
                ((equal (ellm--alist-get-nested frontmatter '(ellm session-id))
                        session-id))
                ((equal (ellm--alist-get-nested frontmatter '(subagent parent-id))
                        parent-id)))
      (ellm-tools--persisted-subagent-entry file frontmatter))))

(defun ellm-tools--restore-persisted-subagents ()
  "Restore subagent identity and direct-child history from persisted files."
  (when (derived-mode-p 'ellm-mode)
    (let* ((frontmatter (ellm--parse-frontmatter t))
           (session-id (ellm--alist-get-nested frontmatter '(ellm session-id)))
           (id (ellm--alist-get-nested frontmatter '(subagent id)))
           (parent-file (ellm--alist-get-nested
                         frontmatter '(subagent parent-file))))
      (when id
        (setq-local ellm-subagent-id id)
        (when (and buffer-file-name parent-file)
          (when-let* ((parent (find-buffer-visiting
                               (expand-file-name parent-file
                                                 (file-name-directory
                                                  buffer-file-name)))))
            (setq-local ellm-subagent-parent-buffer (buffer-name parent)))))
      (when-let* ((directory ellm--session-directory)
                  (subagents-directory (expand-file-name "subagents/" directory))
                  ((file-directory-p subagents-directory)))
        (setq-local
         ellm-subagent-history
         (delq nil
               (mapcar (lambda (file)
                         (ellm-tools--read-persisted-subagent
                          file session-id id))
                       (directory-files subagents-directory t "\\.ellm\\'" t))))
        (let ((prefix (concat "\\`" (regexp-quote (or id "subagent"))
                              "_\\([0-9]+\\)\\'")))
          (setq-local
           ellm-subagent-counter
           (cl-loop for entry in ellm-subagent-history
                    for child-id = (plist-get entry :id)
                    when (and child-id (string-match prefix child-id))
                    maximize (string-to-number (match-string 1 child-id))
                    into maximum
                    finally return (or maximum 0))))))))

(defun ellm-tools--last-assistant-content (buffer)
  "Return BUFFER's last assistant turn content, or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((turn (cl-find-if
                         (lambda (turn)
                           (equal (ellm-turn-role turn) "assistant"))
                         (reverse (ellm--parse-turns)))))
        (ellm-turn-content turn)))))

(defun ellm-tools--wait-subagent (subagent callback)
  "Wait asynchronously for SUBAGENT, then call CALLBACK with its result."
  (let* ((target (ellm-tools--subagent-target subagent))
         (buffer (plist-get target :buffer))
         listener done)
    (cl-labels
        ((running-p ()
                    (and (buffer-live-p buffer)
                         (with-current-buffer buffer ellm--active-request)))
         (cleanup ()
                  (when (and listener (buffer-live-p buffer))
                    (with-current-buffer buffer
                      (remove-hook 'ellm-request-finished-hook listener t))))
         (finish ()
                 (unless done
                   (setq done t)
                   (cleanup)
                   (let ((content (ellm-tools--last-assistant-content buffer)))
                     (funcall callback
                              (or content
                                  (format "Subagent %s has no assistant response available."
                                          (plist-get target :id))))))))
      (setq listener (lambda (_request _outcome) (finish)))
      (if (running-p)
          (with-current-buffer buffer
            (add-hook 'ellm-request-finished-hook listener nil t))
        (finish))
      (lambda ()
        (setq done t)
        (cleanup)))))

(defun ellm-tools--append-ellm-prompt (prompt)
  "Append PROMPT to the current ellm buffer as the next user turn."
  (when-let* ((text (ellm-tools--present-string prompt)))
    (let* ((turns (ellm--parse-turns))
           (last-turn (car (last turns))))
      (if (and last-turn
               (equal (ellm-turn-role last-turn) "user")
               (ellm-tools--blank-p (ellm-turn-content last-turn)))
          (progn
            (goto-char (ellm-turn-beg last-turn))
            (delete-region (ellm-turn-beg last-turn)
                           (ellm-turn-end last-turn))
            (insert (ellm--ensure-newline text)))
        (ellm--insert-turn "user")
        (insert (ellm--ensure-newline text))))))

(defun ellm-tools--send-subagent (subagent prompt)
  "Implementation for the `send_subagent' tool."
  (let* ((target (ellm-tools--subagent-target subagent))
         (entry (plist-get target :entry))
         (buffer (plist-get target :buffer)))
    (unless entry
      (ellm-tools--error "unknown subagent: %s" subagent))
    (unless buffer
      (ellm-tools--error "subagent buffer is unavailable: %s"
                         (plist-get target :id)))
    (ellm-tools--validate-pattern prompt "prompt")
    (with-current-buffer buffer
      (when ellm--active-request
        (ellm-tools--error "subagent already has a request in flight: %s"
                           (plist-get target :id)))
      (ellm-tools--append-ellm-prompt prompt)
      (ellm-send)
      (format "<subagent id=%S buffer=%S status=%S>\nSent.\n</subagent>"
              (plist-get target :id)
              (buffer-name buffer)
              (ellm-tools--ellm-buffer-status buffer)))))

;;;;;; Webfetch

(declare-function dom-by-tag "dom")
(declare-function dom-text "dom")
(declare-function shr-insert-document "shr")
(declare-function url-expand-file-name "url-expand")
(declare-function url-generic-parse-url "url-parse")
(declare-function url-hexify-string "url-util")
(declare-function url-host "url-parse")
(declare-function url-recreate-url "url-parse")
(declare-function url-retrieve "url")
(declare-function url-retrieve-synchronously "url")
(declare-function url-type "url-parse")
(declare-function url-unhex-string "url-util")

(defvar shr-base)
(defvar shr-fill-text)
(defvar shr-inhibit-images)
(defvar shr-use-colors)
(defvar shr-use-fonts)
(defvar url-current-object)
(defvar url-request-extra-headers)
(defvar url-request-method)
(defvar url-user-agent)

(defun ellm-tools--validate-webfetch-url (url)
  "Signal an error unless URL is an absolute HTTP or HTTPS URL."
  (require 'url-parse)
  (ellm-tools--validate-pattern url "url")
  (let ((parsed (url-generic-parse-url url)))
    (unless (and (member (downcase (or (url-type parsed) ""))
                         '("http" "https"))
                 (not (ellm-tools--blank-p (url-host parsed))))
      (ellm-tools--error "url must be an absolute HTTP or HTTPS URL"))))

(defun ellm-tools--webfetch-header (name header-end)
  "Return response header NAME before HEADER-END in the current buffer."
  (save-restriction
    (narrow-to-region (point-min) header-end)
    (mail-fetch-field name)))

(defun ellm-tools--webfetch-content-type (header body)
  "Return normalized content type from HEADER and BODY."
  (let ((type (and header
                   (downcase
                    (string-trim
                     (car (split-string header ";")))))))
    (cond
     ((not (ellm-tools--blank-p type)) type)
     ((string-match-p
       "\\`[[:space:]\ufeff]*<\\(?:!doctype[[:space:]]+html\\|html\\|head\\|body\\)"
       (downcase (substring body 0 (min 1024 (length body)))))
      "text/html")
     (t "text/plain"))))

(defun ellm-tools--webfetch-textual-content-type-p (content-type)
  "Return non-nil when CONTENT-TYPE is suitable for textual output."
  (or (string-prefix-p "text/" content-type)
      (string-match-p
       "\\`application/\\(?:[^;]+[+]\\)?\\(?:json\\|xml\\)\\'"
       content-type)
      (member content-type
              '("application/javascript" "application/x-javascript"))))

(defun ellm-tools--webfetch-decode-text (text content-type)
  "Decode response TEXT according to CONTENT-TYPE."
  (let* ((case-fold-search t)
         (charset (and (string-match
                        "charset=[ \t]*[\"']?\\([^; \t\"']+\\)"
                        content-type)
                       (match-string 1 content-type)))
         (coding (and charset
                      (ignore-errors
                        (coding-system-from-name charset)))))
    (decode-coding-string text (or coding 'utf-8) t)))

(defun ellm-tools--webfetch-markdown-link (text url)
  "Return a Markdown link for TEXT and URL."
  (let ((label (string-replace
                "]" "\\]"
                (string-replace "[" "\\["
                                (string-replace "\\" "\\\\" text))))
        (destination (string-replace
                      ")" "\\)" (string-replace "\\" "\\\\" url))))
    (format "[%s](%s)" label destination)))

(defun ellm-tools--webfetch-clean-text (text)
  "Clean rendered webfetch TEXT without destroying its line structure."
  (setq text (replace-regexp-in-string "[ \t]+$" "" text))
  (setq text (replace-regexp-in-string "\\n\\{3,\\}" "\n\n" text))
  (string-trim text))

(defconst ellm-tools--webfetch-readable-minimum-words 100
  "Minimum visible words required for a readable HTML candidate.")

(defconst ellm-tools--webfetch-readable-minimum-characters 400
  "Minimum rendered characters required for readable HTML output.")

(defconst ellm-tools--webfetch-non-content-tags
  '(script style noscript template svg)
  "HTML tags whose text should not affect readability scoring.")

(defconst ellm-tools--webfetch-chrome-tags
  '(nav header footer aside)
  "HTML tags that are not themselves readable-content candidates.")

(defun ellm-tools--webfetch-dom-attribute (node attribute)
  "Return ATTRIBUTE from DOM NODE."
  (cdr (assq attribute (cadr node))))

(defun ellm-tools--webfetch-word-count (text)
  "Return the number of whitespace-separated words in TEXT."
  (length (split-string text "[[:space:]]+" t)))

(defun ellm-tools--webfetch-readable-node (document)
  "Return the best readable-content node in DOCUMENT, or nil.
Each candidate is scored from its visible word count minus twice its linked
word count, which favors prose over navigation.  `main', `article', and
`role=\"main\"' candidates receive a bonus; common chrome identifiers receive
a penalty.  Text under chrome tags and non-content tags is ignored, so it
neither becomes a candidate nor inflates an ancestor's score.  Candidates
must contain at least `ellm-tools--webfetch-readable-minimum-words' words.

This does not change DOCUMENT: the selected subtree is rendered separately,
allowing the caller to fall back to the full document when it is too short or
does not materially reduce the output."
  (let ((statistics (make-hash-table :test #'eq))
        candidates)
    (cl-labels
        ((visit (node in-link in-chrome)
                (cond
                 ((stringp node)
                  (let ((words (if in-chrome 0
                                 (ellm-tools--webfetch-word-count node))))
                    (list :words words :link-words (if in-link words 0))))
                 ((not (consp node))
                  (list :words 0 :link-words 0))
                 (t
                  (let ((tag (car node)))
                    (if (memq tag ellm-tools--webfetch-non-content-tags)
                        (list :words 0 :link-words 0)
                      (let ((words 0)
                            (link-words 0)
                            (chrome (or in-chrome
                                        (memq tag ellm-tools--webfetch-chrome-tags))))
                        (dolist (child (cddr node))
                          (let ((child-statistics
                                 (visit child (or in-link (eq tag 'a)) chrome)))
                            (cl-incf words (plist-get child-statistics :words))
                            (cl-incf link-words
                                     (plist-get child-statistics :link-words))))
                        (let* ((role (ellm-tools--webfetch-dom-attribute node 'role))
                               (identifier
                                (concat (or (ellm-tools--webfetch-dom-attribute node 'id) "")
                                        " "
                                        (or (ellm-tools--webfetch-dom-attribute node 'class) "")))
                               (semantic (or (memq tag '(main article))
                                             (equal role "main")))
                               (score (- words (* 2 link-words))))
                          (when semantic
                            (cl-incf score 100))
                          (when (string-match-p
                                 "\\_<\\(nav\\|menu\\|sidebar\\|footer\\|cookie\\|banner\\|modal\\)\\_>"
                                 identifier)
                            (cl-decf score 100))
                          (let ((result (list :words words :link-words link-words
                                              :score score)))
                            (puthash node result statistics)
                            (unless chrome
                              (push node candidates))
                            result)))))))))
      (visit document nil nil)
      (car
       (sort (seq-filter
              (lambda (node)
                (>= (plist-get (gethash node statistics) :words)
                    ellm-tools--webfetch-readable-minimum-words))
              candidates)
             (lambda (left right)
               (> (plist-get (gethash left statistics) :score)
                  (plist-get (gethash right statistics) :score))))))))

(defun ellm-tools--webfetch-render-document (document base-url)
  "Render HTML DOCUMENT with SHR using BASE-URL."
  (require 'shr)
  (require 'url-expand)
  (with-temp-buffer
    (let ((shr-base base-url)
          (shr-use-fonts nil)
          (shr-fill-text nil)
          (shr-use-colors nil)
          (shr-inhibit-images t))
      (shr-insert-document document))
    (goto-char (point-min))
    (while-let ((match (text-property-search-forward 'shr-url nil nil t)))
      (let* ((begin (prop-match-beginning match))
             (end (prop-match-end match))
             (url (url-expand-file-name
                   (get-text-property begin 'shr-url) base-url))
             (text (buffer-substring-no-properties begin end))
             (link (ellm-tools--webfetch-markdown-link text url)))
        (replace-region-contents begin end (lambda () link))
        (goto-char (+ begin (length link)))))
    (ellm-tools--webfetch-clean-text
     (buffer-substring-no-properties (point-min) (point-max)))))

(defun ellm-tools--webfetch-readable-content-p (content full-content)
  "Return non-nil when CONTENT is a useful reduction of FULL-CONTENT."
  (and (>= (ellm-tools--webfetch-word-count content)
           ellm-tools--webfetch-readable-minimum-words)
       (>= (length content) ellm-tools--webfetch-readable-minimum-characters)
       (< (length content) (* (length full-content) 0.95))))

(defun ellm-tools--webfetch-render-html (html base-url)
  "Render readable HTML from HTML using BASE-URL.
Return a plist containing `:title', `:content', and `:readable'."
  (require 'dom)
  (unless (fboundp 'libxml-parse-html-region)
    (error "HTML rendering requires Emacs with libxml2 support"))
  (with-temp-buffer
    (insert html)
    (let* ((dom (libxml-parse-html-region (point-min) (point-max)))
           (title-node (car (dom-by-tag dom 'title)))
           (title (and title-node
                       (ellm-tools--clean-text (dom-text title-node))))
           (document (or (car (dom-by-tag dom 'body)) dom))
           (full-content (ellm-tools--webfetch-render-document document base-url))
           (readable-node (ellm-tools--webfetch-readable-node document))
           (readable-content
            (and readable-node
                 (ellm-tools--webfetch-render-document readable-node base-url)))
           (readable (and readable-content
                          (ellm-tools--webfetch-readable-content-p
                           readable-content full-content))))
      (list :title title
            :content (if readable readable-content full-content)
            :readable readable))))

(defun ellm-tools--webfetch-response-body (byte-limit)
  "Return the current HTTP response body capped at BYTE-LIMIT.
The return value is a cons of body and whether it was truncated."
  (goto-char (point-min))
  (unless (re-search-forward "\r?\n\r?\n" nil t)
    (error "Malformed HTTP response"))
  (let* ((start (point))
         (available (- (position-bytes (point-max))
                       (position-bytes start)))
         (truncated (> available byte-limit))
         (end (if truncated
                  (or (byte-to-position (+ (position-bytes start) byte-limit))
                      (point-max))
                (point-max))))
    (cons (buffer-substring-no-properties start end) truncated)))

(defun ellm-tools--webfetch (url character-limit user-agent response-byte-limit)
  "Fetch and render URL for the `web_fetch' tool."
  ;; The parent applies CHARACTER-LIMIT so it can retain the complete rendering.
  (ignore character-limit)
  (require 'url)
  (require 'url-parse)
  (condition-case err
      (let ((url-user-agent user-agent)
            (url-request-method "GET")
            (url-request-extra-headers
             '(("Accept" . "text/html,application/xhtml+xml,application/json,text/plain;q=0.9,application/xml;q=0.8,*/*;q=0.1")))
            (buffer (url-retrieve-synchronously url t t)))
        (unless (buffer-live-p buffer)
          (error "request returned no data"))
        (unwind-protect
            (with-current-buffer buffer
              (goto-char (point-min))
              (unless (looking-at "HTTP/[0-9.]+[ \t]+\\([0-9]+\\)")
                (error "Malformed HTTP status line"))
              (let ((status (string-to-number (match-string 1))))
                (unless (<= 200 status 299)
                  (error "HTTP request failed with status %d" status))
                (save-excursion
                  (unless (re-search-forward "\r?\n\r?\n" nil t)
                    (error "Malformed HTTP response"))
                  (let* ((header-end (point))
                         (content-type-header
                          (ellm-tools--webfetch-header
                           "Content-Type" header-end))
                         (final-url
                          (if url-current-object
                              (url-recreate-url url-current-object)
                            url))
                         (body-result
                          (ellm-tools--webfetch-response-body
                           response-byte-limit))
                         (body (car body-result))
                         (response-truncated (cdr body-result))
                         (content-type
                          (ellm-tools--webfetch-content-type
                           content-type-header body))
                         rendered)
                    (cond
                     ((member content-type
                              '("text/html" "application/xhtml+xml"))
                      (setq rendered
                            (ellm-tools--webfetch-render-html
                             (ellm-tools--webfetch-decode-text
                              body (or content-type-header content-type))
                             final-url)))
                     ((ellm-tools--webfetch-textual-content-type-p content-type)
                      (setq rendered
                            (list :content
                              (ellm-tools--webfetch-clean-text
                               (ellm-tools--webfetch-decode-text
                                body (or content-type-header
                                         content-type))))))
                     (t
                      (error "Unsupported content type: %s" content-type)))
                    (let* ((content (or (plist-get rendered :content) ""))
                           (output-truncated (> (length content)
                                                character-limit)))
                      (list :ok t
                            :url url
                            :final-url final-url
                            :status status
                            :content-type content-type
                            :title (plist-get rendered :title)
                            :readable (plist-get rendered :readable)
                            :truncated (or response-truncated output-truncated)
                            :response-truncated response-truncated
                            :output-truncated output-truncated
                            :content content))))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))
    (error
     (list :ok nil :message (error-message-string err)))))

(defun ellm-tools--encode-webfetch-result (result)
  "Encode child webfetch RESULT for safe transport through `async-start'."
  (base64-encode-string
   (encode-coding-string (prin1-to-string result) 'utf-8-emacs-unix)
   t))

(defun ellm-tools--decode-webfetch-result (encoded)
  "Decode an ENCODED child webfetch result."
  (unless (stringp encoded)
    (error "Child Emacs returned an invalid result"))
  (car (read-from-string
        (decode-coding-string (base64-decode-string encoded)
                              'utf-8-emacs-unix))))

(defun ellm-tools--format-webfetch-result (result)
  "Format child webfetch RESULT for the model."
  (if (not (plist-get result :ok))
      (format "Web fetch failed: %s"
              (or (plist-get result :message) "unknown child process error"))
    (concat
     (format
      "<webfetch url=%S final-url=%S status=%d content-type=%S readable=%s truncated=%s>\n"
      (plist-get result :url)
      (plist-get result :final-url)
      (plist-get result :status)
      (plist-get result :content-type)
      (if (plist-get result :readable) "true" "false")
      (if (plist-get result :truncated) "true" "false"))
     (when-let* ((title (plist-get result :title))
                 ((not (ellm-tools--blank-p title))))
       (format "Title: %s\n\n" title))
     (let* ((content (plist-get result :content))
            (output-truncated (plist-get result :output-truncated))
            (response-truncated (plist-get result :response-truncated)))
       (concat
        (if output-truncated
            (concat (substring content 0 (min (length content)
                                              ellm-tools-webfetch-character-limit))
                    (ellm-tools--truncation-marker
                     "webfetch" content
                     (format "showing first %d characters"
                             ellm-tools-webfetch-character-limit)))
          content)
        (when response-truncated
          "\n\n[... response truncated at the capture limit; omitted content is unavailable ...]")))
     "\n</webfetch>")))

(defun ellm-tools--start-webfetch (url limit callback)
  "Fetch URL in a child Emacs and pass at most LIMIT characters to CALLBACK."
  (let* ((conversation (current-buffer))
         (async-process-noquery-on-exit t)
         ;; Arbitrary webpage text may match `tramp-password-prompt-regexp'.
         (async-prompt-for-password nil)
         (completed nil)
         (cancelled nil)
         (process
          (async-start
           (ellm-tools--elisp-child-form
            `(progn
               (require 'ellm-tools)
               (ellm-tools--encode-webfetch-result
                (ellm-tools--webfetch
                 ,url ,limit ,ellm-tools-webfetch-user-agent
                 ,ellm-tools-webfetch-response-byte-limit)))
            load-path exec-path default-directory)
           (lambda (result)
             (unless (async-message-p result)
               (setq completed t)
               (funcall
                callback
                (condition-case err
                    (with-current-buffer conversation
                      (ellm-tools--format-webfetch-result
                       (ellm-tools--decode-webfetch-result result)))
                  (error
                   (format "Web fetch child failed: %s"
                           (error-message-string err))))))))))
    (let ((async-sentinel (process-sentinel process)))
      (set-process-sentinel
       process
       (lambda (proc event)
         (condition-case err
             (when async-sentinel
               (funcall async-sentinel proc event))
           (error
            (unless (or completed cancelled)
              (setq completed t)
              (funcall callback
                       (format "Web fetch child failed: %s"
                               (error-message-string err))))))
         (when (and (not completed)
                    (not cancelled)
                    (memq (process-status proc) '(exit signal)))
           (setq completed t)
           (funcall callback
                    (format "Web fetch child exited unexpectedly (%s)"
                            (string-trim event)))))))
    (lambda ()
      (setq cancelled t)
      (ellm-tools--cancel-elisp-process process))))

;;;;;; Websearch

(defun ellm-tools--websearch (query limit endpoint)
  "Synchronously search ENDPOINT for QUERY and format LIMIT results."
  (require 'url)
  (require 'url-util)
  (let* ((url-request-method "GET")
         (url (concat endpoint
                      (if (string-match-p "[?&]\\'" endpoint)
                          ""
                        (if (string-match-p "\\?" endpoint) "&" "?"))
                      "q=" (url-hexify-string query)))
         (buffer (url-retrieve-synchronously url)))
    (unless buffer
      (error "DuckDuckGo returned no response"))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (unless (re-search-forward "\r?\n\r?\n" nil t)
            (error "Malformed HTTP response"))
          (ellm-tools--format-websearch-results
           query
           (ellm-tools--parse-duckduckgo-html
            (buffer-substring-no-properties (point) (point-max)) limit)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ellm-tools--start-websearch (query limit callback)
  "Search DuckDuckGo in a child Emacs and pass LIMIT results to CALLBACK."
  (let* ((async-process-noquery-on-exit t)
         ;; Search result text may match `tramp-password-prompt-regexp'.
         (async-prompt-for-password nil)
         (completed nil)
         (cancelled nil)
         (process
          (async-start
           (ellm-tools--elisp-child-form
            `(progn
               (require 'ellm-tools)
               (condition-case err
                   (ellm-tools--websearch
                    ,query ,limit ,ellm-tools-websearch-url)
                 (error
                  (format "DuckDuckGo search failed: %s"
                          (error-message-string err)))))
            load-path exec-path default-directory)
           (lambda (result)
             (unless (async-message-p result)
               (setq completed t)
               (funcall callback
                        (if (stringp result)
                            result
                          "DuckDuckGo search child returned an invalid result")))))))
    (let ((async-sentinel (process-sentinel process)))
      (set-process-sentinel
       process
       (lambda (proc event)
         (condition-case err
             (when async-sentinel
               (funcall async-sentinel proc event))
           (error
            (unless (or completed cancelled)
              (setq completed t)
              (funcall callback
                       (format "DuckDuckGo search child failed: %s"
                               (error-message-string err))))))
         (when (and (not completed)
                    (not cancelled)
                    (memq (process-status proc) '(exit signal)))
           (setq completed t)
           (funcall callback
                    (format "DuckDuckGo search child exited unexpectedly (%s)"
                            (string-trim event)))))))
    (lambda ()
      (setq cancelled t)
      (ellm-tools--cancel-elisp-process process))))

(defun ellm-tools--dom-node-p (node)
  "Return non-nil when NODE is an XML/HTML DOM node."
  (and (consp node) (symbolp (car node))))

(defun ellm-tools--dom-attr (node attr)
  "Return NODE's ATTR value."
  (cdr (assq attr (cadr node))))

(defun ellm-tools--dom-class-p (node class)
  "Return non-nil when NODE has CSS CLASS."
  (member class
          (split-string (or (ellm-tools--dom-attr node 'class) "")
                        "[[:space:]]+" t)))

(defun ellm-tools--dom-descendants-with-class (node class)
  "Return descendants of NODE that have CSS CLASS."
  (let (result)
    (cl-labels ((walk (child)
                      (when (ellm-tools--dom-node-p child)
                        (when (ellm-tools--dom-class-p child class)
                          (push child result))
                        (dolist (grandchild (cddr child))
                          (walk grandchild)))))
      (walk node))
    (nreverse result)))

(defun ellm-tools--dom-text (node)
  "Return textual contents of DOM NODE."
  (cond
   ((stringp node) node)
   ((ellm-tools--dom-node-p node)
    (mapconcat #'ellm-tools--dom-text (cddr node) ""))
   (t "")))

(defun ellm-tools--clean-text (text)
  "Normalize whitespace in TEXT."
  (string-trim (replace-regexp-in-string
                "[[:space:]\n\r]+" " " (or text ""))))

(defun ellm-tools--decode-html-entities (text)
  "Decode common HTML entities in TEXT."
  (let ((decoded (ellm-tools--replace-all '(("&amp;" . "&")
                                  ("&lt;" . "<")
                                  ("&gt;" . ">")
                                  ("&quot;" . "\"")
                                  ("&#39;" . "'")
                                  ("&apos;" . "'"))
                                (or text ""))))
    (setq decoded
          (replace-regexp-in-string
           "&#x\\([0-9a-fA-F]+\\);"
           (lambda (match)
             (if (string-match "\\`&#x\\([0-9a-fA-F]+\\);\\'" match)
                 (char-to-string (string-to-number (match-string 1 match) 16))
               match))
           decoded t t))
    (replace-regexp-in-string
     "&#\\([0-9]+\\);"
     (lambda (match)
       (if (string-match "\\`&#\\([0-9]+\\);\\'" match)
           (char-to-string (string-to-number (match-string 1 match)))
         match))
     decoded t t)))

(defun ellm-tools--strip-html-tags (html)
  "Return HTML with tags stripped and entities decoded."
  (ellm-tools--clean-text
   (ellm-tools--decode-html-entities
    (replace-regexp-in-string "<[^>]+>" " " (or html "")))))

(defun ellm-tools--duckduckgo-result-url (href)
  "Return the destination URL for a DuckDuckGo result HREF."
  (require 'url-util)
  (when (and href (not (ellm-tools--blank-p href)))
    (let ((url (ellm-tools--decode-html-entities href)))
      (when (string-prefix-p "//" url)
        (setq url (concat "https:" url)))
      (if (string-match "[?&]uddg=\\([^&]+\\)" url)
          (url-unhex-string (match-string 1 url))
        (if (string-prefix-p "/" url)
            (concat "https://duckduckgo.com" url)
          url)))))

(defun ellm-tools--parse-duckduckgo-html-with-libxml (html limit)
  "Parse DuckDuckGo HTML using libxml and return up to LIMIT result plists."
  (when (and (fboundp 'libxml-parse-html-region)
             (or (not (fboundp 'libxml-available-p))
                 (libxml-available-p)))
    (with-temp-buffer
      (insert html)
      (let* ((dom (libxml-parse-html-region (point-min) (point-max)))
             (nodes (ellm-tools--dom-descendants-with-class dom "result"))
             (seen (make-hash-table :test 'equal))
             results)
        (dolist (node nodes)
          (when (< (length results) limit)
            (when-let* ((anchor (car (ellm-tools--dom-descendants-with-class
                                      node "result__a")))
                        (title (ellm-tools--clean-text
                                (ellm-tools--dom-text anchor)))
                        (href (ellm-tools--dom-attr anchor 'href))
                        (url (ellm-tools--duckduckgo-result-url href)))
              (unless (or (ellm-tools--blank-p title)
                          (gethash url seen))
                (puthash url t seen)
                (push (list :title title
                            :url url
                            :snippet
                            (let ((snippet-node
                                   (car (ellm-tools--dom-descendants-with-class
                                         node "result__snippet"))))
                              (ellm-tools--clean-text
                               (and snippet-node
                                    (ellm-tools--dom-text snippet-node)))))
                      results)))))
        (nreverse results)))))

(defun ellm-tools--html-attr (attrs attr)
  "Return ATTR from an HTML attribute string ATTRS."
  (when (string-match (format "%s=[\"']\\([^\"']+\\)[\"']" attr) attrs)
    (match-string 1 attrs)))

(defun ellm-tools--parse-duckduckgo-html-with-regexp (html limit)
  "Parse DuckDuckGo HTML with regex fallback and return LIMIT result plists."
  (let ((pos 0)
        (seen (make-hash-table :test 'equal))
        results)
    (while (and (< (length results) limit)
                (string-match
                 "<a\\([^>]*\\)>\\(\\(?:.\\|\n\\)*?\\)</a>" html pos))
      (let* ((attrs (match-string 1 html))
             (body (match-string 2 html))
             (end (match-end 0))
             (class (ellm-tools--html-attr attrs "class"))
             (href (ellm-tools--html-attr attrs "href")))
        (setq pos end)
        (when (and class
                   (member "result__a" (split-string class "[[:space:]]+" t))
                   href)
          (let* ((title (ellm-tools--strip-html-tags body))
                 (url (ellm-tools--duckduckgo-result-url href))
                 (next (or (string-match
                            "<a[^>]*class=[\"'][^\"']*result__a" html end)
                           (length html)))
                 (block (substring html end (min next (+ end 5000))))
                 (snippet
                  (when (string-match
                         "class=[\"'][^\"']*result__snippet[^\"']*[\"'][^>]*>\\(\\(?:.\\|\n\\)*?\\)</\\(?:a\\|div\\)>"
                         block)
                    (ellm-tools--strip-html-tags (match-string 1 block)))))
            (unless (or (not url) (ellm-tools--blank-p title) (gethash url seen))
              (puthash url t seen)
              (push (list :title title :url url :snippet (or snippet ""))
                    results))))))
    (nreverse results)))

(defun ellm-tools--parse-duckduckgo-html (html limit)
  "Parse DuckDuckGo HTML and return up to LIMIT result plists."
  (or (condition-case nil
          (ellm-tools--parse-duckduckgo-html-with-libxml html limit)
        (error nil))
      (ellm-tools--parse-duckduckgo-html-with-regexp html limit)))

(defun ellm-tools--format-websearch-results (query results)
  "Return a model-readable websearch result string for QUERY and RESULTS."
  (if results
      (concat
       (format "<websearch query=%S results=%d>\n" query (length results))
       (mapconcat
        (lambda (indexed)
          (let ((index (car indexed))
                (result (cdr indexed)))
            (concat
             (format "%d. %s\nURL: %s"
                     index
                     (plist-get result :title)
                     (plist-get result :url))
             (let ((snippet (plist-get result :snippet)))
               (unless (ellm-tools--blank-p snippet)
                 (concat "\nSnippet: " snippet))))))
        (cl-loop for result in results
                 for index from 1
                 collect (cons index result))
        "\n\n")
       "\n</websearch>")
    (format "No web search results found for %S." query)))

;;;;;; Edit tool

(defun ellm-tools--set-file-edit-buffer-mode (file-path)
  "Select the syntax mode needed by checks for a temporary file-edit buffer."
  (when (string-equal (downcase (or (file-name-extension file-path) ""))
                      "el")
    (delay-mode-hooks
      (emacs-lisp-mode))))

(defun ellm-tools-file-edit-check-elisp-parens (file-path buffer callback)
  "Report an unmatched delimiter in Emacs Lisp FILE-PATH, if any.
BUFFER contains the edited contents.  CALLBACK receives nil when the contents
are balanced, or a concise diagnostic string otherwise."
  (if (not (and file-path
                (string-equal (downcase (or (file-name-extension file-path) ""))
                              "el")))
      (funcall callback nil)
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          (condition-case err
              (progn
                (check-parens)
                (funcall callback nil))
            (user-error
             (funcall callback
                      (format "Emacs Lisp has an unmatched delimiter near line %d, column %d: %s"
                              (line-number-at-pos) (current-column)
                              (error-message-string err)))))))))
  nil)

(defun ellm-tools-file-edit-check-json (file-path buffer callback)
  "Report invalid JSON in FILE-PATH, if any.
JSON with comments is deliberately not supported.  BUFFER contains the edited
contents and CALLBACK receives nil or a concise diagnostic string."
  (if (not (and file-path
                (string-equal (downcase (or (file-name-extension file-path) ""))
                              "json")))
      (funcall callback nil)
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (condition-case err
              (progn
                (require 'json)
                (if (fboundp 'json-parse-buffer)
                    (json-parse-buffer)
                  (json-read))
                (skip-chars-forward " \t\n\r")
                (unless (eobp)
                  (error "Unexpected content after JSON value"))
                (funcall callback nil))
            (error
             (funcall callback
                      (format "JSON is invalid near line %d, column %d: %s"
                              (line-number-at-pos) (current-column)
                              (error-message-string err)))))))))
  nil)

(defun ellm-tools--file-edit-shell-shebang-p (buffer)
  "Return non-nil when BUFFER starts with a shell shebang."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (looking-at "#!.*\\_<[^ \\t\\n]*sh\\_>"))))

(defun ellm-tools--start-file-edit-command-checker
    (name program arguments callback)
  "Run PROGRAM with ARGUMENTS and report a failed check through CALLBACK."
  (if (not (executable-find program))
      (progn
        (funcall callback (format "%s check could not find executable %S"
                                  name program))
        nil)
    (let ((output-buffer (generate-new-buffer " *ellm-tools-check*"))
          finished process)
      (setq process
            (make-process
             :name (concat "ellm-tools-" (downcase name) "-check")
             :buffer output-buffer
             :stderr output-buffer
             :command (cons program arguments)
             :noquery t
             :connection-type 'pipe
             :sentinel
             (lambda (proc _event)
               (when (and (memq (process-status proc) '(exit signal))
                          (not finished))
                 (setq finished t)
                 (let ((exit-code (process-exit-status proc))
                       (output (with-current-buffer output-buffer
                                 (string-trim (buffer-string)))))
                   (when (buffer-live-p output-buffer)
                     (kill-buffer output-buffer))
                   (funcall callback
                            (unless (zerop exit-code)
                              (format "%s check failed (exit code %d)%s"
                                      name exit-code
                                      (if (string-empty-p output)
                                          ""
                                        (concat ": " output))))))))))
      (lambda ()
        (when (process-live-p process)
          (kill-process process))
        (when (buffer-live-p output-buffer)
          (kill-buffer output-buffer))))))

(defun ellm-tools-file-edit-check-shell-syntax (file-path buffer callback)
  "Run a configurable shell syntax check for FILE-PATH when applicable.
The checker applies to .sh files and shell shebangs.  It skips modified
visiting buffers because the external program can only inspect disk contents."
  (if (and file-path
           (not (buffer-modified-p buffer))
           (or (string-equal (downcase (or (file-name-extension file-path) ""))
                             "sh")
               (ellm-tools--file-edit-shell-shebang-p buffer)))
      (ellm-tools--start-file-edit-command-checker
       "Shell syntax" ellm-tools-file-edit-shell-program
       (list "-n" file-path) callback)
    (funcall callback nil)
    nil))

(defun ellm-tools-file-edit-check-python-syntax (file-path buffer callback)
  "Run a configurable Python syntax check for .py FILE-PATH.
The checker skips modified visiting buffers because the external program can
only inspect disk contents."
  (if (and file-path
           (not (buffer-modified-p buffer))
           (string-equal (downcase (or (file-name-extension file-path) ""))
                         "py"))
      (ellm-tools--start-file-edit-command-checker
       "Python syntax" ellm-tools-file-edit-python-program
       (list "-m" "py_compile" file-path) callback)
    (funcall callback nil)
    nil))

(defun ellm-tools--run-file-edit-checkers (file-path buffer callback)
  "Run `ellm-tools-file-edit-checkers' for FILE-PATH and BUFFER.
CALLBACK receives a list of diagnostic strings.  Return a function that
cancels the checker currently in progress."
  (let ((checkers ellm-tools-file-edit-checkers)
        diagnostics active)
    (cl-labels
        ((run-next ()
                   (if-let* ((checker (pop checkers)))
                       (let (called checker-callback)
                         (setq checker-callback
                               (lambda (diagnostic)
                                 (unless called
                                   (setq called t)
                                   (when diagnostic
                                     (unless (stringp diagnostic)
                                       (setq diagnostic
                                             (format "Post-edit checker %S returned a non-string diagnostic: %S"
                                                     checker diagnostic)))
                                     (push diagnostic diagnostics))
                                   (run-next))))
                         (let ((handle
                                (condition-case err
                                    (funcall checker file-path buffer checker-callback)
                                  (error
                                   (funcall checker-callback
                                            (format "Post-edit checker %S failed: %s"
                                                    checker (error-message-string err)))
                                   nil))))
                           ;; A synchronous checker has already advanced the pipeline;
                           ;; preserve the cancellation handle of a later checker.
                           (unless called
                             (setq active handle))))
                     (funcall callback (nreverse diagnostics)))))
      (run-next)
      (lambda ()
        (ellm-tools--cancel-async-handle active)))))

(defun ellm-tools--format-file-edit-result (result diagnostics)
  "Append post-edit DIAGNOSTICS to successful edit RESULT."
  (if diagnostics
      (concat result "\n\nPost-edit checks reported:\n"
              (mapconcat (lambda (diagnostic) (concat "- " diagnostic))
                         diagnostics "\n"))
    result))

(defun ellm-tools--edit-tool (buffer-or-file old-string new-string callback
                                             &optional replace-all)
  "Replace occurrence(s) of OLD-STRING with NEW-STRING.
BUFFER-OR-FILE is either a buffer object or a file path string.  CALLBACK
receives the edit result after configured post-edit checkers have finished.
If REPLACE-ALL is non-nil, replace all occurrences; otherwise replace
exactly one occurrence."
  (unless buffer-or-file
    (ellm-tools--error "Invalid target"))
  (unless (stringp old-string)
    (ellm-tools--error "`old_string' must be a string"))
  (unless (stringp new-string)
    (ellm-tools--error "`new_string' must be a string"))
  (let* ((is-file? (not (bufferp buffer-or-file)))
         (name (if is-file?
                   (concat "file " buffer-or-file)
                 (concat "buffer " (buffer-name buffer-or-file))))
         (file-path (if is-file?
                        (expand-file-name buffer-or-file)
                      (buffer-local-value 'buffer-file-name buffer-or-file))))
    (cl-labels ((finish (result buffer &optional kill-buffer)
                        (let ((cancel
                               (ellm-tools--run-file-edit-checkers
                                file-path buffer
                                (lambda (diagnostics)
                                  (unwind-protect
                                      (funcall callback
                                               (ellm-tools--format-file-edit-result
                                                result diagnostics))
                                    (when (and kill-buffer (buffer-live-p buffer))
                                      (kill-buffer buffer)))))))
                          (lambda ()
                            (funcall cancel)
                            (when (and kill-buffer (buffer-live-p buffer))
                              (kill-buffer buffer))))))
      (cond
       ((string-empty-p old-string)
        (unless is-file?
          (ellm-tools--error "`old_string' cannot be empty for buffer edits"))
        (let ((result (ellm-tools--create-file file-path new-string name))
              (buffer (generate-new-buffer " *ellm-tools-edit*")))
          (with-current-buffer buffer
            (insert new-string)
            (ellm-tools--set-file-edit-buffer-mode file-path)
            (set-buffer-modified-p nil))
          (finish result buffer t)))
       ((bufferp buffer-or-file)
        (with-current-buffer buffer-or-file
          (finish (ellm-tools--do-edit old-string new-string replace-all name)
                  buffer-or-file)))
       (t
        (ellm-tools--prepare-visiting-buffer-for-file-write file-path)
        (let ((buffer (generate-new-buffer " *ellm-tools-edit*")))
          (condition-case err
              (with-current-buffer buffer
                (insert-file-contents file-path)
                (ellm-tools--set-file-edit-buffer-mode file-path)
                (let ((result (ellm-tools--do-edit
                               old-string new-string replace-all name)))
                  (write-region (point-min) (point-max) file-path nil 'silent)
                  (set-buffer-modified-p nil)
                  (ellm-tools--refresh-clean-visiting-buffer file-path)
                  (finish result buffer t)))
            (error
             (when (buffer-live-p buffer)
               (kill-buffer buffer))
             (signal (car err) (cdr err))))))))))

(defun ellm-tools--prepare-visiting-buffer-for-file-write (file-path)
  "Prepare FILE-PATH's visiting buffer for a direct disk write."
  (when-let* ((buffer (find-buffer-visiting file-path)))
    (with-current-buffer buffer
      (if (buffer-modified-p)
          ;; Suppress the supersession check for this intentional disk write.
          ;; Its modtime becomes stale again as soon as the write completes.
          (set-visited-file-modtime)
        (revert-buffer t t t)))))

(defun ellm-tools--refresh-clean-visiting-buffer (file-path)
  "Refresh FILE-PATH's clean visiting buffer and mark others stale."
  (when-let* ((buffer (find-buffer-visiting file-path)))
    (with-current-buffer buffer
      (if (buffer-modified-p)
          ;; Ensure a later save detects the disk edit even on filesystems
          ;; whose modification-time resolution is too coarse for this write.
          (set-visited-file-modtime -1)
        (revert-buffer t t t)))))

(defun ellm-tools--create-file (file-path content name)
  "Create FILE-PATH with CONTENT for tool target NAME."
  (when (or (file-exists-p file-path)
            (file-symlink-p file-path))
    (ellm-tools--error
     "Refusing to create %s because it already exists" name))
  (let ((parent-directory (file-name-directory file-path)))
    (unless (file-directory-p parent-directory)
      (make-directory parent-directory t)))
  (write-region content nil file-path nil 'silent nil 'excl)
  (ellm-tools--refresh-clean-visiting-buffer file-path)
  (ellm-tools--success "Successfully created %s" name))

(defun ellm-tools--do-edit (old-string new-string replace-all name)
  "Perform the replacement of OLD-STRING with NEW-STRING in the current buffer.
If REPLACE-ALL is non-nil, replace all occurrences; otherwise replace
exactly one occurrence.  NAME is used for error and status messages."
  (let ((case-fold-search nil))
    (save-excursion
      (goto-char (point-min))
      (let ((count 0)
            (first-match-pos nil))
        (while (search-forward old-string nil 'noerror)
          (setq count (1+ count))
          (unless first-match-pos
            (setq first-match-pos (match-beginning 0))))
        (cond
         ((= count 0)
          (ellm-tools--error "Could not find text '%s' to replace in %s"
                             old-string name))
         ((and (> count 1) (not replace-all))
          (ellm-tools--error "Found %d matches for '%s' in %s, need exactly one"
                             count old-string name))
         (replace-all
          (goto-char (point-min))
          (while (search-forward old-string nil 'noerror)
            (replace-match new-string 'fixedcase 'literal))
          (ellm-tools--success "Successfully edited %s (%d replacement%s)"
                               name count (if (= count 1) "" "s")))
         (t
          (goto-char first-match-pos)
          (search-forward old-string nil 'noerror)
          (replace-match new-string 'fixedcase 'literal)
          (format "Successfully edited %s" name)))))))

;;;; Footer

(add-hook 'ellm-request-cancelling-hook #'ellm-tools--cancel-subagent-requests)
(add-hook 'ellm-mode-hook #'ellm-tools--restore-persisted-subagents)
(add-hook 'ellm-mode-hook #'ellm-tools--initialize-elisp-sessions)

(provide 'ellm-tools)
;;; ellm-tools.el ends here
