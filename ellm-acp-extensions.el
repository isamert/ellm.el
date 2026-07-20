;;; ellm-acp-extensions.el --- Built-in ACP extensions for ellm  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: llm, acp

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Built-in handlers for vendor-specific ACP methods and optional projections
;; of standard ACP updates into shared ellm UI state.

;;; Code:

(require 'cl-lib)
(require 'ellm)

(declare-function ellm-acp-call-with-buffer "ellm-acp" (connection function))
(declare-function ellm-acp-tool-call-title "ellm-acp" (connection tool-call-id))
(declare-function ellm-acp-extension-state-get "ellm-acp"
                  (connection namespace key &optional default))
(declare-function ellm-acp-extension-state-put "ellm-acp"
                  (connection namespace key value))
(declare-function ellm-acp-extension-state-remove "ellm-acp"
                  (connection namespace key))
(declare-function ellm-acp-extension-state-map "ellm-acp"
                  (connection namespace function))

(defun ellm-acp-extensions--update-todos (todos &optional merge)
  "Apply ACP TODOS to the current ellm buffer.
When MERGE is non-nil, merge items by id through `ellm-update-todos'.
Return a cons whose cdr is the resulting list, or nil for invalid input."
  (condition-case err
      (cons t (ellm-update-todos todos merge))
    (error
     (message "ellm ACP: ignored invalid todo update: %s"
              (error-message-string err))
     nil)))

;;;; Cursor

(defun ellm-acp-extensions--cursor-update-todos (connection params)
  "Apply Cursor todo notification PARAMS to CONNECTION's ellm buffer."
  (ellm-acp-call-with-buffer
   connection
   (lambda ()
     (ellm-acp-extensions--update-todos
      (plist-get params :todos)
      (eq (plist-get params :merge) t)))))

;;;; OpenCode

(defconst ellm-acp-extensions--opencode-todo-state 'opencode-todo
  "Extension state namespace for OpenCode todo tool calls.")

(cl-defstruct (ellm-acp-extensions--todo-call-state
               (:constructor ellm-acp-extensions--make-todo-call-state))
  "Optimistic state for one OpenCode todo tool call."
  before applied)

(defun ellm-acp-extensions--opencode-todo-tool-p (connection update)
  "Return non-nil when UPDATE is an OpenCode todo-write tool call."
  (let* ((id (plist-get update :toolCallId))
         (title (or (ellm-acp-tool-call-title connection id)
                    (plist-get update :title))))
    (and (stringp title)
         (equal (replace-regexp-in-string
                 "[^[:alnum:]]" "" (downcase title))
                "todowrite"))))

(defun ellm-acp-extensions--opencode-todo-result-p
    (connection update state)
  "Return non-nil when UPDATE carries an OpenCode todo result.
STATE is a prior optimistic transaction for the same tool call."
  (or state
      (ellm-acp-extensions--opencode-todo-tool-p connection update)
      (when-let* ((title (plist-get update :title)))
        (and (stringp title)
             (string-match-p "\\`[0-9]+ todos?\\'" (downcase title))))))

(defun ellm-acp-extensions--opencode-fail-todo-update
    (connection id state)
  "Discard optimistic todo update STATE for CONNECTION tool call ID."
  (when-let* ((before-cell (ellm-acp-extensions--todo-call-state-before state)))
    (let ((before (car before-cell))
          (applied (ellm-acp-extensions--todo-call-state-applied state)))
      (ellm-acp-extension-state-map
       connection ellm-acp-extensions--opencode-todo-state
       (lambda (other-id other)
         (when-let* ((other-before
                      (and (not (equal other-id id))
                           (ellm-acp-extensions--todo-call-state-before other))))
           (when (equal (car other-before) applied)
             (setf (ellm-acp-extensions--todo-call-state-before other)
                   (list (copy-tree before)))))))
      (when (equal (ellm-buffer-state-todos ellm-buffer-state) applied)
        (ellm-update-todos before))))
  (ellm-acp-extension-state-remove
   connection ellm-acp-extensions--opencode-todo-state id))

(defun ellm-acp-extensions--opencode-clear-todo-state (connection id)
  "Clear OpenCode todo transaction state for CONNECTION tool call ID."
  (ellm-acp-extension-state-remove
   connection ellm-acp-extensions--opencode-todo-state id))

(defun ellm-acp-extensions--opencode-update-todos (connection update)
  "Project OpenCode ACP tool UPDATE into the current ellm todo state."
  (let* ((id (plist-get update :toolCallId))
         (state (ellm-acp-extension-state-get
                 connection ellm-acp-extensions--opencode-todo-state id))
         (status (plist-get update :status))
         (raw-input (plist-get update :rawInput))
         (raw-output (plist-get update :rawOutput))
         (metadata (and (listp raw-output)
                        (plist-get raw-output :metadata)))
         (todo-tool-p
          (ellm-acp-extensions--opencode-todo-tool-p connection update))
         (todo-result-p
          (ellm-acp-extensions--opencode-todo-result-p
           connection update state)))
    (cond
     ((and (or todo-tool-p state)
           (member status '("failed" "cancelled")))
      (when state
        (ellm-acp-extensions--opencode-fail-todo-update
         connection id state)))
     ((and todo-result-p
           (listp metadata)
           (plist-member metadata :todos))
      (when (ellm-acp-extensions--update-todos (plist-get metadata :todos))
        (ellm-acp-extensions--opencode-clear-todo-state connection id)))
     ((and todo-result-p
           (listp raw-output)
           (plist-member raw-output :todos))
      (when (ellm-acp-extensions--update-todos (plist-get raw-output :todos))
        (ellm-acp-extensions--opencode-clear-todo-state connection id)))
     ((and todo-tool-p
           (listp raw-input)
           (plist-member raw-input :todos))
      (let ((before (copy-tree
                     (ellm-buffer-state-todos ellm-buffer-state))))
        (when-let* ((result
                     (ellm-acp-extensions--update-todos
                      (plist-get raw-input :todos))))
          (unless state
            (setq state (ellm-acp-extensions--make-todo-call-state))
            (ellm-acp-extension-state-put
             connection ellm-acp-extensions--opencode-todo-state id state))
          (unless (ellm-acp-extensions--todo-call-state-before state)
            (setf (ellm-acp-extensions--todo-call-state-before state)
                  (list before)))
          (setf (ellm-acp-extensions--todo-call-state-applied state)
                (copy-tree (cdr result)))
          (when (equal status "completed")
            (ellm-acp-extensions--opencode-clear-todo-state
             connection id))))))))

;;;; ACP Plan

(defun ellm-acp-extensions--update-plan-todos (update)
  "Project standard ACP plan UPDATE into the current ellm todo state."
  (ellm-acp-extensions--update-todos (plist-get update :entries)))

;;;; Dispatch

(defun ellm-acp-extensions-handle-notification (connection method params)
  "Handle built-in ACP extension METHOD with PARAMS for CONNECTION."
  (pcase method
    ('cursor/update_todos
     (ellm-acp-extensions--cursor-update-todos connection params)
     t)
    (_ nil)))

(defun ellm-acp-extensions-handle-session-update (connection update phase)
  "Handle built-in extension projections for ACP UPDATE during PHASE."
  (when (eq phase 'post-render)
    (pcase (plist-get update :sessionUpdate)
      ((or "tool_call" "tool_call_update")
       (ellm-acp-extensions--opencode-update-todos connection update))
      ("plan"
       (ellm-acp-extensions--update-plan-todos update))))
  nil)

(provide 'ellm-acp-extensions)
;;; ellm-acp-extensions.el ends here
