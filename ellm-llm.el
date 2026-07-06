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
(require 'llm-provider-utils)
(require 'llm-models)
(require 'ellm)

;; `llm.el' signals `(not-implemented)' from generic fall-through methods
;; without registering it as an error symbol.
(unless (get 'not-implemented 'error-conditions)
  (define-error 'not-implemented "Operation is not implemented for this LLM provider"))

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

(cl-defmethod ellm-provider-current-model ((provider llm-standard-chat-provider))
  "Return PROVIDER's `llm.el' chat model name, or nil when unset."
  (ellm-llm--provider-current-model provider))

(cl-defmethod ellm-provider-model-candidates ((provider llm-standard-chat-provider))
  "Return model completion candidates for `llm.el' PROVIDER."
  (or (and-let* ((model (ellm-llm--provider-current-model provider)))
        (list model))
      (mapcar (lambda (m) (symbol-name (llm-model-symbol m)))
              llm-models)))

(cl-defmethod ellm-provider-with-model ((provider llm-standard-chat-provider) model)
  "Return a copy of PROVIDER with its `chat-model' slot set to MODEL."
  (ellm-llm--provider-with-model provider model))

;;;; Internal

;;;;; Tool handling

(defun ellm-llm--gen-call-id (&rest _)
  "Return a fresh synthetic tool-call ID for buffer serialization.
Provider IDs are not surfaced through `llm.el's multi-output result, so
ellm assigns its own opaque IDs to pair `tool-call' and `tool-result'
turns across re-parses."
  (format "call_%08x" (random (expt 2 32))))

(defun ellm-llm--provider-current-model (provider)
  "Return PROVIDER's `chat-model' slot when present and meaningful."
  (let ((chat-model (and (recordp provider)
                         (condition-case nil
                             (cl-struct-slot-value
                              (type-of provider) 'chat-model provider)
                           (error nil)))))
    (when (and (stringp chat-model)
               (not (string-empty-p chat-model))
               (not (equal "unset" chat-model)))
      chat-model)))

(defun ellm-llm--make-llm-tool (tool)
  "Convert backend-neutral ellm TOOL to an `llm-tool'."
  (llm-make-tool
   :name (ellm-tool-name tool)
   :description (ellm-tool-description tool)
   :args (ellm-tool-args tool)
   :function (ellm-tool-function tool)
   :async (ellm-tool-async tool)))

(defun ellm-llm--resolve-tools (frontmatter)
  "Return FRONTMATTER selected tools converted to `llm-tool' objects."
  (mapcar #'ellm-llm--make-llm-tool (ellm--resolve-tools frontmatter)))

(defun ellm-llm--collect-tool-call-args (tool-call-turn following-turns base-prompt)
  "Return (ARGS . TURNS-CONSUMED) for TOOL-CALL-TURN."
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
                                       :key #'ellm-tool-name
                                       :test #'equal)))
                    (arg-name (and tool
                                   (if (llm-tool-p tool)
                                       (and (llm-tool-args tool)
                                            (plist-get (car (llm-tool-args tool))
                                                       :name))
                                     (and (ellm-tool-args tool)
                                          (plist-get (car (ellm-tool-args tool))
                                                     :name))))))
               (when arg-name
                 (list (cons (intern arg-name)
                             (ellm-turn-content tool-call-turn))))))
            (t nil))))
      (cons args consumed))))

