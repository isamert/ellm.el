;;; ellm-kagi.el --- Kagi Assistant backend for ellm  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.2
;; Package-Requires: ((emacs "29.1") (plz "0.9"))
;; Keywords: llm, kagi

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

;; Backend for the session-based Kagi Assistant v2 web API
;; (assistant.kagi.com).  Authentication uses the `kagi_session'
;; cookie from an existing Kagi login.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'plz)
(require 'subr-x)
(require 'ellm)

(defgroup ellm-kagi nil
  "Kagi Assistant backend for ellm."
  :group 'ellm)

(defcustom ellm-kagi-models
  '("ki_quick" "kimi-k2-7-code" "kimi-k2-6-thinking" "kimi-k2-6"
    "glm-5-3-flash" "claude-5-opus-thinking" "qwen-3-8-27b" "qwen-3-7-plus"
    "gpt-5-6-luna" "gpt-oss-120b" "deepseek-v4-flash"
    "gemini-3-1-flash-lite" "grok-4-3" "mistral-small-4" "mistral-large"
    "hermes-4-405b-thinking" "minimax-m3")
  "Fallback Kagi Assistant model IDs offered for completion.
Run `ellm-kagi-refresh-models' to replace a provider's configured model list
with the currently supported models returned by Kagi's `/api/init' endpoint."
  :type '(repeat string)
  :group 'ellm-kagi)

(cl-defstruct
    (ellm-kagi-provider
     (:constructor ellm-make-kagi-provider
      (&key session-token model models
            (base-url "https://assistant.kagi.com")
            (enable-search t) (personalization t)
            thinking-preset)))
  "Configuration for the Kagi Assistant backend.
SESSION-TOKEN is the value of the `kagi_session' cookie, or a function
returning it.  MODEL is Kagi's model id.  MODELS optionally supplies model
completion candidates.  ENABLE-SEARCH, PERSONALIZATION, and THINKING-PRESET
provide request defaults that may be overridden by `kagi:' frontmatter."
  session-token model models base-url enable-search personalization
  thinking-preset)

(cl-defstruct (ellm-kagi-request (:constructor ellm-kagi--make-request))
  "Protocol driver and cumulative stream state for a Kagi request."
  (provider nil
            :type ellm-kagi-provider
            :documentation "Kagi provider configuration serving the request.")
  (buffer nil
          :type buffer
          :documentation "Conversation buffer associated with the request.")
  (process nil
           :type (or null process)
           :documentation "Current cancellable HTTP transport process, or nil.")
  (conversation-id nil
                   :type (or null string)
                   :documentation "Remote Kagi conversation identifier.")
  (branch-id nil
             :type (or null string)
             :documentation "Remote branch receiving submitted messages.")
  (stream-url nil
              :type (or null string)
              :documentation "Relative endpoint used to consume response events.")
  (cancel-url nil
              :type (or null string)
              :documentation "Relative endpoint used to cancel remote generation.")
  (wire-input nil
              :type (or null string)
              :documentation "Unconsumed bytes while parsing HTTP response headers.")
  (body-started nil
                :type boolean
                :documentation "Non-nil after the HTTP response body has begun.")
  (sse-input nil
             :type (or null string)
             :documentation "Incomplete Server-Sent Events input carried between reads.")
  (completed nil
             :type boolean
             :documentation "Non-nil after the protocol driver has terminated.")
  (cancelled nil
             :type boolean
             :documentation "Non-nil after local cancellation was requested.")
  (cancel-sent nil
               :type boolean
               :documentation "Non-nil while remote cancellation has been sent.")
  (phase nil
         :type (member nil creating posting streaming done)
         :documentation "Current protocol operation.")
  (payload nil
           :type list
           :documentation "JSON-ready message payload.")
  (emit nil
        :type (or null function)
        :documentation "Core event sink, or nil after request finalization.")
  (root-id nil :documentation "Root assistant message node ID.")
  (nodes nil :documentation "Node ID to payload alist, in creation order.")
  (references nil :documentation "Reference ID to source metadata alist.")
  (seen-events (make-hash-table :test #'equal)
               :documentation "Event IDs already consumed, for replay deduplication.")
  (turn-completed nil :documentation "Non-nil after turn.completed was received.")
  (serial 0
          :type integer
          :documentation "Generation counter used to reject stale HTTP callbacks."))

;;;; Backend interface

(cl-defmethod ellm-provider-current-model ((provider ellm-kagi-provider))
  "Return Kagi PROVIDER's configured model."
  (ellm-kagi-provider-model provider))

(cl-defmethod ellm-provider-model-candidates ((provider ellm-kagi-provider))
  "Return Kagi PROVIDER's configured model candidates."
  (let ((models (copy-sequence
                 (or (ellm-kagi-provider-models provider)
                     ellm-kagi-models)))
        (current (ellm-kagi-provider-model provider)))
    (if (and current (not (member current models)))
        (cons current models)
      models)))

(cl-defmethod ellm-provider-with-model ((provider ellm-kagi-provider) model)
  "Return a copy of Kagi PROVIDER configured to use MODEL."
  (let ((copy (copy-sequence provider)))
    (setf (ellm-kagi-provider-model copy) model)
    copy))

(cl-defmethod ellm-provider-frontmatter-entries
  ((provider ellm-kagi-provider) path _buffer)
  "Return Kagi-specific frontmatter entries for PROVIDER under PATH."
  (when (null path)
    (list
     (list
      "kagi" :ann "map"
      :desc "Kagi Assistant request settings and persisted conversation metadata."
      :children
      (list
       (list "enable-search" :ann "boolean"
             :desc "Enable Kagi web search for this conversation."
             :type 'boolean :editable t
             :default (if (ellm-kagi-provider-enable-search provider)
                          t :false)
             :values '(("true" :desc "Enable Kagi web search.")
                       ("false" :desc "Disable Kagi web search.")))
       (list "personalization" :ann "boolean"
             :desc "Use Kagi account personalization for this conversation."
             :type 'boolean :editable t
             :default (if (ellm-kagi-provider-personalization provider)
                          t :false)
             :values '(("true" :desc "Enable Kagi personalization.")
                       ("false" :desc "Disable Kagi personalization.")))
       (append
        (list "thinking-preset" :ann "preset"
              :desc "Kagi thinking budget for models that support thinking presets."
              :type 'enum :editable t
              :values '(("standard" :desc "Use Kagi's standard thinking budget.")
                        ("extended" :desc "Use Kagi's extended thinking budget.")))
        (when-let* ((preset (ellm-kagi--provider-thinking-preset provider)))
          (list :default preset))))))))

