;;; ellm-tools.el --- Tool definitions for ellm  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.1
;; Package-Requires: ((emacs "25.2"))
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
(require 'cl-lib)
(require 'seq)
(require 's)
(require 'subr-x)
(require 'url)
(require 'url-util)

;;;; Customization

(defgroup ellm-tools nil
  "Settings for `ellm-tools'."
  :group 'ellm
  :link '(url-link "https://github.com/isamert/ellm.el"))

(defcustom ellm-tools-default-timeout 60
  "Default timeout in seconds for asynchronous ellm tools.
Set to nil to disable the macro-level timeout.  Individual tools can
override this with `:timeout' in `ellm-deftool' SPECS."
  :type '(choice (const :tag "No timeout" nil)
                 (number :tag "Seconds"))
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

(defcustom ellm-tools-grep-options
  '("--vimgrep" "--hidden" "--glob" "!.git" "--color=never")
  "Command line options used by the `grep' tool.
By default these are options for ripgrep and include `--vimgrep'.  If an
option contains `%p' or `%d', they are replaced with the regex pattern and
path, respectively, and no implicit pattern/path arguments are appended."
  :type '(repeat string)
  :group 'ellm-tools)

(defcustom ellm-tools-search-result-limit 200
  "Default maximum number of lines returned by file search tools."
  :type 'integer
  :group 'ellm-tools)

(defcustom ellm-tools-websearch-url "https://html.duckduckgo.com/html/"
  "DuckDuckGo HTML endpoint used by the `websearch' tool."
  :type 'string
  :group 'ellm-tools)

(defcustom ellm-tools-websearch-result-limit 5
  "Default maximum number of results returned by the `websearch' tool."
  :type 'integer
  :group 'ellm-tools)

;;;; Variables

(defvar ellm-tools-refs '()
  "List of all ellm tools definitions.
This contains a list of symbols that points to tool definition plists.
This is provided so that you can use these tools with `gptel-make-tool'
or `llm-make-tool' etc. via doing something like:

  (mapcar
    (lambda (tool) (apply #\\='gptel-make-tool (symbol-value tool)))
    `ellm-tools-refs')")

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

(defvar-local ellm-tools-todo-list nil
  "Buffer-local todo list managed by the `todowrite' tool.
Each item is a plist with `:content', `:status' and `:priority'.")

(defcustom ellm-subagent-buffer-name-format "*ellm subagent:%s*"
  "Format string used for generated subagent buffer names.
It receives one `%s' argument: the subagent display name or id."
  :type 'string
  :group 'ellm-tools)

(defcustom ellm-subagent-wait-default-timeout 60
  "Default maximum seconds `wait_subagent' waits for a subagent."
  :type 'number
  :group 'ellm-tools)

(defcustom ellm-subagent-wait-result-line-limit 120
  "Default maximum lines returned by `wait_subagent' result sections."
  :type 'integer
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

;;;; `ellm-deftool' macro

(eval-and-compile
  (defun ellm-tools--normalize-name (s)
    (string-replace "-" "_" s)))

(defmacro ellm-deftool (name specs arglist doc &rest body)
  (declare (indent 2))
  (pcase-let* ((`(,category ,tool-name-def) (string-split (symbol-name name) "/"))
               (tool-name (ellm-tools--normalize-name tool-name-def))
               (const-sym (intern (format "ellm-tools/%s-tool" tool-name-def)))
               (lambda-args (mapcar #'car arglist))
               (async? (plist-get specs :async))
               (timeout-expr (if (plist-member specs :timeout)
                                 (plist-get specs :timeout)
                               'ellm-tools-default-timeout))
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
               :description ,(s-replace-all
                              param-name-replacements
                              doc)
               :async ,async?
               :args ',(mapcar
                        (lambda (it)
                          (list :name (ellm-tools--normalize-name (symbol-name (nth 0 it)))
                                :type  (intern (string-trim-left (symbol-name (nth 1 it)) ":"))
                                :optional (or (eq (nth 3 it) '&optional) (eq (nth 3 it) :optional))
                                :description
                                (s-replace-all
                                 param-name-replacements
                                 (nth 2 it))))
                        arglist)
               :function #',const-sym
               :category ,category)
         ,(format "Tool definition plist for %s.\n%s" name doc))
       ,(if async?
            `(defun ,const-sym (,callback-sym ,@lambda-args)
               ,doc
               (let* ((,tool-sym ',const-sym)
                      (,tool-args-sym (list ,@lambda-args))
                      (,timeout-sym ,timeout-expr)
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
                   (,tool-args-sym (list ,@lambda-args)))
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

;;;;; Shell

(ellm-deftool shell/run-shell-command (:async t)
  ((command :string "The shell command to run."))
  "Run a shell command and return its output (stdout and stderr combined).
The command is run via the system shell and the default directory is the
root of the current project. The command has no stdin (EOF immediately)
and is killed after 60 seconds if still running."
  (let* ((default-directory (ellm-tools--default-directory))
         (process-connection-type nil)
         (buf (generate-new-buffer " *ellm-tools-shell*"))
         (proc (start-process-shell-command
                "ellm-tools-shell" buf command)))
    (process-send-eof proc)
    (set-process-sentinel
     proc
     (lambda (process _event)
       (when (memq (process-status process) '(exit signal))
         (let* ((process-buffer (process-buffer process))
                (output (if (buffer-live-p process-buffer)
                            (with-current-buffer process-buffer
                              (buffer-string))
                          ""))
                (exit-code (process-exit-status process)))
           (when (buffer-live-p process-buffer)
             (kill-buffer process-buffer))
           (funcall callback
                    (format "Exit code: %d\n%s" exit-code output))))))
    (lambda ()
      (when (process-live-p proc)
        (kill-process proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;;;;; Files

(ellm-deftool files/glob (:async t)
  ((pattern :string "File glob pattern to match, for example `*.el' or `src/**/*.ts'.")
   (path :string "Directory to search. Relative paths are resolved from the current project root or frontmatter `cwd'. Defaults to `.'." &optional)
   (max-results :integer "Maximum number of matching paths to return. Defaults to `ellm-tools-search-result-limit'." &optional))
  "Find files matching PATTERN under PATH.
Uses `ellm-tools-glob-program' (fd by default) with
`ellm-tools-glob-options'."
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
   (path :string "File or directory to search. Relative paths are resolved from the current project root or frontmatter `cwd'. Defaults to `.'." &optional)
   (max-results :integer "Maximum number of matching lines to return. Defaults to `ellm-tools-search-result-limit'." &optional))
  "Search file contents for PATTERN under PATH.
Uses `ellm-tools-grep-program' (ripgrep by default) with
`ellm-tools-grep-options'.  The default ripgrep options include
`--vimgrep', so matches are returned as file:line:column:text lines."
  (ellm-tools--validate-pattern pattern "pattern")
  (let* ((default-directory (ellm-tools--default-directory))
         (search-path (ellm-tools--search-path path))
         (limit (ellm-tools--normalized-limit
                 max-results ellm-tools-search-result-limit))
         (command (ellm-tools--grep-command pattern search-path)))
    (ellm-tools--start-command
     "ellm-tools-grep" (car command) (cdr command)
     (lambda (exit-code stdout stderr)
       (ellm-tools--format-line-command-result
        "grep" pattern search-path exit-code stdout stderr limit
        "No matches found" 1))
     callback)))

(ellm-deftool files/file-edit ()
  ((file-path :string "The absolute or relative path to the file to edit.")
   (old-string :string "The exact text to search for and replace in the file.")
   (new-string :string "The text to replace OLD-STRING with.")
   (replace-all :boolean "If non-nil, replace all occurrences of OLD-STRING. Otherwise replace only the first occurrence, erroring if it is not unique." &optional))
  "Edit a file by replacing OLD-STRING with NEW-STRING.
OLD-STRING must appear exactly once in the file unless REPLACE-ALL
is non-nil, in which case all occurrences are replaced."
  (let ((default-directory (ellm-tools--default-directory)))
    (ellm-tools--edit-tool file-path old-string new-string replace-all)))

(ellm-deftool files/read-file-lines ()
  ((file-path :string "Path to the file. Path is relative to the current project's root.")
   (start-line :integer "Starting line number.")
   (end-line :integer "Ending line number."))
  "Return the contents of the file from START-LINE to END-LINE (inclusive)."
  (when (or (s-blank? file-path)
            (not (and (numberp start-line) (numberp end-line)))
            (< start-line 1)
            (< end-line start-line))
    (ellm-tools--error "invalid input"))
  (let ((default-directory (ellm-tools--default-directory)))
    (with-temp-buffer
      (insert-file-contents file-path)
      (let ((start-pos (progn (goto-char (point-min)) (forward-line (1- start-line)) (point)))
            (end-pos (progn (goto-char (point-min)) (forward-line end-line) (point))))
        (let ((content (buffer-substring-no-properties start-pos end-pos)))
          (concat
           (format "<file_lines start_line=%s end_line=%s>\n" start-line end-line)
           content
           (unless (string-suffix-p "\n" content) "\n")
           "</file_lines>"))))))

;;;;; Buffers

(ellm-deftool buffers/buffer-edit ()
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
    (ellm-tools--error "invalid buffer name"))
  (ellm-tools--edit-tool (get-buffer buffer-name)
                         old-string new-string replace-all))

(ellm-deftool buffers/list-buffers ()
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

(ellm-deftool buffers/read-buffer-lines ()
  ((buffer-name :string "Name of the buffer to read.")
   (start-line :integer "Starting line number (1-indexed). Optional." &optional)
   (end-line :integer "Ending line number (1-indexed). Optional." &optional))
  "Return the contents of the buffer with the given name (max 500 lines).
Optionally specify a line range."
  (when (or (not (stringp buffer-name))
            (string-empty-p buffer-name)
            (not (get-buffer buffer-name))
            (and start-line
                 (or (not (integerp start-line)) (< start-line 1)))
            (and end-line
                 (or (not (integerp end-line)) (< end-line 1)))
            (and start-line end-line (< end-line start-line)))
    (ellm-tools--error "Operation failed: invalid input" ))
  (with-current-buffer buffer-name
    (let* ((start-pos (if start-line
                          (save-excursion
                            (goto-char (point-min))
                            (forward-line (1- start-line))
                            (point))
                        (point-min)))
           (end-pos (if end-line
                        (save-excursion
                          (goto-char (point-min))
                          (forward-line end-line)
                          (point))
                      (point-max)))
           (content (buffer-substring-no-properties start-pos end-pos))
           (lines (split-string content "\n"))
           (limited-lines (seq-take lines 500))
           (truncated (> (length lines) 500)))
      (concat
       (format "<buffer name=%S%s%s>\n"
               buffer-name
               (if start-line (format " start-line=%d" start-line) "")
               (if end-line (format " end-line=%d" end-line) ""))
       (string-join limited-lines "\n")
       (if truncated "\n[... truncated, showing first 500 lines ...]" "")
       "\n</buffer>"))))

(ellm-deftool buffers/search-buffer ()
  ((buffer-name :string "Name of the buffer to search in.")
   (pattern :string "The search pattern to look for.")
   (regexp :boolean "If true, treat pattern as a regular expression. Default is false." &optional)
   (case-sensitive :boolean "If true, search is case-sensitive. By default does a case-insensitive search." &optional))
  "Search for PATTERN in BUFFER-NAME.
Return matching lines with line numbers, capped at 50 matches."
  (when (or (not (stringp buffer-name))
            (string-empty-p buffer-name)
            (not (get-buffer buffer-name)))
    (ellm-tools--error "invalid buffer name"))
  (when (s-blank? pattern)
    (ellm-tools--error "search pattern is empty"))
  (with-current-buffer buffer-name
    (let ((case-fold-search (not case-sensitive))
          (search-fn (if regexp #'re-search-forward #'search-forward))
          (matches '())
          (done nil)
          (max-matches 50))
      (save-excursion
        (goto-char (point-min))
        (while (and (not done)
                    (< (length matches) max-matches)
                    (funcall search-fn pattern nil t))
          (let* ((match-beg (match-beginning 0))
                 (match-end (match-end 0))
                 (line-num (line-number-at-pos match-beg))
                 (line-content (buffer-substring-no-properties
                                (line-beginning-position)
                                (line-end-position))))
            (push (format "%d: %s" line-num line-content) matches)
            (when (= match-beg match-end)
              (if (eobp)
                  (setq done t)
                (forward-char 1))))))
      (if matches
          (concat
           (format "<search_results buffer=%S pattern=%S matches=%d%s>\n"
                   buffer-name pattern (length matches)
                   (if (= (length matches) max-matches) " truncated=true" ""))
           (string-join (nreverse matches) "\n")
           "\n</search_results>")
        (format "No matches found for %S in buffer %S." pattern buffer-name)))))

(declare-function flymake-diagnostic-beg "flymake")
(declare-function flymake-diagnostic-end "flymake")
(declare-function flymake-diagnostic-type "flymake")
(declare-function flymake-diagnostic-text "flymake")

;; TODO: Make the issue backend configurable: flymake, flycheck, ...?
(ellm-deftool buffers/get-buffer-issues ()
  ((buffer :string "Name of the buffer to get flymake diagnostics for."))
  "List current Flymake diagnostics for BUFFER.
Each issue is returned as line-range:type:message."
  (when (or (not (stringp buffer))
            (string-empty-p buffer)
            (not (get-buffer buffer)))
    (ellm-tools--error "invalid buffer name"))
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

;;;;; Tasks

(ellm-deftool tasks/todowrite ()
  ((todos :array "The complete todo list. Each item must have `content' and `status' (`pending', `in_progress', `completed', or `cancelled'); `priority' may be `high', `medium', or `low'."))
  "Replace the current buffer's todo list with TODOS.
This is a classic LLM todo tracker: always pass the full current list, not
just incremental changes.  The normalized list is stored in the
buffer-local variable `ellm-tools-todo-list'."
  (setq ellm-tools-todo-list (ellm-tools--normalize-todos todos))
  (ellm-tools--format-todos ellm-tools-todo-list))

;;;;; Agents

(ellm-deftool agents/launch-subagent ()
  ((prompt :string "Prompt to put in the new subagent's initial user turn.")
   (profile :string "Optional subagent profile name from frontmatter `subagents.profiles' or global `ellm-subagents'." &optional)
   (name :string "Optional display name for the subagent buffer and history entry." &optional)
   (provider :string "Optional provider name from `ellm-provider-alist'. Overrides inherited/profile provider." &optional)
   (model :string "Optional model name. Validated against configured model candidates when available." &optional)
   (tools :array "Optional complete tool list for the child buffer, for example [`@files', `@buffers']. Overrides inherited/profile tools." &optional)
   (system :string "Optional system prompt for the child buffer. Overrides inherited/profile system." &optional)
   (cwd :string "Optional working directory for the child buffer. Overrides inherited/profile cwd." &optional))
  "Launch a subagent in a new `ellm-mode' buffer and start it.
The child buffer inherits the current buffer's frontmatter, then applies
the selected subagent profile, then applies explicit PROVIDER/MODEL/TOOLS/
SYSTEM/CWD overrides.  Frontmatter `subagents:' takes precedence over the
global `ellm-subagents' variable when selecting profiles."
  (ellm-tools--launch-subagent
   prompt profile name provider model tools system cwd))

(ellm-deftool agents/list-subagents ()
  ()
  "List subagents launched from the current ellm buffer."
  (ellm-tools--format-subagent-history ellm-subagent-history))

(ellm-deftool agents/wait-subagent ()
  ((subagent :string "Subagent id from `list_subagents' or the subagent buffer name.")
   (timeout :integer "Maximum seconds to wait. Defaults to `ellm-subagent-wait-default-timeout'." &optional)
   (max-lines :integer "Maximum lines to return from the last assistant turn and buffer tail. Defaults to `ellm-subagent-wait-result-line-limit'." &optional))
  "Wait for SUBAGENT to finish and return its latest result.
If SUBAGENT is still running after TIMEOUT seconds, return a timeout result
without cancelling it."
  (ellm-tools--wait-subagent subagent timeout max-lines))

(ellm-deftool buffers/send-ellm-buffer ()
  ((buffer-name :string "Name of the ellm buffer to send.")
   (prompt :string "Optional prompt to add as a new trailing user turn before sending." &optional))
  "Send an existing ellm buffer, optionally appending PROMPT first.
This is useful for continuing a subagent after inspecting or editing its
conversation buffer."
  (ellm-tools--send-ellm-buffer buffer-name prompt))

;;;;; Web

(ellm-deftool web/websearch (:async t)
  ((query :string "Search query.")
   (max-results :integer "Maximum number of web results to return. Defaults to `ellm-tools-websearch-result-limit'." &optional))
  "Search the web using DuckDuckGo's HTML endpoint and return parsed results."
  (ellm-tools--validate-pattern query "query")
  (let ((limit (ellm-tools--normalized-limit
                max-results ellm-tools-websearch-result-limit)))
    (ellm-tools--start-websearch query limit callback)))

;;;; Tool helpers

(defun ellm-tools--default-directory ()
  "Return the directory custom tools should use for relative paths."
  (file-name-as-directory
   (expand-file-name
    (or (and ellm--frontmatter-cwd-directory
             (file-directory-p ellm--frontmatter-cwd-directory)
             ellm--frontmatter-cwd-directory)
        (funcall ellm-current-project-function)
        default-directory))))

;;;;; Internal

;;;;;; General validation

(defun ellm-tools--validate-pattern (pattern name)
  "Signal an error unless PATTERN is a non-blank string named NAME."
  (when (or (not (stringp pattern))
            (s-blank? pattern))
    (ellm-tools--error "%s must be a non-empty string" name)))

(defun ellm-tools--search-path (path)
  "Return PATH or `.' for file search tools."
  (if (and (stringp path) (not (s-blank? path)))
      path
    "."))

(defun ellm-tools--normalized-limit (limit default)
  "Return LIMIT normalized against DEFAULT."
  (let ((value (or limit default)))
    (unless (and (integerp value) (> value 0))
      (ellm-tools--error "limit must be a positive integer"))
    value))

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

(defun ellm-tools--grep-command (pattern path)
  "Return command list for running the grep tool with PATTERN under PATH."
  (let ((program ellm-tools-grep-program)
        (options ellm-tools-grep-options))
    (cons program
          (if (ellm-tools--command-template-p options)
              (ellm-tools--expand-command-template options pattern path)
            (append options (list "--" pattern path))))))

;;;;;; External command handling

(defun ellm-tools--start-command (name program args formatter callback)
  "Start PROGRAM with ARGS asynchronously.
FORMATTER is called with EXIT-CODE, STDOUT and STDERR, and its return value
is passed to CALLBACK.  Return a cancellation function."
  (unless (and (stringp program) (not (s-blank? program)))
    (ellm-tools--error "invalid command program"))
  (unless (executable-find program)
    (ellm-tools--error "program not found: %s" program))
  (dolist (arg args)
    (unless (stringp arg)
      (ellm-tools--error "command argument is not a string: %S" arg)))
  (let* ((stdout-buffer (generate-new-buffer (format " *%s-stdout*" name)))
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
                                (funcall formatter exit-code stdout stderr))
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
           (format "\n[... truncated, showing first %d of %d lines ...]"
                   limit total))
         (unless (string-empty-p stderr)
           (concat "\n<warnings>\n" stderr "\n</warnings>"))
         (format "\n</%s>" kind)))))))

;;;;;; TodoTool

(defun ellm-tools--todo-field (item field)
  "Return FIELD from todo ITEM.
FIELD is a symbol such as `content'."
  (let ((keyword (intern (concat ":" (symbol-name field))))
        (string-name (symbol-name field)))
    (cond
     ((hash-table-p item)
      (or (gethash field item)
          (gethash keyword item)
          (gethash string-name item)))
     ((and (listp item) (keywordp (car item)))
      (plist-get item keyword))
     ((listp item)
      (or (alist-get field item)
          (alist-get keyword item)
          (alist-get string-name item nil nil #'equal))))))

(defun ellm-tools--todo-string (value)
  "Return VALUE as a todo string field."
  (cond
   ((stringp value) value)
   ((null value) nil)
   ((symbolp value) (symbol-name value))
   (t (format "%s" value))))

(defun ellm-tools--normalize-todo (item index)
  "Normalize todo ITEM at INDEX into a plist."
  (let* ((content (ellm-tools--todo-string
                   (ellm-tools--todo-field item 'content)))
         (status (ellm-tools--todo-string
                  (ellm-tools--todo-field item 'status)))
         (priority (or (ellm-tools--todo-string
                        (ellm-tools--todo-field item 'priority))
                       "medium")))
    (when (or (not content) (s-blank? content))
      (ellm-tools--error "todo item %d has no content" index))
    (unless (member status '("pending" "in_progress" "completed" "cancelled"))
      (ellm-tools--error "todo item %d has invalid status: %S" index status))
    (unless (member priority '("high" "medium" "low"))
      (ellm-tools--error "todo item %d has invalid priority: %S" index priority))
    (list :content content :status status :priority priority)))

(defun ellm-tools--normalize-todos (todos)
  "Normalize TODOS into a list of todo plists."
  (let ((items (cond
                ((vectorp todos) (append todos nil))
                ((listp todos) todos)
                (t (ellm-tools--error "todos must be an array")))))
    (cl-loop for item in items
             for index from 1
             collect (ellm-tools--normalize-todo item index))))

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
  (when (and (stringp value) (not (s-blank? value)))
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

(defun ellm-tools--map-entries (object)
  "Return OBJECT as a list of (KEY . VALUE) frontmatter entries.
OBJECT may be a YAML-style alist or an Elisp plist."
  (cond
   ((null object) nil)
   ((and (listp object) (keywordp (car object)))
    (let ((rest object)
          entries)
      (while rest
        (let ((key (pop rest))
              (value (pop rest)))
          (push (cons (ellm-tools--key-symbol key) value) entries)))
      (nreverse entries)))
   ((listp object)
    (cl-loop for cell in object
             when (consp cell)
             collect (cons (ellm-tools--key-symbol (car cell))
                           (cdr cell))))
   (t
    (ellm-tools--error "subagent profile must be a map: %S" object))))

(defun ellm-tools--frontmatter-set (frontmatter key value)
  "Return FRONTMATTER with top-level KEY set to VALUE."
  (append (ellm-tools--alist-delete-nested frontmatter key)
          (list (cons (ellm-tools--key-symbol key) value))))

(defun ellm-tools--merge-frontmatter-map (frontmatter map)
  "Return FRONTMATTER with every entry from MAP set at the top level."
  (let ((result frontmatter))
    (dolist (entry (ellm-tools--map-entries map) result)
      (setq result (ellm-tools--frontmatter-set
                    result (car entry) (cdr entry))))))

(defun ellm-tools--subagent-config (frontmatter)
  "Return subagent config from FRONTMATTER or global `ellm-subagents'."
  (if-let* ((cell (and frontmatter
                       (ellm--alist-get-nested-cell frontmatter 'subagents))))
      (cdr cell)
    ellm-subagents))

(defun ellm-tools--subagent-profile-name (value)
  "Return VALUE as a subagent profile name, or nil."
  (cond
   ((null value) nil)
   ((symbolp value) (symbol-name value))
   ((stringp value) (ellm-tools--present-string value))
   (t nil)))

(defun ellm-tools--resolve-subagent-profile (config profile)
  "Return (PROFILE-NAME . PROFILE-MAP) selected from CONFIG.
PROFILE may be nil.  CONFIG `default' may name a profile or be an inline
map; when no profile/default map is selected, both parts are nil."
  (let* ((requested (ellm-tools--present-string profile))
         (default (ellm--plistish-get config 'default))
         (profile-name (or requested
                           (ellm-tools--subagent-profile-name default)))
         (default-map (and (not profile-name)
                           (listp default)
                           default)))
    (if profile-name
        (let* ((profiles (ellm--plistish-get config 'profiles))
               (profile-map (ellm--plistish-get profiles profile-name)))
          (unless profile-map
            (ellm-tools--error "subagent profile not found: %s" profile-name))
          (cons profile-name profile-map))
      (cons nil default-map))))

(defun ellm-tools--normalize-tool-list (tools)
  "Return TOOLS normalized for frontmatter."
  (cond
   ((eq tools t) t)
   ((null tools) nil)
   ((stringp tools)
    (let ((tool (ellm-tools--present-string tools)))
      (and tool (list tool))))
   ((vectorp tools)
    (mapcar (lambda (tool)
              (format "%s" tool))
            (append tools nil)))
   ((listp tools)
    (mapcar (lambda (tool)
              (format "%s" tool))
            tools))
   (t
    (ellm-tools--error "tools must be a string or array"))))

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

(defun ellm-tools--model-candidates (entry provider)
  "Return configured model candidates from ENTRY or PROVIDER."
  (or (and entry (ellm--provider-entry-models entry))
      (and provider (ellm-provider-model-candidates provider))))

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
           (candidates (ellm-tools--model-candidates entry provider)))
      (unless provider
        (ellm-tools--error "subagent has no provider configured"))
      (when (and model candidates
                 (not (member model candidates)))
        (ellm-tools--error
         "subagent model `%s' is not configured for provider `%s'"
         model (or provider-name "<fallback>"))))))

(defun ellm-tools--sanitize-subagent-frontmatter (frontmatter)
  "Return FRONTMATTER copied and safe for a fresh child buffer."
  (let ((result (copy-tree frontmatter)))
    (dolist (path '((acp session-id)
                    (acp title)
                    (acp updated-at)
                    (ellm role)
                    (subagent)))
      (setq result (ellm-tools--alist-delete-nested result path)))
    result))

(defun ellm-tools--subagent-frontmatter
    (parent-frontmatter id parent-id parent-name parent-file name prompt profile
                        provider model tools system cwd fallback-provider)
  "Return (FRONTMATTER . PROFILE-NAME) for a new subagent."
  (let* ((config (ellm-tools--subagent-config parent-frontmatter))
         (profile-entry (ellm-tools--resolve-subagent-profile config profile))
         (profile-name (car profile-entry))
         (profile-map (cdr profile-entry))
         (frontmatter (ellm-tools--sanitize-subagent-frontmatter
                       parent-frontmatter)))
    (when profile-map
      (setq frontmatter
            (ellm-tools--merge-frontmatter-map frontmatter profile-map)))
    (when-let* ((value (ellm-tools--provider-name provider)))
      (setq frontmatter (ellm-tools--frontmatter-set frontmatter 'provider value)))
    (when-let* ((value (ellm-tools--model-name model)))
      (setq frontmatter (ellm-tools--frontmatter-set frontmatter 'model value)))
    (when (or tools (vectorp tools))
      (setq frontmatter
            (ellm-tools--frontmatter-set
             frontmatter 'tools (ellm-tools--normalize-tool-list tools))))
    (when-let* ((value (ellm-tools--present-string system)))
      (setq frontmatter (ellm-tools--frontmatter-set frontmatter 'system value)))
    (when-let* ((value (ellm-tools--present-string cwd)))
      (setq frontmatter (ellm-tools--frontmatter-set frontmatter 'cwd value)))
    (setq frontmatter
          (ellm-tools--frontmatter-set
           frontmatter 'created (ellm--timestamp)))
    (setq frontmatter
          (ellm-tools--frontmatter-set
           frontmatter 'subagent
           (delq nil
                 (list (cons 'id id)
                       (and parent-id (cons 'parent-id parent-id))
                       (cons 'parent-buffer parent-name)
                       (and parent-file (cons 'parent-file parent-file))
                       (and (ellm-tools--present-string name)
                            (cons 'name name))
                       (and profile-name (cons 'profile profile-name))
                       (cons 'prompt (ellm-tools--prompt-summary prompt))))))
    (ellm-tools--validate-subagent-frontmatter frontmatter fallback-provider)
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
          (when fallback-provider
            (setq-local ellm-provider fallback-provider))
          (insert "---\n" (ellm--ensure-newline (yaml-encode frontmatter))
                  "---\n\n")
          (ellm-mode)
          (ellm--insert-turn "user" :ts (ellm--timestamp))
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
                  "Use read_buffer_lines, search_buffer, buffer_edit, or send_ellm_buffer to inspect or continue this buffer when those tools are enabled.\n"
                  "</subagent>")
          (plist-get entry :id)
          (buffer-name buffer)
          (ellm-tools--ellm-buffer-status buffer)))

(defun ellm-tools--launch-subagent
    (prompt profile name provider model tools system cwd)
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
         (fallback-provider ellm-provider)
         (parent-default-directory default-directory)
         (parent-ephemeral-p ellm--persistence-ephemeral-p)
         (id (ellm-tools--next-subagent-id))
         (frontmatter-entry
          (ellm-tools--subagent-frontmatter
           parent-frontmatter id parent-id parent-buffer-name parent-file name prompt
           profile provider model tools system cwd fallback-provider))
         (frontmatter (car frontmatter-entry))
         (profile-name (cdr frontmatter-entry))
         (buffer (ellm-tools--create-subagent-buffer
                  id name profile-name prompt frontmatter fallback-provider
                  parent-default-directory parent-buffer-name
                  parent-session-directory parent-ephemeral-p))
         (entry (ellm-tools--record-subagent
                 id buffer name profile-name prompt frontmatter)))
    (ellm-tools--format-subagent-launch-result entry buffer)))

(defun ellm-tools--normalize-wait-timeout (timeout)
  "Return TIMEOUT normalized for `wait_subagent'."
  (let ((value (or timeout ellm-subagent-wait-default-timeout)))
    (unless (and (numberp value) (>= value 0))
      (ellm-tools--error "timeout must be a non-negative number"))
    value))

(defun ellm-tools--normalize-wait-line-limit (max-lines)
  "Return MAX-LINES normalized for `wait_subagent'."
  (ellm-tools--normalized-limit
   max-lines ellm-subagent-wait-result-line-limit))

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

(defun ellm-tools--limited-lines (text max-lines)
  "Return TEXT limited to its last MAX-LINES lines as a plist."
  (let* ((lines (split-string (or text "") "\n"))
         (total (length lines))
         (drop (max 0 (- total max-lines)))
         (shown (nthcdr drop lines)))
    (list :text (string-join shown "\n")
          :total total
          :shown (length shown)
          :truncated (> drop 0))))

(defun ellm-tools--last-assistant-content (buffer)
  "Return BUFFER's last assistant turn content, or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((turn (cl-find-if
                         (lambda (turn)
                           (equal (ellm-turn-role turn) "assistant"))
                         (reverse (ellm--parse-turns)))))
        (ellm-turn-content turn)))))

(defun ellm-tools--buffer-text (buffer)
  "Return BUFFER text without properties, or nil when it is not live."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun ellm-tools--format-limited-section (tag attrs limited)
  "Return TAG section with ATTRS and LIMITED line data."
  (format "<%s%s lines=%d total-lines=%d%s>\n%s\n</%s>\n"
          tag
          (if attrs (concat " " attrs) "")
          (plist-get limited :shown)
          (plist-get limited :total)
          (if (plist-get limited :truncated) " truncated=true" "")
          (plist-get limited :text)
          tag))

(defun ellm-tools--format-subagent-wait-result (target timed-out max-lines)
  "Return model-readable wait result for TARGET."
  (let* ((buffer (plist-get target :buffer))
         (buffer-name (plist-get target :buffer-name))
         (status (ellm-tools--ellm-buffer-status buffer))
         (last-assistant (and buffer
                              (ellm-tools--last-assistant-content buffer)))
         (tail (and buffer (ellm-tools--buffer-text buffer))))
    (concat
     (format "<subagent id=%S buffer=%S status=%S%s>\n"
             (plist-get target :id)
             buffer-name
             status
             (if timed-out " timed-out=true" ""))
     (if (not (buffer-live-p buffer))
         "Buffer is not live.\n"
       (concat
        (if last-assistant
            (ellm-tools--format-limited-section
             "last_assistant" nil
             (ellm-tools--limited-lines last-assistant max-lines))
          "No assistant turn found.\n")
        (ellm-tools--format-limited-section
         "buffer_tail" nil
         (ellm-tools--limited-lines tail max-lines))))
     "</subagent>")))

(defun ellm-tools--wait-subagent (subagent timeout max-lines)
  "Implementation for the `wait_subagent' tool."
  (let* ((target (ellm-tools--subagent-target subagent))
         (buffer (plist-get target :buffer))
         (seconds (ellm-tools--normalize-wait-timeout timeout))
         (line-limit (ellm-tools--normalize-wait-line-limit max-lines))
         (deadline (+ (float-time) seconds))
         timed-out)
    (while (and (buffer-live-p buffer)
                (with-current-buffer buffer ellm--active-request)
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (setq timed-out
          (and (buffer-live-p buffer)
               (with-current-buffer buffer ellm--active-request)))
    (ellm-tools--format-subagent-wait-result target timed-out line-limit)))

(defun ellm-tools--ellm-buffer (buffer-name)
  "Return live ellm buffer named BUFFER-NAME, or signal an error."
  (unless (and (stringp buffer-name)
               (not (string-empty-p buffer-name)))
    (ellm-tools--error "invalid buffer name"))
  (let ((buffer (get-buffer buffer-name)))
    (unless buffer
      (ellm-tools--error "invalid buffer name"))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ellm-mode)
        (ellm-tools--error "buffer is not an ellm buffer: %s" buffer-name)))
    buffer))

(defun ellm-tools--append-ellm-prompt (prompt)
  "Append PROMPT to the current ellm buffer as the next user turn."
  (when-let* ((text (ellm-tools--present-string prompt)))
    (let* ((turns (ellm--parse-turns))
           (last-turn (car (last turns))))
      (if (and last-turn
               (equal (ellm-turn-role last-turn) "user")
               (s-blank? (ellm-turn-content last-turn)))
          (progn
            (goto-char (ellm-turn-beg last-turn))
            (delete-region (ellm-turn-beg last-turn)
                           (ellm-turn-end last-turn))
            (insert (ellm--ensure-newline text)))
        (ellm--insert-turn "user" :ts (ellm--timestamp))
        (insert (ellm--ensure-newline text))))))

(defun ellm-tools--send-ellm-buffer (buffer-name prompt)
  "Implementation for the `send_ellm_buffer' tool."
  (let ((buffer (ellm-tools--ellm-buffer buffer-name)))
    (with-current-buffer buffer
      (when ellm--active-request
        (ellm-tools--error "ellm buffer already has a request in flight: %s"
                           buffer-name))
      (ellm-tools--append-ellm-prompt prompt)
      (ellm-send)
      (format "<ellm_buffer buffer=%S status=%S>\nSent.\n</ellm_buffer>"
              (buffer-name buffer)
              (ellm-tools--ellm-buffer-status buffer)))))

;;;;;; Websearch

(defun ellm-tools--start-websearch (query limit callback)
  "Search DuckDuckGo HTML for QUERY and pass formatted LIMIT results to CALLBACK."
  (let* ((url-request-method "GET")
         (url (concat ellm-tools-websearch-url
                      (if (string-match-p "[?&]\\'" ellm-tools-websearch-url)
                          ""
                        (if (string-match-p "\\?" ellm-tools-websearch-url)
                            "&"
                          "?"))
                      "q=" (url-hexify-string query)))
         (buffer
          (url-retrieve
           url
           (lambda (status)
             (let ((buf (current-buffer)))
               (unwind-protect
                   (condition-case err
                       (if-let* ((url-error (plist-get status :error)))
                           (funcall callback
                                    (format "DuckDuckGo search failed: %s"
                                            url-error))
                         (goto-char (point-min))
                         (if (not (re-search-forward "\r?\n\r?\n" nil t))
                             (funcall callback
                                      "DuckDuckGo search failed: malformed HTTP response")
                           (let ((html (buffer-substring-no-properties
                                        (point) (point-max))))
                             (funcall
                              callback
                              (ellm-tools--format-websearch-results
                               query
                               (ellm-tools--parse-duckduckgo-html
                                html limit))))))
                     (error
                      (funcall callback
                               (format "Error while parsing DuckDuckGo results: %s"
                                       err))))
                 (when (buffer-live-p buf)
                   (kill-buffer buf))))))))
    (unless buffer
      (ellm-tools--error "failed to start DuckDuckGo request"))
    (lambda ()
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

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
  (let ((decoded (s-replace-all '(("&amp;" . "&")
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
  (when (and href (not (s-blank? href)))
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
              (unless (or (s-blank? title)
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
            (unless (or (not url) (s-blank? title) (gethash url seen))
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
               (unless (s-blank? snippet)
                 (concat "\nSnippet: " snippet))))))
        (cl-loop for result in results
                 for index from 1
                 collect (cons index result))
        "\n\n")
       "\n</websearch>")
    (format "No web search results found for %S." query)))

;;;;;; Edit tool

(defun ellm-tools--edit-tool (buffer-or-file old-string new-string &optional replace-all)
  "Replace occurrence(s) of OLD-STRING with NEW-STRING.
BUFFER-OR-FILE is either a buffer object or a file path string.
If REPLACE-ALL is non-nil, replace all occurrences; otherwise replace
exactly one occurrence."
  (unless buffer-or-file
    (ellm-tools--error "invalid target"))
  (unless (stringp old-string)
    (ellm-tools--error "`old_string' must be a string"))
  (unless (stringp new-string)
    (ellm-tools--error "`new_string' must be a string"))
  (when (string= old-string "")
    (ellm-tools--error "`old_string' cannot be empty"))
  (let* ((is-file? (not (bufferp buffer-or-file)))
         (name (if is-file?
                   (concat "file " buffer-or-file)
                 (concat "buffer " (buffer-name buffer-or-file))))
         (file-path (when is-file? (expand-file-name buffer-or-file)))
         (existing-buffer (when file-path (find-buffer-visiting file-path))))
    (cond
     ((bufferp buffer-or-file)
      (with-current-buffer buffer-or-file
        (ellm-tools--do-edit old-string new-string replace-all name)))
     (existing-buffer
      (when (buffer-modified-p existing-buffer)
        (ellm-tools--error
         "Refusing to edit %s because it has unsaved changes" name))
      (with-current-buffer existing-buffer
        (let ((result (ellm-tools--do-edit
                       old-string new-string replace-all name)))
          (save-buffer)
          result)))
     (t
      (let ((temp-buf (generate-new-buffer " *ellm-tools-edit*")))
        (unwind-protect
            (with-current-buffer temp-buf
              (insert-file-contents file-path)
              (let ((result (ellm-tools--do-edit
                             old-string new-string replace-all name)))
                (write-region (point-min) (point-max) file-path nil 'silent)
                result))
          (when (buffer-live-p temp-buf)
            (kill-buffer temp-buf))))))))

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

(add-hook 'ellm-mode-hook #'ellm-tools--restore-persisted-subagents)

(provide 'ellm-tools)
;;; ellm-tools.el ends here
