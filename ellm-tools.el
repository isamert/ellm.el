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
(require 'seq)
(require 's)

;;;; Customization

(defgroup ellm-tools nil
  "Settings for `ellm-tools'."
  :group 'ellm
  :link '(url-link "https://github.com/isamert/ellm.el"))

(defcustom ellm-tools-current-project-function #'ellm-tools-current-project-root
  "Function for getting the root of the current project.
Some of the tools functionality depends on finding the root of the
current project.  Default implementation simply finds the closest .git
directories parent folder."
  :type 'function
  :group 'ellm-tools)

(defcustom ellm-tools-default-timeout 60
  "Default timeout in seconds for asynchronous ellm tools.
Set to nil to disable the macro-level timeout.  Individual tools can
override this with `:timeout' in `ellm-deftool' SPECS."
  :type '(choice (const :tag "No timeout" nil)
                 (number :tag "Seconds"))
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

;;;; Tool helpers

;;;;; Public

(defun ellm-tools-current-project-root ()
  "Return the root path of current project."
  (when-let* ((path (locate-dominating-file default-directory ".git")))
    (expand-file-name path)))

(defun ellm-tools--default-directory ()
  "Return the directory custom tools should use for relative paths."
  (file-name-as-directory
   (expand-file-name
    (or (and ellm--frontmatter-cwd-directory
             (file-directory-p ellm--frontmatter-cwd-directory)
             ellm--frontmatter-cwd-directory)
        (funcall ellm-tools-current-project-function)
        default-directory))))

;;;;; Internal

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

(provide 'ellm-tools)
;;; ellm-tools.el ends here
