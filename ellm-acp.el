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

(defcustom ellm-acp-stderr-buffer-name "*ellm-acp-stderr*"
  "Buffer name used for ACP agent diagnostics written to stderr."
  :type 'string
  :group 'ellm-acp)

(defcustom ellm-acp-tool-detail-limit 'summary
  "How much detail to render for ACP tool calls and results.
Nil renders full tool parameters and results.  The symbol `summary' renders
only human-facing ACP titles and content, omitting raw input/output, locations,
and structured diffs.  Zero inserts only `tool-call' and `tool-result'
headings.  A positive integer renders up to that many characters for each
parameter value and result body, followed by a truncation marker when text was
omitted."
  :type '(choice (const :tag "No limit" nil)
                 (const :tag "Human-facing summary" summary)
                 (natnum :tag "Maximum characters"))
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
   (config-options
    :initform nil
    :accessor ellm-acp--connection-config-options)
   (last-message-key
    :initform nil
    :accessor ellm-acp--connection-last-message-key)
   (rendered-tools
    :initform (make-hash-table :test 'equal)
    :accessor ellm-acp--connection-rendered-tools)
   (log-buffer
    :initform nil
    :accessor ellm-acp--connection-log-buffer))
  "ACP JSON-RPC connection using newline-delimited stdio.")

(cl-defstruct (ellm-acp-rendered-tool (:constructor ellm-acp--make-rendered-tool))
  "Marker state for one rendered ACP tool call/result pair."
  id call-title result-title result-summary
  call-beg params-beg params-end result-beg result-body-beg result-end)

(cl-defstruct (ellm-acp-request (:constructor ellm-acp--make-request))
  "Active request handle for the ACP backend."
  connection cancelled)

(defvar-local ellm-acp--connection nil
  "ACP connection associated with the current ellm buffer.")

(defvar ellm-acp--inhibit-frontmatter-persist nil
  "When non-nil, do not persist ACP session metadata into frontmatter.")

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

(cl-defmethod ellm-provider-prepare-new-buffer
  ((provider ellm-acp-provider) frontmatter buffer on-ready on-error)
  "Asynchronously start PROVIDER's session for BUFFER."
  (with-current-buffer buffer
    (let ((connection (ellm-acp--ensure-connection provider buffer)))
      (ellm-acp--ensure-session connection provider frontmatter on-ready on-error))))

(cl-defmethod ellm-provider-configure-new-buffer
  ((_provider ellm-acp-provider) frontmatter buffer on-ready on-error)
  "Asynchronously apply BUFFER's model and prompt for session configuration."
  (with-current-buffer buffer
    (let* ((connection (ellm-acp--buffer-connection buffer))
           (model (alist-get 'model frontmatter))
           (config-id (or (ellm-acp--connection-model-config-id connection)
                          "model")))
      (message "ellm ACP: applying model %s..." model)
      (ellm-acp--set-model
       connection config-id model
       (lambda ()
         (message "ellm ACP: model %s ready; select session options" model)
         (let ((ids
                (cl-loop for option in (ellm-acp--connection-config-options
                                        connection)
                         unless (or (equal (plist-get option :category) "model")
                                    (equal (plist-get option :id) config-id))
                         collect (plist-get option :id))))
           (ellm--defer-call
            #'ellm-acp--configure-new-buffer-options
            connection buffer ids on-ready on-error)))
       on-error))))

(defun ellm-acp--configure-new-buffer-options
    (connection buffer config-ids on-ready on-error)
  "Prompt for CONFIG-IDS sequentially, applying each on CONNECTION for BUFFER."
  (cond
   ((not (buffer-live-p buffer))
    (funcall on-error '(:message "conversation buffer was killed")))
   ((null config-ids)
    (funcall on-ready))
   (t
    (let ((option (ellm-acp--config-option connection (car config-ids))))
      (if (not option)
          (ellm-acp--configure-new-buffer-options
           connection buffer (cdr config-ids) on-ready on-error)
        (with-current-buffer buffer
          (message "ellm ACP: select %s"
                   (or (plist-get option :name) (plist-get option :id)))
          (ellm-acp-set-config
           connection option
           (lambda ()
             (ellm--defer-call
              #'ellm-acp--configure-new-buffer-options
              connection buffer (cdr config-ids) on-ready on-error))
           on-error)))))))

(cl-defmethod ellm-provider-slash-command-candidates ((_provider ellm-acp-provider) buffer)
  "Return slash command candidates advertised by BUFFER's ACP session."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and ellm-acp--connection
                 (jsonrpc-running-p ellm-acp--connection))
        (mapcar #'ellm-acp--slash-command-candidate
                (ellm-acp--connection-available-commands ellm-acp--connection))))))

(cl-defmethod ellm-provider-frontmatter-entries ((_provider ellm-acp-provider) path buffer)
  "Return ACP frontmatter entries under PATH in BUFFER."
  (pcase path
    ('(acp config)
     (ellm-acp--config-frontmatter-entries buffer))
    (_ nil)))

(cl-defmethod ellm-provider-start-session ((provider ellm-acp-provider) frontmatter buffer)
  "Start/login an ACP session for BUFFER without sending a prompt."
  (ellm-acp-start-session provider frontmatter buffer))

(cl-defmethod ellm-provider-model-completion-session-start-p
  ((_provider ellm-acp-provider) buffer)
  "Return non-nil when BUFFER has no live ACP session yet."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (not (and ellm-acp--connection
                   (jsonrpc-running-p ellm-acp--connection)
                   (ellm-acp--connection-session-id ellm-acp--connection))))))

(cl-defmethod ellm-provider-start-session-for-model-completion
  ((provider ellm-acp-provider) frontmatter buffer)
  "Start an ACP session for model completion without rewriting frontmatter."
  (let ((ellm-acp--inhibit-frontmatter-persist t))
    (ellm-acp-start-session provider frontmatter buffer :quiet)))

(cl-defmethod ellm-provider-load-session ((provider ellm-acp-provider) frontmatter)
  "Select and load an ACP session for PROVIDER."
  (ellm-acp-load-session provider frontmatter))

(cl-defmethod ellm-provider-close-session ((provider ellm-acp-provider) frontmatter buffer)
  "Close BUFFER's active ACP session for PROVIDER."
  (ellm-acp-close-session provider frontmatter buffer))

(cl-defmethod ellm-provider-delete-session ((provider ellm-acp-provider) frontmatter buffer
                                            &optional select)
  "Delete an ACP session for PROVIDER."
  (ellm-acp-delete-session provider frontmatter buffer select))

