;;; ellm-acp.el --- ACP backend for ellm  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: llm, acp

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

;; Minimal Agent Client Protocol backend.  This uses `jsonrpc.el' for
;; JSON-RPC request/response dispatch, but intentionally does not use
;; `jsonrpc-process-connection': ACP stdio messages are newline-delimited
;; JSON, while `jsonrpc-process-connection' uses LSP-style Content-Length
;; framing.

;;; Code:

(require 'cl-lib)
(require 'eieio)
(require 'json)
(require 'jsonrpc)
(require 'subr-x)
(require 'ellm)

(defgroup ellm-acp nil
  "ACP backend for ellm."
  :group 'ellm)

(defcustom ellm-acp-permission-function #'ellm-acp-ask-permission
  "Function used to answer ACP `session/request_permission' requests.
It is called with two arguments: TOOL-CALL and OPTIONS from the ACP
request.  It must return the selected option id, or nil to cancel."
  :type 'function
  :group 'ellm-acp)

(defcustom ellm-acp-log-messages nil
  "If non-nil, log raw ACP JSON-RPC messages to `ellm-acp-log-buffer-name'."
  :type 'boolean
  :group 'ellm-acp)

(defcustom ellm-acp-log-buffer-name "*ellm-acp-log*"
  "Base buffer name used when `ellm-acp-log-messages' is non-nil.
Each ACP connection gets its own log buffer derived from this name."
  :type 'string
  :group 'ellm-acp)

(cl-defstruct (ellm-acp-provider (:constructor ellm-make-acp-provider))
  "Provider configuration for an ACP agent process.
COMMAND is the executable used to start the ACP agent.  ARGS is a list of
command-line arguments.  ENV is an alist of environment overrides.  CWD,
when non-nil, is the session working directory; otherwise `default-directory'
is used.  MODEL is the default model written to new buffers and, when the
ACP agent exposes a model config option, selected for the session.  MODELS is
an optional list of model candidates used for frontmatter completion."
  command args env cwd model models)

(defclass ellm-acp-connection (jsonrpc-connection)
  ((process
    :initarg :process
    :accessor ellm-acp--connection-process)
   (buffer
    :initarg :buffer
    :accessor ellm-acp--connection-buffer)
   (input
    :initform ""
    :accessor ellm-acp--connection-input)
    (session-id
     :initform nil
     :accessor ellm-acp--connection-session-id)
    (prompt-request-id
     :initform nil
     :accessor ellm-acp--connection-prompt-request-id)
    (initialized
     :initform nil
     :accessor ellm-acp--connection-initialized)
    (agent-capabilities
     :initform nil
     :accessor ellm-acp--connection-agent-capabilities)
    (available-commands
     :initform nil
     :accessor ellm-acp--connection-available-commands)
    (model-candidates
     :initform nil
     :accessor ellm-acp--connection-model-candidates)
    (model-config-id
     :initform nil
     :accessor ellm-acp--connection-model-config-id)
    (current-model
     :initform nil
     :accessor ellm-acp--connection-current-model)
   (log-buffer
    :initform nil
    :accessor ellm-acp--connection-log-buffer))
  "ACP JSON-RPC connection using newline-delimited stdio.")

(cl-defstruct (ellm-acp-request (:constructor ellm-acp--make-request))
  "Active request handle for the ACP backend."
  connection cancelled)

(defvar-local ellm-acp--connection nil
  "ACP connection associated with the current ellm buffer.")

;;;; Interface implementation

(cl-defmethod ellm-provider-current-model ((provider ellm-acp-provider))
  "Return ACP PROVIDER's configured default model."
  (ellm-acp-provider-model provider))

(cl-defmethod ellm-provider-model-candidates ((provider ellm-acp-provider))
  "Return ACP PROVIDER's configured model candidates."
  (or (ellm-acp-provider-models provider)
      (and (ellm-acp-provider-model provider)
           (list (ellm-acp-provider-model provider)))))

(cl-defmethod ellm-provider-buffer-model-candidates ((provider ellm-acp-provider) buffer)
  "Return ACP model candidates from BUFFER's live session, or PROVIDER config."
  (or (and (buffer-live-p buffer)
           (with-current-buffer buffer
             (and ellm-acp--connection
                  (jsonrpc-running-p ellm-acp--connection)
                  (ellm-acp--connection-model-candidates ellm-acp--connection))))
      (ellm-provider-model-candidates provider)))

(cl-defmethod ellm-provider-with-model ((provider ellm-acp-provider) model)
  "Return a copy of ACP PROVIDER using MODEL as its default model."
  (let ((copy (copy-sequence provider)))
    (setf (ellm-acp-provider-model copy) model)
    copy))

(cl-defmethod ellm-provider-slash-command-candidates ((_provider ellm-acp-provider) buffer)
  "Return slash command candidates advertised by BUFFER's ACP session."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and ellm-acp--connection
                 (jsonrpc-running-p ellm-acp--connection))
        (mapcar #'ellm-acp--slash-command-candidate
                (ellm-acp--connection-available-commands ellm-acp--connection))))))

(cl-defmethod ellm-provider-load-session ((provider ellm-acp-provider) frontmatter)
  "Select and load an ACP session for PROVIDER."
  (ellm-acp-load-session provider frontmatter))

(cl-defmethod ellm-backend-send ((provider ellm-acp-provider) frontmatter buffer)
  "Send BUFFER's trailing user turn through ACP PROVIDER."
  (with-current-buffer buffer
    (let* ((connection (ellm-acp--ensure-connection provider buffer))
           (request (ellm-acp--make-request :connection connection)))
      (ellm-acp--ensure-session
       connection provider frontmatter
       (lambda ()
          (ellm-acp--ensure-frontmatter-model
           connection frontmatter
           (lambda ()
             (ellm-acp--send-prompt connection buffer))
           (lambda (error-object)
             (ellm-acp--finish-with-error buffer error-object))))
       (lambda (error-object)
         (ellm-acp--finish-with-error buffer error-object)))
      request)))

(cl-defmethod ellm-backend-cancel ((request ellm-acp-request))
  "Cancel ACP REQUEST."
  (setf (ellm-acp-request-cancelled request) t)
  (let* ((connection (ellm-acp-request-connection request))
         (session-id (ellm-acp--connection-session-id connection)))
    (when session-id
      (jsonrpc-notify connection :session/cancel `(:sessionId ,session-id)))))

