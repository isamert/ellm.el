;;; ellm-llm.el --- llm.el backend for ellm  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (llm "0.31.1"))
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
  raw buffer generation cancelled timer (attempt 0) (retries 0))

;;;; Interface implementation

(cl-defmethod ellm-backend-send ((provider llm-standard-chat-provider)
                                 frontmatter buffer)
  "Send BUFFER through a standard `llm.el' chat PROVIDER."
  (ellm-llm--backend-send provider frontmatter buffer))

(cl-defmethod ellm-backend-send (provider frontmatter buffer)
  "Compatibility fallback for direct `llm.el' PROVIDER objects.
Backend-specific provider types should define a more specific
`ellm-backend-send' method, as `ellm-acp-provider' does."
  (ellm-llm--backend-send provider frontmatter buffer))

(cl-defmethod ellm-backend-cancel ((request ellm-llm-request))
  "Cancel an active `llm.el' REQUEST."
  (setf (ellm-llm-request-cancelled request) t)
  (cl-incf (ellm-llm-request-attempt request))
  (when-let* ((timer (ellm-llm-request-timer request)))
    (cancel-timer timer)
    (setf (ellm-llm-request-timer request) nil))
  (when-let* ((raw (ellm-llm-request-raw request)))
    (llm-cancel-request raw)
    (setf (ellm-llm-request-raw request) nil)))

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

(cl-defmethod ellm-provider-close-session ((_provider llm-standard-chat-provider) _frontmatter _buffer)
  "Close the session.
In this case there is no real session, so we just close the in-flight requests."
  ()
  (ellm-cancel t))

(cl-defmethod ellm-provider-config-effect
  ((provider llm-standard-chat-provider) path _buffer)
  "Return the `llm.el' backend's application effect for config PATH."
  (ellm-llm--config-effect provider path))

(cl-defmethod ellm-provider-config-effect (provider path _buffer)
  "Compatibility fallback matching direct `llm.el' backend dispatch."
  (ellm-llm--config-effect provider path))

