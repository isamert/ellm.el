;;; ellm-mcp.el --- mcp.el integration for ellm  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.2
;; Package-Requires: ((emacs "29.1"))
;; Keywords: llm, tools

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Optional mcp.el integration for ellm's llm.el backend.

;;; Code:

(require 'cl-lib)
(require 'ellm)

(declare-function mcp-hub-get-all-tool "mcp-hub" (&rest args))
(declare-function mcp-hub-get-servers "mcp-hub" ())
(declare-function mcp-hub-start-all-server "mcp-hub" (&optional callback servers syncp))
(defvar mcp-hub-servers)

(defvar ellm-mcp-tools nil
  "MCP tools most recently registered by `ellm-register-mcp-tools'.")

(defun ellm-mcp--normalize-schema (schema)
  "Convert MCP JSON Schema types in SCHEMA to llm.el's representation.

mcp.el preserves JSON Schema type names as strings, whereas llm.el expects
symbols.  Types may occur in nested `:items' and `:properties' schemas too."
  (cond
   ((consp schema)
    (let ((normalized (mapcar #'ellm-mcp--normalize-schema schema)))
      (cl-loop for tail on normalized by #'cddr
               when (and (eq (car tail) :type)
                         (stringp (cadr tail)))
               do (setcar (cdr tail) (intern (cadr tail))))
      normalized))
   ((vectorp schema)
    (vconcat (mapcar #'ellm-mcp--normalize-schema schema)))
   (t schema)))

(defun ellm-mcp--tool-name (category name)
  "Return an exposed MCP tool name from CATEGORY and NAME.
MCP tool names use underscores instead of hyphens and slashes so providers
that require `^[a-zA-Z0-9_\\.-]+$' names can accept them."
  (replace-regexp-in-string "[-/]" "_" (format "%s_%s" category name)))

(defun ellm-mcp--make-tool (tool)
  "Convert mcp.el TOOL plist to an `ellm-tool'."
  (let* ((category (or (plist-get tool :category) "mcp"))
         (name (ellm-mcp--tool-name category (plist-get tool :name))))
    (ellm-make-tool
     :name name
     :description (plist-get tool :description)
     :args (ellm-mcp--normalize-schema (plist-get tool :args))
     :async (plist-get tool :async)
     :function (plist-get tool :function)
     :category category)))

(defconst ellm-mcp--connection-keys
  '(:command :args :url :env :token :headers :roots :timeout)
  "MCP server configuration keys accepted by `mcp-connect-server'.")

(defun ellm-mcp--require-hub ()
  "Load mcp.el's hub, or signal a useful error."
  (unless (and (fboundp 'mcp-hub-get-all-tool)
               (boundp 'mcp-hub-servers))
    (condition-case err
        (require 'mcp-hub)
      (file-missing
       (user-error "ellm MCP integration requires mcp.el: %s"
                   (error-message-string err))))))

(defun ellm-mcp--connection-config (config)
  "Return the mcp.el connection subset of MCP CONFIG."
  (cl-loop for key in ellm-mcp--connection-keys
           for value = (ellm--plistish-get config (intern (substring (symbol-name key) 1)))
           when value append (list key value)))

(defun ellm-mcp--hub-server (name)
  "Return NAME's configured mcp-hub server, if any."
  (cl-find name mcp-hub-servers
           :key (lambda (server) (ellm--mcp-server-name (car server)))
           :test #'equal))

(defun ellm-mcp--add-server (server)
  "Add resolved SERVER to `mcp-hub-servers' unless it is already configured."
  (let* ((name (ellm--mcp-server-name (car server)))
         (config (ellm-mcp--connection-config (cdr server)))
         (existing (ellm-mcp--hub-server name)))
    (if existing
        (unless (equal config (ellm-mcp--connection-config (cdr existing)))
          (warn "ellm: MCP server `%s' uses its existing mcp-hub configuration" name))
      (setq mcp-hub-servers
            (append mcp-hub-servers (list (cons name config)))))))

(defun ellm-mcp--connected-p (name)
  "Return non-nil when mcp-hub reports NAME as connected."
  (eq (plist-get (cl-find name (mcp-hub-get-servers)
                          :key (lambda (server) (plist-get server :name))
                          :test #'equal)
                 :status)
      'connected))

(defun ellm-mcp--ensure-servers (servers)
  "Synchronously connect resolved MCP SERVERS through mcp.el."
  (ellm-mcp--require-hub)
  (let ((names (mapcar (lambda (server) (ellm--mcp-server-name (car server)))
                       servers)))
    (dolist (server servers)
      (ellm-mcp--add-server server))
    (when names
      (mcp-hub-start-all-server nil names t)
      (dolist (name names)
        (unless (ellm-mcp--connected-p name)
          (user-error "ellm: MCP server `%s' did not connect" name))))))

(defun ellm-mcp--tools-for-servers (servers)
  "Return `ellm-tool' objects for connected resolved MCP SERVERS."
  (let ((categories
         (mapcar (lambda (server)
                   (format "mcp-%s" (ellm--mcp-server-name (car server))))
                 servers)))
    (mapcar #'ellm-mcp--make-tool
            (cl-remove-if-not
             (lambda (tool) (member (plist-get tool :category) categories))
             (mcp-hub-get-all-tool :asyncp t :categoryp t)))))

(defun ellm-mcp-session-tools (frontmatter)
  "Connect FRONTMATTER's MCP servers and return their tools.

The returned tools are scoped to the caller's session; this function does
not modify `ellm-tools-list'."
  (ellm-mcp--require-hub)
  (let ((servers (ellm--resolve-mcp-servers frontmatter)))
    (when servers
      (ellm-mcp--ensure-servers servers)
      (ellm-mcp--tools-for-servers servers))))

;;;###autoload
(defun ellm-register-mcp-tools ()
  "Refresh MCP tools registered in `ellm-tools-list'.

This obtains every tool from currently connected mcp.el servers through
`mcp-hub-get-all-tool'.  Start and connect servers with mcp.el first, then
call this command; call it again after an MCP reconnect or tool-list change.

Registered names are qualified by their `mcp-SERVER' category, for example
`mcp-filesystem/read_file', so tools from separate servers cannot collide.
This command is for manually exposing already connected tools globally;
normal llm.el sessions instead use their `mcp:' selection directly.

The mcp.el dependency is loaded only when this command is invoked.  Return
the newly registered `ellm-tool' objects."
  (interactive)
  (ellm-mcp--require-hub)
  (setq ellm-tools-list
        (cl-delete-if (lambda (tool) (memq tool ellm-mcp-tools))
                      ellm-tools-list))
  (setq ellm-mcp-tools
        (mapcar #'ellm-mcp--make-tool
                (mcp-hub-get-all-tool :asyncp t :categoryp t)))
  (setq ellm-tools-list (append ellm-tools-list ellm-mcp-tools))
  (when (called-interactively-p 'interactive)
    (message "ellm: registered %d MCP tool%s"
             (length ellm-mcp-tools)
             (if (= (length ellm-mcp-tools) 1) "" "s")))
  ellm-mcp-tools)

(provide 'ellm-mcp)
;;; ellm-mcp.el ends here