(cl-defmethod ellm-backend-send ((provider ellm-acp-provider) frontmatter buffer)
  "Send BUFFER's trailing user turn through ACP PROVIDER."
  (with-current-buffer buffer
    (let* ((connection (ellm-acp--ensure-connection provider buffer))
           (prompt-text (ellm-acp--last-user-content))
           (request (ellm-acp--make-request :connection connection)))
      (ellm-acp--ensure-session
       connection provider frontmatter
       (lambda ()
         (ellm-acp--ensure-frontmatter-model
          connection frontmatter
          (lambda ()
            (ellm-acp--ensure-frontmatter-config
             provider connection frontmatter
             (lambda ()
               (ellm-acp--send-prompt connection buffer prompt-text))
             (lambda (error-object)
               (ellm-acp--finish-with-error buffer error-object))))
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
                     :stderr (get-buffer-create ellm-acp-stderr-buffer-name)
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
            (ellm--set-active-request nil)
            (ellm--notify-request-finished)
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
    (and present (not (eq value :json-false)))))

(defun ellm-acp--provider-cwd (provider frontmatter)
  "Return absolute ACP cwd for PROVIDER and FRONTMATTER."
  (expand-file-name
   (file-name-as-directory
    (or (ellm-acp-provider-cwd provider)
        (alist-get 'cwd frontmatter)
        default-directory))))

(defun ellm-acp--resolve-value (value)
  "Resolve VALUE when it follows mcp.el's dynamic value convention."
  (cond
   ((functionp value) (funcall value))
   ((and (symbolp value) (boundp value)) (symbol-value value))
   (t value)))

(defun ellm-acp--sequence-vector (value)
  "Return VALUE as a vector suitable for JSON arrays."
  (cond
   ((null value) [])
   ((vectorp value) value)
   ((listp value) (vconcat value))
   (t (vector value))))

(defun ellm-acp--env-vector (env)
  "Return ACP EnvVariable vector for mcp.el-style ENV."
  (cond
   ((null env) [])
   ((vectorp env) env)
   ((and (listp env) (keywordp (car env)))
    (vconcat
     (cl-loop for (key value) on env by #'cddr
              collect `(:name ,(substring (symbol-name key) 1)
                        :value ,(format "%s" (ellm-acp--resolve-value value))))))
   ((and (listp env) (listp (car env))
         (or (ellm--plistish-get (car env) 'name)
             (ellm--plistish-get (car env) 'value)))
    (vconcat (mapcar #'ellm-acp--name-value-map env)))
   ((listp env)
    (vconcat
     (mapcar (lambda (cell)
               (let ((key (car cell))
                     (value (if (consp (cdr cell))
                                (cadr cell)
                              (cdr cell))))
                 `(:name ,(ellm-acp--env-name key)
                   :value ,(format "%s" (ellm-acp--resolve-value value)))))
             env)))
   (t [])))

(defun ellm-acp--env-name (key)
  "Return KEY as an environment/header name string."
  (cond
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   (t (format "%s" key))))

(defun ellm-acp--name-value-map (item)
  "Return ACP name/value object for plistish ITEM."
  `(:name ,(format "%s" (ellm--plistish-get item 'name))
    :value ,(format "%s"
                    (ellm-acp--resolve-value
                     (ellm--plistish-get item 'value)))))

(defun ellm-acp--headers-vector (config)
  "Return ACP HTTP header vector for MCP CONFIG."
  (let ((headers (ellm--plistish-get config 'headers))
        (token (ellm-acp--resolve-value (ellm--plistish-get config 'token)))
        result)
    (cond
     ((vectorp headers)
      (setq result (append headers nil)))
     ((and (listp headers) (listp (car headers))
           (or (ellm--plistish-get (car headers) 'name)
               (ellm--plistish-get (car headers) 'value)))
      (setq result (mapcar #'ellm-acp--name-value-map headers)))
     ((listp headers)
      (setq result
            (mapcar (lambda (cell)
                      (let ((key (car cell))
                            (value (if (consp (cdr cell))
                                       (cadr cell)
                                     (cdr cell))))
                        `(:name ,(ellm-acp--env-name key)
                          :value ,(format "%s" (ellm-acp--resolve-value value)))))
                    headers))))
    (when token
      (setq result (append result
                           (list `(:name "Authorization"
                                   :value ,(concat "Bearer " token))))))
    (vconcat result)))

(defun ellm-acp--mcp-command (command)
  "Return COMMAND as an ACP stdio MCP command."
  (or (and command (executable-find command)) command))

(defun ellm-acp--mcp-server (connection server)
  "Return ACP MCP server object for resolved SERVER."
  (let* ((name (ellm--mcp-server-name (car server)))
         (config (cdr server))
         (command (ellm--plistish-get config 'command))
         (url (ellm--plistish-get config 'url))
         (type (ellm--plistish-get config 'type)))
    (cond
     (command
      `(:name ,name
        :command ,(ellm-acp--mcp-command command)
        :args ,(ellm-acp--sequence-vector (ellm--plistish-get config 'args))
        :env ,(ellm-acp--env-vector (ellm--plistish-get config 'env))))
     (url
      (let ((transport (format "%s" (or type "http"))))
        (unless (ellm-acp--capability connection `(mcpCapabilities ,(intern transport)))
          (user-error "ellm ACP: agent does not support MCP %s transport" transport))
        `(:type ,transport
          :name ,name
          :url ,url
          :headers ,(ellm-acp--headers-vector config))))
     (t
      (user-error "ellm ACP: MCP server `%s' must define :command or :url" name)))))

(defun ellm-acp--mcp-servers (connection frontmatter)
  "Return ACP mcpServers vector for CONNECTION and FRONTMATTER."
  (vconcat
   (mapcar (lambda (server) (ellm-acp--mcp-server connection server))
           (ellm--resolve-mcp-servers frontmatter))))

(defun ellm-acp--additional-directories (frontmatter &optional override)
  "Return ACP additionalDirectories from FRONTMATTER or OVERRIDE."
  (let ((dirs (or override
                  (ellm--alist-get-nested frontmatter '(acp additional-directories)))))
    (cond
     ((null dirs) nil)
     ((stringp dirs) (vector (expand-file-name dirs)))
     ((vectorp dirs) (vconcat (mapcar #'expand-file-name dirs)))
     ((listp dirs) (vconcat (mapcar #'expand-file-name dirs)))
     (t nil))))

(defun ellm-acp--session-lifecycle-params (connection provider frontmatter
                                                      &optional session-id additional-directories)
  "Return common ACP session lifecycle params.
SESSION-ID, when non-nil, is included for load/resume requests."
  (let* ((params (append (when session-id (list :sessionId session-id))
                         (list :cwd (ellm-acp--provider-cwd provider frontmatter)
                               :mcpServers (ellm-acp--mcp-servers connection frontmatter))))
         (dirs (ellm-acp--additional-directories frontmatter additional-directories)))
    (when (and dirs (ellm-acp--capability connection '(sessionCapabilities additionalDirectories)))
      (setq params (append params (list :additionalDirectories dirs))))
    params))

(defun ellm-acp--with-lifecycle-params (connection provider frontmatter session-id
                                                   additional-directories on-error fn)
  "Call FN with lifecycle params, routing validation errors to ON-ERROR."
  (condition-case err
      (funcall fn (ellm-acp--session-lifecycle-params
                   connection provider frontmatter session-id additional-directories))
    (error
     (funcall on-error `(:message ,(error-message-string err))))))

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
    (if-let* ((session-id (ellm--alist-get-nested frontmatter '(acp session-id))))
        (ellm-acp--restore-session connection provider frontmatter session-id
                                   on-ready on-error)
      (ellm-acp--new-session connection provider frontmatter on-ready on-error)))
   (t
    (ellm-acp--initialize
     connection
      (lambda (_result)
        (setf (ellm-acp--connection-initialized connection) t)
        (ellm-acp--ensure-session
         connection provider frontmatter on-ready on-error))
      on-error))))

(defun ellm-acp--ensure-session-sync (connection provider frontmatter)
  "Synchronously ensure CONNECTION is initialized and has an ACP session."
  (ellm-acp--initialize-sync connection)
  (unless (ellm-acp--connection-session-id connection)
    (if-let* ((session-id (ellm--alist-get-nested frontmatter '(acp session-id))))
        (ellm-acp--restore-session-sync connection provider frontmatter session-id)
      (ellm-acp--new-session-sync connection provider frontmatter)))
  connection)

(defun ellm-acp--new-session-sync (connection provider frontmatter)
  "Synchronously create a new ACP session for CONNECTION."
  (let* ((params (ellm-acp--session-lifecycle-params
                  connection provider frontmatter))
         (result (ellm-acp--request-sync connection :session/new params))
         (session-id (plist-get result :sessionId)))
    (setf (ellm-acp--connection-session-id connection) session-id)
    (when session-id
      (ellm-acp--persist-session-id connection session-id))
    (ellm-acp--update-model-candidates
     connection (plist-get result :configOptions))
    (ellm-acp--maybe-set-model-sync
     connection
     (or (alist-get 'model frontmatter)
         (ellm-acp-provider-model provider)))))

(defun ellm-acp--restore-session-sync (connection provider frontmatter session-id)
  "Synchronously restore ACP SESSION-ID for CONNECTION."
  (cond
   ((ellm-acp--capability connection '(sessionCapabilities resume))
    (ellm-acp--resume-session-sync connection provider frontmatter session-id))
   ((ellm-acp--capability connection '(loadSession))
    (ellm-acp--load-existing-session-sync
     connection provider frontmatter session-id nil))
   (t
    (user-error
     "ellm ACP: agent does not support session/resume or session/load for saved session `%s'"
     session-id))))

(defun ellm-acp--resume-session-sync (connection provider frontmatter session-id)
  "Synchronously resume ACP SESSION-ID without replaying history."
  (setf (ellm-acp--connection-session-id connection) session-id)
  (let* ((params (ellm-acp--session-lifecycle-params
                  connection provider frontmatter session-id))
         (result (ellm-acp--request-sync connection :session/resume params)))
    (ellm-acp--update-model-candidates
     connection (plist-get result :configOptions))))

(defun ellm-acp--load-existing-session-sync (connection provider frontmatter session-id
                                                        additional-directories)
  "Synchronously load ACP SESSION-ID and replay history into CONNECTION's buffer."
  (setf (ellm-acp--connection-session-id connection) session-id)
  (let* ((params (ellm-acp--session-lifecycle-params
                  connection provider frontmatter session-id additional-directories))
         (result (ellm-acp--request-sync connection :session/load params)))
    (ellm-acp--update-model-candidates
     connection (plist-get result :configOptions))))

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
  (ellm-acp--with-lifecycle-params
   connection provider frontmatter nil nil on-error
   (lambda (params)
     (jsonrpc-async-request
      connection :session/new params
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
      :error-fn on-error))))

(defun ellm-acp--restore-session (connection provider frontmatter session-id on-ready on-error)
  "Restore SESSION-ID for a fresh ACP CONNECTION."
  (cond
   ((ellm-acp--capability connection '(sessionCapabilities resume))
    (ellm-acp--resume-session connection provider frontmatter session-id
                              on-ready on-error))
   ((ellm-acp--capability connection '(loadSession))
    (ellm-acp--load-existing-session connection provider frontmatter session-id nil
                                     on-ready on-error))
   (t
    (funcall on-error
             `(:message ,(format "agent does not support session/resume or session/load for saved session `%s'"
                                 session-id))))))

(defun ellm-acp--resume-session (connection provider frontmatter session-id on-ready on-error)
  "Resume ACP SESSION-ID without replaying history."
  (setf (ellm-acp--connection-session-id connection) session-id)
  (ellm-acp--with-lifecycle-params
   connection provider frontmatter session-id nil on-error
   (lambda (params)
     (jsonrpc-async-request
      connection :session/resume params
      :success-fn (lambda (result)
                    (ellm-acp--update-model-candidates
                     connection (plist-get result :configOptions))
                    (funcall on-ready))
      :error-fn on-error))))

(defun ellm-acp--load-existing-session (connection provider frontmatter session-id
                                                   additional-directories on-ready on-error)
  "Load ACP SESSION-ID and replay history into CONNECTION's buffer."
  (setf (ellm-acp--connection-session-id connection) session-id)
  (ellm-acp--with-lifecycle-params
   connection provider frontmatter session-id additional-directories on-error
   (lambda (params)
     (jsonrpc-async-request
      connection :session/load params
      :success-fn (lambda (result)
                    (ellm-acp--update-model-candidates
                     connection (plist-get result :configOptions))
                    (funcall on-ready))
      :error-fn on-error))))

(defun ellm-acp--persist-session-id (connection session-id)
  "Persist ACP SESSION-ID in CONNECTION's conversation frontmatter."
  (unless ellm-acp--inhibit-frontmatter-persist
    (when-let* ((buffer (ellm-acp--connection-buffer connection)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (ellm--set-frontmatter-value '(acp session-id) session-id))))))

(defun ellm-acp--ensure-frontmatter-model (connection frontmatter on-ready on-error)
  "Apply FRONTMATTER `model:' to CONNECTION before calling ON-READY."
  (ellm-acp--maybe-set-model
   connection (alist-get 'model frontmatter) on-ready on-error))

(defun ellm-acp--ensure-frontmatter-config (provider connection frontmatter
                                                     on-ready on-error)
  "Apply generic ACP config from FRONTMATTER before calling ON-READY."
  (condition-case err
      (ellm-acp--apply-config-options
       connection
       (ellm-acp--frontmatter-config-values provider connection frontmatter)
       on-ready
       on-error)
    (error
     (funcall on-error `(:message ,(error-message-string err))))))

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

(defun ellm-acp--maybe-set-model-sync (connection model)
  "Synchronously set ACP session MODEL when it differs."
  (let ((config-id (ellm-acp--connection-model-config-id connection))
        (current (ellm-acp--connection-current-model connection)))
    (cond
     ((or (not model) (equal model current))
      nil)
     ((not config-id)
      (setq config-id "model")
      (ellm-acp--set-model-sync connection config-id model))
     (t
      (ellm-acp--set-model-sync connection config-id model)))))

(defun ellm-acp--set-model (connection config-id model on-ready on-error)
  "Set ACP session MODEL using CONFIG-ID, then call ON-READY."
  (ellm-acp--set-config-option
   connection config-id model on-ready on-error
   (ellm-acp--config-option connection config-id)
   (lambda (_result)
     (setf (ellm-acp--connection-current-model connection) model)
     (ellm-acp--persist-current-model connection))))

(defun ellm-acp--set-model-sync (connection config-id model)
  "Synchronously set ACP session MODEL using CONFIG-ID."
  (ellm-acp--set-config-option-sync
   connection config-id model
   (ellm-acp--config-option connection config-id)
   (lambda (_result)
     (setf (ellm-acp--connection-current-model connection) model)
     (ellm-acp--persist-current-model connection))))

(defun ellm-acp--set-config-option (connection config-id value on-ready on-error
                                               &optional option after-success)
  "Set ACP CONFIG-ID to VALUE on CONNECTION, then call ON-READY.
OPTION is the advertised ACP config option, when known.  AFTER-SUCCESS is
called with the raw response before ON-READY."
  (let* ((wire-value (ellm-acp--config-value-for-wire option value config-id))
         (params `(:sessionId ,(ellm-acp--connection-session-id connection)
                   :configId ,config-id
                   :value ,wire-value)))
    (when (equal (plist-get option :type) "boolean")
      (setq params (append params '(:type "boolean"))))
    (jsonrpc-async-request
     connection :session/set_config_option params
     :success-fn (lambda (result)
                   (ellm-acp--update-config-options
                    connection (plist-get result :configOptions))
                   (when after-success
                     (funcall after-success result))
                   (funcall on-ready))
     :error-fn on-error)))

(defun ellm-acp--set-config-option-sync (connection config-id value
                                                    &optional option after-success)
  "Synchronously set ACP CONFIG-ID to VALUE on CONNECTION."
  (let* ((wire-value (ellm-acp--config-value-for-wire option value config-id))
         (params `(:sessionId ,(ellm-acp--connection-session-id connection)
                   :configId ,config-id
                   :value ,wire-value)))
    (when (equal (plist-get option :type) "boolean")
      (setq params (append params '(:type "boolean"))))
    (let ((result (ellm-acp--request-sync
                   connection :session/set_config_option params)))
      (ellm-acp--update-config-options
       connection (plist-get result :configOptions))
      (when after-success
        (funcall after-success result))
      result)))

(defun ellm-acp--apply-config-options (connection entries on-ready on-error)
  "Apply desired ACP config ENTRIES sequentially for CONNECTION."
  (if (null entries)
      (funcall on-ready)
    (let* ((entry (car entries))
           (config-id (plist-get entry :id))
           (value (plist-get entry :value))
           (option (ellm-acp--config-option connection config-id)))
      (cond
       ((and (ellm-acp--connection-config-options connection)
             (not option))
        (funcall on-error
                 `(:message ,(format "ACP config option `%s' is not advertised"
                                     config-id))))
       ((ellm-acp--config-value-current-p option value config-id)
        (ellm-acp--apply-config-options
         connection (cdr entries) on-ready on-error))
       (t
        (ellm-acp--set-config-option
         connection config-id value
         (lambda ()
           (ellm-acp--apply-config-options
            connection (cdr entries) on-ready on-error))
         on-error
         option))))))

(defun ellm-acp--apply-config-options-sync (connection entries)
  "Synchronously apply desired ACP config ENTRIES for CONNECTION."
  (dolist (entry entries)
    (let* ((config-id (plist-get entry :id))
           (value (plist-get entry :value))
           (option (ellm-acp--config-option connection config-id)))
      (cond
       ((and (ellm-acp--connection-config-options connection)
             (not option))
        (user-error "ellm ACP: config option `%s' is not advertised"
                    config-id))
       ((ellm-acp--config-value-current-p option value config-id)
        nil)
       (t
        (ellm-acp--set-config-option-sync
         connection config-id value option))))))

(defun ellm-acp--frontmatter-config-values (_provider connection frontmatter)
  "Return desired ACP config entries from FRONTMATTER."
  (let (entries)
    (dolist (cell (ellm-acp--frontmatter-acp-config-cells frontmatter))
      (setq entries
            (ellm-acp--add-frontmatter-config-value
             entries
             (ellm-acp--key-name (car cell))
             (cdr cell))))
    (when-let* ((model (alist-get 'model frontmatter))
                (model-id (or (ellm-acp--connection-model-config-id connection)
                              "model")))
      (when-let* ((entry (cl-find model-id entries
                                  :key (lambda (entry)
                                         (plist-get entry :id))
                                  :test #'equal)))
        (unless (ellm-acp--frontmatter-values-equal-p
                 model (plist-get entry :value))
          (user-error "ellm ACP: conflicting frontmatter values for ACP config `%s'"
                      model-id))))
    (nreverse entries)))

(defun ellm-acp--frontmatter-acp-config-cells (frontmatter)
  "Return cells under FRONTMATTER `acp.config'."
  (let ((config (ellm--alist-get-nested frontmatter '(acp config))))
    (and (listp config)
         (cl-remove-if-not #'consp config))))

(defun ellm-acp--add-frontmatter-config-value (entries config-id value)
  "Return ENTRIES with CONFIG-ID set to VALUE, signalling on conflicts."
  (unless config-id
    (user-error "ellm ACP: config option id is missing"))
  (let ((existing (cl-find config-id entries
                           :key (lambda (entry) (plist-get entry :id))
                           :test #'equal)))
    (cond
     ((not existing)
      (cons (list :id config-id :value value) entries))
     ((ellm-acp--frontmatter-values-equal-p
       value (plist-get existing :value))
      entries)
     (t
      (user-error "ellm ACP: conflicting frontmatter values for ACP config `%s'"
                  config-id)))))

(defun ellm-acp--frontmatter-values-equal-p (left right)
  "Return non-nil when LEFT and RIGHT express the same frontmatter value."
  (or (equal left right)
      (equal (ellm-acp--value-string left)
             (ellm-acp--value-string right))
      (and (ellm-acp--false-value-p left)
           (ellm-acp--false-value-p right))))

(defun ellm-acp--value-string (value)
  "Return VALUE as a frontmatter scalar string."
  (cond
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   (t (format "%s" value))))

(defun ellm-acp--key-name (key)
  "Return KEY as a string suitable for an ACP config id."
  (cond
   ((stringp key) key)
   ((symbolp key) (symbol-name key))
   (t (format "%s" key))))

(defun ellm-acp--false-value-p (value)
  "Return non-nil when VALUE represents boolean false."
  (or (null value)
      (eq value :json-false)
      (and (stringp value)
           (equal (downcase value) "false"))))

(defun ellm-acp--config-value-for-wire (option value config-id)
  "Return VALUE converted for OPTION/CONFIG-ID on the ACP wire."
  (if (equal (plist-get option :type) "boolean")
      (ellm-acp--boolean-config-value value config-id)
    (ellm-acp--value-string value)))

(defun ellm-acp--boolean-config-value (value config-id)
  "Return VALUE as an ACP boolean for CONFIG-ID."
  (cond
   ((or (eq value t)
        (and (stringp value) (equal (downcase value) "true")))
    t)
   ((ellm-acp--false-value-p value)
    :json-false)
   (t
    (user-error "ellm ACP: boolean config `%s' expects true or false"
                config-id))))

(defun ellm-acp--config-value-current-p (option value config-id)
  "Return non-nil when OPTION's current value equals VALUE."
  (and option
       (plist-member option :currentValue)
       (equal (ellm-acp--config-value-for-wire option value config-id)
              (ellm-acp--config-value-for-wire
               option (plist-get option :currentValue) config-id))))

(defun ellm-acp--config-option (connection config-id)
  "Return advertised ACP config option CONFIG-ID from CONNECTION."
  (cl-find config-id (ellm-acp--connection-config-options connection)
           :key (lambda (option) (plist-get option :id))
           :test #'equal))

(defun ellm-acp--config-option-by-category (connection category)
  "Return first advertised ACP config option in CATEGORY from CONNECTION."
  (cl-find category (ellm-acp--connection-config-options connection)
           :key (lambda (option) (plist-get option :category))
           :test #'equal))

(defun ellm-acp--model-config-option (config-options)
  "Return model-like ACP config option from CONFIG-OPTIONS."
  (cl-find-if
   (lambda (option)
     (or (equal (plist-get option :category) "model")
         (equal (plist-get option :id) "model")))
   config-options))

(defun ellm-acp--update-config-options (connection config-options)
  "Store ACP CONFIG-OPTIONS and derived state on CONNECTION."
  (when config-options
    (setf (ellm-acp--connection-config-options connection) config-options)
    (ellm-acp--update-model-state connection)))

(defun ellm-acp--update-model-candidates (connection config-options)
  "Store model candidates from ACP CONFIG-OPTIONS on CONNECTION."
  (ellm-acp--update-config-options connection config-options))

(defun ellm-acp--update-model-state (connection)
  "Update CONNECTION's model state from stored ACP config options."
  (when-let* ((option (or (ellm-acp--config-option-by-category connection "model")
                          (ellm-acp--config-option connection "model"))))
    (setf (ellm-acp--connection-model-config-id connection)
          (plist-get option :id))
    (setf (ellm-acp--connection-current-model connection)
          (plist-get option :currentValue))
    (ellm-acp--persist-current-model connection)
    (setf (ellm-acp--connection-model-candidates connection)
          (mapcar #'ellm-acp--config-value-candidate
                  (ellm-acp--flatten-select-options
                   (plist-get option :options))))))

(defun ellm-acp--persist-current-model (connection)
  "Persist CONNECTION's current ACP model in its buffer frontmatter."
  (unless ellm-acp--inhibit-frontmatter-persist
    (when-let* ((model (ellm-acp--connection-current-model connection))
                (buffer (ellm-acp--connection-buffer connection)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (ellm--set-frontmatter-value 'model model))))))

(defun ellm-acp--config-value-candidate (option)
  "Return a completion candidate for ACP select OPTION."
  (let ((value (plist-get option :value))
        (name (plist-get option :name))
        (desc (plist-get option :description)))
    (append (list (ellm-acp--value-string value))
            (append (when name (list :ann name))
                    (when desc (list :desc desc))))))

(defun ellm-acp--flatten-select-options (options)
  "Return flat ACP select options from possibly grouped OPTIONS."
  (cl-loop for option in (ellm-acp--sequence-list options)
           append (if (plist-member option :options)
                      (ellm-acp--flatten-select-options
                       (plist-get option :options))
                    (list option))))

(defun ellm-acp--config-option-value-candidates (option)
  "Return frontmatter value candidates for ACP config OPTION."
  (pcase (plist-get option :type)
    ("select"
     (mapcar #'ellm-acp--config-value-candidate
             (ellm-acp--flatten-select-options
              (plist-get option :options))))
    ("boolean"
     '("true" "false"))
    (_ nil)))

(defun ellm-acp--config-option-frontmatter-entry (option)
  "Return a frontmatter key entry for ACP config OPTION."
  (let* ((id (plist-get option :id))
         (category (plist-get option :category))
         (type (plist-get option :type))
         (values (ellm-acp--config-option-value-candidates option)))
    (append (list id
                  :ann (or category type "config"))
            (when-let* ((desc (or (plist-get option :description)
                                  (plist-get option :name))))
              (list :desc desc))
            (when values
              (list :values values)))))

(defun ellm-acp--buffer-connection (buffer)
  "Return BUFFER's live ACP connection, or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (and ellm-acp--connection
           (jsonrpc-running-p ellm-acp--connection)
           ellm-acp--connection))))

(defun ellm-acp--config-frontmatter-entries (buffer)
  "Return dynamic frontmatter entries for BUFFER's `acp.config'."
  (when-let* ((connection (ellm-acp--buffer-connection buffer)))
    (mapcar #'ellm-acp--config-option-frontmatter-entry
            (ellm-acp--connection-config-options connection))))

(defun ellm-acp--send-prompt (connection buffer text)
  "Send TEXT as BUFFER's pending user prompt through CONNECTION."
  (let ((params `(:sessionId ,(ellm-acp--connection-session-id connection)
                  :prompt [(:type "text" :text ,(or text ""))])))
    (jsonrpc-async-request
     connection :session/prompt params
     :success-fn (lambda (_result)
                   (ellm-acp--finish-prompt buffer))
     :error-fn (lambda (error-object)
                 (ellm-acp--finish-with-error buffer error-object)))))

(defun ellm-acp--last-turn-role ()
  "Return the role of the final turn in the current buffer, or nil."
  (save-excursion
    (save-match-data
      (goto-char (point-max))
      (when (re-search-backward ellm-turn-regexp nil t)
        (match-string-no-properties 2)))))

(defun ellm-acp--last-turn-body-empty-p ()
  "Return non-nil if the final turn body contains only whitespace."
  (save-excursion
    (save-match-data
      (goto-char (point-max))
      (when (re-search-backward ellm-turn-regexp nil t)
        (goto-char (min (1+ (line-end-position)) (point-max)))
        (skip-chars-forward " \t\n\r")
        (eobp)))))

(defun ellm-acp--last-turn-content (role)
  "Return content of the most recent ROLE turn, or nil."
  (save-excursion
    (save-match-data
      (goto-char (point-max))
      (let ((body-end (point-max)))
        (catch 'content
          (while (re-search-backward ellm-turn-regexp nil t)
            (let ((delimiter-beg (match-beginning 0)))
              (when (equal (match-string-no-properties 2) role)
                (throw 'content
                       (string-trim
                        (buffer-substring-no-properties
                         (min (1+ (line-end-position)) (point-max))
                         body-end))))
              (setq body-end delimiter-beg))))))))

(defun ellm-acp--last-user-content ()
  "Return the content of the most recent user turn in the current buffer."
  (ellm-acp--last-turn-content "user"))

(defun ellm-acp-start-session (provider frontmatter buffer &optional quiet)
  "Start/login an ACP session for BUFFER without sending a prompt.
FRONTMATTER is BUFFER's parsed YAML frontmatter.  When QUIET is non-nil,
do not show a success message.  Return the ready ACP connection."
  (unless (buffer-live-p buffer)
    (user-error "ellm ACP: buffer is not live"))
  (with-current-buffer buffer
    (let ((connection (ellm-acp--ensure-connection provider buffer)))
      (ellm-acp--ensure-session-sync connection provider frontmatter)
      (ellm-acp--maybe-set-model-sync
       connection (alist-get 'model frontmatter))
      (ellm-acp--apply-config-options-sync
       connection
       (ellm-acp--frontmatter-config-values provider connection frontmatter))
      (unless quiet
        (message "ellm ACP: session %s ready"
                 (or (ellm-acp--connection-session-id connection) "<unknown>")))
      connection)))

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

(defun ellm-acp--current-session-id (connection frontmatter)
  "Return current ACP session id from CONNECTION or FRONTMATTER."
  (or (and connection (ellm-acp--connection-session-id connection))
      (ellm--alist-get-nested frontmatter '(acp session-id))))

(defun ellm-acp-close-session (provider frontmatter buffer)
  "Close BUFFER's active ACP session for PROVIDER."
  (unless (buffer-live-p buffer)
    (user-error "ellm ACP: buffer is not live"))
  (with-current-buffer buffer
    (let* ((connection (ellm-acp--ensure-connection provider buffer))
           (session-id (ellm-acp--current-session-id connection frontmatter)))
      (unless session-id
        (user-error "ellm ACP: no session id to close"))
      (ellm-acp--initialize-sync connection)
      (unless (ellm-acp--capability connection '(sessionCapabilities close))
        (user-error "ellm ACP: agent does not support session/close"))
      (ellm-acp--request-sync connection :session/close `(:sessionId ,session-id))
      (setf (ellm-acp--connection-session-id connection) nil)
      (ellm--set-frontmatter-value '(acp session-id) nil)
      (and-let* ((proc (ellm-acp--connection-process connection))
                  ((process-live-p proc)))
        (kill-process proc))
      (message "ellm ACP: closed session %s" session-id))))

(defun ellm-acp-delete-session (provider frontmatter buffer &optional select)
  "Delete an ACP session for PROVIDER.
When SELECT is non-nil, choose a session from `session/list'."
  (unless (buffer-live-p buffer)
    (user-error "ellm ACP: buffer is not live"))
  (with-current-buffer buffer
    (let* ((connection (ellm-acp--ensure-connection provider buffer))
           (session-id (unless select
                         (ellm-acp--current-session-id connection frontmatter))))
      (ellm-acp--initialize-sync connection)
      (unless (ellm-acp--capability connection '(sessionCapabilities delete))
        (user-error "ellm ACP: agent does not support session/delete"))
      (unless session-id
        (let ((session (ellm-acp--session-choice
                        (ellm-acp--list-sessions connection provider frontmatter))))
          (setq session-id (plist-get session :sessionId))))
      (unless session-id
        (user-error "ellm ACP: no session selected"))
      (ellm-acp--request-sync connection :session/delete `(:sessionId ,session-id))
      (when (equal session-id (ellm-acp--current-session-id connection frontmatter))
        (setf (ellm-acp--connection-session-id connection) nil)
        (ellm--set-frontmatter-value '(acp session-id) nil))
      (message "ellm ACP: deleted session %s" session-id))))

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
         (ellm-acp--session-lifecycle-params
          connection provider frontmatter session-id
          (or (plist-get session :additionalDirectories) [])))
        :configOptions))
      (goto-char (point-max))
      (unless (equal (ellm-acp--last-turn-role) "user")
        (ellm--insert-turn "user"))
      (ellm--persistence-checkpoint))
    (switch-to-buffer buf)
    buf))

;;;; Rendering

(defun ellm-acp--handle-session-update (connection params)
  "Render ACP session/update PARAMS for CONNECTION."
  (when-let* ((buffer (ellm-acp--connection-buffer connection)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ellm--preserve-user-position
          (let ((update (plist-get params :update)))
            (pcase (plist-get update :sessionUpdate)
              ("user_message_chunk"
               (ellm-acp--insert-content connection "user"
                                         (plist-get update :content)
                                         (plist-get update :messageId)))
              ("agent_message_chunk"
               (ellm-acp--insert-content connection "assistant"
                                         (plist-get update :content)
                                         (plist-get update :messageId)))
              ("agent_thought_chunk"
               (ellm-acp--insert-content connection "reasoning"
                                         (plist-get update :content)
                                         (plist-get update :messageId)))
              ("tool_call"
               (setf (ellm-acp--connection-last-message-key connection) nil)
               (ellm-acp--insert-tool-call update connection))
              ("tool_call_update"
               (setf (ellm-acp--connection-last-message-key connection) nil)
               (ellm-acp--insert-tool-update update connection))
              ("plan"
               (setf (ellm-acp--connection-last-message-key connection) nil)
               (ellm-acp--insert-plan update))
              ("available_commands_update"
               (setf (ellm-acp--connection-available-commands connection)
                     (plist-get update :availableCommands)))
              ("session_info_update"
               (ellm-acp--handle-session-info-update connection update))
              ("config_option_update"
               (ellm-acp--update-model-candidates
                connection (plist-get update :configOptions)))
              ("usage_update"
               (setf (ellm-acp--connection-last-message-key connection) nil)
               (ellm-acp--update-usage update))
              (_ nil))))))))

(defun ellm-acp--handle-session-info-update (connection update)
  "Persist ACP session metadata UPDATE for CONNECTION."
  (unless ellm-acp--inhibit-frontmatter-persist
    (when-let* ((buffer (ellm-acp--connection-buffer connection)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (plist-member update :title)
            (ellm--set-frontmatter-value '(acp title) (plist-get update :title)))
          (when (plist-member update :updatedAt)
            (ellm--set-frontmatter-value '(acp updated-at)
                                         (plist-get update :updatedAt))))))))

(defun ellm-acp--slash-command-candidate (command)
  "Return completion candidate for ACP slash COMMAND."
  (let* ((name (plist-get command :name))
         (desc (plist-get command :description))
         (input (plist-get command :input))
         (hint (plist-get input :hint)))
    (append (list (concat "/" name))
            (append (when hint (list :ann hint))
                    (when desc (list :desc desc))))))

(defun ellm-acp--insert-content (connection role content &optional message-id)
  "Insert ACP CONTENT as ROLE for CONNECTION.
MESSAGE-ID, when present, prevents chunks from distinct ACP messages from
being merged into the same ellm turn."
  (let ((text (ellm-acp--content-text content)))
    (when (and text (not (string-empty-p text)))
      (goto-char (point-max))
      (unless (ellm-acp--inside-open-message-p connection role message-id)
        (apply #'ellm--insert-turn
               role
               (append (when (ellm-acp--content-continuation-p role)
                         (list :continuation t))
                       (when message-id
                         (list :message-id message-id)))))
      (setf (ellm-acp--connection-last-message-key connection)
            (cons role message-id))
      (if (not (member role '("assistant" "reasoning")))
          (insert text)
        (let ((beg (copy-marker (point) nil))
              (escaped (ellm--escape-turn-delimiters-for-insertion
                        text (bolp))))
          (insert escaped)
          (let ((end (copy-marker (point) t)))
            (ellm--escape-turn-delimiters-in-region beg end)
            (set-marker end nil))
          (set-marker beg nil))))))

(defun ellm-acp--inside-open-message-p (connection role message-id)
  "Return non-nil when point is in ROLE's current ACP message."
  (and (ellm-acp--inside-open-role-p role)
       (or (not message-id)
           (let ((last-key
                  (ellm-acp--connection-last-message-key connection)))
             (if last-key
                 (and (equal (car last-key) role)
                      (equal (cdr last-key) message-id))
               (ellm-acp--last-turn-body-empty-p))))))

(defun ellm-acp--content-continuation-p (role)
  "Return non-nil when a new content turn for ROLE should be nested."
  (and (not (equal role "user"))
       (not (and (equal role "assistant")
                 (equal (ellm-acp--last-turn-role) "user")))))

(defun ellm-acp--inside-open-role-p (role)
  "Return non-nil if point is currently in an open turn with ROLE."
  (equal (ellm-acp--last-turn-role) role))

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

(defun ellm-acp--insert-tool-call (update &optional connection)
  "Insert ACP tool call UPDATE.
When CONNECTION is non-nil, remember marker ranges for incremental updates."
  (goto-char (point-max))
  (let* ((id (plist-get update :toolCallId))
         (state (ellm-acp--tool-state connection id))
         (title (or (and state (ellm-acp-rendered-tool-call-title state))
                    (plist-get update :title)))
         (details (ellm-acp--tool-call-details update state))
         (call-beg nil))
    (apply #'ellm--insert-turn "tool-call"
           (ellm-acp--tool-turn-attrs update :omit-status t :title title))
    (setq call-beg (save-excursion
                     (forward-line -1)
                     (point-marker)))
    (set-marker-insertion-type call-beg nil)
    (let ((params-beg (point-marker))
          (params-end nil))
      (set-marker-insertion-type params-beg nil)
      (ellm-acp--insert-tool-call-details details)
      (setq params-end (point-marker))
      (set-marker-insertion-type params-end nil)
      (when (and connection id)
        (unless state
          (setq state (ellm-acp--make-rendered-tool :id id))
          (puthash id state (ellm-acp--connection-rendered-tools connection)))
        (unless (ellm-acp-rendered-tool-call-title state)
          (setf (ellm-acp-rendered-tool-call-title state)
                (plist-get update :title)))
        (setf (ellm-acp-rendered-tool-call-beg state) call-beg)
        (setf (ellm-acp-rendered-tool-params-beg state) params-beg)
        (setf (ellm-acp-rendered-tool-params-end state) params-end)))
    (ellm--flush-pending-fold)))

(cl-defun ellm-acp--tool-turn-attrs (update &key omit-status omit-title title)
  "Return ellm turn attrs for ACP tool UPDATE."
  (append (unless omit-title
            (list :pipe-arg (or title (plist-get update :title) "ACP tool")))
          (when-let* ((id (plist-get update :toolCallId)))
            (list :id id))
          (when-let* ((kind (plist-get update :kind)))
            (list :kind kind))
          (when-let* ((status (and (not omit-status)
                                    (plist-get update :status))))
            (unless (member status '("pending" "in_progress"))
              (list :status status)))))

(defun ellm-acp--tool-result-title (title)
  "Return TITLE truncated to fit an ACP tool result heading."
  (and title (truncate-string-to-width title 25 nil nil "...")))

(defun ellm-acp--raw-input-params (raw-input)
  "Return RAW-INPUT as an alist suitable for `tool-param' turns."
  (cond
   ((null raw-input) nil)
   ((and (listp raw-input) (keywordp (car raw-input)))
     (cl-loop for (key value) on raw-input by #'cddr
              collect (cons (substring (symbol-name key) 1)
                            (ellm-acp--json-serializable-value value))))
   ((listp raw-input) raw-input)
   (t `((input . ,(ellm-acp--json-serializable-value raw-input))))))

(defun ellm-acp--json-plist-p (value)
  "Return non-nil when VALUE is a JSON object represented as a plist."
  (and (proper-list-p value)
       (zerop (mod (length value) 2))
       (cl-loop for (key _value) on value by #'cddr
                always (keywordp key))))

(defun ellm-acp--json-serializable-value (value)
  "Return VALUE with ACP JSON arrays converted for `json-serialize'.
ACP messages are parsed with `:array-type' `list', so nested arrays of
objects otherwise look like malformed plists to `json-serialize'."
  (cond
   ((vectorp value)
    (vconcat (mapcar #'ellm-acp--json-serializable-value value)))
   ((ellm-acp--json-plist-p value)
    (cl-loop for (key child) on value by #'cddr
             append (list key (ellm-acp--json-serializable-value child))))
   ((proper-list-p value)
    (vconcat (mapcar #'ellm-acp--json-serializable-value value)))
   (t value)))

(defun ellm-acp--normalized-tool-detail-limit ()
  "Return normalized `ellm-acp-tool-detail-limit'."
  (when (integerp ellm-acp-tool-detail-limit)
    (max 0 ellm-acp-tool-detail-limit)))

(defun ellm-acp--tool-summary-p ()
  "Return non-nil when ACP tools should render human-facing summaries."
  (eq ellm-acp-tool-detail-limit 'summary))

(defun ellm-acp--tool-details-enabled-p ()
  "Return non-nil when ACP tool detail bodies should be rendered."
  (not (equal (ellm-acp--normalized-tool-detail-limit) 0)))

(defun ellm-acp--limited-tool-detail-text (text)
  "Return TEXT capped by `ellm-acp-tool-detail-limit'."
  (let ((limit (ellm-acp--normalized-tool-detail-limit)))
    (cond
     ((null limit) text)
     ((zerop limit) "")
     ((<= (length text) limit) text)
     (t (concat (substring text 0 limit)
                (format "\n[... truncated %d chars]\n"
                        (- (length text) limit)))))))

(cl-defun ellm-acp--tool-result-detail-text (update &key skip-raw-input title state)
  "Return transformed and limited body text for ACP tool result UPDATE."
  (let ((text
         (ellm-acp--limited-tool-detail-text
          (ellm-tools--transform-tool-result
           (or title (plist-get update :title) 'ellm-acp-tool)
           (and (plist-member update :rawInput)
                (ellm-acp--raw-input-params (plist-get update :rawInput)))
           nil
           (if (ellm-acp--tool-summary-p)
               (ellm-acp--tool-summary-text update state)
             (ellm-acp--tool-update-text
              update :skip-raw-input skip-raw-input))))))
    (if (string-empty-p text) text (ellm--ensure-newline text))))

(defun ellm-acp--tool-call-details (update state)
  "Return display details for tool call UPDATE with rendered STATE."
  (if (ellm-acp--tool-summary-p)
      (when-let* ((title (plist-get update :title)))
        (and state
             (not (equal title (ellm-acp-rendered-tool-call-title state)))
             title))
    (and (ellm-acp--tool-details-enabled-p)
         (ellm-acp--raw-input-params (plist-get update :rawInput)))))

(defun ellm-acp--insert-tool-call-details (details)
  "Insert ACP tool call DETAILS at point."
  (if (ellm-acp--tool-summary-p)
      (when details
        (insert (ellm--ensure-newline
                 (ellm-tools--transform-tool-result
                  'ellm-acp-tool-title nil nil details))))
    (ellm-acp--insert-tool-params details)))

(defun ellm-acp--insert-tool-params (params)
  "Insert PARAMS as nested `tool-param' turns at point."
  (when (ellm-acp--tool-details-enabled-p)
    (dolist (param params)
      (unless (bolp) (insert "\n"))
      (insert (ellm--get-turn "tool-param"
                              :pipe-arg (format "%s" (car param)))
              "\n")
      (insert (ellm--ensure-newline
               (ellm-acp--limited-tool-detail-text
                (ellm-tools--transform-tool-result
                 'ellm-acp-tool-param (list param) nil
                 (ellm--format-tool-param-value (cdr param)))))))))

(defun ellm-acp--tool-state (connection id)
  "Return CONNECTION's rendered tool state for ID, or nil."
  (and connection id
       (gethash id (ellm-acp--connection-rendered-tools connection))))

(defun ellm-acp--marker-live-p (marker)
  "Return non-nil when MARKER points into a live buffer."
  (and (markerp marker) (marker-buffer marker)))

(defun ellm-acp--region-has-content-p (beg end)
  "Return non-nil when the region between BEG and END is non-whitespace."
  (save-excursion
    (goto-char beg)
    (re-search-forward "[^[:space:]]" end t)))

(defun ellm-acp--turn-folded-p (marker)
  "Return non-nil when the turn at MARKER has its own outline fold."
  (and (ellm-acp--marker-live-p marker)
       (eq (marker-buffer marker) (current-buffer))
       (save-excursion
         (goto-char marker)
         (beginning-of-line)
         (let ((heading-end (line-end-position)))
           (cl-some (lambda (overlay)
                      (and (= (overlay-start overlay) heading-end)
                           (eq (overlay-get overlay 'invisible) 'outline)))
                    (overlays-at heading-end))))))

(defun ellm-acp--marked-line-valid-p (marker role id)
  "Return non-nil when MARKER is on ROLE's delimiter with ID."
  (and (ellm-acp--marker-live-p marker)
       (eq (marker-buffer marker) (current-buffer))
       (save-excursion
         (goto-char marker)
         (beginning-of-line)
         (and (looking-at ellm-turn-regexp)
              (equal (match-string-no-properties 2) role)
              (equal (alist-get "id"
                                (ellm--parse-turn-attrs
                                 (match-string-no-properties 3))
                                nil nil #'equal)
                     id)))))

(defun ellm-acp--tool-call-state-valid-p (state)
  "Return non-nil when STATE still points at a rendered tool call."
  (and state
       (ellm-acp--marked-line-valid-p
        (ellm-acp-rendered-tool-call-beg state)
        "tool-call"
        (ellm-acp-rendered-tool-id state))
       (ellm-acp--marker-live-p (ellm-acp-rendered-tool-params-beg state))
       (ellm-acp--marker-live-p (ellm-acp-rendered-tool-params-end state))))

(defun ellm-acp--tool-result-state-valid-p (state)
  "Return non-nil when STATE still points at a rendered tool result."
  (and state
       (ellm-acp--marked-line-valid-p
        (ellm-acp-rendered-tool-result-beg state)
        "tool-result"
        (ellm-acp-rendered-tool-id state))
       (ellm-acp--marker-live-p (ellm-acp-rendered-tool-result-body-beg state))
       (ellm-acp--marker-live-p (ellm-acp-rendered-tool-result-end state))))

(defun ellm-acp--replace-region-with (beg end text)
  "Replace region BEG END with TEXT."
  (goto-char beg)
  (delete-region beg end)
  (insert text)
  (when (and (not (string-empty-p text))
             (not (bolp))
             (not (eobp)))
    (insert "\n"))
  (when (markerp end)
    (set-marker end (point))
    (set-marker-insertion-type end nil)))

(defun ellm-acp--update-tool-call-details (state details)
  "Replace STATE's rendered call details with DETAILS."
  (let* ((beg (ellm-acp-rendered-tool-params-beg state))
         (end (ellm-acp-rendered-tool-params-end state))
         (result-beg (ellm-acp-rendered-tool-result-beg state))
         (result-follows (and (ellm-acp--marker-live-p result-beg)
                              (= result-beg end)))
         (folded (ellm-acp--turn-folded-p
                  (ellm-acp-rendered-tool-call-beg state)))
         (had-content (ellm-acp--region-has-content-p beg end)))
    (goto-char beg)
    (delete-region beg end)
    (ellm-acp--insert-tool-call-details details)
    (when (and result-follows (not (bolp)))
      (insert "\n"))
    (set-marker (ellm-acp-rendered-tool-params-end state) (point))
    (set-marker-insertion-type (ellm-acp-rendered-tool-params-end state) nil)
    ;; Keep a result at the old boundary attached to its delimiter rather
    ;; than leaving its marker before the newly inserted parameters.
    (when result-follows
      (set-marker result-beg (point))
      (set-marker-insertion-type result-beg nil))
    (cond
     (folded
      (ellm--fold-subtree-at (ellm-acp-rendered-tool-call-beg state)))
     ((not had-content)
      (ellm--fold-turn-at
       (ellm-acp-rendered-tool-call-beg state) "tool-call")))))

(defun ellm-acp--upsert-tool-call-details (update connection)
  "Render UPDATE's display details on its live tool-call turn."
  (when-let* ((id (plist-get update :toolCallId)))
    (let* ((state (ellm-acp--tool-state connection id))
           (details (ellm-acp--tool-call-details update state)))
      (cond
       ((not (ellm-acp--tool-details-enabled-p))
        (unless (ellm-acp--tool-call-state-valid-p state)
          (ellm-acp--insert-tool-call update connection)))
       ((not (ellm-acp--tool-call-state-valid-p state))
        (ellm-acp--insert-tool-call update connection))
       (details
        (ellm-acp--update-tool-call-details state details))))))

(defun ellm-acp--replace-turn-header (marker role attrs)
  "Replace turn delimiter at MARKER with ROLE and ATTRS."
  (save-excursion
    (goto-char marker)
    (beginning-of-line)
    (delete-region (point) (line-end-position))
    (insert (apply #'ellm--get-turn role attrs))))

(defun ellm-acp--insert-tool-result (update connection &optional delete-existing)
  "Insert ACP tool result UPDATE and record marker state on CONNECTION."
  (let* ((id (plist-get update :toolCallId))
         (state (ellm-acp--tool-state connection id))
         (title (or (and state (ellm-acp-rendered-tool-result-title state))
                    (plist-get update :title)))
         (result-beg nil)
         (body-beg nil)
         (result-end nil))
    (when (and delete-existing id)
      (ellm-acp--delete-marked-turn "tool-result" "id" id))
    (goto-char (point-max))
    (apply #'ellm--insert-turn "tool-result"
           (ellm-acp--tool-turn-attrs
            update :title (ellm-acp--tool-result-title title)))
    (setq result-beg (save-excursion
                       (forward-line -1)
                       (point-marker)))
    (set-marker-insertion-type result-beg nil)
    (setq body-beg (point-marker))
    (set-marker-insertion-type body-beg nil)
    (when (and connection id (not state))
      (setq state (ellm-acp--make-rendered-tool :id id))
      (puthash id state (ellm-acp--connection-rendered-tools connection)))
    (when (ellm-acp--tool-details-enabled-p)
      (insert (ellm-acp--tool-result-detail-text
               update :skip-raw-input t :title title :state state)))
    (setq result-end (point-marker))
    (set-marker-insertion-type result-end nil)
    (when (and connection id)
      (unless (ellm-acp-rendered-tool-result-title state)
        (setf (ellm-acp-rendered-tool-result-title state)
              (plist-get update :title)))
      (setf (ellm-acp-rendered-tool-result-beg state) result-beg)
      (setf (ellm-acp-rendered-tool-result-body-beg state) body-beg)
      (setf (ellm-acp-rendered-tool-result-end state) result-end))
    (ellm--flush-pending-fold)))

(defun ellm-acp--update-tool-result (state update)
  "Update STATE's rendered result header and body from UPDATE."
  (let ((title (or (ellm-acp-rendered-tool-result-title state)
                   (plist-get update :title)))
        (folded (ellm-acp--turn-folded-p
                 (ellm-acp-rendered-tool-result-beg state)))
        (had-content
         (ellm-acp--region-has-content-p
          (ellm-acp-rendered-tool-result-body-beg state)
          (ellm-acp-rendered-tool-result-end state))))
    (unless (ellm-acp-rendered-tool-result-title state)
      (setf (ellm-acp-rendered-tool-result-title state)
            (plist-get update :title)))
    (ellm-acp--replace-turn-header
     (ellm-acp-rendered-tool-result-beg state)
     "tool-result"
     (ellm-acp--tool-turn-attrs
      update :title (ellm-acp--tool-result-title title)))
    (when (ellm-acp--tool-details-enabled-p)
      (ellm-acp--replace-region-with
       (ellm-acp-rendered-tool-result-body-beg state)
       (ellm-acp-rendered-tool-result-end state)
       (ellm-acp--tool-result-detail-text
        update :skip-raw-input t :title title :state state)))
    (cond
     (folded
      (ellm--fold-subtree-at (ellm-acp-rendered-tool-result-beg state)))
     ((not had-content)
      (ellm--fold-turn-at
       (ellm-acp-rendered-tool-result-beg state) "tool-result")))))

(defun ellm-acp--insert-tool-update (update &optional connection)
  "Insert or update ACP tool call UPDATE as live rendered turns."
  (when (if (ellm-acp--tool-summary-p)
            (plist-member update :title)
          (plist-member update :rawInput))
    (ellm-acp--upsert-tool-call-details update connection))
  (let* ((id (plist-get update :toolCallId))
         (state (ellm-acp--tool-state connection id)))
    (if (ellm-acp--tool-result-state-valid-p state)
        (ellm-acp--update-tool-result state update)
      (ellm-acp--insert-tool-result
       update connection
       (or (not state)
           (ellm-acp-rendered-tool-result-beg state))))))

(cl-defun ellm-acp--tool-update-text (update &key skip-raw-input)
  "Return Markdown text for ACP tool UPDATE.
When SKIP-RAW-INPUT is non-nil, omit `rawInput' because it is rendered as
nested `tool-param' turns."
  (let ((parts nil)
        (output (ellm-acp--tool-output-text update)))
    (if output
        (progn
          (when-let* ((locations (plist-get update :locations)))
            (push (ellm-acp--locations-text locations) parts))
          (push output parts))
      (when-let* ((locations (plist-get update :locations)))
        (push (ellm-acp--locations-text locations) parts))
      (unless skip-raw-input
        (when (plist-member update :rawInput)
          (push (ellm-acp--json-section "Raw input" (plist-get update :rawInput))
                parts))))
    (let ((text (string-join (nreverse (delq nil parts)) "\n")))
      (if (string-empty-p text)
          ""
        (ellm--ensure-newline text)))))

(defun ellm-acp--nonempty-string (value)
  "Return VALUE when it is a non-empty string."
  (and (stringp value)
       (not (string-empty-p value))
       value))

(defun ellm-acp--tool-output-text (update)
  "Return the best human-readable output text for tool UPDATE."
  (or (ellm-acp--tool-content-list-text (plist-get update :content))
      (and (plist-member update :rawOutput)
           (ellm-acp--raw-output-text (plist-get update :rawOutput)))
      (and (plist-member update :rawOutput)
           (ellm-acp--json-section "Raw output"
                                    (plist-get update :rawOutput)))))

(defun ellm-acp--raw-output-text (raw-output)
  "Return readable text from ACP RAW-OUTPUT, if present."
  (cond
   ((ellm-acp--nonempty-string raw-output))
   ((and (listp raw-output) (keywordp (car raw-output)))
    (or (ellm-acp--nonempty-string (plist-get raw-output :output))
        (when-let* ((metadata (plist-get raw-output :metadata)))
          (ellm-acp--nonempty-string (plist-get metadata :preview)))))))

(defun ellm-acp--tool-content-list-text (content)
  "Return readable text from ACP tool CONTENT list."
  (when-let* ((items (ellm-acp--sequence-list content)))
    (let ((parts nil))
      (dolist (item items)
        (when-let* ((text (ellm-acp--tool-content-text item)))
          (push text parts)))
      (ellm-acp--nonempty-string
       (string-join (nreverse parts) "\n")))))

(defun ellm-acp--tool-summary-text (update state)
  "Return regular human-facing content text from tool UPDATE and STATE."
  (if (not (plist-member update :content))
      (and state (ellm-acp-rendered-tool-result-summary state))
    (let (parts)
      (dolist (item (ellm-acp--sequence-list (plist-get update :content)))
        (when (equal (plist-get item :type) "content")
          (when-let* ((text (ellm-acp--content-text
                             (plist-get item :content))))
            (push text parts))))
      (let ((summary (ellm-acp--nonempty-string
                      (string-join (nreverse parts) "\n"))))
        (when state
          (setf (ellm-acp-rendered-tool-result-summary state) summary))
        summary))))

(defun ellm-acp--sequence-list (value)
  "Return VALUE as a list."
  (cond ((null value) nil)
        ((vectorp value) (append value nil))
        ((listp value) value)
        (t (list value))))

(defun ellm-acp--locations-text (locations)
  "Return Markdown text for ACP tool LOCATIONS."
  (let ((lines nil))
    (dolist (location (ellm-acp--sequence-list locations))
      (when-let* ((path (plist-get location :path)))
        (push (if-let* ((line (plist-get location :line)))
                  (format "- %s:%s" path line)
                (format "- %s" path))
              lines)))
    (when lines
      (concat "Locations:\n" (string-join (nreverse lines) "\n") "\n"))))

(defun ellm-acp--json-section (title value)
  "Return a fenced JSON section named TITLE for VALUE."
  (format "%s:\n```json\n%s\n```\n"
          title
          (json-serialize (ellm-acp--json-serializable-value value)
                          :false-object :json-false :null-object nil)))

(defun ellm-acp--tool-content-text (item)
  "Return Markdown text for ACP tool content ITEM."
  (pcase (plist-get item :type)
    ("content" (ellm-acp--content-text (plist-get item :content)))
    ("diff"
     (format "Diff: %s\nOld:\n```text\n%s\n```\nNew:\n```text\n%s\n```\n"
             (plist-get item :path)
             (if (plist-member item :oldText)
                 (or (plist-get item :oldText) "")
               "<new file>")
             (or (plist-get item :newText) "")))
    ("terminal"
     (format "Terminal: %s\n" (plist-get item :terminalId)))
    (_ nil)))

(defun ellm-acp--insert-plan (update)
  "Insert ACP plan UPDATE as the current plan reasoning block."
  (ellm-acp--delete-marked-turn "reasoning" "acp" "plan")
  (goto-char (point-max))
  (ellm--insert-turn "reasoning" :continuation t :acp "plan")
  (insert "Current ACP Plan:\n")
  (dolist (entry (plist-get update :entries))
    (insert (format "- [%s/%s] %s\n"
                    (plist-get entry :status)
                    (plist-get entry :priority)
                    (plist-get entry :content)))))

(defun ellm-acp--update-usage (update)
  "Store ACP usage UPDATE in `ellm-buffer-state' for header-line display."
  (setf (ellm-buffer-state-context-usage ellm-buffer-state)
        (plist-get update :used))
  (setf (ellm-buffer-state-context-size ellm-buffer-state)
        (plist-get update :size))
  (when (plist-member update :cost)
    (if-let* ((cost (plist-get update :cost)))
        (progn
          (setf (ellm-buffer-state-cost-amount ellm-buffer-state)
                (plist-get cost :amount))
          (setf (ellm-buffer-state-cost-currency ellm-buffer-state)
                (plist-get cost :currency)))
      (setf (ellm-buffer-state-cost-amount ellm-buffer-state) nil)
      (setf (ellm-buffer-state-cost-currency ellm-buffer-state) nil)))
  (force-mode-line-update))

(defun ellm-acp--delete-marked-turn (role attr value)
  "Delete the last ROLE turn whose ATTR equals VALUE.
If the matched turn has nested child turns, delete those children too."
  (let* ((turns (ellm--parse-turns))
         (pos (ellm-acp--marked-turn-position role attr value turns)))
    (when pos
      (let* ((turn (nth pos turns))
             (depth (or (ellm-turn-depth turn) 1))
             (end (ellm-turn-end turn))
             (rest (nthcdr (1+ pos) turns))
             (beg (save-excursion
                    (goto-char (ellm-turn-beg turn))
                    (forward-line -1)
                    (point))))
        (while (and rest (> (or (ellm-turn-depth (car rest)) 1) depth))
          (setq end (ellm-turn-end (car rest))
                rest (cdr rest)))
        (delete-region beg end)))))

(defun ellm-acp--marked-turn-position (role attr value &optional turns)
  "Return the position of the last ROLE turn whose ATTR equals VALUE."
  (cl-position-if
   (lambda (turn)
     (and (equal (ellm-turn-role turn) role)
          (equal (alist-get attr (ellm-turn-attrs turn) nil nil #'equal)
                 value)))
   (or turns (ellm--parse-turns))
   :from-end t))

(defun ellm-acp--finish-prompt (buffer)
  "Finish ACP prompt in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (ellm--preserve-user-position
        (goto-char (point-max))
        (unless (equal (ellm-acp--last-turn-role) "user")
          (ellm--insert-turn "user"))
        (ellm--set-active-request nil)
        (ellm--persistence-checkpoint)
        (ellm--notify-request-finished)))))

(defun ellm-acp--finish-with-error (buffer error-object)
  "Finish ACP request in BUFFER by signalling ERROR-OBJECT."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (ellm--set-active-request nil)
      (ellm--persistence-checkpoint)
      (ellm--notify-request-finished)))
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

;;;; Interactive helpers

(defun ellm-acp-set-config (connection option &optional on-ready on-error)
  "Interactively select and asynchronously set OPTION on CONNECTION.
Call ON-READY after applying the value, or ON-ERROR on failure."
  (interactive
   (let* ((connection (ellm-acp--buffer-connection (current-buffer)))
          (options (ellm-acp--connection-config-options connection))
          (selected (completing-read
                     "Option: "
                     (mapcar (lambda (option)
                               (or (plist-get option :name)
                                   (capitalize (plist-get option :id))))
                             options)))
          (option (seq-find
                   (lambda (option)
                     (string= selected
                              (or (plist-get option :name)
                                  (capitalize (plist-get option :id)))))
                   options)))
     (list connection option)))
  (unless (and connection option)
    (user-error "ellm ACP: no live session config option selected"))
  (let ((path (list 'acp 'config (intern (plist-get option :id))))
        (values (ellm-acp--config-option-value-candidates option)))
    (if (not values)
        (when on-ready
          (funcall on-ready))
      (let* ((buffer (current-buffer))
           (config-id (plist-get option :id))
           (current (and (plist-member option :currentValue)
                         (ellm-acp--config-value-label
                          (plist-get option :currentValue))))
           (saved-cell (ellm--alist-get-nested-cell
                        (ellm--parse-frontmatter) path))
           (default (if saved-cell
                        (ellm-acp--config-value-label (cdr saved-cell))
                      current))
           (value (completing-read
                   (ellm-acp--config-value-prompt option default current)
                   values nil t nil nil default))
           (name (or (plist-get option :name) config-id)))
      (message "ellm ACP: applying %s=%s..." name value)
      (ellm-acp--set-config-option
       connection config-id value
       (lambda ()
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (ellm--set-frontmatter-value path value)))
         (message "ellm ACP: %s set to %s" name value)
         (when on-ready
           (funcall on-ready)))
       (or on-error
           (lambda (error-object)
             (message "ellm ACP: failed to set %s: %s"
                      name (or (plist-get error-object :message)
                               error-object))))
       option)))))

(defun ellm-acp--config-value-label (value)
  "Return VALUE as a human-readable ACP config value."
  (cond
   ((eq value t) "true")
   ((ellm-acp--false-value-p value) "false")
   (t (ellm-acp--value-string value))))

(defun ellm-acp--config-value-prompt (option default current)
  "Return a value prompt for OPTION showing DEFAULT and CURRENT values."
  (let ((name (or (plist-get option :name)
                  (capitalize (plist-get option :id))))
        (details (delq nil
                       (list (and default (format "default: %s" default))
                             (and current (format "current: %s" current))))))
    (format "%s%s: " name
            (if details
                (format " (%s)" (string-join details ", "))
              ""))))

(provide 'ellm-acp)
;;; ellm-acp.el ends here