(defun ellm-llm--config-effect (provider path)
  "Return the `llm.el' application effect for PROVIDER's config PATH."
  (let ((capabilities (ignore-errors (llm-capabilities provider))))
    (when (or (member path '((system) (temperature) (max-tokens) (cwd)))
              (and (equal path '(model))
                   (ellm-llm--provider-slot-p provider 'chat-model))
              (and (equal path '(reasoning))
                   (cl-intersection capabilities
                                    '(reasoning streaming-reasoning)))
              (and (equal path '(tools))
                   (cl-intersection capabilities
                                    '(tool-use streaming-tool-use))))
      'next-send)))

(defun ellm-llm--provider-slot-p (provider slot)
  "Return non-nil when PROVIDER has struct SLOT."
  (and (cl-struct-p provider)
       (assq slot (cl-struct-slot-info (type-of provider)))))

;;;; Internal

;;;;; Tool handling

(defun ellm-llm--gen-call-id (&rest _)
  "Return a fresh fallback tool-call ID for buffer serialization.
`llm.el's multi-output result omits provider IDs.  ellm recovers them from
the populated prompt when possible and uses this opaque ID otherwise."
  (format "call_%08x" (random (expt 2 32))))

(defun ellm-llm--persistable-call-id-p (id)
  "Return non-nil when provider call ID can be stored in a turn attribute."
  (and (stringp id)
       (not (string-empty-p id))
       (not (string-match-p "[[:space:][:cntrl:]]" id))))

(defun ellm-llm--new-prompt-tool-call-ids (prompt previous-interaction)
  "Return tool-use and result IDs added to PROMPT after PREVIOUS-INTERACTION.
The return value is a cons of (TOOL-USE-IDS . TOOL-RESULT-IDS), retaining
nil entries so each ID stays aligned with its corresponding prompt object."
  (let* ((interactions (llm-chat-prompt-interactions prompt))
         (new-interactions
          (if previous-interaction
              (cdr (memq previous-interaction interactions))
            interactions))
         tool-use-ids tool-result-ids)
    (dolist (interaction new-interactions)
      (let ((content (llm-chat-prompt-interaction-content interaction)))
        (when (and (consp content)
                   (cl-every #'llm-provider-utils-tool-use-p content))
          (dolist (tool-use content)
            (push (llm-provider-utils-tool-use-id tool-use)
                  tool-use-ids))))
      (dolist (tool-result
               (llm-chat-prompt-interaction-tool-results interaction))
        (push (llm-chat-prompt-tool-result-call-id tool-result)
              tool-result-ids)))
    (cons (nreverse tool-use-ids) (nreverse tool-result-ids))))

(defun ellm-llm--new-prompt-tool-uses (prompt previous-interaction)
  "Return tool uses added to PROMPT after PREVIOUS-INTERACTION."
  (let* ((interactions (llm-chat-prompt-interactions prompt))
         (new-interactions
          (if previous-interaction
              (cdr (memq previous-interaction interactions))
            interactions))
         result)
    (dolist (interaction new-interactions)
      (let ((content (llm-chat-prompt-interaction-content interaction)))
        (when (and (consp content)
                   (cl-every #'llm-provider-utils-tool-use-p content))
          (setq result (append result content)))))
    result))

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
  (let ((name (ellm-tool-name tool))
        (function (ellm-tool-function tool))
        (async (ellm-tool-async tool)))
    (llm-make-tool
     :name name
     :description (ellm-tool-description tool)
     :args (ellm-tool-args tool)
     :async async
     :function
     (if async
         (lambda (callback &rest args)
           (let ((callback-called nil))
             (condition-case err
                 (apply
                  function
                  (lambda (&rest values)
                    (setq callback-called t)
                    (apply callback values))
                  args)
               (error
                ;; Errors raised downstream by the result callback are not
                ;; failures of the tool and must not invoke it twice.
                (if callback-called
                    (signal (car err) (cdr err))
                  (funcall callback
                           (format "Tool `%s' failed: %s"
                                   name (error-message-string err)))
                  nil)))))
       (lambda (&rest args)
         (condition-case err
             (apply function args)
           (error
            (format "Tool `%s' failed: %s"
                    name (error-message-string err)))))))))

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
        (push (cons (intern (or pname "_"))
                    (ellm-tools--unescape-tool-body
                     (ellm-turn-content p)))
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
                              (ellm-tools--unescape-tool-body
                               (ellm-turn-content tool-call-turn)))))))
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
          ((equal role "reasoning")
           (ellm-provider-restore-reasoning
            provider prompt
            (ellm--unescape-turn-delimiters (ellm-turn-content turn))
            (when-let* ((id (alist-get "reasoning-state"
                                       (ellm-turn-attrs turn)
                                       nil nil #'equal)))
              (ellm-reasoning-state-read id)))
           (setq rest (cdr rest)))
         ((equal role "tool-result")
          (let (results)
            (while (and rest (equal (ellm-turn-role (car rest)) "tool-result"))
              (let* ((tr (car rest))
                     (attrs (ellm-turn-attrs tr))
                     (id (alist-get "id" attrs nil nil #'equal))
                     (name (alist-get "arg" attrs nil nil #'equal)))
                (push (make-llm-chat-prompt-tool-result
                        :call-id id :tool-name name
                        :result (ellm-tools--unescape-tool-body
                                 (ellm-turn-content tr)))
                       results)
                (setq rest (cdr rest))))
            ;; Providers do not all represent tool results with the generic
            ;; `tool-results' role.  In particular, Claude requires them to be
            ;; user messages, so let the provider choose the wire role just as
            ;; `llm.el' does for a live tool call.
            (llm-provider-append-to-prompt
             provider prompt nil (nreverse results))))
         ((equal role "tool-param")
          (setq rest (cdr rest)))
         ((and (equal role "assistant")
               (string-empty-p (ellm-turn-content turn)))
           (setq rest (cdr rest)))
         (t
          (setf (llm-chat-prompt-interactions prompt)
                (append (llm-chat-prompt-interactions prompt)
                         (list (make-llm-chat-prompt-interaction
                                :role (intern role)
                                :content
                                (if (equal role "assistant")
                                    (ellm--unescape-turn-delimiters
                                     (ellm-turn-content turn))
                                  (ellm-turn-content turn))))))
          (setq rest (cdr rest)))))))
  prompt)

(defun ellm-llm--insert-tool-call (id tool-use)
  "Insert a `tool-call' turn for TOOL-USE plist with synthetic ID.
TOOL-USE is `(:name NAME :args ARGS)' as produced by `llm.el' multi-
output.  ARGS is an alist of (ARG-SYM . VALUE)."
  (let* ((name (plist-get tool-use :name))
          (args (plist-get tool-use :args)))
    (ellm--insert-tool-call-with-params name id args)
    (ellm--flush-pending-fold)))

(defun ellm-llm--insert-tool-result (id name result &optional args)
  "Insert a `tool-result' turn for NAME pairing call ID with RESULT body.
When ARGS is non-nil, include its single-line values in the folded heading."
  (ellm--insert-turn "tool-result"
                     :pipe-arg (ellm--tool-header-title name args)
                     :id id)
  (insert (ellm--ensure-newline
           (ellm-tools--transform-tool-result name nil nil result)))
  (ellm--flush-pending-fold))

(defun ellm-llm--render-tool-uses (tool-uses tool-results &optional call-ids)
  "Insert `tool-call' / `tool-result' turns for TOOL-USES and TOOL-RESULTS.
When `ellm-fold-tool-calls' is non-nil each inserted turn is folded.
CALL-IDS is an optional cons of provider tool-use and tool-result ID lists."
  (let* ((provider-use-ids (car-safe call-ids))
         (provider-result-ids (cdr-safe call-ids))
         (ids
          (cl-loop for tool-use in tool-uses
                   for index from 0
                   for id = (or (plist-get tool-use :id)
                                (nth index provider-use-ids))
                   collect (if (ellm-llm--persistable-call-id-p id)
                               id
                             (ellm-llm--gen-call-id)))))
    (cl-loop for id in ids
             for tu in tool-uses
             do (ellm-llm--insert-tool-call id tu))
    (cl-loop for tr in tool-results
             for index from 0
             repeat (length ids)
             for provider-id = (nth index provider-result-ids)
             for id = (if (and (ellm-llm--persistable-call-id-p provider-id)
                               (member provider-id ids))
                          provider-id
                        (nth index ids))
             for use-index = (cl-position id ids :test #'equal)
             for tu = (or (nth use-index tool-uses)
                          (nth index tool-uses))
             do (ellm-llm--insert-tool-result
                 id (or (plist-get tu :name) (car-safe tr))
                 (cdr tr) (plist-get tu :args)))))

;;;;; Parsing & sending

(defun ellm-llm--provider-with-model (provider model)
  "Return a copy of PROVIDER with its `chat-model' slot set to MODEL."
  (let ((copy (copy-sequence provider)))
    (condition-case nil
        (progn
          (setf (cl-struct-slot-value (type-of copy) 'chat-model copy) model)
          copy)
      (error provider))))

(cl-defun ellm-llm--parse-buffer-as-chat
    (provider &optional (frontmatter (ellm--parse-frontmatter)))
  "Build an `llm-chat-prompt' from the current buffer for PROVIDER.
FRONTMATTER, when supplied, is the already parsed YAML frontmatter alist."
  (let* ((fm          frontmatter)
         (turns       (ellm--parse-turns))
         (fm-system   (alist-get 'system fm))
         (has-system  (and turns
                           (equal (ellm-turn-role (car turns)) "system")))
         (system      (if has-system
                          (ellm-turn-content (car turns))
                        fm-system))
         (reasoning   (alist-get 'reasoning fm))
         (tools       (ellm-llm--resolve-tools fm))
         (prompt      (make-llm-chat-prompt
                       ;; `llm.el' models system instructions as prompt
                       ;; context.  A literal system interaction is outside
                       ;; its public interaction-role contract and some
                       ;; providers (notably Claude) serialize it with no
                       ;; valid wire role.
                       :context      system
                       :tools        tools
                       :temperature  (alist-get 'temperature fm)
                       :max-tokens   (alist-get 'max-tokens fm)
                       :reasoning    (and reasoning
                                          (intern (format "%s" reasoning))))))
    (ellm-llm--apply-turns-to-prompt
     provider (if has-system (cdr turns) turns) prompt)
    prompt))

(defun ellm-llm--render-streaming-response
    (buf request start end result &optional reasoning-state-id)
  (ellm-llm--ensure-buffer buf request)
  (with-current-buffer buf
    (ellm--preserve-user-position
      (let* ((reasoning-raw (plist-get result :reasoning))
             (text-raw      (plist-get result :text))
             (reasoning (and reasoning-raw
                             (ellm--escape-turn-delimiters reasoning-raw)))
             (text      (and text-raw
                             (ellm--escape-turn-delimiters text-raw)))
             (new-text
              (concat
               (when (or reasoning-state-id
                         (and reasoning (not (string-empty-p reasoning))))
                 (concat (if reasoning-state-id
                             (ellm--get-turn
                              "reasoning" :continuation t
                              :reasoning-state reasoning-state-id)
                           (ellm--get-turn "reasoning" :continuation t))
                         "\n"
                         (if reasoning
                             (ellm--ensure-newline reasoning)
                           "")))
               (when (and text (not (string-empty-p text)))
                 (concat (ellm--get-turn "assistant" :continuation t) "\n"
                         (ellm--ensure-newline text))))))
        (goto-char start)
        (let* ((current-text
                (buffer-substring-no-properties start end))
               (prefix-length
                (length (fill-common-string-prefix
                          current-text new-text))))
          (goto-char (+ start prefix-length))
          (delete-region (point) end)
          (insert (substring new-text prefix-length)))
        (when (and (not (string-empty-p new-text))
                   (save-excursion
                      (goto-char start)
                      (re-search-forward
                       (concat "^"
                               (ellm--turn-header-prefix-regexp
                                ellm-turn-header-2))
                       end t)))
          (ellm--flush-pending-fold 2))
        (when (and ellm-fold-reasoning-blocks
                   reasoning (not (string-empty-p reasoning))
                   text (not (string-empty-p text)))
          (ellm-llm--fold-reasoning-in-region start end))))))

(defun ellm-llm--request-live-p (request)
  "Return non-nil when REQUEST may still invoke buffer callbacks."
  (and (not (ellm-llm-request-cancelled request))
       (ellm--request-current-p
        (ellm-llm-request-buffer request)
        (ellm-llm-request-generation request))))

(defun ellm-llm--cancel-request-timer (request)
  "Cancel REQUEST's current deadline or retry timer."
  (when-let* ((timer (ellm-llm-request-timer request)))
    (cancel-timer timer)
    (setf (ellm-llm-request-timer request) nil)))

(defun ellm-llm--retryable-error-p (type)
  "Return non-nil when an llm.el error TYPE is transient."
  (memq type '(llm-request-error llm-request-timeout)))

(defun ellm-llm--handle-attempt-error
    (request attempt provider prompt partial final on-error type message)
  "Handle one llm.el request failure, retrying transient failures."
  (when (and (= attempt (ellm-llm-request-attempt request))
             (ellm-llm--request-live-p request))
    (ellm-llm--cancel-request-timer request)
    (if (and (ellm-llm--retryable-error-p type)
             (< (ellm-llm-request-retries request) ellm-request-retries))
        (progn
          ;; Invalidate callbacks from the timed-out attempt before cancelling
          ;; its transport.  Some transports invoke callbacks synchronously.
          (cl-incf (ellm-llm-request-attempt request))
          (cl-incf (ellm-llm-request-retries request))
          (when-let* ((raw (ellm-llm-request-raw request)))
            (llm-cancel-request raw)
            (setf (ellm-llm-request-raw request) nil))
          (setf
           (ellm-llm-request-timer request)
           (run-at-time
            ellm-request-retry-delay nil
            #'ellm-llm--start-request
            request provider prompt partial final on-error)))
      (cl-incf (ellm-llm-request-attempt request))
      (funcall on-error type message))))

(defun ellm-llm--start-request
    (request provider prompt partial final on-error)
  "Start or retry one streaming llm.el REQUEST.
PARTIAL, FINAL, and ON-ERROR describe one logical request; timeout and retry
bookkeeping stays within this function."
  (when (ellm-llm--request-live-p request)
    (ellm-llm--cancel-request-timer request)
    (let ((attempt (cl-incf (ellm-llm-request-attempt request))))
      (when ellm-request-timeout
        (setf
         (ellm-llm-request-timer request)
         (run-at-time
          ellm-request-timeout nil
          (lambda ()
            (ellm-llm--handle-attempt-error
             request attempt provider prompt partial final on-error
             'llm-request-timeout
             (format "request timed out after %s seconds"
                     ellm-request-timeout))))))
      (condition-case err
          (let ((raw
                 (let ((llm-request-plz-timeout
                        (or ellm-request-timeout llm-request-plz-timeout)))
                   (llm-chat-streaming
                    provider prompt
                    (lambda (result)
                      (when (and (= attempt
                                    (ellm-llm-request-attempt request))
                                 (ellm-llm--request-live-p request))
                        (funcall partial result)))
                    (lambda (result)
                      (when (and (= attempt
                                    (ellm-llm-request-attempt request))
                                 (ellm-llm--request-live-p request))
                        (ellm-llm--cancel-request-timer request)
                        (cl-incf (ellm-llm-request-attempt request))
                        (funcall final result)))
                    (lambda (type message)
                      (ellm-llm--handle-attempt-error
                       request attempt provider prompt partial final on-error
                       type message))
                    'multi-output))))
            ;; A provider is allowed to complete synchronously.  Do not attach
            ;; the returned handle to an attempt that already completed.
            (when (= attempt (ellm-llm-request-attempt request))
              (setf (ellm-llm-request-raw request) raw)))
        (error
         (ellm-llm--handle-attempt-error
          request attempt provider prompt partial final on-error
          (car err) (error-message-string err))))))
  request)

(defun ellm-llm--tool-call-error-p (type)
  "Return non-nil when TYPE describes a malformed model tool call."
  (memq 'llm-tool-call-error (get type 'error-conditions)))

(defun ellm-llm--tool-call-error-message (type message tool-use)
  "Return a model-facing explanation for malformed TOOL-USE."
  (let ((name (llm-provider-utils-tool-use-name tool-use)))
    (pcase type
      ('llm-tool-unknown-tool
       (if name
           (format "Tool call rejected: `%s' is not an advertised tool. %s"
                   name message)
         "Tool call rejected: the provider returned a call without a tool name. \
Call one of the advertised tools and include its exact name."))
      ('llm-tool-missing-argument
       (format "Tool call rejected because a required argument is missing. %s"
               message))
      ('llm-tool-unknown-argument
       (format "Tool call rejected because it contains an unknown argument. %s"
               message))
      (_
       (format "Tool call rejected as malformed. %s" message)))))

(defun ellm-llm--recover-tool-call-error
    (provider prompt previous-interaction type message)
  "Record malformed tool calls as results and return data for rendering.
Return (TOOL-USES TOOL-RESULTS IDS), or nil when no call was recoverable."
  (when-let* ((uses (ellm-llm--new-prompt-tool-uses
                     prompt previous-interaction)))
    (let (rendered-uses rendered-results prompt-results ids)
      (dolist (use uses)
        (let* ((id (or (llm-provider-utils-tool-use-id use)
                       (ellm-llm--gen-call-id)))
               (name (llm-provider-utils-tool-use-name use))
               (result (ellm-llm--tool-call-error-message
                        type message use)))
          (setf (llm-provider-utils-tool-use-id use) id)
          (push id ids)
          (push (list :id id :name name
                      :args (llm-provider-utils-tool-use-args use))
                rendered-uses)
          (push (cons name result) rendered-results)
          (push (make-llm-chat-prompt-tool-result
                 :call-id id :tool-name name :result result)
                prompt-results)))
      (llm-provider-append-to-prompt
       provider prompt nil (nreverse prompt-results))
      (list (nreverse rendered-uses)
            (nreverse rendered-results)
            (cons (nreverse ids) (nreverse ids))))))

(defun ellm-llm--send-once (provider prompt buf)
  "Stream PROVIDER's reply for PROMPT into the trailing assistant turn of BUF.
Uses multi-output mode.  If the LLM emits tool calls, llm.el executes
them and populates PROMPT with both calls and results before the final
callback fires; this function then writes corresponding `tool-call' /
`tool-result' turns into BUF, opens a continuation `assistant' turn,
and recurses with the (already populated) PROMPT.  When the response
is text-only, a fresh trailing `user' turn is appended."
  (with-current-buffer buf
    (let* ((previous-interaction
            (car (last (llm-chat-prompt-interactions prompt))))
           (start (copy-marker (point-max) nil))
           (end   (copy-marker (point-max) t))
           reasoning-state-id
           (request
            (ellm-llm--make-request
             :buffer buf :generation ellm--request-generation))
           (partial-render
            (lambda (result)
              (when-let* ((state
                           (ellm-provider-reasoning-state provider result)))
                (setq reasoning-state-id
                      (ellm-reasoning-state-write state)))
              (ellm-llm--render-streaming-response
               buf request start end result reasoning-state-id)))
           (final-render
            (lambda (result)
              (ellm-llm--ensure-buffer buf request)
              (funcall partial-render result)
              (with-current-buffer buf
                (ellm--preserve-user-position
                  (let ((recurse nil))
                    (ellm--set-active-request nil)
                    (if-let* ((tool-uses (plist-get result :tool-uses))
                              (tool-results (plist-get result :tool-results)))
                        (progn
                          (ellm-llm--render-tool-uses
                           tool-uses tool-results
                           (ellm-llm--new-prompt-tool-call-ids
                            prompt previous-interaction))
                          (setq recurse t))
                      (ellm--insert-turn "user"))
                    ;; Fold reasoning after the following turn gives it a
                    ;; stable boundary; covers reasoning-only responses too.
                    (when ellm-fold-reasoning-blocks
                      (ellm-llm--fold-reasoning-in-region start end))
                    (ellm--persistence-checkpoint)
                    (if recurse
                        (ellm-llm--send-once provider prompt buf)
                      (ellm--notify-request-finished)))))))
           (on-error
             (lambda (type msg)
               (ellm-llm--ensure-buffer buf request)
               (if (ellm-llm--tool-call-error-p type)
                   (if-let* ((recovery
                              (ellm-llm--recover-tool-call-error
                               provider prompt previous-interaction
                               type msg)))
                       (with-current-buffer buf
                         (ellm--preserve-user-position
                           (ellm--set-active-request nil)
                           (ellm-llm--render-tool-uses
                            (nth 0 recovery) (nth 1 recovery)
                            (nth 2 recovery))
                           (when ellm-fold-reasoning-blocks
                             (ellm-llm--fold-reasoning-in-region start end))
                           (ellm--persistence-checkpoint)
                           (ellm-llm--send-once provider prompt buf)))
                     ;; Argument JSON can fail before llm.el has a structured
                     ;; tool use to pair with a result.  Give the model a
                     ;; correction as an ordinary interaction instead.
                     (let ((correction
                            (format "Your previous tool call was malformed and \
could not be executed: %s. Retry it using an advertised tool and valid arguments."
                                    msg)))
                       (setf (llm-chat-prompt-interactions prompt)
                             (append
                              (llm-chat-prompt-interactions prompt)
                              (list (make-llm-chat-prompt-interaction
                                     :role 'user :content correction))))
                       (with-current-buffer buf
                         (ellm--preserve-user-position
                           (ellm--set-active-request nil)
                           (ellm--insert-turn "assistant" :continuation t)
                           (insert (ellm--ensure-newline correction))
                           (ellm--persistence-checkpoint)
                           (ellm-llm--send-once provider prompt buf)))))
                 (with-current-buffer buf
                   (ellm--set-active-request nil)
                   (ellm--ensure-next-user-turn)
                   (ellm--persistence-checkpoint)
                   (ellm--notify-request-finished)
                   (message "ellm: %s" msg))))))
      (ellm--set-active-request ellm--request-starting)
      (condition-case err
          (progn
            (ellm-llm--start-request
             request provider prompt partial-render final-render on-error)
            (when (eq ellm--active-request ellm--request-starting)
              (ellm--set-active-request request)))
        (error
         (when (eq ellm--active-request ellm--request-starting)
           (ellm--set-active-request nil)
           (ellm--ensure-next-user-turn)
           (ellm--persistence-checkpoint)
           (ellm--notify-request-finished))
         (signal (car err) (cdr err)))))))

(defun ellm-llm--frontmatter-cwd (frontmatter)
  "Return FRONTMATTER's `cwd' as an absolute directory, or nil."
  (when-let* ((cwd (alist-get 'cwd frontmatter)))
    (file-name-as-directory
     (expand-file-name cwd (or ellm--base-default-directory
                               default-directory)))))

(defun ellm-llm--apply-cwd (frontmatter)
  "Apply FRONTMATTER `cwd:' to the current ellm buffer.
  This sets buffer-local `default-directory' instead of dynamically binding
it so async callbacks and llm.el tool execution keep using the same cwd
when they later re-enter the buffer."
  (let ((base (or ellm--base-default-directory default-directory)))
    (setq-local ellm--frontmatter-cwd-directory nil)
    (if-let* ((cwd (ellm-llm--frontmatter-cwd frontmatter)))
        (progn
          (unless (file-directory-p cwd)
            (user-error "ellm: cwd does not exist: %s" cwd))
          (setq-local ellm--frontmatter-cwd-directory cwd)
          (setq-local default-directory cwd))
      (setq-local default-directory base))))

(defun ellm-llm--backend-send (provider frontmatter buffer)
  "Send BUFFER through a normal `llm.el' PROVIDER."
  (with-current-buffer buffer
    (ellm-llm--apply-cwd frontmatter)
    (let ((prompt (ellm-llm--parse-buffer-as-chat provider frontmatter)))
      (ellm-llm--send-once provider prompt buffer))))

;;;;; Utility

(defun ellm-llm--ensure-buffer (buf &optional request-to-cancel)
  (unless (buffer-live-p buf)
    (when request-to-cancel
      (if (ellm-llm-request-p request-to-cancel)
          (ellm-backend-cancel request-to-cancel)
        (llm-cancel-request request-to-cancel)))
    (user-error "ellm :: Buffer is gone")))

(defun ellm-llm--fold-reasoning-in-region (start end)
  "Fold the `reasoning' turn located between START and END, if any."
  (save-excursion
    (goto-char start)
    (when (re-search-forward
           (concat "^"
                   (ellm--turn-header-prefix-regexp ellm-turn-header-2)
                   "reasoning\\b")
           end t)
      (ellm--fold-subtree-at (match-beginning 0)))))

;;;; Footer

(provide 'ellm-llm)
;;; ellm-llm.el ends here
