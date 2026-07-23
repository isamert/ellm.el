;;; ellm-kagi.el --- Kagi Assistant backend for ellm  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.1
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

;; Backend for the session-based Kagi Assistant web API.  Authentication uses
;; the `kagi_session' cookie from an existing Kagi login.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'plz)
(require 'shr)
(require 'subr-x)
(require 'ellm)

(defgroup ellm-kagi nil
  "Kagi Assistant backend for ellm."
  :group 'ellm)

(defcustom ellm-kagi-models
  '("ki_quick" "kimi-k2-7-code" "kimi-k2-6-thinking" "kimi-k2-6"
    "glm-4-7-thinking" "glm-4-7" "claude-4-8-opus-thinking"
    "qwen-3-7-plus" "qwen-3-coder" "gpt-5-4-nano" "gpt-oss-120b"
    "deepseek-v4-flash" "gemini-3-1-flash-lite" "gemma-4-31b" "grok-4-3"
    "mistral-small-4" "mistral-large" "hermes-4-405b-thinking"
    "minimax-m3")
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
  "Active Kagi request and cumulative stream state."
  provider buffer process conversation-id branch-id stream-url cancel-url
  start end wire-input body-started sse-input completed cancelled cancel-sent
  phase retry-timer)

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
      (when (ellm-kagi-request-p ellm--active-request)
        (ellm-cancel t)))))

(cl-defmethod ellm-backend-send
  ((provider ellm-kagi-provider) frontmatter buffer)
  "Send BUFFER's last user turn through Kagi PROVIDER using FRONTMATTER."
  (unless (buffer-live-p buffer)
    (user-error "Ellm Kagi: buffer is not live"))
  (let ((model (ellm-kagi-provider-model provider)))
    (unless (and (stringp model) (not (string-empty-p model)))
      (user-error "Ellm Kagi: provider model is required")))
  (with-current-buffer buffer
    (let* ((request
            (ellm-kagi--make-request
             :provider provider
             :buffer buffer
             :conversation-id
             (ellm--alist-get-nested frontmatter '(kagi conversation-id))
             :branch-id
             (ellm--alist-get-nested frontmatter '(kagi branch-id))
             :start (copy-marker (point-max) nil)
             :end (copy-marker (point-max) t)))
           (message (ellm-kagi--last-user-content))
           (payload (ellm-kagi--message-payload provider frontmatter message)))
      (if (ellm-kagi-request-branch-id request)
          (ellm-kagi--post-message request payload)
        (ellm-kagi--create-conversation request payload))
      request)))

(cl-defmethod ellm-backend-cancel ((request ellm-kagi-request))
  "Cancel Kagi REQUEST locally and on Kagi when a branch exists."
  (setf (ellm-kagi-request-cancelled request) t)
  (ellm-kagi--stop-request request))

(defun ellm-kagi--stop-request (request)
  "Stop REQUEST's current transport and cancel remote generation once."
  (when-let* ((timer (ellm-kagi-request-retry-timer request)))
    (cancel-timer timer)
    (setf (ellm-kagi-request-retry-timer request) nil))
  (when-let* ((process (ellm-kagi-request-process request)))
    (when (and (processp process) (process-live-p process))
      (delete-process process)))
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

(defun ellm-kagi--transient-error-p (error)
  "Return non-nil when a Kagi request ERROR is safe to retry."
  (and (plz-error-p error)
       (or (plz-error-curl-error error)
           (when-let* ((response (plz-error-response error))
                       (status (plz-response-status response)))
             (or (= status 429) (<= 500 status 599))))))

(defun ellm-kagi--request-json
    (provider method path body then else &optional request)
  "Send a managed JSON request through PROVIDER.
METHOD and PATH identify the endpoint.  BODY is a plist or nil.  THEN and ELSE
are terminal callbacks.  When REQUEST is non-nil, keep its cancellable process
and retry timer current."
  (let ((attempt 0)
        (done nil)
        process)
    (cl-labels
        ((live-p ()
           (and (not done)
                (or (not request)
                    (not (ellm-kagi-request-cancelled request)))))
         (start ()
           (when (live-p)
             (cl-incf attempt)
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
                    (if (and (ellm-kagi--transient-error-p error)
                             (<= attempt ellm-request-retries))
                        (let ((timer
                               (run-at-time ellm-request-retry-delay nil
                                            #'start)))
                          (when request
                            (setf (ellm-kagi-request-retry-timer request)
                                  timer)))
                      (setq done t)
                      (funcall else error))))
                :timeout ellm-request-timeout
                :noquery t))
             (when request
               (setf (ellm-kagi-request-process request) process)))))
      (start))
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
                           (ellm--parse-frontmatter)))
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
    (list :message message
          :thinking_preset (ellm-kagi--setting-string thinking-preset)
          :model_name (ellm-kagi-provider-model provider)
          :enable_search
          (ellm-kagi--json-boolean
           (ellm-kagi--frontmatter-option
            frontmatter '(kagi enable-search)
            (ellm-kagi-provider-enable-search provider)))
          :personalization
          (ellm-kagi--json-boolean
           (ellm-kagi--frontmatter-option
            frontmatter '(kagi personalization)
            (ellm-kagi-provider-personalization provider))))))

(defun ellm-kagi--create-conversation (request payload)
  "Create Kagi REQUEST's conversation, then send PAYLOAD."
  (let ((provider (ellm-kagi-request-provider request)))
    (setf (ellm-kagi-request-phase request) 'creating)
    (ellm-kagi--request-json
     provider 'post "/api/conversations"
     (list :model_name (ellm-kagi-provider-model provider))
     (lambda (result)
       (unless (ellm-kagi-request-cancelled request)
         (let ((conversation-id
                (plist-get (plist-get result :conversation) :uuid))
               (branch-id
                (plist-get (plist-get result :default_branch) :uuid)))
           (if (not branch-id)
               (ellm-kagi--finish-error
                request "create response did not include a branch id")
             (setf (ellm-kagi-request-conversation-id request)
                   conversation-id
                   (ellm-kagi-request-branch-id request) branch-id)
             (ellm-kagi--persist-session request)
             (ellm-kagi--post-message request payload)))))
     (lambda (error)
       (ellm-kagi--finish-plz-error request "creating conversation" error))
     request)))

(defun ellm-kagi--post-message (request payload)
  "Post PAYLOAD to Kagi REQUEST's branch, then begin its stream."
  (let* ((provider (ellm-kagi-request-provider request))
         (branch-id (ellm-kagi-request-branch-id request))
         (path (format "/api/branches/%s/messages" branch-id)))
    ;; Establish this before POSTing so cancellation still reaches Kagi when
    ;; the server accepts the message but the client cancels before its reply.
    (setf (ellm-kagi-request-phase request) 'posting
          (ellm-kagi-request-cancel-url request)
          (format "/api/branches/%s/stream/cancel" branch-id))
    (ellm-kagi--request-json
     provider 'post path payload
     (lambda (result)
       (unless (ellm-kagi-request-cancelled request)
         (let ((conversation-id
                (plist-get (plist-get result :conversation) :uuid))
               (response-branch-id
                (plist-get (plist-get result :branch) :uuid)))
           (when conversation-id
             (setf (ellm-kagi-request-conversation-id request)
                   conversation-id))
           (when response-branch-id
             (setf (ellm-kagi-request-branch-id request)
                   response-branch-id))
           (setf (ellm-kagi-request-stream-url request)
                 (or (plist-get result :stream_url)
                     (format "/api/branches/%s/stream"
                             (ellm-kagi-request-branch-id request)))
                 (ellm-kagi-request-cancel-url request)
                 (or (plist-get result :stream_cancel_url)
                     (format "/api/branches/%s/stream/cancel"
                             (ellm-kagi-request-branch-id request))))
           (ellm-kagi--persist-session request)
           (ellm-kagi--start-stream request))))
     (lambda (error)
       (ellm-kagi--finish-plz-error request "posting message" error))
     request)))

(defun ellm-kagi--start-stream (request)
  "Consume Kagi REQUEST's SSE response."
  (let* ((provider (ellm-kagi-request-provider request))
         (path (concat (ellm-kagi-request-stream-url request) "?cursor=0-0")))
    (setf (ellm-kagi-request-phase request) 'streaming
          (ellm-kagi-request-wire-input request) nil
          (ellm-kagi-request-body-started request) nil
          (ellm-kagi-request-sse-input request) nil
          (ellm-kagi-request-process request)
          (plz 'get (ellm-kagi--url provider path)
            :headers (ellm-kagi--headers provider "text/event-stream")
            :as 'string
            :then (lambda (_body)
                    (unless (or (ellm-kagi-request-cancelled request)
                                (ellm-kagi-request-completed request))
                      (ellm-kagi--finish-error
                       request "stream ended before its final event")))
            :else (lambda (error)
                    (ellm-kagi--finish-plz-error request "streaming" error))
            :filter (lambda (process output)
                      (ellm-kagi--stream-filter request process output))
            :timeout ellm-request-timeout
            :noquery t))))

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
              (ellm-kagi--finish-error
               request "stream ended without a final event"))
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

(defun ellm-kagi--html-to-text (html)
  "Render HTML as unpropertized plain text."
  (if (string-empty-p (string-trim html))
      ""
    (with-temp-buffer
      (insert html)
      (let ((shr-use-colors nil)
            (shr-use-fonts nil)
            (shr-width 10000))
        (shr-render-region (point-min) (point-max)))
      (string-trim (buffer-substring-no-properties (point-min) (point-max))))))

(defun ellm-kagi--split-partial-html (html)
  "Return (REASONING . TEXT) from cumulative Kagi HTML."
  (let ((position 0)
        reasoning-start reasoning-end details-end)
    (while (string-match "<details><summary>Thinking</summary>" html position)
      (let ((start (match-end 0)))
        (if (string-match "</details>" html start)
            (setq reasoning-start start
                  reasoning-end (match-beginning 0)
                  details-end (match-end 0)
                  position (match-end 0))
          (setq position (length html)))))
    (if reasoning-start
        (let* ((tail (string-trim-left (substring html details-end)))
               (text (unless (string-prefix-p "<details" tail)
                       (ellm-kagi--html-to-text tail))))
          (cons (ellm-kagi--html-to-text
                 (substring html reasoning-start reasoning-end))
                text))
      (cons nil (ellm-kagi--html-to-text html)))))

(defun ellm-kagi--split-final-text (text)
  "Return (REASONING . TEXT) from Kagi's canonical final TEXT."
  (let ((prefix "<details><summary>Thinking</summary>"))
    (if (and (string-prefix-p prefix text)
             (string-match "</details>" text (length prefix)))
        (let ((details-beg (match-beginning 0))
              (details-end (match-end 0)))
          (cons (string-trim
                 (substring text (length prefix) details-beg))
                (string-trim (substring text details-end))))
      (cons nil text))))

(defun ellm-kagi--append-references (content references)
  "Append Kagi REFERENCES as Markdown sources to CONTENT's answer."
  (if (not references)
      content
    (let ((sources
           (cl-loop for reference in references
                    for position from 1
                    for index = (or (plist-get reference :index) position)
                    for url = (or (plist-get reference :url)
                                  (plist-get reference :source))
                    for title = (or (plist-get reference :title)
                                    (plist-get reference :domain)
                                    url)
                    when url
                    collect (format "%s. [%s](%s)"
                                    index
                                    (replace-regexp-in-string "]" "\\]" title)
                                    url))))
      (when sources
        (setcdr content
                (concat (cdr content) "\n\n### Sources\n"
                        (string-join sources "\n"))))
      content)))

(defun ellm-kagi--snapshot-string (content)
  "Return ellm continuation text for Kagi CONTENT.
CONTENT is a (REASONING . TEXT) pair."
  (let ((reasoning (car content))
        (text (cdr content)))
    (concat
     (when (and reasoning (not (string-empty-p reasoning)))
       (concat (ellm--get-turn "reasoning" :continuation t) "\n"
               (ellm--ensure-newline
                (ellm--escape-turn-delimiters reasoning))))
     (when (and text (not (string-empty-p text)))
       (concat (ellm--get-turn "assistant" :continuation t) "\n"
               (ellm--ensure-newline
                (ellm--escape-turn-delimiters text)))))))

(defun ellm-kagi--render-snapshot (request content)
  "Replace Kagi REQUEST's rendered region with cumulative CONTENT."
  (when-let* ((buffer (ellm-kagi-request-buffer request)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ellm--preserve-user-position
          (let* ((start (ellm-kagi-request-start request))
                 (end (ellm-kagi-request-end request))
                 (new-text (ellm-kagi--snapshot-string content))
                 (current-text (buffer-substring-no-properties start end))
                 (prefix-length
                  (length (fill-common-string-prefix current-text new-text))))
            (goto-char (+ start prefix-length))
            (delete-region (point) end)
            (insert (substring new-text prefix-length))
            (when (and ellm-fold-reasoning-blocks
                       (car content)
                       (cdr content)
                       (not (string-empty-p (cdr content))))
              (ellm-kagi--fold-reasoning request))))))))

(defun ellm-kagi--fold-reasoning (request)
  "Fold the reasoning turn rendered for REQUEST when it has a boundary."
  (save-excursion
    (goto-char (ellm-kagi-request-start request))
    (when (re-search-forward
           (concat "^" (ellm--turn-header-prefix-regexp ellm-turn-header-2)
                   "reasoning\\b")
           (ellm-kagi-request-end request) t)
      (ellm--fold-subtree-at (match-beginning 0)))))

(defun ellm-kagi--handle-event (request event)
  "Handle one parsed Kagi stream EVENT for REQUEST."
  (unless (or (ellm-kagi-request-cancelled request)
              (ellm-kagi-request-completed request))
    (when-let* ((title (plist-get event :conversation_title)))
      (ellm-kagi--update-title request title))
    (cond
     ((plist-member event :error)
      (ellm-kagi--finish-error
       request (format "%s" (or (plist-get event :error) "stream failed"))))
     ((eq (plist-get event :is_final) t)
      (ellm-kagi--render-snapshot
       request
       (ellm-kagi--append-references
        (ellm-kagi--split-final-text (or (plist-get event :text) ""))
        (plist-get event :references)))
      (ellm-kagi--update-usage request event)
      (ellm-kagi--finish-success request))
     ((plist-get event :html_content)
      (ellm-kagi--render-snapshot
       request (ellm-kagi--split-partial-html
                (plist-get event :html_content)))))))

(defun ellm-kagi--update-title (request title)
  "Store TITLE and rename Kagi REQUEST's buffer."
  (when-let* ((buffer (ellm-kagi-request-buffer request)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ellm--preserve-user-position
          (ellm--set-frontmatter-value '(kagi title) title))
        (ellm-update-session-title title buffer)))))

(defun ellm-kagi--update-usage (request event)
  "Update REQUEST's buffer status from final Kagi EVENT."
  (when-let* ((buffer (ellm-kagi-request-buffer request)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((context (plist-get event :context_usage))
              (usage (plist-get event :usage)))
          (setf (ellm-buffer-state-context-usage ellm-buffer-state)
                (plist-get context :total_used)
                (ellm-buffer-state-context-size ellm-buffer-state)
                (plist-get context :context_window)
                (ellm-buffer-state-cost-amount ellm-buffer-state)
                (plist-get usage :cost_usd)
                (ellm-buffer-state-cost-currency ellm-buffer-state)
                (and (plist-member usage :cost_usd) "USD"))
          (force-mode-line-update))))))

(defun ellm-kagi--persist-session (request)
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
  "Finish Kagi REQUEST and append the next user turn."
  (unless (ellm-kagi-request-completed request)
    (setf (ellm-kagi-request-completed request) t
          (ellm-kagi-request-phase request) 'done)
    (when-let* ((buffer (ellm-kagi-request-buffer request)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (ellm--preserve-user-position
            (ellm--set-active-request nil)
            (goto-char (point-max))
            (ellm--insert-turn "user")
            (ellm--persistence-checkpoint)
            (ellm--notify-request-finished)))))))

(defun ellm-kagi--finish-plz-error (request action error)
  "Finish REQUEST after ACTION failed with a `plz' ERROR."
  (if (ellm-kagi-request-cancelled request)
      (ellm-kagi--stop-request request)
    (ellm-kagi--finish-error
     request
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
  "Finish Kagi REQUEST with MESSAGE-TEXT."
  (unless (or (ellm-kagi-request-cancelled request)
              (ellm-kagi-request-completed request))
    (setf (ellm-kagi-request-completed request) t)
    (ellm-kagi--stop-request request)
    (setf (ellm-kagi-request-phase request) 'done)
    (when-let* ((buffer (ellm-kagi-request-buffer request)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (ellm--set-active-request nil)
          (ellm--ensure-next-user-turn)
          (ellm--persistence-checkpoint)
          (ellm--notify-request-finished))))
    (message "ellm Kagi: %s" message-text)))

;;;; Footer

(provide 'ellm-kagi)
;;; ellm-kagi.el ends here
