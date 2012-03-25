;;; eproject-extras.el --- various utilities that make eproject more enjoyable

;; Copyright (C) 2009  Jonathan Rockway

;; Author: Jonathan Rockway <jon@jrock.us>
;; Keywords: eproject

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

;; Some of this stuff used to be in eproject "core", but it is a bit
;; bloated, and not strictly necessary.  So now it lives here, leaving
;; the eproject core pristine and minimal.

;;; User-visible commands:

;; eproject-find-file
;;
;; - easily visit another file in the current project

;; eproject-ibuffer
;;
;; - open an ibuffer with current project buffers (or other project if
;;   invoked with prefix arg)

;; eproject-kill-project-buffers
;;
;; - kill all of the current project's buffers (or other project if
;;   prefixed)

;; eproject-open-all-project-files
;;
;; - open all files in the current project (or other project if
;;   prefixed)

;; eproject-revisit-project
;;
;; - open the named project root, or a project file if prefixed


;;; Code:

(require 'eproject)
(require 'cl)
(require 'iswitchb)
(require 'ibuffer)
(require 'ibuf-ext)

;; support for visiting other project files
(defalias 'eproject-ifind-file 'eproject-find-file)  ;; ifind is deperecated

(defun eproject--shorten-filename (filename)
  "Use the function provided by the `:file-name-map' project attribute to shorten FILENAME in the context of the current project.

The default implementation just makes the filename relative to the project root."
  (cons (funcall (eproject-attribute :file-name-map)
                 (eproject-root)
                 (file-relative-name filename (eproject-root)))
        filename))

(defun eproject-find-file ()
  "Present the user with a list of files in the current project
to select from, open file when selected."
  (interactive)
  (find-file (eproject--icomplete-read-with-alist
              "Project file: "
              (mapcar #'eproject--shorten-filename (eproject-list-project-files)))))

(defun eproject--completing-read (prompt choices)
  "Use completing-read to do a completing read."
  (completing-read prompt choices nil t))

(defun eproject--icompleting-read (prompt choices)
  "Use iswitchb to do a completing read."
  (let ((iswitchb-make-buflist-hook
         (lambda ()
           (setq iswitchb-temp-buflist choices))))
    (unwind-protect
        (progn
          (when (not iswitchb-mode)
            (add-hook 'minibuffer-setup-hook 'iswitchb-minibuffer-setup))
          (iswitchb-read-buffer prompt nil t))
      (when (not iswitchb-mode)
        (remove-hook 'minibuffer-setup-hook 'iswitchb-minibuffer-setup)))))

(defun eproject--ido-completing-read (prompt choices)
  "Use ido to do a completing read."
  (ido-completing-read prompt choices nil t))

(defcustom eproject-completing-read-function
  #'eproject--icompleting-read
  "The function used to ask the user select a single file from a
list of files; used by `eproject-find-file'."
  :group 'eproject
  :type '(radio (function-item :doc "Use emacs' standard completing-read function."
                               eproject--completing-read)
                (function-item :doc "Use iswitchb's completing-read function."
                               eproject--icompleting-read)
                (function-item :doc "Use ido's completing-read function."
                               eproject--ido-completing-read)
                (function)))

(defun eproject--do-completing-read (&rest args)
  "Do a completing read with the user's favorite completing read function."
  (apply eproject-completing-read-function args))

(defun eproject--icomplete-read-with-alist (prompt alist)
  (let ((show (mapcar (lambda (x) (car x)) alist)))
    (cdr (assoc (eproject--do-completing-read prompt show) alist))))

(defun eproject--project-buffers ()
  "Return an alist mapping each project root to its open buffers."
  (let ((hash (make-hash-table :test 'equal)))
    (loop for (root attrs) in eproject-attributes-alist
          do (setf (gethash root hash) nil))
    (loop for (root . buf) in
          (delete-if #'not
              (mapcar (lambda (b) (ignore-errors (cons (eproject-root b) b)))
                      (buffer-list)))
          do (push buf (gethash root hash nil)))
    (loop for key being the hash-keys of hash
          collect (cons key (gethash key hash)))))

(defun* eproject--get-name-root-alist (&key live-only)
  (let ((buffers (eproject--project-buffers)))
    (when (null buffers)
      (error "No projects yet"))
    (loop for (root . attrs) in
          (remove-if-not (lambda (attrs)
                           (or (not live-only)
                               (cdr (assoc (car attrs) buffers))))
                     eproject-attributes-alist)
        collect (cons (getf attrs :name) root))))

(defun* eproject--read-project-name (&key live-only)
  (eproject--icomplete-read-with-alist
   "Project name: " (eproject--get-name-root-alist :live-only live-only)))

(defun* eproject--handle-root-prefix-arg (prefix &key live-only)
  (if (= prefix 4)
      (eproject--read-project-name :live-only live-only)
    (eproject-root)))

;; ibuffer support

(define-ibuffer-filter eproject-root
    "Filter buffers that have the provided eproject root"
  (:reader (read-directory-name "Project root: " (ignore-errors (eproject-root)))
   :description "project root")
  (with-current-buffer buf
    (equal (file-name-as-directory (expand-file-name qualifier))
           (ignore-errors (eproject-root)))))

(define-ibuffer-filter eproject
    "Filter buffers that have the provided eproject name"
  (:reader (eproject--do-completing-read "Project name: " eproject-project-names)
   :description "project name")
  (with-current-buffer buf
    (equal qualifier
           (ignore-errors (eproject-name)))))

(define-ibuffer-column eproject (:name "Project" :inline t)
  (ignore-errors (eproject-name)))

(defun eproject-ibuffer (prefix)
  "Open an IBuffer window showing all buffers in the current project, or named project if PREFIX arg is supplied."
  (interactive "p")
  (if (= prefix 4)
      (call-interactively #'eproject--ibuffer-byname)
    (ibuffer nil "*Project Buffers*"
             (list (cons 'eproject-root (eproject-root))))))

(defun eproject--ibuffer-byname (project-name)
  "Open an IBuffer window showing all buffers in the project named PROJECT-NAME."
  (interactive (list
                (eproject--do-completing-read
                 "Project name: " eproject-project-names)))
  (ibuffer nil (format "*%s Buffers*" project-name)
           (list (cons 'eproject project-name))))
;; helm support
(defun helm-eproject-get-files ()
  (let ((matcher (format "\\(?:%s\\)"
                         (reduce (lambda (a b) (concat a "\\|" b))
                                 (mapcar (lambda (f) (format "\\(?:%s\\)" f))
                                         (eproject-get-project-metadatum
                                          (eproject-type) :relevant-files))))))
    (eproject--search-directory-tree (eproject-root) matcher)))

(defvar helm-eproject-source
  '((name . "eproject")
    (init . (lambda ()
              (setq helm-eproject-last-buffer (current-buffer))))
    (type . file)
    (candidates . (lambda ()
                    (with-current-buffer helm-eproject-last-buffer (helm-eproject-get-files))))))

(defun helm-eproject ()
  "helps helm to use eproject to find a file"
  (interactive)
  (let ((helm-sources '(helm-eproject-source)) helm-samewindow)
    (helm nil nil nil nil nil "eproject")))
                                        ;(global-set-key [(control x) (f) ] 'helm-eproject) ;;customize so you can call it cleanly

;; extra macros

(defmacro* with-each-buffer-in-project
    ((binding &optional project-root)
     &body body)
  "Given a project root PROJECT-ROOT, finds each buffer visiting a file in that project, and executes BODY with each buffer bound to BINDING (and made current)."
  (declare (indent 2))
  `(progn
     (loop for ,binding in (cdr (assoc (or ,project-root (eproject-root))
                                           (eproject--project-buffers)))
           do
           (with-current-buffer ,binding
             ,@body))))

;; bulk management utils
(defun eproject-kill-project-buffers (prefix)
  "Kill every buffer in the current project, including the current buffer.

If PREFIX is specified, prompt for a project name and kill those
buffers instead."
  (interactive "p")
  (with-each-buffer-in-project
      (buf (eproject--handle-root-prefix-arg prefix :live-only t))
    (kill-buffer buf)))

(defun eproject-open-all-project-files (prefix)
  "Open every file in the same project.

If PREFIX arg is supplied, prompt for a project.  Otherwise,
assume the project of the current buffer."
  (interactive "p")
  (let ((total 0)
        (root (eproject--handle-root-prefix-arg prefix)))
    (message "Opening files...")
    (save-window-excursion
      (loop for file in (eproject-list-project-files root)
            do (progn (find-file file) (incf total))))
    (message "Opened %d files" total)))

;; project management

(defun eproject-project-root (project)
  "Given a PROJECT name, return the root directory."
  (let ((projects (eproject--get-name-root-alist)))
    (cdr (assoc project projects))))

(defun eproject-revisit-project (prefix)
  "Given a project name, visit the root directory.

If PREFIX arg is supplied, run `eproject-find-file'."
  (interactive "p")
  (let ((eproject-root (eproject--read-project-name))
        (eproject-mode t)) ;; XXX: very messy, needs rewrite
    (if (= prefix 4)
          (eproject-find-file)
      (find-file eproject-root))))

;; grep project files (contributed by Julian Snitow)

;; TODO: make the grep command customizeable; to use "Ack", for example
(defun eproject-grep (regexp)
  "Search all files in the current project for REGEXP."
  (interactive "sRegexp grep: ")
  (let* ((root (eproject-root))
         (default-directory root)
         (files (eproject-list-project-files-relative root)))
    (grep-compute-defaults)
    (lgrep regexp (combine-and-quote-strings files) root)))

(defcustom eproject-todo-expressions
  '("TODO" "XXX" "FIXME")
  "A list of tags for eproject-todo to search for when generating the project's TODO list."
  :group 'eproject
  :type 'list)

(defun eproject-todo ()
  "Display a project TODO list.

Customize `eproject-todo-expressions' to control what this function looks for."
  (interactive)
  ;; TODO: display output in a buffer called *<project>-TODO* instead of *grep*.
  (eproject-grep (regexp-opt eproject-todo-expressions)))

(defun eproject-eshell-cd-here (&optional look-in-invisible-buffers)
  "If there is an EShell buffer, cd to the project root in that buffer.

With the prefix arg LOOK-IN-INVISIBLE-BUFFERS looks in buffers that are not currently displayed."
  (interactive "p")
  (message "%s" look-in-invisible-buffers)
  (setq look-in-invisible-buffers (cond ((= look-in-invisible-buffers 4) t)))
  (message "%s" look-in-invisible-buffers)
  (let* ((root (eproject-root))
         (eshell-p (lambda (buf)
                     (with-current-buffer buf (eq major-mode 'eshell-mode))))
         (eshell-buffer (find-if eshell-p
                                 (if look-in-invisible-buffers
                                     (buffer-list)
                                   (mapcar (lambda (w) (window-buffer w))
                                           (window-list))))))

    (cond ((and (not eshell-buffer) look-in-invisible-buffers)
           (error "No EShell buffer!"))
          ((and (not eshell-buffer) (not look-in-invisible-buffers))
           (error "No visible EShell buffer; try re-running with the prefix arg"))
          (eshell-buffer
           (with-current-buffer eshell-buffer
             (goto-char (point-max))
             (eshell/cd root)
             (eshell-send-input nil t)
             eshell-buffer))))) ;; returns eshell-buf so you can focus
                                ;; the window if you want

(provide 'eproject-extras)
;;; eproject-extras.el ends here
