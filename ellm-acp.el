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

;; Stub backend for Agent Client Protocol providers.  The provider type and
;; generic methods are intentionally in place now so the real transport and
;; session implementation can be added without changing `ellm-send'.

;;; Code:

(require 'cl-lib)
(require 'ellm)

(cl-defstruct (ellm-acp-provider (:constructor ellm-make-acp-provider))
  "Provider configuration for an ACP agent process.
COMMAND is the executable used to start the ACP agent.  ARGS is a list of
command-line arguments.  ENV is an alist of environment overrides."
  command args env)

(cl-defstruct (ellm-acp-request (:constructor ellm-acp--make-request))
  "Active request handle for the ACP backend."
  process session-id request-id)

(cl-defmethod ellm-backend-send ((_provider ellm-acp-provider) _frontmatter buffer)
  "Stub ACP send implementation for BUFFER."
  (with-current-buffer buffer
    (insert (ellm--get-turn "assistant" :continuation t) "\n")
    (insert "ACP backend is not implemented yet.\n")
    (ellm--insert-turn "user"))
  nil)

(cl-defmethod ellm-backend-cancel ((request ellm-acp-request))
  "Stub ACP cancellation for REQUEST."
  (ignore request)
  (message "ellm: ACP backend cancellation is not implemented yet"))

(provide 'ellm-acp)
;;; ellm-acp.el ends here
