;;; ellm-llm.el --- llm.el backend for ellm  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (llm "0.32.0"))
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
(require 'pp)
(require 'ellm)

(declare-function ellm-mcp-session-tools "ellm-mcp" (frontmatter))

;; `llm.el' signals `(not-implemented)' from generic fall-through methods
;; without registering it as an error symbol.
(unless (get 'not-implemented 'error-conditions)
  (define-error 'not-implemented "Operation is not implemented for this LLM provider"))

(defcustom ellm-llm-generate-title t
  "Whether the `llm.el' backend generates a title for new conversations.
Generation is a best-effort asynchronous request using only the first user
prompt.  It uses the provider entry's `:small-model' when configured, and
otherwise uses the current chat model."
  :type 'boolean
  :group 'ellm)

(defcustom ellm-llm-log-messages nil
  "If non-nil, log `llm.el' requests and responses per conversation.
Logs include final request bodies passed to the plz transport and parsed
results delivered to ellm.  Authentication headers are redacted, but prompts,
responses, tool arguments, and opaque reasoning state are not; enable this
only while debugging.  Log buffers grow without bound."
  :type 'boolean
  :group 'ellm)

(defcustom ellm-llm-trust-cumulative-partials t
  "Whether to trust `llm.el' multi-output partials to extend monotonically.
When non-nil, emit the suffix after the previous assistant length without
comparing the old and new strings.  This avoids quadratic work while streaming
long responses.  `llm-chat-streaming' documents multi-output partials as
cumulative snapshots, so this is the normal and fastest mode.

Set this to nil to validate every assistant partial with `string-prefix-p'.
A non-monotonic provider then falls back to snapshot rendering, at the cost of
work proportional to the accumulated response on every partial."
  :type 'boolean
  :group 'ellm)

(defcustom ellm-llm-log-buffer-name "*ellm-llm-log*"
  "Base name for per-conversation `llm.el' log buffers."
  :type 'string
  :group 'ellm)

(defconst ellm-llm--title-instruction
  "Create a concise 3-7 word title for the user's message. Use the message's language. Return only the title, without quotes, markdown, a 'Title:' prefix, or explanation.")

(cl-defstruct (ellm-llm-driver (:constructor ellm-llm--make-driver))
  "Protocol driver for one logical `llm.el' request."
  (provider nil
            :type t
            :documentation "The `llm.el' provider serving this request.")
  (buffer nil
          :type buffer
          :documentation "Conversation buffer from which the prompt was built.")
  (prompt nil
          :type llm-chat-prompt
          :documentation "Mutable prompt shared across recursive tool legs.")
  (raw nil
       :type t
       :documentation "Current cancellable transport handle, or nil.")
  (emit nil
        :type (or null function)
        :documentation "Core event sink installed for the current attempt.")
  (serial 0
          :type integer
          :documentation "Generation counter used to invalidate stale callbacks.")
  (leg 0
       :type integer
       :documentation "Tool-loop leg number used to identify cumulative streams.")
  (stream-channels nil
                   :type list
                   :documentation "Most recent cumulative partial channels for this leg.")
  (stream-reasoning-state-id nil
                             :type (or null string)
                             :documentation "Reasoning state ID rendered with the current stream snapshot.")
  (title-prompt nil
                :type (or null string)
                :documentation "First user prompt eligible for title generation.")
  (title-request nil
                 :type t
                 :documentation "Cancellable background title request, or nil.")
  (title-started nil
                 :type boolean
                 :documentation "Non-nil once title generation has been attempted.")
  (log-buffer nil
              :type (or null buffer)
              :documentation "Per-conversation diagnostic log buffer.")
  (tool-activity-timers nil
                        :type list
                        :documentation "Heartbeat timers for running llm.el tools."))

(defconst ellm-llm--turn-usage-attrs
  '((:input-tokens . "input-tokens")
    (:output-tokens . "output-tokens")
    (:cached-tokens . "cached-tokens")
    (:cache-write-tokens . "cache-write-tokens"))
  "Mapping from `llm.el' usage keys to assistant turn attributes.")

;;;; Logging

(defvar ellm-llm--transport-log-buffer nil
  "Log buffer for a dynamically scoped `llm.el' transport request.")

(defun ellm-llm--driver-log-buffer (driver)
  "Return DRIVER's diagnostic log buffer, creating it if needed."
  (or (and (buffer-live-p (ellm-llm-driver-log-buffer driver))
           (ellm-llm-driver-log-buffer driver))
      (let* ((source (ellm-llm-driver-buffer driver))
             (source-name (if (buffer-live-p source)
                              (buffer-name source)
                            "dead-buffer"))
             (buffer (generate-new-buffer
                      (format "%s<%s>" ellm-llm-log-buffer-name source-name))))
        (setf (ellm-llm-driver-log-buffer driver) buffer)
        buffer)))

(defun ellm-llm--log (buffer direction label value)
  "Append VALUE to BUFFER as a DIRECTION and LABEL log entry."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert (format "[%s] %s %s\n%s\n\n"
                      (format-time-string "%Y-%m-%d %H:%M:%S")
                      direction label
                      (pp-to-string value))))))

(defun ellm-llm--redact-headers (headers)
  "Return a copy of HEADERS with credentials redacted."
  (mapcar
   (lambda (header)
     (if (string-match-p
          "\\`\\(?:authorization\\|cookie\\|proxy-authorization\\|x-api-key\\)\\'"
          (downcase (format "%s" (car header))))
         (cons (car header) "<redacted>")
       (copy-tree header)))
   headers))

(defun ellm-llm--log-url (url)
  "Return URL with a query string redacted."
  (replace-regexp-in-string "[?].*\\'" "?<redacted>" url))

(defun ellm-llm--request-plz-advice (original url &rest args)
  "Log an `llm-request-plz-async' call before invoking ORIGINAL.
URL and ARGS are the transport request.  Response callbacks retain the log
buffer selected by the originating ellm request."
  (if (not (and ellm-llm-log-messages
                (buffer-live-p ellm-llm--transport-log-buffer)))
      (apply original url args)
    (let* ((log-buffer ellm-llm--transport-log-buffer)
           (safe-url (ellm-llm--log-url url))
           (on-success (plist-get args :on-success))
           (on-error (plist-get args :on-error)))
      (ellm-llm--log
       log-buffer "-->" safe-url
       (list :headers (ellm-llm--redact-headers (plist-get args :headers))
             :body (plist-get args :data)))
      (setq args
            (plist-put
             args :on-success
             (lambda (response)
               (ellm-llm--log log-buffer "<--" safe-url response)
               (when on-success
                 (funcall on-success response)))))
      (setq args
            (plist-put
             args :on-error
             (lambda (&rest error)
               (ellm-llm--log log-buffer "<!!" safe-url error)
               (when on-error
                 (apply on-error error)))))
      (apply original url args))))

;;;; Provider model cache

(defvar ellm-llm--provider-model-candidates
  (make-hash-table :test #'eq :weakness 'key)
  "Successfully discovered model lists keyed by llm.el provider objects.")

(defun ellm-llm--provider-model-candidates (provider)
  "Return cached or newly discovered model names for PROVIDER.
Only providers advertising `model-list' are queried.  Failed and empty
lookups are not cached so a later completion attempt can retry."
  (or (gethash provider ellm-llm--provider-model-candidates)
      (when (member 'model-list (llm-capabilities provider))
        (condition-case nil
            (when-let* ((models (llm-models provider)))
              (puthash provider models ellm-llm--provider-model-candidates)
              models)
          (error nil)))))

;;;; Interface implementation

(cl-defmethod ellm-backend-create ((provider llm-standard-chat-provider)
                                   frontmatter buffer)
  "Create a standard `llm.el' driver for BUFFER."
  (ellm-llm--backend-create provider frontmatter buffer))

(cl-defmethod ellm-backend-create (provider frontmatter buffer)
  "Fallback driver creation for direct `llm.el' PROVIDER objects."
  (ellm-llm--backend-create provider frontmatter buffer))

(cl-defmethod ellm-backend-cancel ((driver ellm-llm-driver))
  "Cancel DRIVER's active `llm.el' transport."
  (cl-incf (ellm-llm-driver-serial driver))
  (ellm-llm--cancel-tool-activity-timers driver)
  (when-let* ((raw (ellm-llm-driver-raw driver)))
    (llm-cancel-request raw)
    (setf (ellm-llm-driver-raw driver) nil)))

(cl-defmethod ellm-backend-render-event
  ((_driver ellm-llm-driver) event _request)
  "Render normalized llm.el tool and correction EVENT."
  (pcase (plist-get event :kind)
    ('tool-batch
     (ellm-llm--render-tool-uses
      (plist-get event :tool-uses)
      (plist-get event :tool-results)
      (plist-get event :call-ids)
      (plist-get event :tool-call-ids)))
    ('correction
     (ellm--insert-turn "assistant" :continuation t)
     (insert (ellm--ensure-newline (plist-get event :text))))))

(cl-defmethod ellm-backend-finish ((driver ellm-llm-driver) _outcome)
  "Release DRIVER's timers and transport reference."
  (cl-incf (ellm-llm-driver-serial driver))
  (ellm-llm--cancel-tool-activity-timers driver)
  (setf (ellm-llm-driver-raw driver) nil
        (ellm-llm-driver-emit driver) nil))

(cl-defmethod ellm-provider-current-model ((provider llm-standard-chat-provider))
  "Return PROVIDER's `llm.el' chat model name, or nil when unset."
  (ellm-llm--provider-current-model provider))

(cl-defmethod ellm-provider-model-candidates ((provider llm-standard-chat-provider))
  "Return model completion candidates for `llm.el' PROVIDER."
  (or (ellm-llm--provider-model-candidates provider)
      (and-let* ((model (ellm-llm--provider-current-model provider)))
        (list model))))

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

(cl-defmethod ellm-provider-reasoning-state
  ((provider llm-standard-chat-provider) result)
  "Return durable generic `llm.el' reasoning metadata from RESULT."
  (when-let* ((multi-turn (plist-get result :multi-turn)))
    (let ((state
           (list :version 1
                 :provider (symbol-name (type-of provider))
                 :multi-turn multi-turn)))
      (and (ignore-errors (ellm--reasoning-state-json state))
           state))))

(cl-defmethod ellm-provider-restore-reasoning
  ((provider llm-standard-chat-provider) prompt summary state)
  "Restore generic `llm.el' reasoning STATE or fall back to SUMMARY."
  (if (and (equal (plist-get state :version) 1)
           (equal (plist-get state :provider)
                  (symbol-name (type-of provider)))
           (plist-member state :multi-turn))
      (setf (llm-chat-prompt-interactions prompt)
            (append
             (llm-chat-prompt-interactions prompt)
             (list
              (make-llm-chat-prompt-interaction
               :role 'assistant
               :multi-turn-plist (plist-get state :multi-turn)))))
    (unless (string-empty-p summary)
      (setf (llm-chat-prompt-interactions prompt)
            (append
             (llm-chat-prompt-interactions prompt)
             (list (make-llm-chat-prompt-interaction
                    :role 'assistant :content summary)))))))

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
  (let* ((new-interactions
          (ellm-llm--interactions-after prompt previous-interaction))
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

(defun ellm-llm--interactions-after (prompt previous-interaction)
  "Return PROMPT interactions following PREVIOUS-INTERACTION.
Use object identity for the boundary because provider serializers may prepend
interactions while preparing a request."
  (let ((interactions (llm-chat-prompt-interactions prompt)))
    (if previous-interaction
        (cdr (memq previous-interaction interactions))
      interactions)))

(defun ellm-llm--new-prompt-tool-uses (prompt previous-interaction)
  "Return tool uses added to PROMPT after PREVIOUS-INTERACTION."
  (let* ((new-interactions
          (ellm-llm--interactions-after prompt previous-interaction))
         result)
    (dolist (interaction new-interactions)
      (let ((content (llm-chat-prompt-interaction-content interaction)))
        (when (and (consp content)
                   (cl-every #'llm-provider-utils-tool-use-p content))
          (setq result (append result content)))))
    result))

(defun ellm-llm--new-prompt-tool-results (prompt previous-interaction)
  "Return tool results appended to PROMPT after PREVIOUS-INTERACTION."
  (let (results)
    (dolist (interaction
             (ellm-llm--interactions-after prompt previous-interaction))
      (setq results
            (append results
                    (llm-chat-prompt-interaction-tool-results interaction))))
    results))

(defun ellm-llm--prompt-tool-result-pairs (tool-results)
  "Return TOOL-RESULTS as (TOOL-NAME . RESULT) pairs without reordering.

llm.el returns only successful entries in `:tool-results' when a tool batch
partially fails.  Its mutable prompt contains the complete set, including
model-facing failures.  Retaining that prompt order also makes persisted
transcripts replay identically to the immediate next request."
  (mapcar
   (lambda (result)
     (cons (llm-chat-prompt-tool-result-tool-name result)
           (llm-chat-prompt-tool-result-result result)))
   tool-results))

(defun ellm-llm--canonical-text (text)
  "Return TEXT with buffer-only boundary whitespace removed."
  (if (stringp text) (string-trim text) text))

(defun ellm-llm--tool-arg-spec (tool name)
  "Return TOOL's argument specification named NAME, or nil."
  (cl-find name (and tool
                     (if (llm-tool-p tool)
                         (llm-tool-args tool)
                       (ellm-tool-args tool)))
           :key (lambda (spec) (format "%s" (plist-get spec :name)))
           :test #'equal))

(defun ellm-llm--deserialize-tool-param (text spec)
  "Deserialize persisted tool parameter TEXT according to SPEC.
String parameters remain strings.  Invalid edited values also remain strings
so the provider can report a useful malformed-call error."
  (if (or (null spec) (eq (plist-get spec :type) 'string))
      text
    (condition-case nil
        (json-parse-string text :object-type 'alist
                           :array-type 'array
                           :null-object nil
                           :false-object :false)
      (error text))))

(defun ellm-llm--canonical-tool-param (tool name value)
  "Return VALUE as it will be reconstructed from TOOL parameter NAME."
  (let* ((spec (ellm-llm--tool-arg-spec tool name))
         (serialized (ellm--format-tool-param-value value))
         (transformed
          (ellm-tools--transform-tool-result
           (and tool (llm-tool-name tool))
           (list (cons (intern name) value)) nil serialized))
         (text (ellm-llm--canonical-text
                (ellm-tools--unescape-tool-body transformed))))
    (ellm-llm--deserialize-tool-param text spec)))

(defun ellm-llm--canonical-tool-result (result)
  "Return RESULT as it will be reconstructed from its serialized turn."
  (ellm-llm--canonical-text
   (ellm-tools--unescape-tool-body
    (ellm-tools--transform-tool-result
     (llm-chat-prompt-tool-result-tool-name result) nil nil
     (llm-chat-prompt-tool-result-result result)))))

(defun ellm-llm--canonicalize-new-interactions
    (prompt previous-interaction)
  "Canonicalize interactions appended to PROMPT after PREVIOUS-INTERACTION.
This makes an immediate tool-loop request byte-stable with the same history
reconstructed from the conversation buffer later."
  (dolist (interaction
           (ellm-llm--interactions-after prompt previous-interaction))
    (let ((content (llm-chat-prompt-interaction-content interaction)))
      (cond
       ((stringp content)
        (setf (llm-chat-prompt-interaction-content interaction)
              (ellm-llm--canonical-text content)))
       ((and (consp content)
             (cl-every #'llm-provider-utils-tool-use-p content))
        (dolist (tool-use content)
          (when-let* ((tool
                       (cl-find
                        (llm-provider-utils-tool-use-name tool-use)
                        (llm-chat-prompt-tools prompt)
                        :key #'llm-tool-name :test #'equal)))
            (dolist (arg (llm-provider-utils-tool-use-args tool-use))
              (setcdr arg
                      (ellm-llm--canonical-tool-param
                       tool (format "%s" (car arg)) (cdr arg)))))))))
    (dolist (result
             (llm-chat-prompt-interaction-tool-results interaction))
      (setf (llm-chat-prompt-tool-result-result result)
            (ellm-llm--canonical-tool-result result))))
  prompt)

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

(defun ellm-llm--tool-error-result (name error)
  "Return a model-facing result for tool NAME and ERROR."
  (format "Tool `%s' failed: %s"
          name
          (if (stringp error) error (error-message-string error))))

(defun ellm-llm--make-llm-tool (tool &optional request)
  "Convert backend-neutral ellm TOOL to a permission-aware `llm-tool'."
  (let ((name (ellm-tool-name tool))
        (function (ellm-tool-function tool))
        (async (ellm-tool-async tool)))
    ;; Every local tool is exposed asynchronously so an `ask' policy can wait
    ;; for a user decision without blocking Emacs.
    (llm-make-tool
     :name name
     :description (ellm-tool-description tool)
     :args (ellm-tool-args tool)
     :async t
     :function
     (lambda (callback &rest args)
       (let ((callback-called nil))
         (cl-labels
             ((finish (result)
                      ;; Misbehaving asynchronous tools must not append
                      ;; duplicate results or start multiple continuation
                      ;; legs by invoking their callback more than once.
                      (unless callback-called
                        (setq callback-called t)
                        (funcall callback result)))
              (tool-callback (&rest values)
                             (finish
                              (if (= (length values) 1)
                                  (car values)
                                (ellm-llm--tool-error-result
                                 name
                                 (format "callback returned %d values; expected one"
                                         (length values))))))
              (run ()
                   (condition-case err
                       (if async
                           (apply function #'tool-callback args)
                         (finish (apply function args)))
                     (error
                      ;; Errors raised downstream by the result callback are not
                      ;; failures of the tool and must not invoke it twice.
                      (if callback-called
                          (signal (car err) (cdr err))
                        (finish (ellm-llm--tool-error-result name err)))))))
           (ellm--authorize-tool-call
            request tool args
            (lambda (decision)
              (if (eq decision 'allow)
                  (run)
                (finish (format "Tool `%s` was denied by the user." name)))))))))))

(defun ellm-llm--resolve-tools (frontmatter request &optional mcp-tools)
  "Return FRONTMATTER and MCP tools converted to `llm-tool' objects."
  (mapcar (lambda (tool) (ellm-llm--make-llm-tool tool request))
          (append (ellm--resolve-tools frontmatter) mcp-tools)))

(defun ellm-llm--cancel-tool-activity-timers (driver)
  "Cancel heartbeat timers owned by DRIVER."
  (dolist (timer (ellm-llm-driver-tool-activity-timers driver))
    (cancel-timer timer))
  (setf (ellm-llm-driver-tool-activity-timers driver) nil))

(defun ellm-llm--tool-activity-start (driver)
  "Start emitting activity while an llm.el tool for DRIVER runs.
Return a function that stops the heartbeat."
  (let ((timeout (with-current-buffer (ellm-llm-driver-buffer driver)
                   ellm-request-timeout))
        (serial (ellm-llm-driver-serial driver))
        timer)
    (when timeout
      ;; llm.el invokes tools without reporting them until their callbacks
      ;; complete.  Keep the core's provider-idle watchdog alive meanwhile;
      ;; ellm-tools retains responsibility for the tool's own deadline.
      (ellm-llm--emit driver '(:type activity))
      (let ((interval (max 0.01 (/ (float timeout) 2))))
        (setq timer
              (run-at-time
               interval interval
               (lambda ()
                 (if (ellm-llm--driver-live-p driver serial)
                     (ellm-llm--emit driver '(:type activity))
                   (cancel-timer timer)
                   (setf (ellm-llm-driver-tool-activity-timers driver)
                         (delq timer
                               (ellm-llm-driver-tool-activity-timers driver)))))))
        (push timer (ellm-llm-driver-tool-activity-timers driver))))
    (lambda ()
      (when timer
        (cancel-timer timer)
        (setf (ellm-llm-driver-tool-activity-timers driver)
              (delq timer (ellm-llm-driver-tool-activity-timers driver)))))))

(defun ellm-llm--emit-tool-observation (driver observation)
  "Emit OBSERVATION as a non-rendering tool update for DRIVER."
  (ellm-llm--emit driver `(:type tool-update :observations (,observation))))

(defun ellm-llm--instrument-tool-activity (driver)
  "Make DRIVER's llm.el tools report their actual execution lifetime."
  (dolist (tool (llm-chat-prompt-tools (ellm-llm-driver-prompt driver)))
    (let ((function (llm-tool-function tool))
          (name (llm-tool-name tool)))
      (setf (llm-tool-function tool)
            (if (llm-tool-async tool)
                (lambda (callback &rest args)
                  (let ((stop (ellm-llm--tool-activity-start driver))
                        (finished nil))
                    (ellm-llm--emit-tool-observation
                     driver `(:type tool-call :name ,name :arguments ,args
                              :backend llm))
                    (cl-labels ((finish (outcome &optional result)
                                       (unless finished
                                         (setq finished t)
                                         (ellm-llm--emit-tool-observation
                                          driver
                                          `(:type tool-finished :name ,name
                                            :outcome ,outcome :result ,result
                                            :backend llm)))))
                      (condition-case err
                          (apply function
                                 (lambda (&rest values)
                                   (finish 'completed (car values))
                                   (unwind-protect
                                       (apply callback values)
                                     (funcall stop)))
                                 args)
                        (error
                         (finish 'failed (error-message-string err))
                         (funcall stop)
                         (signal (car err) (cdr err)))))))
              (lambda (&rest args)
                (let ((stop (ellm-llm--tool-activity-start driver)))
                  (ellm-llm--emit-tool-observation
                   driver `(:type tool-call :name ,name :arguments ,args
                            :backend llm))
                  (unwind-protect
                      (condition-case err
                          (let ((result (apply function args)))
                            (ellm-llm--emit-tool-observation
                             driver `(:type tool-finished :name ,name
                                      :outcome completed :result ,result
                                      :backend llm))
                            result)
                        (error
                         (ellm-llm--emit-tool-observation
                          driver `(:type tool-finished :name ,name
                                   :outcome failed :result ,(error-message-string err)
                                   :backend llm))
                         (signal (car err) (cdr err))))
                    (funcall stop)))))))))

(defun ellm-llm--collect-tool-call-args (tool-call-turn following-turns base-prompt)
  "Return (ARGS . TURNS-CONSUMED) for TOOL-CALL-TURN."
  (let* ((tool-name
          (alist-get "arg" (ellm-turn-attrs tool-call-turn)
                     nil nil #'equal))
         (tool
          (cl-find tool-name (llm-chat-prompt-tools base-prompt)
                   :key #'llm-tool-name :test #'equal))
         (params nil)
         (consumed 0)
         (rest following-turns))
    (while (and rest
                (let ((nx (car rest)))
                  (and (equal (ellm-turn-role nx) "tool-param")
                       (eql (ellm-turn-depth nx) 3))))
      (let* ((p (car rest))
             (pname (or (alist-get "arg" (ellm-turn-attrs p)
                                   nil nil #'equal)
                        "_"))
             (text (ellm-tools--unescape-tool-body
                    (ellm-turn-content p))))
        (push (cons (intern pname)
                    (ellm-llm--deserialize-tool-param
                     text (ellm-llm--tool-arg-spec tool pname)))
              params))
      (setq rest (cdr rest))
      (cl-incf consumed))
    (let ((args
           (cond
            (params (nreverse params))
            ((not (string-empty-p
                   (string-trim (ellm-turn-content tool-call-turn))))
             (let* ((tool
                     (or tool
                         (cl-find tool-name ellm-tools-list
                                  :key #'ellm-tool-name :test #'equal)))
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
                             (ellm-llm--deserialize-tool-param
                              (ellm-tools--unescape-tool-body
                               (ellm-turn-content tool-call-turn))
                              (ellm-llm--tool-arg-spec
                               tool arg-name)))))))
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
          (let ((content
                 (if (equal role "assistant")
                     (ellm--unescape-turn-delimiters
                      (ellm-turn-content turn))
                   (ellm-turn-content turn)))
                (previous
                 (car (last (llm-chat-prompt-interactions prompt)))))
            (if (and (equal role "assistant")
                     previous
                     (null (llm-chat-prompt-interaction-content previous))
                     (llm-chat-prompt-interaction-multi-turn-plist previous))
                (setf (llm-chat-prompt-interaction-content previous) content)
              (setf (llm-chat-prompt-interactions prompt)
                    (append
                     (llm-chat-prompt-interactions prompt)
                     (list (make-llm-chat-prompt-interaction
                            :role (intern role)
                            :content content))))))
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

(defun ellm-llm--tool-call-ids (tool-uses call-ids)
  "Return stable rendered IDs for TOOL-USES and provider CALL-IDS."
  (let ((provider-use-ids (car-safe call-ids)))
    (cl-loop for tool-use in tool-uses
             for index from 0
             for id = (or (plist-get tool-use :id)
                          (nth index provider-use-ids))
             collect (if (ellm-llm--persistable-call-id-p id)
                         id
                       (ellm-llm--gen-call-id)))))

(defun ellm-llm--render-tool-uses (tool-uses tool-results &optional call-ids ids)
  "Insert `tool-call' / `tool-result' turns for TOOL-USES and TOOL-RESULTS.
When `ellm-fold-tool-calls' is non-nil each inserted turn is folded.
CALL-IDS is an optional cons of provider tool-use and tool-result ID lists.
IDS, when non-nil, are the stable rendered IDs for TOOL-USES."
  (let* ((provider-result-ids (cdr-safe call-ids))
         (ids (or ids (ellm-llm--tool-call-ids tool-uses call-ids))))
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

;;;;; Title stuff

(defun ellm-llm--title-warning (format-string &rest args)
  "Report a title-generation warning using FORMAT-STRING and ARGS."
  (display-warning
   'ellm (concat "llm title generation: "
                 (apply #'format format-string args))
   :warning))

(defun ellm-llm--title-text (result)
  "Return a normalized title from llm.el RESULT, or nil."
  (when (listp result)
    (setq result (plist-get result :text)))
  (when (stringp result)
    (let* ((line (car (split-string (string-trim result) "[\r\n]+" t)))
           (title (and line
                       (string-trim
                        (replace-regexp-in-string
                         "\\`[Tt]itle:[[:space:]]*" "" line)
                        "[[:space:]\"'`]+" "[[:space:]\"'`]+"))))
      (when (and title (not (string-empty-p title)))
        (truncate-string-to-width title 100 nil nil t)))))

(defun ellm-llm--start-title-generation (driver)
  "Start best-effort title generation for DRIVER when eligible."
  (when (and ellm-llm-generate-title
             (with-current-buffer (ellm-llm-driver-buffer driver)
               ellm--session-titling-p)
             (not (ellm-llm-driver-title-started driver))
             (ellm-llm-driver-title-prompt driver))
    (setf (ellm-llm-driver-title-started driver) t)
    (let* ((provider (ellm-llm-driver-provider driver))
           (small-model (ellm-provider-small-model provider))
           (title-provider
            (if small-model
                (condition-case err
                    (ellm-provider-with-model provider small-model)
                  (error
                   (ellm-llm--title-warning
                    "cannot select small model %S; using chat model: %s"
                    small-model (error-message-string err))
                   provider))
              provider))
           (buffer (ellm-llm-driver-buffer driver))
           (prompt
            (make-llm-chat-prompt
             :context ellm-llm--title-instruction
             :interactions
             (list (make-llm-chat-prompt-interaction
                    :role 'user
                    :content (ellm-llm-driver-title-prompt driver))))))
      (condition-case err
          (setf
           (ellm-llm-driver-title-request driver)
           (let ((ellm-llm--transport-log-buffer
                  (and ellm-llm-log-messages
                       (ellm-llm--driver-log-buffer driver))))
             (llm-chat-streaming
              title-provider prompt #'ignore
              (lambda (result)
                (setf (ellm-llm-driver-title-request driver) nil)
                (if-let* ((title (ellm-llm--title-text result)))
                    (when (buffer-live-p buffer)
                      (with-current-buffer buffer
                        ;; A title set while this request was running wins.
                        (unless ellm--session-title
                          (condition-case err
                              (ellm-set-session-title title buffer)
                            (error
                             (ellm-llm--title-warning
                              "could not persist title: %s"
                              (error-message-string err)))))))
                  (ellm-llm--title-warning
                   "provider returned no usable title: %S" result)))
              (lambda (&rest error-data)
                (setf (ellm-llm-driver-title-request driver) nil)
                (ellm-llm--title-warning
                 "request failed: %s"
                 (mapconcat (lambda (value) (format "%S" value))
                            error-data " ")))
              'multi-output)))
        (error
         (ellm-llm--title-warning
          "could not start request: %s" (error-message-string err)))))))

;;;;; Parsing & sending

(defun ellm-llm--provider-with-model (provider model)
  "Return a copy of PROVIDER with its `chat-model' slot set to MODEL."
  (let ((copy (copy-sequence provider)))
    (condition-case nil
        (progn
          (setf (cl-struct-slot-value (type-of copy) 'chat-model copy) model)
          copy)
      (error provider))))

(defun ellm-llm--merge-leg-usage (usage result)
  "Return per-leg USAGE updated with numeric usage values from RESULT.
Streaming multi-output results are cumulative, so values from RESULT replace
earlier observations from the same request leg."
  (dolist (spec ellm-llm--turn-usage-attrs usage)
    (let* ((key (car spec))
           (value (plist-get result key)))
      (when (numberp value)
        (setq usage (plist-put usage key value))))))

(cl-defun ellm-llm--parse-buffer-as-chat
    (provider &optional (frontmatter (ellm--effective-frontmatter)) mcp-tools)
  "Build an `llm-chat-prompt' from the current buffer for PROVIDER.
FRONTMATTER, when supplied, is the already parsed YAML frontmatter alist."
  (let* ((fm          frontmatter)
         (system-state (ellm--resolve-system-prompts provider fm))
         (turns       (plist-get system-state :turns))
         (has-system  (plist-get system-state :leading))
         (system      (ellm-llm--canonical-text
                       (plist-get system-state :initial)))
         (reasoning   (alist-get 'reasoning fm))
         (tools       (ellm-llm--resolve-tools fm ellm--active-request mcp-tools))
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

(defun ellm-llm--retryable-error-p (type)
  "Return non-nil when an llm.el error TYPE is transient."
  (memq type '(llm-request-error llm-request-timeout)))

(defun ellm-llm--driver-live-p (driver serial)
  "Return non-nil when callbacks for DRIVER SERIAL are current."
  (= serial (ellm-llm-driver-serial driver)))

(defun ellm-llm--emit (driver event)
  "Emit EVENT from DRIVER when it has a live sink."
  (when-let* ((emit (ellm-llm-driver-emit driver)))
    (funcall emit event)))

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
    (let* ((call-ids (ellm-llm--new-prompt-tool-call-ids
                      prompt previous-interaction))
           (existing-results (ellm-llm--new-prompt-tool-results
                              prompt previous-interaction)))
      ;; llm.el 0.32.0 records an error result for every failed tool call
      ;; before invoking the error callback.  Reuse those results: appending
      ;; replacements here would duplicate their provider call IDs.
      (if existing-results
          (list
           (mapcar (lambda (use)
                     (list :id (llm-provider-utils-tool-use-id use)
                           :name (llm-provider-utils-tool-use-name use)
                           :args (llm-provider-utils-tool-use-args use)))
                   uses)
           (ellm-llm--prompt-tool-result-pairs existing-results)
           call-ids)
        ;; Keep a defensive fallback for providers that report malformed
        ;; calls without first adding their tool results to the prompt.
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
                (cons (nreverse ids) (nreverse ids))))))))

(defun ellm-llm--reset-stream (driver)
  "Forget cumulative partial state for DRIVER's next request leg."
  (setf (ellm-llm-driver-stream-channels driver) nil
        (ellm-llm-driver-stream-reasoning-state-id driver) nil))

(defun ellm-llm--stream-events (driver result reasoning-state-id)
  "Return normalized stream events for cumulative llm.el RESULT.

llm.el's partial results are snapshots.  Emit only their newly appended text
when the assistant channel extends its previous value.  Reasoning changes
remain snapshots because its turn precedes the assistant turn in the core's
ordered snapshot rendering.  A first partial, a shorter value, or changed
durable reasoning state emits a snapshot.  When
`ellm-llm-trust-cumulative-partials' is nil, revised assistant text also emits
a snapshot after prefix validation."
  (let* ((channels `((reasoning . ,(plist-get result :reasoning))
                     (assistant . ,(plist-get result :text))))
         (previous (ellm-llm-driver-stream-channels driver))
         (previous-state (ellm-llm-driver-stream-reasoning-state-id driver))
         (id (cons 'llm (ellm-llm-driver-leg driver)))
         (snapshot-p
          (or (null previous)
              (not (equal reasoning-state-id previous-state))
              ;; An append event can add only at buffer end, while reasoning
              ;; belongs before the assistant turn in a snapshot.
              (not (equal (alist-get 'reasoning channels)
                          (alist-get 'reasoning previous)))
              (let ((old (alist-get 'assistant previous))
                    (new (alist-get 'assistant channels)))
                (or (and new (not (stringp new)))
                    (and (stringp old)
                         (or (not (stringp new))
                             (if ellm-llm-trust-cumulative-partials
                                 (< (length new) (length old))
                               (not (string-prefix-p old new))))))))))
    (setf (ellm-llm-driver-stream-channels driver) channels
          (ellm-llm-driver-stream-reasoning-state-id driver) reasoning-state-id)
    (if snapshot-p
        (list `(:type stream :mode snapshot :id ,id
                :channels ,channels :reasoning-state ,reasoning-state-id))
      (delq nil
            (mapcar
             (lambda (entry)
               (let* ((channel (car entry))
                      (new (cdr entry))
                      (old (alist-get channel previous))
                      (delta (and (stringp new)
                                  (substring new (if (stringp old)
                                                     (length old) 0)))))
                 (and (stringp delta) (not (string-empty-p delta))
                      `(:type stream :mode append :id ,id
                        :channel ,channel :text ,delta
                        ,@(when (and (eq channel 'assistant)
                                     (stringp old)
                                     (not (string-suffix-p "\n" old)))
                            '(:join t))))))
             channels)))))

(defun ellm-llm--usage-event (provider usage)
  "Return a normalized usage event for PROVIDER from llm.el USAGE.
The latest leg's input tokens represent its context usage; the provider's
chat token limit supplies the corresponding context size when available."
  (let ((input-tokens (plist-get usage :input-tokens))
        (context-size (ignore-errors (llm-chat-token-limit provider))))
    (append
     (list :type 'usage)
     (cl-loop for key in '(:input-tokens :output-tokens :cached-tokens
                           :cache-write-tokens)
              when (plist-member usage key)
              append (list key (plist-get usage key)))
     (and (numberp input-tokens)
          (list :context-usage input-tokens))
     (and (numberp context-size) (> context-size 0)
          (list :context-size context-size)))))

(cl-defmethod ellm-backend-start ((driver ellm-llm-driver) emit)
  "Start or resume one llm.el leg and emit normalized events."
  (setf (ellm-llm-driver-emit driver) emit)
  ;; Each tool-loop leg has its own core stream region and cumulative result.
  (ellm-llm--reset-stream driver)
  (ellm-llm--start-title-generation driver)
  (let* ((serial (cl-incf (ellm-llm-driver-serial driver)))
         (provider (ellm-llm-driver-provider driver))
         (prompt (ellm-llm-driver-prompt driver))
         (previous-interaction
          (car (last (llm-chat-prompt-interactions prompt))))
         (log-buffer (and ellm-llm-log-messages
                          (ellm-llm--driver-log-buffer driver)))
         reasoning-state-id
         leg-usage)
    (when log-buffer
      (ellm-llm--log
       log-buffer "ellm --> llm.el" "prompt"
       (list :provider (type-of provider)
             :model (ellm-llm--provider-current-model provider)
             :prompt prompt)))
    (cl-labels
        ((live-p ()
                 (ellm-llm--driver-live-p driver serial))
         (partial (result)
                  (when (live-p)
                    (when log-buffer
                      (ellm-llm--log
                       log-buffer "llm.el --> ellm" "partial" result))
                    ;; The request timeout guards an unresponsive provider, not the
                    ;; total duration of an active stream.
                    (setq leg-usage
                          (ellm-llm--merge-leg-usage leg-usage result))
                    (when-let* ((state
                                 (ellm-provider-reasoning-state provider result)))
                      (setq reasoning-state-id
                            (ellm-reasoning-state-write state)))
                    (dolist (event (ellm-llm--stream-events
                                    driver result reasoning-state-id))
                      (ellm-llm--emit driver event))))
         (continue-with-tools (tool-uses tool-results call-ids)
                              (when (live-p)
                                (cl-incf (ellm-llm-driver-serial driver)))
                              (let ((tool-call-ids
                                     (ellm-llm--tool-call-ids tool-uses call-ids)))
                                (ellm-llm--emit
                                 driver
                                 `(:type tool-call :kind tool-batch
                                   :tool-uses ,tool-uses :tool-results ,tool-results
                                   :call-ids ,call-ids :tool-call-ids ,tool-call-ids)))
                              (ellm-llm--canonicalize-new-interactions
                               prompt previous-interaction)
                              (cl-incf (ellm-llm-driver-leg driver))
                              (ellm-llm--emit driver '(:type continue)))
         (final (result)
                (when (live-p)
                  (when log-buffer
                    (ellm-llm--log
                     log-buffer "llm.el --> ellm" "final" result))
                  (setf (ellm-llm-driver-raw driver) nil)
                  (partial result)
                  (when leg-usage
                    (ellm-llm--emit driver
                                    (ellm-llm--usage-event provider leg-usage)))
                  (if-let* ((tool-uses (plist-get result :tool-uses))
                            (call-ids (ellm-llm--new-prompt-tool-call-ids
                                       prompt previous-interaction)))
                      (continue-with-tools
                       tool-uses
                       (let ((prompt-results
                              (ellm-llm--new-prompt-tool-results
                               prompt previous-interaction)))
                         ;; llm.el 0.32.0 omits failed calls from RESULT's
                         ;; `:tool-results', but always records them in the
                         ;; prompt.  Rendering the complete prompt results
                         ;; preserves the one-result-per-call invariant.
                         (if prompt-results
                             (ellm-llm--prompt-tool-result-pairs prompt-results)
                           (plist-get result :tool-results)))
                       call-ids)
                    (progn
                      (cl-incf (ellm-llm-driver-serial driver))
                      (ellm-llm--emit driver '(:type complete))))))
         (fail (type message)
               (when (live-p)
                 (when log-buffer
                   (ellm-llm--log
                    log-buffer "llm.el --> ellm" "error"
                    (list :type type :message message)))
                 (setf (ellm-llm-driver-raw driver) nil)
                 (cl-incf (ellm-llm-driver-serial driver))
                 (if (ellm-llm--tool-call-error-p type)
                     (if-let* ((recovery
                                (ellm-llm--recover-tool-call-error
                                 provider prompt previous-interaction
                                 type message)))
                         (continue-with-tools
                          (nth 0 recovery) (nth 1 recovery) (nth 2 recovery))
                       (let ((correction
                              (format "Your previous tool call was malformed and \
could not be executed: %s. Retry it using an advertised tool and valid arguments."
                                      message)))
                         (setf (llm-chat-prompt-interactions prompt)
                               (append
                                (llm-chat-prompt-interactions prompt)
                                (list (make-llm-chat-prompt-interaction
                                       :role 'user :content correction))))
                         (ellm-llm--emit
                          driver
                          `(:type extension :kind correction :text ,correction))
                         (cl-incf (ellm-llm-driver-leg driver))
                         (ellm-llm--emit driver '(:type continue))))
                   (ellm-llm--emit
                    driver
                    `(:type failure :condition ,type :message ,message
                      :retryable ,(and (ellm-llm--retryable-error-p type) t)))))))
      (condition-case err
          (let ((raw
                 ;; Do not pass `ellm-request-timeout' to plz: its timeout is
                 ;; a total transfer deadline and would abort an active stream.
                 (let ((ellm-llm--transport-log-buffer log-buffer))
                   (llm-chat-streaming
                    provider prompt #'partial #'final #'fail 'multi-output))))
            (when (live-p)
              (setf (ellm-llm-driver-raw driver) raw)))
        (error
         (funcall #'fail (car err) (error-message-string err)))))
    (ellm-llm-driver-raw driver)))

(defun ellm-llm--backend-create (provider frontmatter buffer)
  "Create a normal `llm.el' backend driver for BUFFER."
  (with-current-buffer buffer
    (ellm--apply-working-directory frontmatter)
    (let* ((mcp-tools (when (or (alist-get 'mcp frontmatter)
                                    (alist-get 'mcp+ frontmatter))
                         (require 'ellm-mcp)
                         (ellm-mcp-session-tools frontmatter)))
           (prompt (ellm-llm--parse-buffer-as-chat provider frontmatter mcp-tools))
           (interactions (llm-chat-prompt-interactions prompt))
           (users (seq-filter
                   (lambda (interaction)
                     (eq (llm-chat-prompt-interaction-role interaction) 'user))
                   interactions))
           (assistants (seq-find
                        (lambda (interaction)
                          (eq (llm-chat-prompt-interaction-role interaction)
                              'assistant))
                        interactions))
           (first-user (and (= (length users) 1)
                            (not assistants)
                            (llm-chat-prompt-interaction-content (car users)))))
      (let ((driver
             (ellm-llm--make-driver
              :provider provider :buffer buffer :prompt prompt
              :title-prompt (and (stringp first-user)
                                 (not (alist-get 'title frontmatter))
                                 first-user))))
        (ellm-llm--instrument-tool-activity driver)
        driver))))

;;;; Footer

(unless (advice-member-p #'ellm-llm--request-plz-advice
                         'llm-request-plz-async)
  (advice-add 'llm-request-plz-async :around
              #'ellm-llm--request-plz-advice))

(provide 'ellm-llm)
;;; ellm-llm.el ends here
