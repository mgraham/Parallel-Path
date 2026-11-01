;;; parallel-path-projectile.el --- Projectile integration for parallel-path -*- lexical-binding: t -*-

;; Copyright (C) 2026 Michael Graham

;; Author: Michael Graham
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (parallel-path "0.1.0") (projectile "2.6.0"))
;; Keywords: files, project, navigation
;; URL: https://github.com/mgraham/parallel-path

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Projectile integration for parallel-path.  Provides two commands:
;;
;; `parallel-path-projectile-toggle-test'
;;   Toggle between implementation and test files/directories using
;;   projectile's project-type-aware mapping.  This extends projectile's
;;   own `projectile-toggle-between-implementation-and-test' to also work
;;   in dired buffers — the gap that motivated this package.
;;
;;   In a file buffer: delegates entirely to
;;   `projectile-find-implementation-or-test', so all projectile project
;;   types, custom suffixes/prefixes, and :file-kinds definitions work
;;   unchanged.
;;
;;   In a dired buffer: calls `projectile--test-to-impl-dir' or
;;   `projectile--impl-to-test-dir' — functions that already exist in
;;   projectile but are not exposed via any dired command.
;;
;; `parallel-path-projectile-switch-worktree'
;;   Switch to the same relative path in another git worktree, chosen via
;;   `completing-read'.  Uses `projectile-project-worktrees' to discover
;;   all worktrees for the current project (including linked worktrees
;;   and Jujutsu workspaces), then applies `parallel-path--apply-root'
;;   to compute the counterpart path.
;;
;; Usage:
;;
;;   (require 'parallel-path-projectile)
;;
;;   ;; Projectile-aware test toggle (buffer + dired)
;;   (keymap-set global-map "C-c t" #'parallel-path-projectile-toggle-test)
;;
;;   ;; Worktree switch with completing-read
;;   (keymap-set global-map "C-c w" #'parallel-path-projectile-switch-worktree)
;;
;; PR note: `parallel-path-projectile-toggle-test' for dired is a natural
;; candidate to contribute back to projectile as an extension of
;; `projectile-toggle-between-implementation-and-test'.

;;; Code:

(require 'parallel-path)
(require 'projectile)

;; Declare projectile internals we call directly.  These are not part of
;; projectile's documented public API but are stable in practice.
(declare-function projectile-find-implementation-or-test   "projectile" (file-name))
(declare-function projectile--impl-to-test-dir             "projectile" (impl-dir-path))
(declare-function projectile--test-to-impl-dir             "projectile" (test-dir-path))
(declare-function projectile-project-root                  "projectile" (&optional dir))
(declare-function projectile-project-worktrees             "projectile" (&optional project-root))
(declare-function projectile-test-directory                "projectile" (project-type))
(declare-function projectile-project-type                  "projectile" (&optional dir))

;;;; Test toggle

;;;###autoload
(defun parallel-path-projectile-toggle-test (&optional other-window)
  "Toggle between implementation and test using projectile's mapping.

In a file buffer: delegates to `projectile-find-implementation-or-test',
giving full access to projectile's project-type-specific suffix/prefix
rules, custom :file-kinds definitions, and missing-file creation.

In a dired buffer: uses `projectile--test-to-impl-dir' and
`projectile--impl-to-test-dir' to map the current directory — the
capability that projectile itself does not expose via any dired command.

When OTHER-WINDOW is non-nil open in another window."
  (interactive)
  (if (derived-mode-p 'dired-mode)
      (parallel-path-projectile--toggle-dired other-window)
    (parallel-path-projectile--toggle-buffer other-window)))

;;;###autoload
(defun parallel-path-projectile-toggle-test-other-window ()
  "Like `parallel-path-projectile-toggle-test' but open in another window."
  (interactive)
  (parallel-path-projectile-toggle-test t))

(defun parallel-path-projectile--toggle-buffer (other-window)
  "Toggle impl<->test for the current file buffer via projectile."
  (unless buffer-file-name
    (user-error "parallel-path-projectile: buffer is not visiting a file"))
  (let ((counterpart (projectile-find-implementation-or-test buffer-file-name)))
    (if other-window
        (find-file-other-window counterpart)
      (find-file counterpart))))

(defun parallel-path-projectile--toggle-dired (other-window)
  "Toggle impl<->test for the current dired directory via projectile."
  (let* ((dir     default-directory)
         (new-dir (or (ignore-errors (projectile--test-to-impl-dir dir))
                      (ignore-errors (projectile--impl-to-test-dir dir)))))
    (unless new-dir
      (user-error
       "parallel-path-projectile: no impl/test counterpart found for %s" dir))
    (unless (file-directory-p new-dir)
      (user-error
       "parallel-path-projectile: counterpart directory does not exist: %s" new-dir))
    (if other-window (dired-other-window new-dir) (dired new-dir))))

;;;; Worktree switch

;;;###autoload
(defun parallel-path-projectile-switch-worktree (&optional other-window)
  "Switch to the same relative path in another git worktree.

Calls `projectile-project-worktrees' to discover all worktrees for the
current project (git linked worktrees, Jujutsu workspaces, and any other
source configured via `projectile-worktree-functions').  Presents non-prunable
worktrees other than the current one via `completing-read', annotated with
their branch labels.

Applies `parallel-path--apply-root' to map the current file or directory
path into the chosen worktree.

When OTHER-WINDOW is non-nil open in another window."
  (interactive)
  (let* ((current-root (projectile-project-root))
         (all-worktrees (projectile-project-worktrees current-root))
         (candidates
          (cl-remove-if
           (lambda (wt)
             (or (plist-get wt :prunable)
                 (file-equal-p (expand-file-name (plist-get wt :path))
                               (expand-file-name current-root))))
           all-worktrees)))
    (unless candidates
      (user-error
       "parallel-path-projectile: no other worktrees found for %s" current-root))
    (let* ((path        (parallel-path--current-path))
           (target-root (parallel-path-projectile--read-worktree candidates))
           (result      (parallel-path--apply-root path current-root target-root)))
      (unless result
        (user-error
         "parallel-path-projectile: %s is not under project root %s"
         path current-root))
      (unless (file-exists-p result)
        (user-error
         "parallel-path-projectile: counterpart does not exist: %s" result))
      (parallel-path--visit result other-window))))

;;;###autoload
(defun parallel-path-projectile-switch-worktree-other-window ()
  "Like `parallel-path-projectile-switch-worktree' but open in another window."
  (interactive)
  (parallel-path-projectile-switch-worktree t))

(defun parallel-path-projectile--read-worktree (candidates)
  "Prompt for a worktree from CANDIDATES and return its :path.
CANDIDATES is a list of plists with at minimum a :path key and
optionally a :label key (branch name)."
  (let* ((display-alist
          (mapcar (lambda (wt)
                    (let* ((path  (plist-get wt :path))
                           (label (plist-get wt :label))
                           (display (if label
                                        (format "%s  [%s]" path label)
                                      path)))
                      (cons display path)))
                  candidates))
         (choice (completing-read "Worktree: " (mapcar #'car display-alist) nil t)))
    (cdr (assoc choice display-alist))))

(provide 'parallel-path-projectile)
;;; parallel-path-projectile.el ends here
