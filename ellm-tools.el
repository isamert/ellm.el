;;; ellm-tools.el --- Tool definitions for ellm  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Isa Mert Gurbuz

;; Author: Isa Mert Gurbuz <isamertgurbuz@gmail.com>
;; URL: https://github.com/isamert/ellm.el
;; Version: 0.0.1
;; Package-Requires: ((emacs "25.2"))
;; Keywords: llm, tools

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

;; Some of the tools and ideas are taken from
;; skissue/llm-tool-collection and edited.

;;; Code:

(require 'llm)
(require 'ellm)

;;;; Customization

(defgroup ellm-tools nil
  "Settings for `ellm-tools'."
  :link '(url-link "https://github.com/isamert/ellm.el"))

;;;; Variables

(defvar ellm-tools-refs '()
  "List of all ellm tools definitions.
This contains a list of symbols that points to tool definition plists.
This is provided so that you can use these tools with `gptel-make-tool'
or `llm-make-tool' etc. via doing something like:

  (mapcar
    (lambda (tool) (apply #'gptel-make-tool (symbol-value tool)))
    ellm-tools-refs)")

(defvar ellm-tools-list '()
  "List of all ellm tool objects.")

;;;; `ellm-deftool' macro

(defun ellm-tools--normalize-name (s)
  (string-replace "-" "_" s))

(defmacro ellm-deftool (name specs arglist doc &rest body)
  (declare (indent 2))
  (pcase-let* ((`(,_category ,tool-name-def) (string-split (symbol-name name) "/"))
               (tool-name (ellm-tools--normalize-name tool-name-def))
               (const-sym (intern (format "ellm-tools/%s-tool" tool-name-def)))
               (lambda-args (mapcar #'car arglist))
               (async? (plist-get specs :async))
               (final-args (if async? `(callback ,@lambda-args) lambda-args)))
    `(progn
       (defconst ,const-sym
         (list :name ,tool-name
               :description ,doc
               :async ,async?
               :args ',(mapcar
                        (lambda (it)
                          (list :name (ellm-tools--normalize-name (symbol-name (nth 0 it)))
                                :type  (nth 2 it)
                                :description (nth 3 it)))
                        arglist)
               :function #',const-sym)
         ,(format "Tool definition plist for %s.\n%s" name doc))
       ,(if async?
            `(defun ,const-sym (callback ,@lambda-args)
               (let ((tool-args (list ,@lambda-args)))
                 (ellm-tools--tool-call-start-hook ',const-sym tool-args)
                 (cl-flet ((callback (raw-result)
                                     (let ((result (ellm-tools--transform-tool-result
                                                    tool-args ',const-sym raw-result)))
                                       (ellm-tools--tool-call-end-hook
                                        ',const-sym tool-args raw-result result)
                                       (funcall callback result))))
                   ,@body)))
          `(defun ,const-sym ,lambda-args
             (let ((tool-args (list ,@lambda-args)))
               (ellm-tools--tool-call-start-hook ',const-sym tool-args)
               (let* ((raw-result (progn ,@body))
                      (result (ellm-tools--transform-tool-result
                               tool-args ',const-sym raw-result)))
                 (ellm-tools--tool-call-end-hook
                  ',const-sym tool-args raw-result result)
                 result))))
       (cl-pushnew ',const-sym ellm-tools-refs)
       (setq ellm-tools-list
             (cl-remove-if (lambda (it) (equal (ellm-tool-name it) ,tool-name))
                           ellm-tools-list))
       (push (apply #'ellm-make-tool ,const-sym) ellm-tools-list))))

;;;; Tool lifecycle

(defun ellm-tools--tool-call-start-hook (hook args)
  (message "TODO: tool start hook"))

(defun ellm-tools--tool-call-end-hook (hook args raw result)
  (message "TODO: tool start hook"))

(defun ellm-tools--transform-tool-result (hook args raw)
  ""
  (message "TODO: tool result transformer")
  (car (last args)))

;;;; Tools


;;;; Footer

(provide 'ellm-tools)
;;; ellm-tools.el ends here
