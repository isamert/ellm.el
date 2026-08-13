;;; ellm-mcp.el --- mcp.el integration for ellm  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.1
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

(defvar ellm-mcp-tools nil
  "MCP tools most recently registered by `ellm-register-mcp-tools'.")

(defun ellm-mcp--make-tool (tool)
  "Convert mcp.el TOOL plist to an `ellm-tool'."
  (let* ((category (or (plist-get tool :category) "mcp"))
         (name (format "%s--%s" category (plist-get tool :name))))
    (ellm-make-tool
     :name name
     :description (plist-get tool :description)
     :args (plist-get tool :args)
     :async (plist-get tool :async)
     :function (plist-get tool :function)
     :category category)))

;;;###autoload
(defun ellm-register-mcp-tools ()
  "Refresh MCP tools registered in `ellm-tools-list'.

This obtains every tool from currently connected mcp.el servers through
`mcp-hub-get-all-tool'.  Start and connect servers with mcp.el first, then
call this command; call it again after an MCP reconnect or tool-list change.

Registered names are prefixed with their `mcp-SERVER' category, for example
`mcp-filesystem--read_file', so tools from separate servers cannot collide.
Enable a server's tools in ellm frontmatter with `tools: [@mcp-SERVER]'.

The mcp.el dependency is loaded only when this command is invoked.  Return
the newly registered `ellm-tool' objects."
  (interactive)
  (unless (fboundp 'mcp-hub-get-all-tool)
    (condition-case err
        (require 'mcp-hub)
      (file-missing
       (user-error "ellm MCP integration requires mcp.el: %s"
                   (error-message-string err)))))
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
