;;; ellm-tools.el --- Tool definitions for ellm  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.1
;; Package-Requires: ((emacs "25.2"))
;; Keywords: llm, tools

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

(require 'llm)
(require 'ellm)
(require 'seq)
(require 's)

;;;; Customization

(defgroup ellm-tools nil
  "Settings for `ellm-tools'."
  :link '(url-link "https://github.com/isamert/ellm.el"))

(defcustom ellm-tools-current-project-function #'ellm-tools-current-project-root
  "Function for getting the root of the current project.
Some of the tools functionality depends on finding the root of the
current project.  Default implementation simply finds the closest .git
directories parent folder."
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

;;;; `ellm-deftool' macro

(defun ellm-tools--normalize-name (s)
  (string-replace "-" "_" s))

(defmacro ellm-deftool (name specs arglist doc &rest body)
  (declare (indent 2))
  (pcase-let* ((`(,category ,tool-name-def) (string-split (symbol-name name) "/"))
               (tool-name (ellm-tools--normalize-name tool-name-def))
               (const-sym (intern (format "ellm-tools/%s-tool" tool-name-def)))
               (lambda-args (mapcar #'car arglist))
               (async? (plist-get specs :async))
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
            ;; TODO: Define timeouts for async functions and raise a
            ;; timeout error. Users should be able to define :timeout
            ;; through the SPECS and there should be a default value

            ;; TODO: Fix lexical variables via gensym for hygine
            `(defun ,const-sym (callback ,@lambda-args)
               (let ((tool-args (list ,@lambda-args))
                     (error? nil))
                 (ellm-tools--tool-call-start-hook ',const-sym tool-args)
                 (cl-flet ((callback (raw-result)
                                     (let ((result (ellm-tools--transform-tool-result
                                                    tool-args ',const-sym error? raw-result)))
                                       (ellm-tools--tool-call-end-hook
                                        ',const-sym tool-args error? raw-result result)
                                       (funcall callback result))))
                   (condition-case err
                       (progn ,@body)
                     (error
                      (funcall callback (format "Error while calling the tool: %s" err)))))))
          `(defun ,const-sym ,lambda-args
             ,doc
             (let ((tool-args (list ,@lambda-args)))
               (ellm-tools--tool-call-start-hook ',const-sym tool-args)
               (let* ((error? nil)
                      (raw-result
                       (condition-case err
                           (progn ,@body)
                         (error
                          (setq error? t)
                          (format "Error while calling the tool: %s" err))))
                      (result (ellm-tools--transform-tool-result
                               tool-args ',const-sym error? raw-result)))
                 (ellm-tools--tool-call-end-hook
                  ',const-sym tool-args error? raw-result result)
                 result))))
       (cl-pushnew ',const-sym ellm-tools-refs)
       (setq ellm-tools-list
             (cl-remove-if (lambda (it) (equal (ellm-tool-name it) ,tool-name))
                           ellm-tools-list))
       (push (apply #'ellm-make-tool ,const-sym) ellm-tools-list))))


;;;; Tool lifecycle

(defun ellm-tools--tool-call-start-hook (hook args)
  (message "TODO: tool start hook"))

(defun ellm-tools--tool-call-end-hook (hook args error? raw result)
  (message "TODO: tool start hook"))

(defun ellm-tools--transform-tool-result (hook args error? raw)
  (message "TODO: tool result transformer")
  raw)

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

;;;;; Files

(ellm-deftool files/file-edit ()
  ((file-path :string "The absolute or relative path to the file to edit.")
   (old-string :string "The exact text to search for and replace in the file.")
   (new-string :string "The text to replace OLD-STRING with.")
   (replace-all :boolean "If non-nil, replace all occurrences of OLD-STRING. Otherwise replace only the first occurrence, erroring if it is not unique." &optional))
  "Edit a file by replacing OLD-STRING with NEW-STRING.
OLD-STRING must appear exactly once in the file unless REPLACE-ALL
is non-nil, in which case all occurrences are replaced."
  (ellm-tools--edit-tool file-path old-string new-string replace-all))

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
  (let ((default-directory (funcall ellm-tools-current-project-function)))
    (with-temp-buffer
      (insert-file-contents file-path)
      (let ((start-pos (progn (goto-char (point-min)) (forward-line (1- start-line)) (point)))
            (end-pos (progn (goto-char (point-min)) (forward-line (1- end-line)) (point))))
        (concat
         (format "<file_lines start_line=%s end_line=%s>\n" start-line end-line)
         (buffer-substring-no-properties start-pos end-pos)
         "\n</file_lines>")))))

;;;;; Buffers

(ellm-deftool buffers/buffer-edit ()
  ((buffer-name :string "The name of the buffer to edit.")
   (old-string :string "The exact text to search for and replace in the buffer.")
   (new-string :string "The text to replace OLD-STRING with.")
   (replace-all :boolean "If non-nil, replace all occurrences of OLD-STRING. Otherwise replace only the first occurrence, erroring if it is not unique." &optional))
  "Edit a buffer by replacing OLD-STRING with NEW-STRING.
OLD-STRING must appear exactly once in the buffer unless REPLACE-ALL
is non-nil, in which case all occurrences are replaced."
  (ellm-tools--edit-tool (get-buffer buffer-name) old-string new-string replace-all))

(ellm-deftool buffers/list-buffers ()
  ()
  "List names of open buffers. Act directly on buffers if you know the name already, without listing."
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
  (when (or (string-empty-p buffer-name)
            (not (get-buffer buffer-name)))
    (ellm-tools--error "Operation failed: invalid input." ))
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
  "Search for a PATTERN in buffer BUFFER-NAME and return matching lines with line numbers (max 50 matches)."
  (when (or (string-empty-p buffer-name) (not (get-buffer buffer-name)))
    (ellm-tools--error "invalid buffer name"))
  (when (s-blank? pattern)
    (ellm-tools--error "search pattern is empty"))
  (with-current-buffer buffer-name
    (let ((case-fold-search (not case-sensitive))
          (search-fn (if regexp #'re-search-forward #'search-forward))
          (matches '())
          (max-matches 50))
      (save-excursion
        (goto-char (point-min))
        (while (and (< (length matches) max-matches)
                    (funcall search-fn pattern nil t))
          (let* ((line-num (line-number-at-pos (match-beginning 0)))
                 (line-content (buffer-substring-no-properties
                                (line-beginning-position)
                                (line-end-position))))
            (push (format "%d: %s" line-num line-content) matches))))
      (if matches
          (concat
           (format "<search_results buffer=%S pattern=%S matches=%d%s>\n"
                   buffer-name pattern (length matches)
                   (if (= (length matches) max-matches) " truncated=true" ""))
           (string-join (nreverse matches) "\n")
           "\n</search_results>")
        (format "No matches found for %S in buffer %S." pattern buffer-name)))))

(ellm-deftool buffers/get-buffer-issues ()
  ((buffer :string "Name of the buffer to get flymake diagnostics for."))
  "List all current flymake diagnostics for given buffer with line-range:type:message."
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

;;;;; Internal

(defun ellm-tools--edit-tool (buffer-or-file old-string new-string &optional replace-all)
  "Replace occurrence(s) of OLD-STRING with NEW-STRING.
BUFFER-OR-FILE is either a buffer object or a file path string.
If REPLACE-ALL is non-nil, replace all occurrences; otherwise replace
exactly one occurrence."
  (when (string= old-string "")
    (ellm-tools--error "`old_string' cannot be empty"))
  (let* ((is-file? (not (bufferp buffer-or-file)))
         (name (if is-file?
                   (concat "file " buffer-or-file)
                 (concat "buffer " (buffer-name buffer-or-file))))
         (file-path (when is-file? (expand-file-name buffer-or-file)))
         (existing-buffer (when file-path (find-buffer-visiting file-path))))
    (if (bufferp buffer-or-file)
        (with-current-buffer buffer-or-file
          (ellm-tools--do-edit old-string new-string replace-all name))
      (if existing-buffer
          ;; There's an existing buffer; edit in temp buffer, write file, revert existing buffer
          (let ((temp-buf (generate-new-buffer " *temp*")))
            (with-current-buffer temp-buf
              (insert-file-contents file-path)
              (ellm-tools--do-edit old-string new-string replace-all name)
              (write-file file-path))
            (with-current-buffer existing-buffer
              (revert-buffer t t))
            (kill-buffer temp-buf)
            (format "Successfully edited %s" name))
        ;; No existing buffer, edit in temp buffer and write file
        (let ((temp-buf (generate-new-buffer " *temp*"))
              (result nil))
          (with-current-buffer temp-buf
            (insert-file-contents file-path)
            (setq result (do-edit))
            (write-file file-path))
          (kill-buffer temp-buf)
          (ellm-tools--success result))))))

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