;;;; JSON-RPC newline transport

(cl-defmethod jsonrpc-connection-send ((connection ellm-acp-connection)
                                       &rest args
                                       &key id method _params
                                       (_result nil result-supplied-p)
                                       error
                                       &allow-other-keys)
  "Send ARGS to ACP CONNECTION as one newline-delimited JSON-RPC message."
  (when (and id method
             (equal (ellm-acp--method-name method) "session/prompt"))
    (setf (ellm-acp--connection-prompt-request-id connection) id))
  (when method
    (setq args (plist-put args :method (ellm-acp--method-name method))))
  (let* ((kind (cond ((or result-supplied-p error) 'reply)
                     (id 'request)
                     (method 'notification)))
         (message (jsonrpc-convert-to-endpoint connection args kind))
         (json (json-serialize message
                               :false-object :json-false
                               :null-object nil)))
    (ellm-acp--log-wire connection "-->" json)
    (process-send-string (ellm-acp--connection-process connection)
                         (concat json "\n"))))

(cl-defmethod jsonrpc-running-p ((connection ellm-acp-connection))
  "Return non-nil if ACP CONNECTION's process is live."
  (process-live-p (ellm-acp--connection-process connection)))

(cl-defmethod jsonrpc-shutdown ((connection ellm-acp-connection))
  "Shut down ACP CONNECTION."
  (when (process-live-p (ellm-acp--connection-process connection))
    (delete-process (ellm-acp--connection-process connection))))

(defun ellm-acp--method-name (method)
  "Return wire method name for METHOD."
  (cond
   ((keywordp method) (substring (symbol-name method) 1))
   ((symbolp method) (symbol-name method))
   ((stringp method) method)
   (t (error "ellm ACP: invalid method %S" method))))

(defun ellm-acp--ensure-connection (provider buffer)
  "Return a live ACP connection for PROVIDER and BUFFER."
  (if (and ellm-acp--connection
           (jsonrpc-running-p ellm-acp--connection))
      ellm-acp--connection
    (let* ((command (or (ellm-acp-provider-command provider)
                        (user-error "ellm ACP: provider command is required")))
           (args (ellm-acp-provider-args provider))
           (process-environment
            (append (mapcar (lambda (cell)
                              (format "%s=%s" (car cell) (cdr cell)))
                            (ellm-acp-provider-env provider))
                    process-environment))
           (process (make-process
                     :name (format "ellm-acp-%s" command)
                     :buffer nil
                     :command (cons command args)
                     :coding 'utf-8
                     :connection-type 'pipe
                     :noquery t))
           (connection (ellm-acp-connection
                        :name (format "ellm-acp-%s" command)
                        :process process
                        :buffer buffer
                        :request-dispatcher #'ellm-acp--dispatch-request
                        :notification-dispatcher #'ellm-acp--dispatch-notification)))
      (process-put process 'ellm-acp-connection connection)
      (set-process-filter process #'ellm-acp--process-filter)
      (set-process-sentinel process #'ellm-acp--process-sentinel)
      (setq ellm-acp--connection connection))))

(defun ellm-acp--process-filter (process string)
  "Handle ACP PROCESS output STRING."
  (when-let* ((connection (process-get process 'ellm-acp-connection)))
    (setf (ellm-acp--connection-input connection)
          (concat (ellm-acp--connection-input connection) string))
    (let ((input (ellm-acp--connection-input connection))
          line)
      (while (string-match "\n" input)
        (setq line (substring input 0 (match-beginning 0))
              input (substring input (match-end 0)))
        (unless (string-empty-p line)
          (ellm-acp--log-wire connection "<--" line)
          (condition-case err
              (let ((message (json-parse-string line
                                                 :object-type 'plist
                                                 :array-type 'list
                                                 :null-object nil
                                                 :false-object :json-false)))
                (setq message (plist-put message :jsonrpc-json line))
                (ellm-acp--maybe-finish-prompt-reply connection message)
                (jsonrpc-connection-receive connection message))
            (error
             (message "ellm ACP: failed to handle message: %S" err)))))
      (setf (ellm-acp--connection-input connection) input))))

(defun ellm-acp--maybe-finish-prompt-reply (connection message)
  "Finish prompt if MESSAGE is the final reply for CONNECTION's prompt."
  (let ((prompt-id (ellm-acp--connection-prompt-request-id connection)))
    (when (and prompt-id
               (equal (plist-get message :id) prompt-id)
               (plist-get (plist-get message :result) :stopReason))
      (setf (ellm-acp--connection-prompt-request-id connection) nil)
      (when-let* ((buffer (ellm-acp--connection-buffer connection)))
        (ellm-acp--finish-prompt buffer)))))

(defun ellm-acp--log-wire (connection direction line)
  "Log raw ACP JSON LINE for CONNECTION with DIRECTION when enabled."
  (when ellm-acp-log-messages
    (with-current-buffer (ellm-acp--log-buffer connection)
      (goto-char (point-max))
      (insert (format "%s %s\n" direction line)))))

(defun ellm-acp--log-buffer (connection)
  "Return CONNECTION's wire log buffer, creating it if needed."
  (or (and (buffer-live-p (ellm-acp--connection-log-buffer connection))
           (ellm-acp--connection-log-buffer connection))
      (let* ((source-buffer (ellm-acp--connection-buffer connection))
             (source-name (if (buffer-live-p source-buffer)
                              (buffer-name source-buffer)
                            "dead-buffer"))
             (buffer (generate-new-buffer
                      (format "%s<%s>" ellm-acp-log-buffer-name source-name))))
        (setf (ellm-acp--connection-log-buffer connection) buffer)
        buffer)))

(defun ellm-acp--process-sentinel (process event)
  "Handle ACP PROCESS EVENT."
  (unless (process-live-p process)
    (when-let* ((connection (process-get process 'ellm-acp-connection))
                (buffer (ellm-acp--connection-buffer connection)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when ellm--active-request
            (setq ellm--active-request nil)
            (message "ellm ACP: process exited: %s" (string-trim event))))))))

(defun ellm-acp--dispatch-notification (connection method params)
  "Dispatch ACP notification METHOD with PARAMS for CONNECTION."
  (pcase method
    ('session/update
     (ellm-acp--handle-session-update connection params))
    (_ nil)))

(defun ellm-acp--request-sync (connection method params)
  "Send METHOD with PARAMS over CONNECTION and synchronously return result."
  (let ((done nil)
        result error-object)
    (jsonrpc-async-request
     connection method params
     :success-fn (lambda (value)
                   (setq result value
                         done t))
     :error-fn (lambda (err)
                 (setq error-object err
                       done t)))
    (while (and (not done) (jsonrpc-running-p connection))
      (accept-process-output (ellm-acp--connection-process connection) 0.05))
    (cond
     (error-object
      (user-error "ellm ACP: %s"
                  (or (plist-get error-object :message) "request failed")))
     (done result)
     (t (user-error "ellm ACP: connection closed")))))

(defun ellm-acp--initialize-sync (connection)
  "Initialize CONNECTION synchronously when needed."
  (unless (ellm-acp--connection-initialized connection)
    (let ((result (ellm-acp--request-sync
                   connection :initialize
                   '(:protocolVersion 1
                     :clientCapabilities (:fs (:readTextFile :json-false
                                          :writeTextFile :json-false)
                                          :terminal :json-false)
                     :clientInfo (:name "ellm" :title "ellm" :version "0.0.1")))))
      (setf (ellm-acp--connection-agent-capabilities connection)
            (plist-get result :agentCapabilities))
      (setf (ellm-acp--connection-initialized connection) t)
      result)))

(defun ellm-acp--capability (connection path)
  "Return ACP capability at PATH for CONNECTION."
  (let ((value (ellm-acp--connection-agent-capabilities connection))
        present)
    (while (and path (listp value))
      (let ((key (if (keywordp (car path))
                     (car path)
                   (intern (format ":%s" (car path))))))
        (setq present (plist-member value key)
              value (plist-get value key)
              path (cdr path))))
    present))

(defun ellm-acp--provider-cwd (provider frontmatter)
  "Return absolute ACP cwd for PROVIDER and FRONTMATTER."
  (expand-file-name
   (file-name-as-directory
    (or (ellm-acp-provider-cwd provider)
        (alist-get 'cwd frontmatter)
        default-directory))))

(defun ellm-acp--provider-name (provider)
  "Return frontmatter provider name for ACP PROVIDER, or nil."
  (catch 'name
    (dolist (entry ellm-provider-alist)
      (when (eq provider (ellm--provider-entry-provider (cdr entry)))
        (throw 'name (symbol-name (car entry)))))))

(defun ellm-acp--dispatch-request (_connection method params)
  "Dispatch ACP request METHOD with PARAMS for CONNECTION."
  (pcase method
    ('session/request_permission
     (ellm-acp--handle-permission-request params))
    (_
     (jsonrpc-error :code -32601
                    :message (format "Unsupported ACP client method: %s"
                                     method)))))

;;;; Session lifecycle

(defun ellm-acp--ensure-session (connection provider frontmatter on-ready on-error)
  "Ensure CONNECTION is initialized and has a session, then call ON-READY."
  (cond
   ((ellm-acp--connection-session-id connection)
    (funcall on-ready))
   ((ellm-acp--connection-initialized connection)
    (if-let* ((session-id (let-alist frontmatter .acp.session-id)))
        (progn
          (setf (ellm-acp--connection-session-id connection) session-id)
          (funcall on-ready))
      (ellm-acp--new-session connection provider frontmatter on-ready on-error)))
   (t
    (ellm-acp--initialize
     connection
     (lambda (_result)
       (setf (ellm-acp--connection-initialized connection) t)
       (ellm-acp--ensure-session
        connection provider frontmatter on-ready on-error))
     on-error))))

(defun ellm-acp--initialize (connection on-result on-error)
  "Initialize ACP CONNECTION."
  (jsonrpc-async-request
   connection :initialize
   '(:protocolVersion 1
     :clientCapabilities (:fs (:readTextFile :json-false
                          :writeTextFile :json-false)
                          :terminal :json-false)
     :clientInfo (:name "ellm" :title "ellm" :version "0.0.1"))
   :success-fn (lambda (result)
                 (setf (ellm-acp--connection-agent-capabilities connection)
                       (plist-get result :agentCapabilities))
                 (funcall on-result result))
   :error-fn on-error))

(defun ellm-acp--new-session (connection provider frontmatter on-ready on-error)
  "Create a new ACP session for CONNECTION."
  (let ((cwd (ellm-acp--provider-cwd provider frontmatter)))
    (jsonrpc-async-request
     connection :session/new
     `(:cwd ,cwd :mcpServers [])
      :success-fn
      (lambda (result)
        (let ((session-id (plist-get result :sessionId)))
          (setf (ellm-acp--connection-session-id connection) session-id)
         (when session-id
            (ellm-acp--persist-session-id connection session-id)))
        (ellm-acp--update-model-candidates
         connection (plist-get result :configOptions))
        (ellm-acp--maybe-set-model
         connection
         (or (alist-get 'model frontmatter)
             (ellm-acp-provider-model provider))
         on-ready
         on-error))
      :error-fn on-error)))

(defun ellm-acp--persist-session-id (connection session-id)
  "Persist ACP SESSION-ID in CONNECTION's conversation frontmatter."
  (when-let* ((buffer (ellm-acp--connection-buffer connection)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ellm--set-frontmatter-value '(acp session-id) session-id)))))

(defun ellm-acp--ensure-frontmatter-model (connection frontmatter on-ready on-error)
  "Apply FRONTMATTER `model:' to CONNECTION before calling ON-READY."
  (ellm-acp--maybe-set-model
   connection (alist-get 'model frontmatter) on-ready on-error))

(defun ellm-acp--maybe-set-model (connection model on-ready on-error)
  "Set ACP session MODEL when it differs, then call ON-READY."
  (let ((config-id (ellm-acp--connection-model-config-id connection))
        (current (ellm-acp--connection-current-model connection)))
    (cond
     ((or (not model) (equal model current))
      (funcall on-ready))
     ((not config-id)
      ;; ACP agents conventionally use `model' as the model config id.  If a
      ;; resumed session has not returned configOptions yet, this still lets a
      ;; changed frontmatter model take effect before the prompt.
      (setq config-id "model")
      (ellm-acp--set-model connection config-id model on-ready on-error))
     (t
      (ellm-acp--set-model connection config-id model on-ready on-error)))))

(defun ellm-acp--set-model (connection config-id model on-ready on-error)
  "Set ACP session MODEL using CONFIG-ID, then call ON-READY."
  (jsonrpc-async-request
   connection :session/set_config_option
   `(:sessionId ,(ellm-acp--connection-session-id connection)
     :configId ,config-id
     :value ,model)
   :success-fn (lambda (result)
                 (setf (ellm-acp--connection-current-model connection) model)
                 (ellm-acp--persist-current-model connection)
                 (ellm-acp--update-model-candidates
                  connection (plist-get result :configOptions))
                 (funcall on-ready))
   :error-fn on-error))

(defun ellm-acp--model-config-option (config-options)
  "Return model-like ACP config option from CONFIG-OPTIONS."
  (cl-find-if
   (lambda (option)
     (or (equal (plist-get option :category) "model")
          (equal (plist-get option :id) "model")))
    config-options))

(defun ellm-acp--update-model-candidates (connection config-options)
  "Store model candidates from ACP CONFIG-OPTIONS on CONNECTION."
  (when-let* ((option (ellm-acp--model-config-option config-options)))
    (setf (ellm-acp--connection-model-config-id connection)
          (plist-get option :id))
    (setf (ellm-acp--connection-current-model connection)
          (plist-get option :currentValue))
    (ellm-acp--persist-current-model connection)
    (setf (ellm-acp--connection-model-candidates connection)
          (mapcar #'ellm-acp--model-candidate
                  (plist-get option :options)))))

(defun ellm-acp--persist-current-model (connection)
  "Persist CONNECTION's current ACP model in its buffer frontmatter."
  (when-let* ((model (ellm-acp--connection-current-model connection))
              (buffer (ellm-acp--connection-buffer connection)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ellm--set-frontmatter-value 'model model)))))

(defun ellm-acp--model-candidate (option)
  "Return a completion candidate for ACP model OPTION."
  (let ((value (plist-get option :value))
        (name (plist-get option :name))
        (desc (plist-get option :description)))
    (append (list value)
            (append (when name (list :ann name))
                    (when desc (list :desc desc))))))

(defun ellm-acp--send-prompt (connection buffer)
  "Send BUFFER's last user turn through CONNECTION."
  (let* ((text (with-current-buffer buffer
                 (ellm-acp--last-user-content)))
         (params `(:sessionId ,(ellm-acp--connection-session-id connection)
                   :prompt [(:type "text" :text ,(or text ""))])))
    (jsonrpc-async-request
     connection :session/prompt params
     :success-fn (lambda (_result)
                   (ellm-acp--finish-prompt buffer))
     :error-fn (lambda (error-object)
                 (ellm-acp--finish-with-error buffer error-object)))))

(defun ellm-acp--last-user-content ()
  "Return the content of the most recent user turn in the current buffer."
  (when-let* ((turn (cl-find-if (lambda (turn)
                                  (equal (ellm-turn-role turn) "user"))
                                 (reverse (ellm--parse-turns)))))
    (ellm-turn-content turn)))

;;;; Session listing/loading

(defun ellm-acp--list-sessions (connection provider frontmatter)
  "Return all ACP sessions for CONNECTION, PROVIDER, and FRONTMATTER."
  (ellm-acp--initialize-sync connection)
  (unless (ellm-acp--capability connection '(sessionCapabilities list))
    (user-error "ellm ACP: agent does not support session/list"))
  (let ((cursor nil)
        sessions done)
    (while (not done)
      (let* ((params (append (list :cwd (ellm-acp--provider-cwd provider frontmatter))
                             (when cursor (list :cursor cursor))))
             (result (ellm-acp--request-sync connection :session/list params)))
        (setq sessions (append sessions (plist-get result :sessions))
              cursor (plist-get result :nextCursor)
              done (not cursor))))
    sessions))

(defun ellm-acp--session-label (session)
  "Return a completing-read label for ACP SESSION."
  (let ((title (plist-get session :title))
        (updated (plist-get session :updatedAt))
        (cwd (plist-get session :cwd))
        (id (plist-get session :sessionId)))
    (string-join (delq nil (list (or title id) updated cwd id)) "  ")))

(defun ellm-acp--session-choice (sessions)
  "Read and return one session from SESSIONS."
  (unless sessions
    (user-error "ellm ACP: no sessions found"))
  (let* ((choices (mapcar (lambda (session)
                            (cons (ellm-acp--session-label session) session))
                          sessions))
         (choice (completing-read "ACP session: " choices nil t)))
    (cdr (assoc choice choices))))

(defun ellm-acp-load-session (provider frontmatter)
  "Interactively load an ACP session for PROVIDER using FRONTMATTER context."
  (let* ((list-buffer (generate-new-buffer " *ellm-acp-list*"))
         (list-connection nil))
    (unwind-protect
        (progn
          (with-current-buffer list-buffer
            (setq list-connection (ellm-acp--ensure-connection provider list-buffer)))
          (let* ((sessions (ellm-acp--list-sessions list-connection provider frontmatter))
                 (session (ellm-acp--session-choice sessions)))
            (unless session
              (user-error "ellm ACP: no session selected"))
            (ellm-acp--load-session-into-new-buffer provider frontmatter session)))
      (when (and list-connection (jsonrpc-running-p list-connection))
        (jsonrpc-shutdown list-connection))
      (when (buffer-live-p list-buffer)
        (kill-buffer list-buffer)))))

(defun ellm-acp--load-session-into-new-buffer (provider frontmatter session)
  "Load ACP SESSION for PROVIDER into a new ellm buffer."
  (let* ((session-id (plist-get session :sessionId))
         (cwd (or (plist-get session :cwd)
                  (ellm-acp--provider-cwd provider frontmatter)))
         (buf (generate-new-buffer (format "*ellm:%s*"
                                           (or (plist-get session :title)
                                               session-id))))
         connection)
    (with-current-buffer buf
      (insert (format "---\nprovider: %s\nmodel: %s\ncwd: %s\nacp:\n  session-id: %s\n---\n\n"
                      (or (alist-get 'provider frontmatter)
                          (ellm-acp--provider-name provider)
                          "null")
                      (or (ellm-acp-provider-model provider) "null")
                      cwd session-id))
      (ellm-mode)
      (setq connection (ellm-acp--ensure-connection provider buf))
      (ellm-acp--initialize-sync connection)
      (unless (ellm-acp--capability connection '(loadSession))
        (user-error "ellm ACP: agent does not support session/load"))
      (setf (ellm-acp--connection-session-id connection) session-id)
      (ellm-acp--update-model-candidates
       connection
       (plist-get
        (ellm-acp--request-sync
         connection :session/load
         `(:sessionId ,session-id
           :cwd ,cwd
           :mcpServers []
           :additionalDirectories ,(or (plist-get session :additionalDirectories) [])))
        :configOptions))
      (goto-char (point-max))
      (unless (and (ellm--parse-turns)
                   (equal (ellm-turn-role (car (last (ellm--parse-turns)))) "user"))
        (ellm--insert-turn "user")))
    (switch-to-buffer buf)
    buf))

;;;; Rendering

(defun ellm-acp--handle-session-update (connection params)
  "Render ACP session/update PARAMS for CONNECTION."
  (when-let* ((buffer (ellm-acp--connection-buffer connection)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((update (plist-get params :update)))
          (pcase (plist-get update :sessionUpdate)
            ("agent_message_chunk"
             (ellm-acp--insert-content "assistant"
                                       (plist-get update :content)))
            ("agent_thought_chunk"
             (ellm-acp--insert-content "reasoning"
                                       (plist-get update :content)))
            ("tool_call"
             (ellm-acp--insert-tool-call update))
            ("tool_call_update"
             (ellm-acp--insert-tool-update update))
            ("plan"
             (ellm-acp--insert-plan update))
            ("available_commands_update"
             (setf (ellm-acp--connection-available-commands connection)
                   (plist-get update :availableCommands)))
            ("session_info_update"
             (ellm-acp--handle-session-info-update connection update))
            (_ nil)))))))

(defun ellm-acp--handle-session-info-update (connection update)
  "Persist ACP session metadata UPDATE for CONNECTION."
  (when-let* ((buffer (ellm-acp--connection-buffer connection)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (plist-member update :title)
          (ellm--set-frontmatter-value '(acp title) (plist-get update :title)))
        (when (plist-member update :updatedAt)
          (ellm--set-frontmatter-value '(acp updated-at)
                                      (plist-get update :updatedAt)))))))

(defun ellm-acp--slash-command-candidate (command)
  "Return completion candidate for ACP slash COMMAND."
  (let* ((name (plist-get command :name))
         (desc (plist-get command :description))
         (input (plist-get command :input))
         (hint (plist-get input :hint)))
    (append (list (concat "/" name))
            (append (when hint (list :ann hint))
                    (when desc (list :desc desc))))))

(defun ellm-acp--insert-content (role content)
  "Insert ACP CONTENT as ROLE."
  (let ((text (ellm-acp--content-text content)))
    (when (and text (not (string-empty-p text)))
      (goto-char (point-max))
      (unless (ellm-acp--inside-open-role-p role)
        (ellm--insert-turn role :continuation t))
      (insert text))))

(defun ellm-acp--inside-open-role-p (role)
  "Return non-nil if point is currently in an open turn with ROLE."
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward ellm-turn-regexp nil t)
      (equal (match-string-no-properties 2) role))))

(defun ellm-acp--content-text (content)
  "Return text display for ACP CONTENT block."
  (pcase (plist-get content :type)
    ("text" (plist-get content :text))
    ("resource_link"
     (format "[%s](%s)" (or (plist-get content :name) "resource")
             (plist-get content :uri)))
    ("resource"
     (let ((resource (plist-get content :resource)))
       (or (plist-get resource :text)
           (and (plist-get resource :uri)
                (format "Resource: %s" (plist-get resource :uri))))))
    (_ nil)))

(defun ellm-acp--insert-tool-call (update)
  "Insert ACP tool call UPDATE."
  (goto-char (point-max))
  (let ((params (ellm-acp--raw-input-params (plist-get update :rawInput))))
    (ellm--insert-tool-call-with-params
     (or (plist-get update :title) "ACP tool")
     (plist-get update :toolCallId)
     params)
    (unless params
      (insert (ellm-acp--tool-update-text update)))))

(defun ellm-acp--raw-input-params (raw-input)
  "Return RAW-INPUT as an alist suitable for `tool-param' turns."
  (cond
   ((null raw-input) nil)
   ((and (listp raw-input) (keywordp (car raw-input)))
    (cl-loop for (key value) on raw-input by #'cddr
             collect (cons (substring (symbol-name key) 1) value)))
   ((listp raw-input) raw-input)
   (t `((input . ,raw-input)))))

(defun ellm-acp--insert-tool-update (update)
  "Insert ACP tool call UPDATE as a result block when it carries content."
  (when (or (plist-get update :content)
            (member (plist-get update :status) '("completed" "failed")))
    (goto-char (point-max))
    (ellm--insert-turn "tool-result"
                       :pipe-arg (or (plist-get update :title) "ACP tool")
                       :id (plist-get update :toolCallId))
    (insert (ellm-acp--tool-update-text update))))

(defun ellm-acp--tool-update-text (update)
  "Return Markdown text for ACP tool UPDATE."
  (let ((parts nil))
    (when-let* ((status (plist-get update :status)))
      (push (format "Status: %s\n" status) parts))
    (when-let* ((content (plist-get update :content)))
      (dolist (item content)
        (push (ellm-acp--tool-content-text item) parts)))
    (ellm--ensure-newline (string-join (nreverse (delq nil parts)) "\n"))))

(defun ellm-acp--tool-content-text (item)
  "Return Markdown text for ACP tool content ITEM."
  (pcase (plist-get item :type)
    ("content" (ellm-acp--content-text (plist-get item :content)))
    ("diff"
     (format "Diff: %s\n```diff\n--- old\n+++ new\n%s\n```\n"
             (plist-get item :path)
             (or (plist-get item :newText) "")))
    ("terminal"
     (format "Terminal: %s\n" (plist-get item :terminalId)))
    (_ nil)))

(defun ellm-acp--insert-plan (update)
  "Insert ACP plan UPDATE as a reasoning block."
  (goto-char (point-max))
  (ellm--insert-turn "reasoning" :continuation t)
  (insert "Plan:\n")
  (dolist (entry (plist-get update :entries))
    (insert (format "- [%s/%s] %s\n"
                    (plist-get entry :status)
                    (plist-get entry :priority)
                    (plist-get entry :content)))))

(defun ellm-acp--finish-prompt (buffer)
  "Finish ACP prompt in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ellm--active-request nil)
      (goto-char (point-max))
      (unless (and-let* ((turns (ellm--parse-turns))
                         (last-turn (car (last turns))))
                (equal (ellm-turn-role last-turn) "user"))
        (ellm--insert-turn "user")))))

(defun ellm-acp--finish-with-error (buffer error-object)
  "Finish ACP request in BUFFER by signalling ERROR-OBJECT."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ellm--active-request nil)))
  (error "ellm ACP: %s"
         (or (plist-get error-object :message)
             "request failed")))

;;;; Permission requests

(defun ellm-acp--handle-permission-request (params)
  "Handle ACP permission request PARAMS and return an ACP response result."
  (let* ((tool-call (plist-get params :toolCall))
         (options (plist-get params :options))
         (option-id (funcall ellm-acp-permission-function tool-call options)))
    `(:outcome ,(if option-id
                    `(:outcome "selected" :optionId ,option-id)
                  '(:outcome "cancelled")))))

(defun ellm-acp-ask-permission (tool-call options)
  "Ask the user to select an ACP permission option for TOOL-CALL.
OPTIONS is the ACP options list.  In noninteractive sessions this returns
nil, causing a cancelled outcome."
  (unless noninteractive
    (let* ((title (or (plist-get tool-call :title) "ACP tool call"))
           (labels (mapcar (lambda (option)
                             (cons (plist-get option :name)
                                   (plist-get option :optionId)))
                           options))
           (choice (completing-read (format "%s: " title)
                                    (mapcar #'car labels)
                                    nil t)))
      (cdr (assoc choice labels)))))

(provide 'ellm-acp)
;;; ellm-acp.el ends here