(cl-defmethod ellm-provider-config-effect
  ((_provider ellm-kagi-provider) path _buffer)
  "Return Kagi's application effect for config PATH."
  (when (member path '((model)
                       (kagi enable-search)
                       (kagi personalization)
                       (kagi thinking-preset)))
    'next-send))

(cl-defmethod ellm-provider-close-session
  ((_provider ellm-kagi-provider) _frontmatter buffer)
  "Cancel BUFFER's active request without deleting its Kagi conversation."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (ellm-request-p ellm--active-request)
                 (ellm-kagi-request-p
                  (ellm-request-backend ellm--active-request)))
        (ellm-cancel t)))))

(cl-defmethod ellm-backend-create
  ((provider ellm-kagi-provider) frontmatter buffer)
  "Create a Kagi driver for BUFFER using FRONTMATTER."
  (unless (buffer-live-p buffer)
    (user-error "Ellm Kagi: buffer is not live"))
  (let ((model (ellm-kagi-provider-model provider)))
    (unless (and (stringp model) (not (string-empty-p model)))
      (user-error "Ellm Kagi: provider model is required")))
  (with-current-buffer buffer
    (ellm--apply-working-directory frontmatter)
    (let* ((request
             (ellm-kagi--make-request
              :provider provider
              :buffer buffer
              :conversation-id
              (ellm--alist-get-nested frontmatter '(kagi conversation-id))
              :branch-id
              (ellm--alist-get-nested frontmatter '(kagi branch-id))))
           (message (ellm-kagi--last-user-content))
           (payload (ellm-kagi--message-payload provider frontmatter message)))
      (setf (ellm-kagi-request-payload request) payload)
      request)))

(cl-defmethod ellm-backend-start ((request ellm-kagi-request) emit)
  "Start or retry REQUEST's current Kagi operation."
  (setf (ellm-kagi-request-emit request) emit)
  (cl-incf (ellm-kagi-request-serial request))
  (pcase (ellm-kagi-request-phase request)
    ((or 'nil 'creating)
     (if (ellm-kagi-request-branch-id request)
         (ellm-kagi--post-message request (ellm-kagi-request-payload request))
       (ellm-kagi--create-conversation
        request (ellm-kagi-request-payload request))))
    ('posting
     (ellm-kagi--post-message request (ellm-kagi-request-payload request)))
    ('streaming
     (ellm-kagi--start-stream request))
    ('done nil)
    (_ (error "ellm Kagi: invalid request phase: %S"
              (ellm-kagi-request-phase request))))
  (ellm-kagi-request-process request))

(cl-defmethod ellm-backend-cancel ((request ellm-kagi-request))
  "Cancel Kagi REQUEST locally and cancel its remote turn when known."
  (setf (ellm-kagi-request-cancelled request) t)
  (unless (memq (ellm-kagi-request-phase request) '(creating posting))
    (cl-incf (ellm-kagi-request-serial request)))
  (ellm-kagi--stop-request request))

(cl-defmethod ellm-backend-finish ((request ellm-kagi-request) outcome)
  "Release Kagi REQUEST after terminal OUTCOME."
  (when (memq outcome '(failed cancelled))
    (ellm-kagi--stop-request request))
  (setf (ellm-kagi-request-completed request) t
        (ellm-kagi-request-phase request) 'done
        (ellm-kagi-request-emit request) nil
        (ellm-kagi-request-process request) nil))

(cl-defmethod ellm-backend-render-event
  ((request ellm-kagi-request) event _core-request)
  "Render Kagi metadata EVENT."
  (pcase (plist-get event :kind)
    ('title
     (ellm-kagi--update-title-direct request (plist-get event :title)))
    ('session
     (ellm-kagi--persist-session-direct request))))

(defun ellm-kagi--emit (request event)
  "Emit EVENT from live Kagi REQUEST."
  (when (and (not (ellm-kagi-request-cancelled request))
             (not (ellm-kagi-request-completed request)))
    (when-let* ((emit (ellm-kagi-request-emit request)))
      (funcall emit event))))

(defun ellm-kagi--stop-request (request)
  "Stop REQUEST's current transport and cancel remote generation once.
An in-flight submit is allowed to return its turn ID after cancellation,
so its callback can cancel the generation rather than orphaning it."
  (when-let* (((not (and (ellm-kagi-request-cancelled request)
                         (memq (ellm-kagi-request-phase request)
                               '(creating posting)))))
              (process (ellm-kagi-request-process request)))
    (when (and (processp process) (process-live-p process))
      (delete-process process))
    (setf (ellm-kagi-request-process request) nil))
  (when-let* (((not (ellm-kagi-request-cancel-sent request)))
              (cancel-url (ellm-kagi-request-cancel-url request)))
    (setf (ellm-kagi-request-cancel-sent request) t)
    (let ((provider (ellm-kagi-request-provider request)))
      (condition-case err
          (plz 'post (ellm-kagi--url provider cancel-url)
            :headers (ellm-kagi--headers provider "application/json"
                                         "application/json")
            :body "{}"
            :as 'string
            :then #'ignore
            :else (lambda (error)
                    (setf (ellm-kagi-request-cancel-sent request) nil)
                    (message "ellm Kagi: cancellation failed: %s"
                             (ellm-kagi--plz-error-message error)))
            :timeout ellm-request-timeout
            :noquery t)
        (error
         (setf (ellm-kagi-request-cancel-sent request) nil)
         (message "ellm Kagi: cancellation failed: %s"
                  (error-message-string err)))))))

;;;; Requests

(defun ellm-kagi--session-token (provider)
  "Return PROVIDER's Kagi session token."
  (let* ((configured (ellm-kagi-provider-session-token provider))
         (token (if (functionp configured)
                    (funcall configured)
                  configured)))
    (unless (and (stringp token) (not (string-empty-p token)))
      (user-error "Ellm Kagi: provider session token is required"))
    (string-remove-prefix "kagi_session=" token)))

(defun ellm-kagi--headers (provider accept &optional content-type)
  "Return minimal request headers for PROVIDER.
ACCEPT is the expected response type.  CONTENT-TYPE is included when non-nil."
  (append `(("Accept" . ,accept)
            ("Cookie" . ,(concat "kagi_session="
                                 (ellm-kagi--session-token provider))))
          (when content-type
            `(("Content-Type" . ,content-type)))))

(defun ellm-kagi--url (provider path)
  "Return PROVIDER's absolute URL for PATH."
  (if (string-match-p "\\`https?://" path)
      path
    (concat (string-remove-suffix
             "/" (or (ellm-kagi-provider-base-url provider)
                     "https://assistant.kagi.com"))
            (if (string-prefix-p "/" path) "" "/")
            path)))

(defun ellm-kagi--provider-thinking-preset (provider)
  "Return PROVIDER's thinking preset, including for older provider records."
  ;; Early backend versions did not have the trailing `thinking-preset' slot.
  (when (> (length provider) 7)
    (ellm-kagi-provider-thinking-preset provider)))

(defun ellm-kagi--request-json
    (provider method path body then else &optional request)
  "Send a managed JSON request through PROVIDER.
METHOD and PATH identify the endpoint.  BODY is a plist or nil.  THEN and ELSE
are terminal callbacks.  When REQUEST is non-nil, keep its cancellable process
current.  Failures are surfaced to the core request state machine."
  (let ((done nil)
        (serial (and request (ellm-kagi-request-serial request)))
        process)
    (cl-labels
        ((live-p ()
                 (and (not done)
                      (or (not request)
                          (and (or (not (ellm-kagi-request-completed request))
                                   (ellm-kagi-request-cancelled request))
                               (= serial (ellm-kagi-request-serial request)))))))
      (setq
       process
       (plz method (ellm-kagi--url provider path)
         :headers (ellm-kagi--headers
                   provider "application/json"
                   (and body "application/json"))
         :body (and body
                    (json-serialize
                     body :null-object nil
                     :false-object :json-false))
         :as 'string
         :then
         (lambda (response-body)
           (when (live-p)
             (let (result parse-error)
               (condition-case err
                   (setq result
                         (json-parse-string
                          response-body
                          :object-type 'plist
                          :array-type 'list
                          :null-object nil
                          :false-object :json-false))
                 (error (setq parse-error err)))
               (setq done t)
               (if parse-error
                   (funcall
                    else
                    (make-plz-error
                     :message
                     (format "invalid JSON response: %s"
                             (error-message-string parse-error))))
                 (funcall then result)))))
         :else
         (lambda (error)
           (when (live-p)
             (setq done t)
             (funcall else error)))
         :timeout ellm-request-timeout
         :noquery t))
      (when (and request (not done)
                 (= serial (ellm-kagi-request-serial request)))
        (setf (ellm-kagi-request-process request) process)))
    process))

(defun ellm-kagi--models-from-init (result)
  "Return supported model IDs from a parsed Kagi init RESULT."
  (delete-dups
   (cl-loop for model in (plist-get (plist-get result :models) :models)
            for id = (plist-get model :id)
            when (and id
                      (not (eq (plist-get model :supported) :json-false))
                      (not (eq (plist-get model :deprecated) t))
                      (not (eq (plist-get model :retired) t)))
            collect id)))

(defun ellm-kagi--configured-provider ()
  "Return the configured Kagi provider for the current command context."
  (let* ((frontmatter (and (derived-mode-p 'ellm-mode)
                           (ellm--effective-frontmatter)))
         (name (alist-get 'provider frontmatter))
         (entry (and name
                     (alist-get (if (symbolp name) name (intern name))
                                ellm-provider-alist)))
         (provider (or (and entry (ellm--provider-entry-provider entry))
                       (and (ellm-kagi-provider-p ellm-provider)
                            ellm-provider)
                       (cl-loop for candidate in ellm-provider-alist
                                for value = (ellm--provider-entry-provider
                                             (cdr candidate))
                                when (ellm-kagi-provider-p value)
                                return value))))
    (unless (ellm-kagi-provider-p provider)
      (user-error "Ellm Kagi: no Kagi provider is configured"))
    provider))

(defun ellm-kagi-refresh-models (&optional provider)
  "Refresh model candidates on Kagi PROVIDER from `/api/init'.
Interactively, use the current buffer's configured Kagi provider, falling back
to `ellm-provider' or the first Kagi entry in `ellm-provider-alist'."
  (interactive)
  (let* ((provider (or provider (ellm-kagi--configured-provider)))
         (body (plz 'get (ellm-kagi--url provider "/api/init")
                 :headers (ellm-kagi--headers provider "application/json")
                 :as 'string
                 :timeout ellm-request-timeout
                 :noquery t))
         (result (json-parse-string body
                                    :object-type 'plist
                                    :array-type 'list
                                    :null-object nil
                                    :false-object :json-false))
         (models (ellm-kagi--models-from-init result)))
    (unless models
      (user-error "Ellm Kagi: init response did not contain supported models"))
    (setf (ellm-kagi-provider-models provider) models)
    (when (called-interactively-p 'interactive)
      (message "ellm Kagi: loaded %d models" (length models)))
    models))

(defun ellm-kagi--frontmatter-option (frontmatter path fallback)
  "Return FRONTMATTER value at PATH, or FALLBACK when PATH is absent."
  (if-let* ((cell (ellm--alist-get-nested-cell frontmatter path)))
      (cdr cell)
    fallback))

(defun ellm-kagi--json-boolean (value)
  "Return VALUE represented as a JSON boolean."
  (if (ellm--false-value-p value) :json-false t))

(defun ellm-kagi--setting-string (value)
  "Return VALUE as a Kagi setting string, preserving nil."
  (and value (format "%s" value)))

(defun ellm-kagi--message-payload (provider frontmatter message)
  "Return Kagi's message payload for PROVIDER, FRONTMATTER, and MESSAGE."
  (let ((thinking-preset
         (ellm-kagi--frontmatter-option
          frontmatter '(kagi thinking-preset)
          (ellm-kagi--provider-thinking-preset provider))))
    (append
     (list :content message
          :model (ellm-kagi-provider-model provider)
          :lens_id nil
          :enable_search
          (ellm-kagi--json-boolean
           (ellm-kagi--frontmatter-option
            frontmatter '(kagi enable-search)
            (ellm-kagi-provider-enable-search provider)))
          :personalization
          (ellm-kagi--json-boolean
           (ellm-kagi--frontmatter-option
            frontmatter '(kagi personalization)
            (ellm-kagi-provider-personalization provider))))
     (when thinking-preset
       (list :thinking_preset (ellm-kagi--setting-string thinking-preset))))))

(defun ellm-kagi--create-conversation (request payload)
  "Create Kagi REQUEST's conversation with its first message PAYLOAD."
  (setf (ellm-kagi-request-phase request) 'creating)
  (ellm-kagi--submit request "/api/v2/conversations" payload))

(defun ellm-kagi--post-message (request payload)
  "Submit PAYLOAD to Kagi REQUEST's existing branch."
  (setf (ellm-kagi-request-phase request) 'posting)
  (ellm-kagi--submit
   request
   (format "/api/v2/branches/%s/respond"
           (ellm-kagi-request-branch-id request))
   payload))

(defun ellm-kagi--submit (request path payload)
  "Submit message PAYLOAD to PATH and stream REQUEST's returned turn."
  (ellm-kagi--request-json
   (ellm-kagi-request-provider request) 'post path payload
   (lambda (result)
     (let ((conversation (plist-get result :conversation_uuid))
           (branch (plist-get result :branch_uuid))
           (turn (plist-get result :assistant_turn_uuid)))
       (if (not (and (stringp conversation) (stringp branch) (stringp turn)))
           (ellm-kagi--finish-error
            request "response did not include conversation, branch and turn IDs")
         (setf (ellm-kagi-request-conversation-id request) conversation
               (ellm-kagi-request-branch-id request) branch
               (ellm-kagi-request-stream-url request)
               (format "/api/v2/turns/%s/stream" turn)
               (ellm-kagi-request-cancel-url request)
               (format "/api/v2/turns/%s/cancel" turn)
               (ellm-kagi-request-phase request) 'streaming)
         (if (ellm-kagi-request-cancelled request)
             (progn
               (setf (ellm-kagi-request-phase request) 'done)
               (ellm-kagi--stop-request request))
           (ellm-kagi--persist-session request)
           (ellm-kagi--emit request '(:type operation))
           (ellm-kagi--start-stream request)))))
   (lambda (error)
     (ellm-kagi--finish-plz-error request "submitting message" error))
   request))

(defun ellm-kagi--start-stream (request)
  "Consume Kagi REQUEST's SSE response."
  (let ((provider (ellm-kagi-request-provider request))
        (serial (ellm-kagi-request-serial request))
        process)
    (setf (ellm-kagi-request-phase request) 'streaming
          (ellm-kagi-request-wire-input request) nil
          (ellm-kagi-request-body-started request) nil
          (ellm-kagi-request-sse-input request) nil)
    (cl-labels ((live-p ()
                  (and (= serial (ellm-kagi-request-serial request))
                       (not (ellm-kagi-request-cancelled request))
                       (not (ellm-kagi-request-completed request)))))
      (setq process
            (plz 'get (ellm-kagi--url provider (ellm-kagi-request-stream-url request))
              :headers (ellm-kagi--headers provider "text/event-stream")
              :as 'string
              :then (lambda (_body)
                      (when (live-p)
                        (if (ellm-kagi-request-turn-completed request)
                            (ellm-kagi--finish-success request)
                          (ellm-kagi--finish-error
                           request "stream ended before turn.completed"))))
              :else (lambda (error)
                      (when (live-p)
                        (ellm-kagi--finish-plz-error request "streaming" error)))
              :filter (lambda (transport output)
                        (when (live-p)
                          (ellm-kagi--stream-filter request transport output)))
              ;; Parsed SSE events restart the core's idle deadline.
              :timeout nil
              :noquery t))
      (when (live-p)
        (setf (ellm-kagi-request-process request) process)))))

;;;; SSE parsing

(defun ellm-kagi--insert-process-output (process output)
  "Insert OUTPUT into PROCESS's response buffer for `plz'."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (let ((moving (= (point) (process-mark process))))
        (save-excursion
          (goto-char (process-mark process))
          (insert output)
          (set-marker (process-mark process) (point)))
        (when moving
          (goto-char (process-mark process)))))))

(defun ellm-kagi--stream-filter (request process output)
  "Insert PROCESS OUTPUT and feed complete body bytes into REQUEST's SSE parser."
  (ellm-kagi--insert-process-output process output)
  (unless (or (ellm-kagi-request-cancelled request)
              (ellm-kagi-request-completed request))
    (if (ellm-kagi-request-body-started request)
        (ellm-kagi--consume-sse request output)
      (setf (ellm-kagi-request-wire-input request)
            (concat (ellm-kagi-request-wire-input request) output))
      (let ((input (ellm-kagi-request-wire-input request))
            body)
        (while (and (not body)
                    (string-match "\r?\n\r?\n" input))
          (let* ((end (match-end 0))
                 (header (substring input 0 end)))
            (setq input (substring input end))
            (let ((case-fold-search t))
              (when (string-match-p
                     "\\(?:\\`\\|\n\\)content-type:[ \t]*text/event-stream"
                     header)
                (setq body input)
                (setf (ellm-kagi-request-body-started request) t)))))
        (setf (ellm-kagi-request-wire-input request)
              (unless body input))
        (when body
          (ellm-kagi--consume-sse request body))))))

(defun ellm-kagi--consume-sse (request bytes)
  "Consume complete SSE records from BYTES for REQUEST."
  (let ((input (concat (ellm-kagi-request-sse-input request) bytes)))
    (while (string-match "\r?\n\r?\n" input)
      (let ((record (substring input 0 (match-beginning 0))))
        (setq input (substring input (match-end 0)))
        (ellm-kagi--handle-sse-record
         request (decode-coding-string record 'utf-8 t))))
    (setf (ellm-kagi-request-sse-input request) input)))

(defun ellm-kagi--handle-sse-record (request record)
  "Parse and handle one SSE RECORD for REQUEST."
  (let ((data-lines
         (cl-loop for line in (split-string record "\r?\n")
                  when (string-prefix-p "data:" line)
                  collect (string-remove-prefix " " (substring line 5)))))
    (when data-lines
      (let ((data (string-join data-lines "\n")))
        (if (equal data "[DONE]")
            (unless (or (ellm-kagi-request-cancelled request)
                        (ellm-kagi-request-completed request))
              (if (ellm-kagi-request-turn-completed request)
                  (ellm-kagi--finish-success request)
                (ellm-kagi--finish-error
                 request "stream ended without turn.completed")))
          (condition-case err
              (ellm-kagi--handle-event
               request
               (json-parse-string data
                                  :object-type 'plist
                                  :array-type 'list
                                  :null-object nil
                                  :false-object :json-false))
            (error
             (ellm-kagi--finish-error
              request (format "invalid stream event: %s"
                              (error-message-string err))))))))))

;;;; Rendering and lifecycle

(defun ellm-kagi--last-user-content ()
  "Return the content of the most recent user turn in the current buffer."
  (let ((turn (cl-find "user" (ellm--parse-turns)
                       :key #'ellm-turn-role :test #'equal :from-end t)))
    (and turn (string-trim (ellm-turn-content turn)))))

(defun ellm-kagi--render-nodes (request &optional final)
  "Emit an ordered snapshot of REQUEST's main nodes.
Nested research agents are deliberately omitted.  Tool calls get a short
status instead of interleaved arguments, search results and agent text.
When FINAL is non-nil, retain any unresolved citation markers verbatim."
  (let (channels cited)
    (dolist (entry (ellm-kagi-request-nodes request))
      (let* ((node (cdr entry))
             (kind (plist-get node :kind))
             (type (plist-get node :type))
             (content (plist-get node :content))
             (channel (if (equal kind "text") 'assistant 'reasoning)))
        (when (and (ellm-kagi-request-root-id request)
                   (equal (plist-get node :parent)
                          (ellm-kagi-request-root-id request)))
          (when (equal type "tool_call")
            (let* ((arguments (plist-get node :arguments))
                   (subject (or (plist-get arguments :query)
                                (plist-get arguments :url)
                                (plist-get arguments :source))))
              (setq content
                    (format "%s: %s%s"
                            (or (plist-get node :tool_name) "Research")
                            (or (plist-get node :status) "running")
                            (if subject (concat " — " subject) "")))))
          (when (and (or (equal kind "text")
                         (member type '("thinking" "tool_call")))
                     (stringp content) (not (string-empty-p content)))
            (unless final
              ;; Citation tokens can span deltas; do not flash half a token.
              (setq content (replace-regexp-in-string
                             "\\[\\^[^]]*\\'" "" content)))
            (setq content
                  (replace-regexp-in-string
                   "\\[\\^\\([^]#]+\\)\\(?:#[^]]*\\)?\\]"
                   (lambda (marker)
                     (let* ((id (match-string 1 marker))
                            (reference (alist-get
                                        id (ellm-kagi-request-references request)
                                        nil nil #'equal))
                            (url (plist-get reference :url)))
                       (if (not url) marker
                         (unless (member id cited)
                           (setq cited (append cited (list id))))
                         (format "[%d](%s)"
                                 (1+ (cl-position id cited :test #'equal)) url))))
                   content t t))
            (push (cons channel content) channels)))))
    (ellm-kagi--emit
     request `(:type stream :mode snapshot :id kagi
               :channels ,(nreverse channels)))))

(defun ellm-kagi--handle-node-event (request event)
  "Apply nested protocol EVENT to REQUEST's node state."
  (let* ((type (plist-get event :type))
         (payload (plist-get event :payload))
         (id (plist-get event :node_id)))
    (pcase type
      ("turn.started"
       (setf (ellm-kagi-request-root-id request)
             (plist-get payload :root_node_id)))
      ((or "node.created" "node.updated" "node.delta" "node.completed")
       (when id
         (let ((cell (assoc id (ellm-kagi-request-nodes request))))
           (unless cell
             (setq cell (cons id nil))
             (setf (ellm-kagi-request-nodes request)
                   (append (ellm-kagi-request-nodes request) (list cell))))
           (when-let* ((parent (plist-get event :parent_node_id)))
             (setcdr cell (plist-put (cdr cell) :parent parent)))
           (if (equal type "node.delta")
               (when-let* ((delta (plist-get payload :delta))
                           ((stringp delta)))
                 (setcdr cell (plist-put
                               (cdr cell) :content
                               (concat (plist-get (cdr cell) :content) delta))))
             (cl-loop for (key value) on payload by #'cddr
                      do (setcdr cell (plist-put (cdr cell) key value))))
           (when (equal (plist-get (cdr cell) :parent)
                        (ellm-kagi-request-root-id request))
             (ellm-kagi--render-nodes request)))))
      ("reference.added"
       (when-let* ((ref (plist-get payload :ref_id)))
         (setf (alist-get ref (ellm-kagi-request-references request)
                          nil nil #'equal) payload)))
      ("turn.completed"
       (setf (ellm-kagi-request-turn-completed request) t)
       (ellm-kagi--render-nodes request t)
       (ellm-kagi--update-usage request payload))
      ((or "turn.failed" "node.failed" "turn.error" "turn.cancelled")
       (ellm-kagi--finish-error
        request (format "%s" (or (plist-get payload :error)
                                 (plist-get payload :message)
                                 (plist-get payload :error_code) type)))))))

(defun ellm-kagi--handle-event (request event)
  "Handle one parsed Kagi stream EVENT for REQUEST."
  (unless (or (ellm-kagi-request-cancelled request)
              (ellm-kagi-request-completed request))
    ;; Even ignored research metadata keeps the core idle deadline alive.
    (ellm-kagi--emit request '(:type activity))
    (when-let* ((title (plist-get event :title)))
      (ellm-kagi--emit
       request `(:type extension :kind title :title ,title)))
    (cond
     ((plist-member event :error)
      (ellm-kagi--finish-error
       request (format "%s" (or (plist-get event :error) "stream failed"))))
     ((plist-get event :event)
      (let* ((nested (plist-get event :event))
             (id (plist-get nested :id))
             (seen (ellm-kagi-request-seen-events request)))
        (unless (and id (gethash id seen))
          (when id (puthash id t seen))
          (ellm-kagi--handle-node-event request nested))))
     ((eq (plist-get event :is_final) t)
      ;; This is billing metadata, not a replacement answer or per-turn usage.
      (if (ellm-kagi-request-turn-completed request)
          (ellm-kagi--finish-success request)
        (ellm-kagi--finish-error request "stream ended without turn.completed"))))))

(defun ellm-kagi--update-title-direct (request title)
  "Store TITLE and rename Kagi REQUEST's buffer."
  (when-let* ((buffer (ellm-kagi-request-buffer request)))
    (when (buffer-live-p buffer)
      (ellm-set-session-title title buffer))))

(defun ellm-kagi--update-usage (request event)
  "Emit normalized usage from final Kagi EVENT."
  (let ((context (plist-get event :context_usage))
        (usage (plist-get event :usage)))
    (ellm-kagi--emit
     request
     `(:type usage
       :input-tokens ,(plist-get usage :input_tokens)
       :output-tokens ,(plist-get usage :output_tokens)
       :cached-tokens ,(plist-get usage :cache_read_tokens)
       :context-usage ,(plist-get context :total_used)
       :context-size ,(plist-get context :context_window)
       :cost-amount ,(plist-get usage :cost_usd)
       :cost-currency ,(and (plist-member usage :cost_usd) "USD")))))

(defun ellm-kagi--persist-session (request)
  "Emit Kagi REQUEST's conversation metadata."
  (if (ellm-kagi-request-emit request)
      (ellm-kagi--emit
       request '(:type extension :kind session :checkpoint t))
    (ellm-kagi--persist-session-direct request)))

(defun ellm-kagi--persist-session-direct (request)
  "Persist Kagi REQUEST's conversation and branch IDs in frontmatter."
  (when-let* ((buffer (ellm-kagi-request-buffer request)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ellm--preserve-user-position
          (when-let* ((conversation-id
                       (ellm-kagi-request-conversation-id request)))
            (ellm--set-frontmatter-value
             '(kagi conversation-id) conversation-id))
          (when-let* ((branch-id (ellm-kagi-request-branch-id request)))
            (ellm--set-frontmatter-value '(kagi branch-id) branch-id)))))))

(defun ellm-kagi--finish-success (request)
  "Emit successful completion for Kagi REQUEST."
  (unless (ellm-kagi-request-completed request)
    (ellm-kagi--emit request '(:type complete))
    (setf (ellm-kagi-request-completed request) t)))

(defun ellm-kagi--finish-plz-error (request action error)
  "Finish REQUEST after ACTION failed with a `plz' ERROR."
  (if (ellm-kagi-request-cancelled request)
      (ellm-kagi--stop-request request)
    (ellm-kagi--finish-error
     request
     ;; POSTs are not idempotent: even a timeout may have accepted a message.
     (format "%s: %s" action (ellm-kagi--plz-error-message error)))))

(defun ellm-kagi--plz-error-message (error)
  "Return a concise message for a `plz' ERROR."
  (cond
   ((not (plz-error-p error)) (format "%S" error))
   ((plz-error-response error)
    (let ((response (plz-error-response error)))
      (format "HTTP %s%s"
              (plz-response-status response)
              (if-let* ((body (plz-response-body response))
                        ((not (string-empty-p body))))
                  (concat ": " body)
                ""))))
   ((plz-error-message error) (plz-error-message error))
   ((plz-error-curl-error error)
    (format "%s" (cdr (plz-error-curl-error error))))
   (t "request failed")))

(defun ellm-kagi--finish-error (request message-text)
  "Emit terminal Kagi failure MESSAGE-TEXT."
  (unless (or (ellm-kagi-request-cancelled request)
              (ellm-kagi-request-completed request))
    (ellm-kagi--emit
     request
     `(:type failure :message ,(concat "Kagi: " message-text)
       :retryable nil))
    (setf (ellm-kagi-request-completed request) t)))

;;;; Footer

(provide 'ellm-kagi)
;;; ellm-kagi.el ends here
