;;; ellm-llm.el --- llm.el backend for ellm  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (llm "0.30"))
;; Keywords: llm

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

;; Backend implementation for llm.el.

;;; Code:

(require 'cl-lib)
(require 'llm)
(require 'ellm)

(cl-defstruct (ellm-llm-request (:constructor ellm-llm--make-request))
  "Active request handle for the `llm.el' backend."
  raw)

;;;; Interface implementation

(cl-defmethod ellm-backend-send ((provider llm-standard-chat-provider)
                                 _frontmatter buffer)
  "Send BUFFER through a standard `llm.el' chat PROVIDER."
  (ellm-llm--backend-send provider buffer))

(cl-defmethod ellm-backend-send (provider _frontmatter buffer)
  "Compatibility fallback for direct `llm.el' PROVIDER objects.
Backend-specific provider types should define a more specific
`ellm-backend-send' method, as `ellm-acp-provider' does."
  (ellm-llm--backend-send provider buffer))

(cl-defmethod ellm-backend-cancel ((request ellm-llm-request))
  "Cancel an active `llm.el' REQUEST."
  (llm-cancel-request (ellm-llm-request-raw request)))

;;;; Internal

(defun ellm-llm--gen-call-id (&rest _)
  "Return a fresh synthetic tool-call ID for buffer serialization.
Provider IDs are not surfaced through `llm.el's multi-output result, so
ellm assigns its own opaque IDs to pair `tool-call' and `tool-result'
turns across re-parses."
  (format "call_%08x" (random (expt 2 32))))

(defun ellm-llm--insert-tool-call (id tool-use)
  "Insert a `tool-call' turn for TOOL-USE plist with synthetic ID.
TOOL-USE is `(:name NAME :args ARGS)' as produced by `llm.el' multi-
output.  ARGS is an alist of (ARG-SYM . VALUE).  With one arg, the
value is dumped as the call body; with multiple args, each is emitted
as a `tool-param' sub-turn."
  (let* ((name (plist-get tool-use :name))
         (args (plist-get tool-use :args)))
    (cond
     ((null args)
      (ellm--insert-turn "tool-call" :pipe-arg name :id id))
     ((= (length args) 1)
      (ellm--insert-turn "tool-call" :pipe-arg name :id id)
      (insert (format "%s\n" (cdar args))))
     (t
      (ellm--insert-turn "tool-call" :pipe-arg name :id id)
      (dolist (a args)
        (ellm--insert-turn "tool-param" :pipe-arg (format "%s" (car a)))
        (insert (format "%s\n" (cdr a))))))))

(defun ellm-llm--insert-tool-result (id name result)
  "Insert a `tool-result' turn for NAME pairing call ID with RESULT body."
  (ellm--insert-turn "tool-result" :pipe-arg name :id id)
  (insert (format "%s\n" result)))

(defun ellm-llm--ensure-buffer (buf &optional request-to-cancel)
  (unless (buffer-live-p buf)
    (when request-to-cancel
      (llm-cancel-request request-to-cancel))
    (user-error "ellm :: Buffer is gone")))

(defun ellm-llm--fold-reasoning-in-region (start end)
  "Fold the `reasoning' turn located between START and END, if any."
  (save-excursion
    (goto-char start)
    (when (re-search-forward
           (concat "^" (regexp-quote ellm-turn-header-2) " reasoning\\b")
           end t)
      (ellm--fold-subtree-at (match-beginning 0)))))

(defun ellm-llm--render-streaming-response (buf request start end result)
  (ellm-llm--ensure-buffer buf request)
  (with-current-buffer buf
    (let* ((inhibit-read-only t)
           (saved (mapcar
                   (lambda (w)
                     (list w (window-start w) (window-point w)))
                   (get-buffer-window-list buf nil t)))
           (reasoning (plist-get result :reasoning))
           (text      (plist-get result :text))
           (new-text
            (concat
             (when (and reasoning (not (string-empty-p reasoning)))
               (concat (ellm--get-turn "reasoning" :continuation t) "\n"
                       (ellm--ensure-newline reasoning)))
             (when (and text (not (string-empty-p text)))
               (concat (ellm--get-turn "assistant" :continuation t) "\n"
                       (ellm--ensure-newline text))))))
      (save-excursion
        (goto-char start)
        (let* ((current-text
                (buffer-substring-no-properties start end))
               (prefix-length
                (length (fill-common-string-prefix
                         current-text new-text))))
          (goto-char (+ start prefix-length))
          (delete-region (point) end)
          (insert (substring new-text prefix-length))))
      (when (and ellm-fold-reasoning-blocks
                 reasoning (not (string-empty-p reasoning))
                 text (not (string-empty-p text)))
        (ellm-llm--fold-reasoning-in-region start end))
      (dolist (state saved)
        (pcase-let* ((`(,w ,ws ,wp) state))
          (when (window-live-p w)
            (set-window-start w ws t)
            (set-window-point w wp)))))))

(defun ellm-llm--insert-and-mark-turn (insert-fn header role)
  "Run INSERT-FN and return a `(MARKER . ROLE)' cons for the inserted turn.
INSERT-FN inserts one turn (possibly with nested children).  HEADER is
the delimiter string for the turn to be folded (e.g. `ellm-turn-header-2')
and ROLE its role string; together they locate the heading line of the
just-inserted turn -- important because INSERT-FN may append deeper
children (e.g. `tool-param') after it.  MARKER points at that heading
line for deferred folding.  Returns nil if the heading is not found."
  (let ((before (point-max)))
    (funcall insert-fn)
    (save-excursion
      (goto-char before)
      (when (re-search-forward
             (concat "^" (regexp-quote header) " " (regexp-quote role) "\\b")
             nil t)
        (cons (copy-marker (match-beginning 0) nil) role)))))

(defun ellm-llm--render-tool-uses (tool-uses tool-results)
  "Insert `tool-call' / `tool-result' turns for TOOL-USES and TOOL-RESULTS.
When `ellm-fold-tool-calls' is non-nil each inserted turn is folded."
  (let ((ids (mapcar #'ellm-llm--gen-call-id tool-uses))
        (fold-markers nil))
    (cl-loop for id in ids
             for tu in tool-uses
             do (push (ellm-llm--insert-and-mark-turn
                       (lambda () (ellm-llm--insert-tool-call id tu))
                       ellm-turn-header-2 "tool-call")
                      fold-markers))
    (cl-loop for id in ids
             for tu in tool-uses
             for tr in tool-results
             do (push (ellm-llm--insert-and-mark-turn
                       (lambda ()
                         (ellm-llm--insert-tool-result
                          id (plist-get tu :name) (cdr tr)))
                       ellm-turn-header-2 "tool-result")
                      fold-markers))
    (when ellm-fold-tool-calls
      (dolist (cell (delq nil fold-markers))
        (ellm--fold-turn-at (marker-position (car cell)) (cdr cell))
        (set-marker (car cell) nil)))))

(defun ellm-llm--send-once (provider prompt buf)
  "Stream PROVIDER's reply for PROMPT into the trailing assistant turn of BUF.
Uses multi-output mode.  If the LLM emits tool calls, llm.el executes
them and populates PROMPT with both calls and results before the final
callback fires; this function then writes corresponding `tool-call' /
`tool-result' turns into BUF, opens a continuation `assistant' turn,
and recurses with the (already populated) PROMPT.  When the response
is text-only, a fresh trailing `user' turn is appended."
  (with-current-buffer buf
    (let* ((start (copy-marker (point-max) nil))
           (end   (copy-marker (point-max) t))
           request)
      (let* ((partial-render
              (lambda (result)
                (ellm-llm--render-streaming-response
                 buf request start end result)))
             (final-render
              (lambda (result)
                (ellm-llm--ensure-buffer buf request)
                (funcall partial-render result)
                (with-current-buffer buf
                  (setq ellm--active-request nil)
                  ;; Catch the reasoning-only case: if the block never got
                  ;; folded during streaming (because no assistant text
                  ;; followed it), fold it now that the response is
                  ;; complete.  Covers both `t' and `after'.
                  (when ellm-fold-reasoning-blocks
                    (ellm-llm--fold-reasoning-in-region start end))
                  (if-let* ((tool-uses (plist-get result :tool-uses))
                            (tool-results (plist-get result :tool-results)))
                      (progn
                        (ellm-llm--render-tool-uses tool-uses tool-results)
                        (ellm-llm--send-once provider prompt buf))
                    (ellm--insert-turn "user")))))
             (on-error
              (lambda (type msg)
                (ellm-llm--ensure-buffer buf request)
                (with-current-buffer buf
                  (setq ellm--active-request nil))
                (signal type (list msg)))))
        (setq request (llm-chat-streaming
                       provider prompt
                       partial-render final-render on-error
                       'multi-output))
        (setq ellm--active-request (ellm-llm--make-request :raw request))))))

(defun ellm-llm--backend-send (provider buffer)
  "Send BUFFER through a normal `llm.el' PROVIDER."
  (with-current-buffer buffer
    (let ((prompt (ellm--parse-buffer-as-llm-chat provider)))
      (ellm-llm--send-once provider prompt buffer))))

;;;; Footer

(provide 'ellm-llm)
;;; ellm-llm.el ends here