(defun ellm-llm--apply-turns-to-prompt (provider turns prompt)
  "Walk TURNS and append corresponding interactions onto PROMPT."
  (let ((rest turns))
    (while rest
      (let* ((turn (car rest))
             (role (ellm-turn-role turn)))
        (cond
         ((equal role "tool-call")
          (let (tool-uses)
            (while (and rest (equal (ellm-turn-role (car rest)) "tool-call"))
              (let* ((tc (car rest))
                     (attrs (ellm-turn-attrs tc))
                     (name (alist-get "arg" attrs nil nil #'equal))
                     (id (alist-get "id" attrs nil nil #'equal))
                     (collected (ellm-llm--collect-tool-call-args
                                 tc (cdr rest) prompt))
                     (args (car collected))
                     (consumed (cdr collected)))
                (push (make-llm-provider-utils-tool-use
                       :id id :name name :args args)
                      tool-uses)
                (setq rest (nthcdr (1+ consumed) rest))))
            (llm-provider-populate-tool-uses
             provider prompt (nreverse tool-uses))))
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
         ((equal role "tool-param")
          (setq rest (cdr rest)))
         (t
          (setf (llm-chat-prompt-interactions prompt)
                (append (llm-chat-prompt-interactions prompt)
                        (list (make-llm-chat-prompt-interaction
                               :role (intern role)
                               :content (ellm-turn-content turn)))))
          (setq rest (cdr rest)))))))
  prompt)

(defun ellm-llm--insert-tool-call (id tool-use)
  "Insert a `tool-call' turn for TOOL-USE plist with synthetic ID.
TOOL-USE is `(:name NAME :args ARGS)' as produced by `llm.el' multi-
output.  ARGS is an alist of (ARG-SYM . VALUE)."
  (let* ((name (plist-get tool-use :name))
          (args (plist-get tool-use :args)))
    (ellm--insert-tool-call-with-params name id args)))

(defun ellm-llm--insert-tool-result (id name result)
  "Insert a `tool-result' turn for NAME pairing call ID with RESULT body."
  (ellm--insert-turn "tool-result" :pipe-arg name :id id)
  (insert (format "%s\n" result)))

(defun ellm-llm--render-tool-uses (tool-uses tool-results)
  "Insert `tool-call' / `tool-result' turns for TOOL-USES and TOOL-RESULTS.
When `ellm-fold-tool-calls' is non-nil each inserted turn is folded."
  (let ((ids (mapcar #'ellm-llm--gen-call-id tool-uses)))
    (cl-loop for id in ids
             for tu in tool-uses
             do (ellm-llm--insert-tool-call id tu))
    (cl-loop for id in ids
             for tu in tool-uses
             for tr in tool-results
             do (ellm-llm--insert-tool-result
                 id (plist-get tu :name) (cdr tr)))))

;;;;; Parsing & sending

(defun ellm-llm--provider-with-model (provider model)
  "Return a copy of PROVIDER with its `chat-model' slot set to MODEL."
  (let ((copy (copy-sequence provider)))
    (condition-case nil
        (progn
          (setf (cl-struct-slot-value (type-of copy) 'chat-model copy) model)
          copy)
      (error provider))))

(defun ellm-llm--parse-buffer-as-chat (provider)
  "Build an `llm-chat-prompt' from the current buffer for PROVIDER."
  (let* ((fm          (ellm--parse-frontmatter))
         (turns       (cl-loop for turn in (ellm--parse-turns)
                               unless (equal "reasoning" (ellm-turn-role turn))
                               collect turn))
         (fm-system   (alist-get 'system fm))
         (has-system  (and turns
                           (equal (ellm-turn-role (car turns)) "system")))
         (reasoning   (alist-get 'reasoning fm))
         (tools       (ellm-llm--resolve-tools fm))
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
    (ellm-llm--apply-turns-to-prompt provider turns prompt)
    prompt))

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
      (when (and (not (string-empty-p new-text))
                 (save-excursion
                   (goto-char start)
                   (re-search-forward
                    (concat "^" (regexp-quote ellm-turn-header-2) " ")
                    end t)))
        (ellm--flush-pending-fold 2))
      (when (and ellm-fold-reasoning-blocks
                 reasoning (not (string-empty-p reasoning))
                 text (not (string-empty-p text)))
        (ellm-llm--fold-reasoning-in-region start end))
      (dolist (state saved)
        (pcase-let* ((`(,w ,ws ,wp) state))
          (when (window-live-p w)
            (set-window-start w ws t)
            (set-window-point w wp)))))))

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
           request
           (partial-render
            (lambda (result)
              (ellm-llm--render-streaming-response
               buf request start end result)))
           (final-render
            (lambda (result)
              (ellm-llm--ensure-buffer buf request)
              (funcall partial-render result)
              (with-current-buffer buf
                (setq ellm--active-request nil)
                (let ((recurse nil))
                  (if-let* ((tool-uses (plist-get result :tool-uses))
                            (tool-results (plist-get result :tool-results)))
                      (progn
                        (ellm-llm--render-tool-uses tool-uses tool-results)
                        (setq recurse t))
                    (ellm--insert-turn "user"))
                  ;; Fold reasoning after the following turn gives it a
                  ;; stable boundary; covers reasoning-only responses too.
                  (when ellm-fold-reasoning-blocks
                    (ellm-llm--fold-reasoning-in-region start end))
                  (when recurse
                    (ellm-llm--send-once provider prompt buf))))))
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
      (setq ellm--active-request (ellm-llm--make-request :raw request)))))

(defun ellm-llm--backend-send (provider buffer)
  "Send BUFFER through a normal `llm.el' PROVIDER."
  (with-current-buffer buffer
    (let ((prompt (ellm-llm--parse-buffer-as-chat provider)))
      (ellm-llm--send-once provider prompt buffer))))

;;;;; Utility

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

;;;; Footer

(provide 'ellm-llm)
;;; ellm-llm.el ends here
