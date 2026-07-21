;;; ellm-codex.el --- ChatGPT Codex provider for ellm  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (llm "0.31.1") (plz "0.9"))
;; Keywords: llm, codex

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; OAuth provider for using a ChatGPT Codex subscription through ellm.
;; Create a provider with `ellm-make-codex-provider', then authenticate with
;; `ellm-codex-login'.

;;; Code:

(require 'browse-url)
(require 'cl-lib)
(require 'json)
(require 'llm-openai)
(require 'llm-request-plz)
(require 'plz)
(require 'plz-event-source)
(require 'url-parse)
(require 'xdg)
(require 'ellm-llm)

(defgroup ellm-codex nil
  "ChatGPT Codex support for ellm."
  :group 'ellm)

(defcustom ellm-codex-auth-file
  (expand-file-name "ellm/codex-auth.json" (xdg-config-home))
  "File in which Codex OAuth credentials are stored.
The file contains refresh credentials and is written with mode 0600."
  :type 'file
  :group 'ellm-codex)

(defcustom ellm-codex-login-timeout 300
  "Seconds to wait for browser OAuth login to complete."
  :type 'integer
  :group 'ellm-codex)

(defconst ellm-codex--client-id "app_EMoamEEZ73f0CkXaXp7hrann")
(defconst ellm-codex--issuer "https://auth.openai.com")
(defconst ellm-codex--responses-url
  "https://chatgpt.com/backend-api/codex/responses")
(defconst ellm-codex--redirect-uri
  "http://localhost:1455/auth/callback")

(defconst ellm-codex--reasoning-efforts-5-6
  '(("low" :desc "Fast responses with lighter reasoning")
    ("medium" :desc "Balances speed and reasoning depth for everyday tasks")
    ("high" :desc "Greater reasoning depth for complex problems")
    ("xhigh" :desc "Extra high reasoning depth for complex problems")
    ("max" :desc "Maximum reasoning depth for the hardest problems")
    ("ultra" :desc "Maximum reasoning with automatic task delegation"))
  "Reasoning efforts advertised by the GPT-5.6 Codex model family.")

(defconst ellm-codex--reasoning-efforts-5-2
  '(("low" :desc "Balances speed with some reasoning; useful for straightforward queries and short explanations")
    ("medium" :desc "Provides a solid balance of reasoning depth and latency for general-purpose tasks")
    ("high" :desc "Maximizes reasoning depth for complex or ambiguous problems")
    ("xhigh" :desc "Extra high reasoning for complex problems"))
  "Reasoning efforts advertised by GPT-5.2.")

(defconst ellm-codex-model-catalog
  `(("gpt-5.6-sol"
     :ann "GPT-5.6-Sol"
     :desc "Latest frontier agentic coding model."
     :default "low"
     :efforts ,ellm-codex--reasoning-efforts-5-6)
    ("gpt-5.6-terra"
     :ann "GPT-5.6-Terra"
     :desc "Balanced agentic coding model for everyday work."
     :default "medium"
     :efforts ,ellm-codex--reasoning-efforts-5-6)
    ("gpt-5.6-luna"
     :ann "GPT-5.6-Luna"
     :desc "Fast and affordable agentic coding model."
     :default "medium"
     :efforts ,(seq-take ellm-codex--reasoning-efforts-5-6 5))
    ("gpt-5.5"
     :ann "GPT-5.5"
     :desc "Frontier model for complex coding, research, and real-world work."
     :default "medium"
     :efforts ,(seq-take ellm-codex--reasoning-efforts-5-6 4))
    ("gpt-5.2"
     :ann "GPT-5.2"
     :desc "Optimized for professional work and long-running agents."
     :default "medium"
     :efforts ,ellm-codex--reasoning-efforts-5-2))
  "Selectable ChatGPT Codex models and their reasoning metadata.
This mirrors the list-visible entries in Codex's bundled models catalog.")

(cl-defstruct (ellm-codex-provider
               (:include llm-openai (embedding-model nil))
               (:constructor ellm-codex--make-provider))
  "An `llm-openai' provider authenticated through a ChatGPT subscription."
  (auth-file ellm-codex-auth-file)
  access-token refresh-token id-token account-id expires-at)

(cl-defun ellm-make-codex-provider
    (&key (chat-model "gpt-5.6-sol")
          (auth-file ellm-codex-auth-file)
          default-chat-non-standard-params)
  "Return a ChatGPT Codex provider.
CHAT-MODEL is the Codex model and AUTH-FILE stores OAuth credentials.
DEFAULT-CHAT-NON-STANDARD-PARAMS become provider defaults for requests that do
not set those prompt fields."
  (ellm-codex--make-provider
   :chat-model chat-model
   :auth-file (expand-file-name auth-file)
   :default-chat-non-standard-params default-chat-non-standard-params))

(cl-defstruct (ellm-codex-request
               (:constructor ellm-codex--make-request))
  "A cancellable Codex request which may replace its process after refresh."
  process cancelled)

(cl-defmethod llm-cancel-request ((request ellm-codex-request))
  "Cancel REQUEST, including a request restarted after token refresh."
  (setf (ellm-codex-request-cancelled request) t)
  (when-let* ((process (ellm-codex-request-process request)))
    (when (process-live-p process)
      (llm-cancel-request process))))

;;;; OAuth storage and transport

(defun ellm-codex--json-parse (text)
  "Parse JSON TEXT into plists and vectors."
  (when (and text (not (string-empty-p text)))
    (json-parse-string text :object-type 'plist
                       :null-object nil :false-object :json-false)))

(defun ellm-codex--wrap-secret (secret)
  "Wrap SECRET in a function so printing a provider does not reveal it."
  (when secret
    (let ((symbol (make-symbol "ellm-codex-secret")))
      (put symbol 'ellm-codex-secret secret)
      (fset symbol (lambda () (get symbol 'ellm-codex-secret)))
      symbol)))

(defun ellm-codex--secret-value (secret)
  "Return the string hidden by SECRET's wrapper."
  (if (functionp secret) (funcall secret) secret))

(defun ellm-codex--plz-error-response (error)
  "Return the `plz-response' embedded in ERROR, if any."
  (when-let* ((data (seq-find #'plz-error-p error)))
    (plz-error-response data)))

(cl-defun ellm-codex--request
    (method url &key body (content-type "application/json"))
  "Send METHOD to URL and return (STATUS . parsed JSON).
BODY is a string and CONTENT-TYPE describes it.  HTTP errors are returned;
transport errors are signaled."
  (condition-case error
      (let ((response (plz method url
                           :headers `(("Content-Type" . ,content-type))
                           :body body :as 'response)))
        (cons (plz-response-status response)
              (ellm-codex--json-parse (plz-response-body response))))
    (plz-error
     (if-let* ((response (ellm-codex--plz-error-response error)))
         (cons (plz-response-status response)
               (ellm-codex--json-parse (plz-response-body response)))
       (signal (car error) (cdr error))))))

(defun ellm-codex--urlencode (value)
  "Return VALUE encoded for an application/x-www-form-urlencoded body."
  (url-hexify-string (format "%s" value)))

(defun ellm-codex--form (&rest pairs)
  "Encode alternating keys and values in PAIRS as an HTTP form."
  (mapconcat
   (lambda (pair)
     (format "%s=%s" (ellm-codex--urlencode (car pair))
             (ellm-codex--urlencode (cadr pair))))
   (seq-partition pairs 2) "&"))

(defun ellm-codex--jwt-claims (token)
  "Return the decoded claims plist from JWT TOKEN, or nil."
  (condition-case nil
      (let* ((part (nth 1 (split-string token "\\.")))
             (base64 (replace-regexp-in-string
                      "_" "/" (replace-regexp-in-string "-" "+" part)))
             (padding (% (- 4 (% (length base64) 4)) 4)))
        (ellm-codex--json-parse
         (decode-coding-string
          (base64-decode-string
           (concat base64 (make-string padding ?=)))
          'utf-8)))
    (error nil)))

(defun ellm-codex--account-id (id-token access-token)
  "Extract a ChatGPT account id from ID-TOKEN or ACCESS-TOKEN."
  (let* ((claims (or (ellm-codex--jwt-claims id-token)
                     (ellm-codex--jwt-claims access-token)))
         (auth (plist-get claims :https://api.openai.com/auth)))
    (or (plist-get claims :chatgpt_account_id)
        (and (listp auth) (plist-get auth :chatgpt_account_id)))))

(defun ellm-codex--read-auth-file (file)
  "Read a credential plist from FILE, or return nil."
  (when (file-readable-p file)
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents file)
          (ellm-codex--json-parse (buffer-string)))
      (error nil))))

(defun ellm-codex--write-auth-file (file auth)
  "Atomically write AUTH to FILE with private permissions."
  (let* ((directory (file-name-directory file))
         temporary)
    (make-directory directory t)
    (set-file-modes directory #o700)
    (setq temporary (make-temp-file (expand-file-name ".codex-auth-" directory)))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region (json-serialize auth :null-object nil
                                          :false-object :json-false)
                          nil temporary nil 'silent))
          (set-file-modes temporary #o600)
          (rename-file temporary file t)
          (set-file-modes file #o600))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

(defun ellm-codex--install-auth (provider response &optional previous)
  "Install token RESPONSE into PROVIDER and its auth file.
PREVIOUS supplies values omitted by a refresh response."
  (let* ((access-token (or (plist-get response :access_token)
                           (plist-get previous :access_token)))
         (refresh-token (or (plist-get response :refresh_token)
                            (plist-get previous :refresh_token)))
         (id-token (or (plist-get response :id_token)
                       (plist-get previous :id_token)))
         (expires-in (plist-get response :expires_in))
         (claims (ellm-codex--jwt-claims access-token))
         (expires-at (or (and expires-in (+ (float-time) expires-in))
                         (plist-get claims :exp)
                         (plist-get previous :expires_at)))
         (account-id (or (ellm-codex--account-id id-token access-token)
                         (plist-get previous :account_id)))
         (auth (list :access_token access-token
                     :refresh_token refresh-token
                     :id_token id-token
                     :account_id account-id
                     :expires_at expires-at)))
    (unless (and access-token refresh-token account-id)
      (error "Codex OAuth response did not contain usable credentials"))
    (setf (ellm-codex-provider-access-token provider)
          (ellm-codex--wrap-secret access-token)
          (ellm-codex-provider-refresh-token provider)
          (ellm-codex--wrap-secret refresh-token)
          (ellm-codex-provider-id-token provider)
          (ellm-codex--wrap-secret id-token)
          (ellm-codex-provider-account-id provider) account-id
          (ellm-codex-provider-expires-at provider) expires-at)
    (ellm-codex--write-auth-file
     (ellm-codex-provider-auth-file provider) auth)
    auth))

(defun ellm-codex--load-auth (provider)
  "Load PROVIDER's persisted OAuth credentials."
  (when-let* ((auth (ellm-codex--read-auth-file
                     (ellm-codex-provider-auth-file provider))))
    (setf (ellm-codex-provider-access-token provider)
          (ellm-codex--wrap-secret (plist-get auth :access_token))
          (ellm-codex-provider-refresh-token provider)
          (ellm-codex--wrap-secret (plist-get auth :refresh_token))
          (ellm-codex-provider-id-token provider)
          (ellm-codex--wrap-secret (plist-get auth :id_token))
          (ellm-codex-provider-account-id provider)
          (or (plist-get auth :account_id)
              (ellm-codex--account-id (plist-get auth :id_token)
                                      (plist-get auth :access_token)))
          (ellm-codex-provider-expires-at provider)
          (plist-get auth :expires_at))
    auth))

(defun ellm-codex--refresh-auth (provider &optional force)
  "Refresh PROVIDER's access token when near expiry or when FORCE is non-nil."
  (let* ((auth (or (ellm-codex--load-auth provider) (list)))
         (expires-at (ellm-codex-provider-expires-at provider)))
    (when (or force
              (and expires-at (< expires-at (+ (float-time) 60))))
      (unless (ellm-codex-provider-refresh-token provider)
        (signal 'llm-provider-unconfigured
                '("Run M-x ellm-codex-login to authenticate")))
      (pcase-let* ((body (ellm-codex--form
                          "grant_type" "refresh_token"
                          "client_id" ellm-codex--client-id
                          "refresh_token"
                          (ellm-codex--secret-value
                           (ellm-codex-provider-refresh-token provider))))
                   (`(,status . ,response)
                    (ellm-codex--request
                     'post (concat ellm-codex--issuer "/oauth/token")
                     :body body
                     :content-type "application/x-www-form-urlencoded")))
        (unless (<= 200 status 299)
          (error "Codex token refresh failed (HTTP %s): %s" status response))
        (ellm-codex--install-auth provider response auth)))))

(defun ellm-codex--provider (&optional provider)
  "Return PROVIDER or the first configured Codex provider."
  (or provider
      (seq-find
       #'ellm-codex-provider-p
       (mapcar (lambda (entry)
                 (ellm--provider-entry-provider (cdr entry)))
               ellm-provider-alist))
      (ellm-make-codex-provider)))

(defun ellm-codex--random-base64url (bytes)
  "Return BYTES random bytes encoded as unpadded base64url."
  (let ((openssl (or (executable-find "openssl")
                     (user-error "OpenSSL is required for Codex OAuth login")))
        random-bytes)
    (setq random-bytes
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (unless (zerop (call-process openssl nil t nil
                                         "rand" (number-to-string bytes)))
              (error "OpenSSL failed to generate OAuth randomness"))
            (buffer-string)))
    (replace-regexp-in-string
     "=+\\'" ""
     (replace-regexp-in-string
      "/" "_" (replace-regexp-in-string
               "+" "-" (base64-encode-string random-bytes t))))))

(defun ellm-codex--exchange-code (provider code verifier redirect-uri)
  "Exchange authorization CODE and VERIFIER, then configure PROVIDER."
  (pcase-let* ((body (ellm-codex--form
                      "grant_type" "authorization_code"
                      "code" code
                      "redirect_uri" redirect-uri
                      "client_id" ellm-codex--client-id
                      "code_verifier" verifier))
               (`(,status . ,response)
                (ellm-codex--request
                 'post (concat ellm-codex--issuer "/oauth/token")
                 :body body
                 :content-type "application/x-www-form-urlencoded")))
    (unless (<= 200 status 299)
      (error "Codex token exchange failed (HTTP %s): %s" status response))
    (ellm-codex--install-auth provider response)
    provider))

(defun ellm-codex--callback-params (line)
  "Return OAuth callback parameters parsed from HTTP request LINE."
  (if (string-match "\\`GET /auth/callback[?]\\([^ ]+\\) HTTP/" line)
      (url-parse-query-string (match-string 1 line))
    '(("error" "invalid_callback"))))

(defun ellm-codex--callback-filter (process chunk receive)
  "Accumulate HTTP CHUNK from PROCESS and pass callback params to RECEIVE."
  (let ((data (concat (or (process-get process 'ellm-codex-data) "") chunk)))
    (process-put process 'ellm-codex-data data)
    (when (string-match "\r?\n\r?\n" data)
      (let* ((line-end (string-match "\r?\n" data))
             (line (substring data 0 line-end))
             (params (ellm-codex--callback-params line)))
        (funcall receive params)
        (let* ((error-code (cadr (assoc "error" params)))
               (body (if error-code
                         "Codex sign-in failed. You may close this page."
                       "Codex sign-in complete. You may close this page.")))
          (process-send-string
           process
           (format (concat "HTTP/1.1 200 OK\r\nContent-Type: text/plain; "
                           "charset=utf-8\r\nContent-Length: %d\r\n"
                           "Connection: close\r\n\r\n%s")
                   (string-bytes body) body))
          (process-send-eof process))))))

(defun ellm-codex--browser-login (provider)
  "Authenticate PROVIDER with a browser and localhost callback."
  (let* ((verifier (ellm-codex--random-base64url 64))
         challenge
         (state (ellm-codex--random-base64url 32))
         (result nil)
         (deadline (+ (float-time) ellm-codex-login-timeout))
         server)
    (setq challenge
          (string-remove-suffix
           "="
           (replace-regexp-in-string
            "/" "_" (replace-regexp-in-string
                     "+" "-"
                     (base64-encode-string
                      (secure-hash 'sha256 verifier nil nil t) t)))))
    (setq server
          (make-network-process
           :name "ellm-codex-oauth" :server t :host 'local :service 1455
           :noquery t
           :filter (lambda (process chunk)
                     (ellm-codex--callback-filter
                      process chunk (lambda (params) (setq result params))))))
    (unwind-protect
        (progn
          (browse-url-firefox
           (concat
            ellm-codex--issuer "/oauth/authorize?"
            (ellm-codex--form
             "response_type" "code"
             "client_id" ellm-codex--client-id
             "redirect_uri" ellm-codex--redirect-uri
             "scope" (concat "openid profile email offline_access "
                             "api.connectors.read api.connectors.invoke")
             "code_challenge" challenge
             "code_challenge_method" "S256"
             "id_token_add_organizations" "true"
             "codex_cli_simplified_flow" "true"
             "state" state
             "originator" "ellm")))
          (message "Waiting for Codex browser sign-in...")
          (while (and (not result) (< (float-time) deadline))
            (accept-process-output nil 0.1))
          (unless result
            (error "Timed out waiting for Codex browser sign-in"))
          (when-let* ((oauth-error (cadr (assoc "error" result))))
            (error "Codex sign-in failed: %s" oauth-error))
          (unless (equal state (cadr (assoc "state" result)))
            (error "Codex OAuth state mismatch"))
          (ellm-codex--exchange-code
           provider (or (cadr (assoc "code" result))
                        (error "Codex callback omitted authorization code"))
           verifier ellm-codex--redirect-uri))
      (when (process-live-p server)
        (delete-process server)))))

(defun ellm-codex--device-login (provider)
  "Authenticate PROVIDER with Codex's device-code flow."
  (pcase-let* ((body (json-serialize (list :client_id ellm-codex--client-id)))
               (`(,status . ,response)
                (ellm-codex--request
                 'post (concat ellm-codex--issuer
                               "/api/accounts/deviceauth/usercode")
                 :body body)))
    (unless (<= 200 status 299)
      (error "Codex device login is unavailable (HTTP %s)" status))
    (let* ((device-id (plist-get response :device_auth_id))
           (user-code (or (plist-get response :user_code)
                          (plist-get response :usercode)))
           (interval (string-to-number
                      (format "%s" (or (plist-get response :interval) 5))))
           (deadline (+ (float-time) 900))
           code-response)
      (kill-new user-code)
      (browse-url-firefox (concat ellm-codex--issuer "/codex/device"))
      (message "Enter Codex device code %s (copied to kill ring)" user-code)
      (while (and (not code-response) (< (float-time) deadline))
        (pcase-let* ((poll-body
                      (json-serialize
                       (list :device_auth_id device-id :user_code user-code)))
                     (`(,poll-status . ,poll-response)
                      (ellm-codex--request
                       'post (concat ellm-codex--issuer
                                     "/api/accounts/deviceauth/token")
                       :body poll-body)))
          (cond
           ((<= 200 poll-status 299) (setq code-response poll-response))
           ((memq poll-status '(403 404)) (sleep-for (max interval 1)))
           (t (error "Codex device authorization failed (HTTP %s)"
                     poll-status)))))
      (unless code-response
        (error "Codex device authorization timed out"))
      (ellm-codex--exchange-code
       provider
       (plist-get code-response :authorization_code)
       (plist-get code-response :code_verifier)
       (concat ellm-codex--issuer "/deviceauth/callback")))))

;;;###autoload
(defun ellm-codex-login (&optional device provider)
  "Authenticate a Codex PROVIDER.
With prefix argument DEVICE, use device-code login instead of a localhost
browser callback.  Interactively, the first configured Codex provider is used."
  (interactive "P")
  (let ((provider (ellm-codex--provider provider)))
    (if device
        (ellm-codex--device-login provider)
      (ellm-codex--browser-login provider))
    (message "Codex sign-in complete")
    provider))

;;;###autoload
(defun ellm-codex-logout (&optional provider)
  "Delete OAuth credentials for PROVIDER."
  (interactive)
  (let* ((provider (ellm-codex--provider provider))
         (file (ellm-codex-provider-auth-file provider)))
    (when (file-exists-p file)
      (delete-file file))
    (setf (ellm-codex-provider-access-token provider) nil
          (ellm-codex-provider-refresh-token provider) nil
          (ellm-codex-provider-id-token provider) nil
          (ellm-codex-provider-account-id provider) nil
          (ellm-codex-provider-expires-at provider) nil)
    (message "Codex credentials removed")))

;;;; Provider implementation

(cl-defmethod llm-provider-request-prelude ((provider ellm-codex-provider))
  "Load and refresh PROVIDER credentials before a request."
  (ellm-codex--refresh-auth provider)
  (unless (and (ellm-codex-provider-access-token provider)
               (ellm-codex-provider-account-id provider))
    (signal 'llm-provider-unconfigured
            '("Run M-x ellm-codex-login to authenticate"))))

(cl-defmethod llm-provider-headers ((provider ellm-codex-provider))
  "Return ChatGPT backend headers for PROVIDER."
  `(("Authorization" . ,(concat "Bearer "
                                (ellm-codex--secret-value
                                 (ellm-codex-provider-access-token provider))))
    ("ChatGPT-Account-Id" . ,(ellm-codex-provider-account-id provider))
    ("OpenAI-Beta" . "responses=experimental")
    ("originator" . "ellm")
    ("User-Agent" . "ellm.el")))

(cl-defmethod llm-provider-chat-url ((_provider ellm-codex-provider))
  "Return the ChatGPT Codex Responses endpoint."
  ellm-codex--responses-url)

(cl-defmethod llm-name ((_provider ellm-codex-provider))
  "Return the display name of the Codex provider."
  "Codex")

(defun ellm-codex--model-metadata (model)
  "Return catalog metadata for MODEL, or nil."
  (cdr (assoc model ellm-codex-model-catalog)))

(cl-defmethod ellm-provider-model-candidates ((_provider ellm-codex-provider))
  "Return selectable Codex models with completion metadata."
  (mapcar (lambda (entry)
            (list (car entry)
                  :ann (plist-get (cdr entry) :ann)
                  :desc (plist-get (cdr entry) :desc)))
          ellm-codex-model-catalog))

(cl-defmethod ellm-provider-reasoning-candidates
  ((_provider ellm-codex-provider) model _buffer)
  "Return the reasoning efforts advertised for Codex MODEL."
  (copy-tree
   (or (plist-get (ellm-codex--model-metadata model) :efforts)
       (cl-delete-duplicates
        (mapcan (lambda (entry)
                  (copy-tree (plist-get (cdr entry) :efforts)))
                ellm-codex-model-catalog)
        :key #'car :test #'equal))))

(cl-defmethod llm-capabilities ((_provider ellm-codex-provider))
  "Return capabilities supported by the Codex Responses endpoint."
  '(streaming tool-use streaming-tool-use reasoning streaming-reasoning
              image-input))

(cl-defmethod llm-chat-token-limit ((_provider ellm-codex-provider))
  "Return a conservative Codex context limit."
  128000)

(defun ellm-codex--reasoning-parameter (provider prompt)
  "Return the Codex reasoning parameter for PROVIDER and PROMPT."
  (let* ((configured (llm-chat-prompt-reasoning prompt))
         (configured (and configured (format "%s" configured)))
         (default
          (or (plist-get
               (ellm-codex--model-metadata
                (llm-openai-chat-model provider))
               :default)
              "medium"))
         (effort (pcase configured
                   ((or 'nil "") default)
                   ("light" "low")
                   ("maximum" "xhigh")
                   (_ configured))))
    (list :effort effort :summary "auto")))

(defun ellm-codex--content-part (part role)
  "Serialize one PART of a message with ROLE."
  (if (llm-media-p part)
      (list :type "input_image"
            :image_url
            (concat "data:" (llm-media-mime-type part) ";base64,"
                    (base64-encode-string (llm-media-data part) t)))
    (list :type (if (eq role 'assistant) "output_text" "input_text")
          :text part)))

(defun ellm-codex--message (interaction)
  "Serialize a regular prompt INTERACTION for Codex."
  (let* ((role (llm-chat-prompt-interaction-role interaction))
         (content (llm-chat-prompt-interaction-content interaction))
         (parts (if (llm-multipart-p content)
                    (llm-multipart-parts content)
                  (list (or content "")))))
    (list :type "message" :role (symbol-name role)
          :content (vconcat
                    (mapcar (lambda (part)
                              (ellm-codex--content-part part role))
                            parts)))))

(defun ellm-codex--input (prompt)
  "Serialize PROMPT history into Codex Responses input items."
  (vconcat
   (mapcan
    (lambda (interaction)
      (let ((content (llm-chat-prompt-interaction-content interaction))
            (multi-turn
             (llm-chat-prompt-interaction-multi-turn-plist interaction)))
        (cond
         ((eq (llm-chat-prompt-interaction-role interaction) 'system) nil)
         ((plist-get multi-turn :ellm-codex-reasoning)
          (append
           (list (plist-get multi-turn :ellm-codex-reasoning))
           (when (and (stringp content) (not (string-empty-p content)))
             (list (ellm-codex--message interaction)))))
         ((llm-chat-prompt-interaction-tool-results interaction)
          (mapcar
           (lambda (result)
             (list :type "function_call_output"
                   :call_id (llm-chat-prompt-tool-result-call-id result)
                   :output (format "%s"
                                   (llm-chat-prompt-tool-result-result result))))
           (llm-chat-prompt-interaction-tool-results interaction)))
         ((and (consp content)
               (llm-provider-utils-tool-use-p (car content)))
          (mapcar
           (lambda (call)
             (list :type "function_call"
                   :call_id (llm-provider-utils-tool-use-id call)
                   :name (llm-provider-utils-tool-use-name call)
                   :arguments
                   (llm-provider-utils-json-serialize
                    (llm-provider-utils-tool-use-args call))))
           content))
         (t (list (ellm-codex--message interaction))))))
    (llm-chat-prompt-interactions prompt))))

(defun ellm-codex--instructions (prompt)
  "Return top-level instructions from PROMPT."
  (let ((instructions
         (delq nil
               (mapcar
                (lambda (interaction)
                  (when (eq (llm-chat-prompt-interaction-role interaction)
                            'system)
                    (llm-chat-prompt-interaction-content interaction)))
                (llm-chat-prompt-interactions prompt))))
        (context (llm-provider-utils-get-system-prompt prompt)))
    (string-join (append instructions
                         (and (not (string-empty-p context)) (list context)))
                 "\n\n")))

(cl-defmethod llm-provider-chat-request
  ((provider ellm-codex-provider) prompt streaming)
  "Build a Codex Responses request for PROVIDER and PROMPT.
STREAMING non-nil requests an event stream."
  (let* ((tools (llm-chat-prompt-tools prompt))
         (instructions (ellm-codex--instructions prompt))
         (request
          (append
           (list :model (llm-openai-chat-model provider)
                 :input (ellm-codex--input prompt)
                 :store :false
                 :stream (if streaming t :false)
                 :include ["reasoning.encrypted_content"]
                 :reasoning (ellm-codex--reasoning-parameter provider prompt))
           (when (not (string-empty-p instructions))
             (list :instructions instructions))
           (when tools
             (list
              :tools
              (vconcat
               (mapcar
                (lambda (tool)
                  (list :type "function"
                        :name (llm-tool-name tool)
                        :description (llm-tool-description tool)
                        :parameters
                        (llm-provider-utils-openai-arguments
                         (llm-tool-args tool))))
                tools))
              :tool_choice "auto"
              :parallel_tool_calls t)))))
    (llm-provider-merge-non-standard-params
     (llm-chat-prompt-non-standard-params prompt) request)))

(defun ellm-codex--event-json (event)
  "Parse the JSON data from EVENT."
  (when-let* ((data (plz-event-source-event-data event))
              ((stringp data)))
    (ellm-codex--json-parse data)))

(defun ellm-codex--stream-error-message (data)
  "Return a useful error message from streaming event DATA."
  (let* ((response (or (plist-get data :response) data))
         (error-data (or (plist-get response :error) response))
         (incomplete (plist-get response :incomplete_details)))
    (or (plist-get error-data :message)
        (plist-get error-data :code)
        (and incomplete
             (format "Codex response incomplete: %s"
                     (or (plist-get incomplete :reason) "unknown reason")))
        "Codex request failed")))

(cl-defmethod llm-provider-streaming-media-handler
  ((_provider ellm-codex-provider) receiver err-receiver)
  "Return a Codex Responses SSE handler.
The handler passes partial results to RECEIVER and errors to ERR-RECEIVER."
  (cons
   'text/event-stream
   (plz-event-source:text/event-stream
    :events
    `((response.completed
       . ,(lambda (event)
            (when-let* ((data (ellm-codex--event-json event))
                        (response (plist-get data :response)))
              (let ((usage (plist-get response :usage)))
                (funcall
                 receiver
                 (append
                  (list :ellm-codex-completed t)
                  (when usage
                    (list :input-tokens (plist-get usage :input_tokens)
                          :output-tokens
                          (plist-get usage :output_tokens)))))))))
      (response.output_text.delta
       . ,(lambda (event)
            (when-let* ((delta (plist-get (ellm-codex--event-json event)
                                          :delta)))
              (funcall receiver (list :text delta)))))
      (response.reasoning_summary_text.delta
       . ,(lambda (event)
            (when-let* ((delta (plist-get (ellm-codex--event-json event)
                                          :delta))
                        ((not (string-empty-p delta))))
              (funcall receiver (list :reasoning delta)))))
      (response.output_item.done
       . ,(lambda (event)
            (when-let* ((item (plist-get (ellm-codex--event-json event)
                                         :item)))
              (pcase (plist-get item :type)
                ("reasoning"
                 (when (plist-get item :encrypted_content)
                   (funcall receiver
                            (list :multi-turn
                                  (list :ellm-codex-reasoning item)))))
                ("function_call"
                 (funcall
                  receiver
                  (list
                   :tool-uses
                   (list
                    (make-llm-provider-utils-tool-use
                     :id (or (plist-get item :call_id)
                             (plist-get item :id))
                     :name (plist-get item :name)
                     :args (json-parse-string
                            (plist-get item :arguments)
                            :object-type 'alist))))))))))
      (response.incomplete
       . ,(lambda (event)
            (funcall err-receiver
                     (ellm-codex--stream-error-message
                      (ellm-codex--event-json event)))))
      (response.failed
       . ,(lambda (event)
            (funcall err-receiver
                     (ellm-codex--stream-error-message
                      (ellm-codex--event-json event)))))
      (error
       . ,(lambda (event)
            (when-let* ((data (ellm-codex--event-json event)))
              (funcall err-receiver
                       (ellm-codex--stream-error-message data)))))))))

(defun ellm-codex--insert-process-output (process output)
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

(defun ellm-codex--dispatch-sse-event (media-type type data)
  "Dispatch an SSE event with TYPE and DATA through MEDIA-TYPE."
  (when-let* ((handler (cdr (assq type (oref media-type events)))))
    (condition-case error
        (funcall handler (plz-event-source-event :type type :data data))
      (error
       (when-let* ((error-handler (cdr (assq 'error (oref media-type events)))))
         (funcall
          error-handler
          (plz-event-source-event
           :type 'error
           :data (json-serialize
                  (list :error
                        (list :message (error-message-string error)))))))))))

(defun ellm-codex--consume-sse (input media-type)
  "Dispatch complete SSE records from INPUT through MEDIA-TYPE.
Return bytes remaining after the last complete record."
  (while (string-match "\r?\n\r?\n" input)
    (let* ((record (decode-coding-string
                    (substring input 0 (match-beginning 0)) 'utf-8 t))
           (lines (split-string record "\r?\n"))
           (type (or (when-let* ((line (seq-find
                                        (lambda (line)
                                          (string-prefix-p "event:" line))
                                        lines)))
                       (intern (string-trim (substring line 6))))
                     'message))
           (data (string-join
                  (cl-loop for line in lines
                           when (string-prefix-p "data:" line)
                           collect (string-remove-prefix
                                    " " (substring line 5)))
                  "\n")))
      (setq input (substring input (match-end 0)))
      (unless (or (string-empty-p data) (equal data "[DONE]"))
        (ellm-codex--dispatch-sse-event media-type type data))))
  input)

(defun ellm-codex--stream-error (error on-error)
  "Translate a `plz' ERROR and call ON-ERROR like `llm-request-plz-async'."
  (cond
   ((plz-error-response error)
    (let* ((response (plz-error-response error))
           (status (plz-response-status response))
           (body (or (plz-response-body response) "")))
      (cond
       ((memq status '(401 403))
        (funcall on-error 'llm-request-authentication-error body))
       ((eq status 400)
        (funcall on-error 'llm-request-bad-request body))
       (t (funcall on-error 'llm-request-error body)))))
   ((plz-error-curl-error error)
    (let ((curl-error (plz-error-curl-error error)))
      (if (eq (car curl-error) 28)
          (funcall on-error 'llm-request-timeout (cdr curl-error))
        (funcall on-error 'llm-request-error
                 (format "curl error code %d: %s"
                         (car curl-error) (cdr curl-error))))))
   (t
    (funcall on-error 'llm-request-error
             (or (plz-error-message error) "Codex request failed")))))

(cl-defun ellm-codex--stream-request
    (url &key headers data on-success media-type on-error)
  "POST DATA to URL and dispatch SSE through MEDIA-TYPE.
HEADERS are added to the request.  ON-SUCCESS and ON-ERROR follow the callback
conventions of `llm-request-plz-async'.  Unlike `plz-media-type', this accepts
SSE responses whose server omits the Content-Type header."
  (let ((wire-input "")
        (sse-input "")
        stream-state
        (media-type (cdr media-type))
        (plz-curl-default-args (cons "--no-buffer" plz-curl-default-args)))
    (plz 'post url
         :headers (append headers '(("Content-Type" . "application/json")))
         :body (encode-coding-string (json-serialize data) 'utf-8)
         :as 'string
         :filter
         (lambda (process output)
           (ellm-codex--insert-process-output process output)
           (pcase stream-state
             ('streaming
              (setq sse-input
                    (ellm-codex--consume-sse
                     (concat sse-input output) media-type)))
             ('ignore nil)
             (_
              (setq wire-input (concat wire-input output))
              (let ((continue t))
                (while (and continue (string-match "\r?\n\r?\n" wire-input))
                  (let* ((end (match-end 0))
                         (header (substring wire-input 0 end))
                         (remaining (substring wire-input end))
                         (status
                          (and (string-match
                                "\\`HTTP/[^ ]+ \\([0-9]+\\)" header)
                               (string-to-number (match-string 1 header)))))
                    (setq wire-input remaining)
                    (cond
                     ((and status (<= 200 status 299)
                           (not (string-match-p "Connection established" header)))
                      (setq stream-state 'streaming
                            continue nil
                            sse-input
                            (ellm-codex--consume-sse remaining media-type)
                            wire-input ""))
                     ((or (and status (<= 100 status 199))
                          (and status (<= 300 status 399))
                          (string-match-p "Connection established" header)))
                     (t
                      (setq stream-state 'ignore
                            continue nil
                            wire-input "")))))))))
         :then (lambda (_body) (funcall on-success nil))
         :else (lambda (error) (ellm-codex--stream-error error on-error))
         :connect-timeout llm-request-plz-connect-timeout
         :timeout llm-request-plz-timeout
         :noquery t)))

(cl-defmethod llm-provider-collect-streaming-tool-uses
  ((_provider ellm-codex-provider) data)
  "Return already assembled Codex tool-use DATA."
  data)

(cl-defmethod ellm-provider-reasoning-state
  ((_provider ellm-codex-provider) result)
  "Extract a durable encrypted reasoning item from RESULT."
  (when-let* ((multi-turn (plist-get result :multi-turn))
              (item (plist-get multi-turn :ellm-codex-reasoning))
              ((equal (plist-get item :type) "reasoning"))
              ((stringp (plist-get item :encrypted_content))))
    (list :version 1 :provider "codex" :item item)))

(cl-defmethod ellm-provider-restore-reasoning
  ((_provider ellm-codex-provider) prompt summary state)
  "Restore encrypted reasoning STATE or human-readable SUMMARY into PROMPT."
  (if (and (equal (plist-get state :version) 1)
           (equal (plist-get state :provider) "codex")
           (let ((item (plist-get state :item)))
             (and (equal (plist-get item :type) "reasoning")
                  (stringp (plist-get item :encrypted_content)))))
      (setf (llm-chat-prompt-interactions prompt)
            (append
             (llm-chat-prompt-interactions prompt)
             (list
              (make-llm-chat-prompt-interaction
               :role 'assistant
               :multi-turn-plist
               (list :ellm-codex-reasoning (plist-get state :item))))))
    (unless (string-empty-p summary)
      (setf (llm-chat-prompt-interactions prompt)
            (append
             (llm-chat-prompt-interactions prompt)
             (list (make-llm-chat-prompt-interaction
                    :role 'assistant :content summary)))))))

(cl-defmethod llm-provider-populate-tool-uses
  ((_provider ellm-codex-provider) prompt tool-uses)
  "Record TOOL-USES in PROMPT with their Codex call ids."
  (llm-provider-utils-append-to-prompt prompt tool-uses nil nil 'assistant))

(cl-defmethod ellm-provider-config-effect
  ((_provider ellm-codex-provider) path _buffer)
  "Return when Codex configuration PATH takes effect."
  (when (member path '((system) (model) (reasoning) (tools) (cwd)))
    'next-send))

(cl-defmethod llm-chat-streaming
  ((provider ellm-codex-provider) prompt partial-callback response-callback
   error-callback &optional multi-output)
  "Stream PROVIDER's reply to PROMPT, refreshing authentication once.
PARTIAL-CALLBACK receives snapshots, RESPONSE-CALLBACK receives the completed
response, and ERROR-CALLBACK receives failures.  MULTI-OUTPUT has its standard
`llm-chat-streaming' meaning."
  (llm-provider-request-prelude provider)
  (let ((buffer (current-buffer))
        (request (ellm-codex--make-request))
        current-result stream-failed completed)
    (cl-labels
        ((send
           (retried)
           (unless (ellm-codex-request-cancelled request)
             (setf
              (ellm-codex-request-process request)
              (ellm-codex--stream-request
               (llm-provider-chat-streaming-url provider)
               :headers (llm-provider-headers provider)
               :data (llm-provider-chat-request provider prompt t)
               :media-type
               (llm-provider-streaming-media-handler
                provider
                (lambda (data)
                  (when (plist-get data :ellm-codex-completed)
                    (setq completed t
                          data (cl-loop for (key value) on data by #'cddr
                                        unless (eq key :ellm-codex-completed)
                                        append (list key value))))
                  (when data
                    (setq current-result
                          (llm-provider-utils-streaming-accumulate
                           current-result data))
                    (when (and partial-callback
                               (not (ellm-codex-request-cancelled request)))
                      (when-let* ((value (if multi-output current-result
                                           (plist-get current-result :text))))
                        (llm-provider-utils-callback-in-buffer
                         buffer partial-callback value)))))
                (lambda (message)
                  (setq stream-failed t)
                  (unless (ellm-codex-request-cancelled request)
                    (llm-provider-utils-callback-in-buffer
                     buffer error-callback 'error message))))
               :on-success
               (lambda (_data)
                 (unless (or stream-failed
                             (ellm-codex-request-cancelled request))
                   (with-current-buffer
                       (if (buffer-live-p buffer)
                           buffer
                         (generate-new-buffer " *ellm-codex-temp*" t))
                     (if (not completed)
                         (llm-provider-utils-callback-in-buffer
                          buffer error-callback 'error
                          "Codex stream ended before response.completed")
                       (when (and (plist-get current-result :tool-uses)
                                  (plist-get current-result :multi-turn)
                                  (not (plist-get current-result :text)))
                         (llm-provider-utils-append-to-prompt
                          prompt nil nil (plist-get current-result :multi-turn)
                          'assistant))
                       (llm-provider-utils-process-result
                        provider prompt current-result multi-output
                        (lambda (result)
                          (unless (ellm-codex-request-cancelled request)
                            (llm-provider-utils-callback-in-buffer
                             buffer response-callback result)))
                        (lambda (type message)
                          (unless (ellm-codex-request-cancelled request)
                            (llm-provider-utils-callback-in-buffer
                             buffer error-callback type message))))))))
               :on-error
               (lambda (type data)
                 (if (and (eq type 'llm-request-authentication-error)
                          (not retried)
                          (not (ellm-codex-request-cancelled request)))
                     (condition-case error
                         (progn
                           (ellm-codex--refresh-auth provider t)
                           (setq current-result nil
                                 stream-failed nil
                                 completed nil)
                           (send t))
                       (error
                        (unless (ellm-codex-request-cancelled request)
                          (llm-provider-utils-callback-in-buffer
                           buffer error-callback (car error)
                           (error-message-string error)))))
                   (unless (ellm-codex-request-cancelled request)
                     (llm-provider-utils-callback-in-buffer
                      buffer error-callback type
                      (if (stringp data) data (format "%s" data)))))))))))
      (send nil))
    request))

;;;; Footer

(provide 'ellm-codex)

;;; ellm-codex.el ends here
