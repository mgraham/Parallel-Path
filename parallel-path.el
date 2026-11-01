;;; parallel-path.el --- Toggle between parallel directory trees -*- lexical-binding: t -*-

;; Copyright (C) 2026 Michael Graham

;; Author: Michael Graham
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
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

;; parallel-path provides commands to navigate between mirrored directory
;; trees.  Two primary use cases:
;;
;;   1. Toggling between implementation and test files/directories.
;;      Named profiles define directory-fragment mappings and optional
;;      filename transforms.  The default :test profile covers Ruby, Go,
;;      Python, JS, and Elisp conventions out of the box.
;;
;;   2. Switching between arbitrary parallel trees — e.g. git worktrees —
;;      by supplying a source root and a target root explicitly.  The roots
;;      need share no common prefix.
;;
;; Quick start:
;;
;;   ;; Toggle test <-> impl (works in file buffers and dired)
;;   (keymap-set global-map "C-c t" (parallel-path-bind #'parallel-path-toggle :test))
;;
;;   ;; Auto-detect which profile applies
;;   (keymap-set global-map "C-c T" #'parallel-path-toggle-auto)
;;
;;   ;; Jump to the same path under a different root (e.g. a worktree)
;;   (keymap-set global-map "C-c w"
;;     (lambda () (interactive)
;;       (parallel-path-to-root "~/src/main" "~/src/feature")))
;;
;; Profiles are configured via `parallel-path-profiles'.  Additional profiles
;; can be appended:
;;
;;   ;; Rails models <-> views (directory remap only, no filename transform)
;;   (add-to-list 'parallel-path-profiles
;;     '(:name :views
;;       :directory-mappings (("/app/models/"      . "/app/views/")
;;                            ("/app/controllers/" . "/app/views/")))
;;     t)
;;
;;   (keymap-set global-map "C-c v" (parallel-path-bind #'parallel-path-toggle :views))
;;
;; For projectile-aware toggling and git worktree switching, see the
;; companion file parallel-path-projectile.el.

;;; Code:

(require 'cl-lib)

;;;; Customisation

(defgroup parallel-path nil
  "Toggle between parallel directory trees."
  :group 'files
  :prefix "parallel-path-")

(defcustom parallel-path-profiles
  '((:name :test
     :directory-mappings (("/lib/"  . "/spec/lib/")
                          ("/app/"  . "/spec/"))
     :name-patterns      (("%s_spec" . "%s")
                          ("%s_test" . "%s")
                          ("test_%s" . "%s")
                          ("%s.test" . "%s")
                          ("%s.spec" . "%s")
                          ("%s-test" . "%s"))))
  "List of profile plists.

Each profile has the following keys:

  :name               — keyword identifier, e.g. :test or :views
  :directory-mappings — alist of (A-FRAGMENT . B-FRAGMENT) pairs tried in
                        order.  A is the \"source\" side; B is the \"dest\"
                        side.  Multiple rules handle asymmetric layouts:
                        \\\"/lib/\\\" -> \\\"/spec/lib/\\\" before \\\"/app/\\\" -> \\\"/spec/\\\"
                        ensures lib files land in spec/lib/, not spec/.
  :name-patterns      — alist of (TEST-FMT . IMPL-FMT) where %s stands for
                        the base name without extension.  Omit or set nil
                        for profiles that remap directories only.

Example — add a Rails models <-> views profile:

  (add-to-list \\='parallel-path-profiles
    \\='(:name :views
       :directory-mappings ((\\\"/app/models/\\\"      . \\\"/app/views/\\\")
                            (\\\"/app/controllers/\\\" . \\\"/app/views/\\\")))
    t)"
  :type '(repeat plist)
  :group 'parallel-path)

;;;; Internal pure functions

(defun parallel-path--fmt-to-regexp (fmt)
  "Convert FMT (a %s-style format string) to a regexp that captures the %s match.
The returned regexp is anchored at both ends.  Special characters outside
the %s placeholder are quoted.

  \"%s_spec\" -> \"\\\\`\\\\(.*\\\\)_spec\\\\'\"
  \"test_%s\"  -> \"\\\\`test_\\\\(.*\\\\)\\\\'\"
  \"%s.test\"  -> \"\\\\`\\\\(.*\\\\)\\\\.test\\\\'\"  (dot is quoted)"
  (let ((parts (split-string fmt "%s")))
    (concat "\\`"
            (mapconcat #'regexp-quote parts "\\(.*\\)")
            "\\'")))

(defun parallel-path--strip-root (path root)
  "Return the relative portion of PATH beneath ROOT, or nil.
Both paths are `expand-file-name' expanded before comparison.
The returned string has no leading slash, e.g. \"src/foo/bar.el\".

  (parallel-path--strip-root \"/a/b/c/d\" \"/a/b\") => \"c/d\""
  (let ((path (expand-file-name path))
        (root (file-name-as-directory (expand-file-name root))))
    (and (string-prefix-p root path)
         (substring path (length root)))))

(defun parallel-path--apply-root (path source-root target-root)
  "Return PATH with SOURCE-ROOT replaced by TARGET-ROOT.
All three arguments are expanded.  Returns nil when PATH is not beneath
SOURCE-ROOT.  SOURCE-ROOT and TARGET-ROOT need not share any common prefix.

  path:        ~/Projects/acme/main/src/foo.el
  source-root: ~/Projects/acme/main
  target-root: ~/Backups/acme
  result:      ~/Backups/acme/src/foo.el"
  (let ((relative (parallel-path--strip-root path source-root)))
    (and relative
         (expand-file-name relative (expand-file-name target-root)))))

(defun parallel-path--profile-get (name)
  "Return the profile plist whose :name is NAME (a keyword), or nil."
  (cl-find name parallel-path-profiles
           :key (lambda (p) (plist-get p :name))))

(defun parallel-path--test-file-p (basename-noext &optional patterns)
  "Return the impl base name if BASENAME-NOEXT matches a test pattern, else nil.
PATTERNS is an alist of (TEST-FMT . IMPL-FMT); defaults to the :name-patterns
of the :test profile.

  (parallel-path--test-file-p \"user_spec\") => \"user\"
  (parallel-path--test-file-p \"test_user\") => \"user\"
  (parallel-path--test-file-p \"user\")      => nil"
  (let ((patterns (or patterns
                      (plist-get (parallel-path--profile-get :test)
                                 :name-patterns))))
    (cl-loop for (test-fmt . impl-fmt) in patterns
             for re = (parallel-path--fmt-to-regexp test-fmt)
             when (let ((case-fold-search nil))
                    (string-match re basename-noext))
             return (format impl-fmt (match-string 1 basename-noext)))))

(defun parallel-path--filename-transform (basename-noext ext direction &optional patterns)
  "Transform BASENAME-NOEXT + EXT according to DIRECTION and PATTERNS.
DIRECTION is :a-to-b (impl->test) or :b-to-a (test->impl).
PATTERNS is an alist of (TEST-FMT . IMPL-FMT); defaults to the :name-patterns
of the :test profile.  Returns a filename string, or nil if no match.

  :a-to-b \"user\"      \".rb\" => \"user_spec.rb\"   (first pattern applied)
  :b-to-a \"user_spec\" \".rb\" => \"user.rb\""
  (let ((patterns (or patterns
                      (plist-get (parallel-path--profile-get :test)
                                 :name-patterns))))
    (pcase direction
      (:a-to-b
       (when-let* ((test-fmt (caar patterns)))
         (concat (format test-fmt basename-noext) ext)))
      (:b-to-a
       (when-let* ((impl-base (parallel-path--test-file-p basename-noext patterns)))
         (concat impl-base ext))))))

(defun parallel-path--directory-transform (dir mappings direction)
  "Apply MAPPINGS to DIR in DIRECTION, returning a transformed string or nil.
MAPPINGS is an alist of (A-FRAGMENT . B-FRAGMENT).
DIRECTION is :a-to-b (replace A with B) or :b-to-a (replace B with A).
The first mapping that matches wins; subsequent mappings are not tried."
  (cl-loop for (a . b) in mappings
           for result =
           (pcase direction
             (:a-to-b (when (string-match (regexp-quote a) dir)
                        (replace-match b t t dir)))
             (:b-to-a (when (string-match (regexp-quote b) dir)
                        (replace-match a t t dir))))
           when result return result))

(defun parallel-path--toggle-with-profile (path profile)
  "Return the counterpart of PATH using PROFILE plist, or nil on no match.
For a file path: transforms the directory portion then the filename.
For a directory path: transforms the directory only.

Direction is auto-detected: for file buffers, the filename is matched
against test patterns; for dired buffers, the directory is checked
against the B-side (test-side) mapping fragments.  Direction is
:b-to-a (test->impl) when on the test side, :a-to-b otherwise."
  (let* ((mappings  (plist-get profile :directory-mappings))
         (patterns  (plist-get profile :name-patterns))
         (is-dir    (file-directory-p path))
         (dir       (if is-dir path (file-name-directory path)))
         (base      (unless is-dir (file-name-nondirectory path)))
         (base-noext (when base (file-name-sans-extension base)))
         (ext        (when base
                       (let ((e (file-name-extension base)))
                         (if e (concat "." e) ""))))
         (direction  (cond
                       ;; Directory: detect side by checking whether the path
                       ;; contains a B-side fragment from the mappings.
                       (is-dir
                        (if (cl-some (lambda (mapping)
                                       (string-match-p
                                        (regexp-quote (cdr mapping)) dir))
                                     mappings)
                            :b-to-a
                          :a-to-b))
                       ;; File: detect from filename patterns.
                       ((and patterns base-noext
                             (parallel-path--test-file-p base-noext patterns))
                        :b-to-a)
                       (t :a-to-b)))
         (new-dir    (parallel-path--directory-transform dir mappings direction)))
    (when new-dir
      (if is-dir
          new-dir
        (let ((new-base (if patterns
                            (parallel-path--filename-transform
                             base-noext ext direction patterns)
                          base)))
          (when new-base
            (concat (file-name-as-directory new-dir) new-base)))))))

;;;; Context helpers

(defun parallel-path--current-path ()
  "Return the relevant path for the current buffer.
For file-visiting buffers returns `buffer-file-name'.
For dired buffers returns `default-directory'.
Signals `user-error' otherwise."
  (or buffer-file-name
      (and (derived-mode-p 'dired-mode) default-directory)
      (user-error
       "parallel-path: buffer is not visiting a file or a dired directory")))

(defun parallel-path--visit (path other-window)
  "Open PATH in a file buffer or dired.
Opens in another window when OTHER-WINDOW is non-nil.
Window placement beyond the other-window split is left to
`display-buffer-alist' (e.g. a shadowboard routing rule)."
  (if (file-directory-p path)
      (if other-window (dired-other-window path) (dired path))
    (if other-window (find-file-other-window path) (find-file path))))

;;;; Public commands

;;;###autoload
(defun parallel-path-to-root (source-root target-root &optional other-window)
  "Jump to the same relative path under TARGET-ROOT.
SOURCE-ROOT is stripped from the current buffer path and TARGET-ROOT is
prepended.  The two roots need share no common prefix.

When OTHER-WINDOW is non-nil open in another window.

Typical use — bind a worktree jump to a key:

  (keymap-set global-map \"C-c w\"
    (lambda () (interactive)
      (parallel-path-to-root \"~/src/main\" \"~/src/feature\")))"
  (interactive "DSource root: \nDTarget root: ")
  (let* ((path   (parallel-path--current-path))
         (result (parallel-path--apply-root path source-root target-root)))
    (unless result
      (user-error "parallel-path: %s is not under source root %s" path source-root))
    (unless (file-exists-p result)
      (user-error "parallel-path: counterpart does not exist: %s" result))
    (parallel-path--visit result other-window)))

;;;###autoload
(defun parallel-path-to-root-other-window (source-root target-root)
  "Like `parallel-path-to-root' but open in another window."
  (interactive "DSource root: \nDTarget root: ")
  (parallel-path-to-root source-root target-root t))

;;;###autoload
(defun parallel-path-toggle (profile-name &optional other-window)
  "Toggle current buffer or dired to its counterpart using PROFILE-NAME.
PROFILE-NAME is a keyword such as :test or :views matching a profile in
`parallel-path-profiles'.  When called interactively, prompts with
`completing-read'.

When OTHER-WINDOW is non-nil open in another window.

Prefer `parallel-path-bind' to create named commands for key bindings:

  (keymap-set global-map \"C-c t\" (parallel-path-bind #\\='parallel-path-toggle :test))"
  (interactive
   (list (intern (completing-read
                  "Profile: "
                  (mapcar (lambda (p) (symbol-name (plist-get p :name)))
                          parallel-path-profiles)
                  nil t ":"))))
  (let ((profile (parallel-path--profile-get profile-name)))
    (unless profile
      (user-error "parallel-path: unknown profile %s" profile-name))
    (let* ((path   (parallel-path--current-path))
           (result (parallel-path--toggle-with-profile path profile)))
      (unless result
        (user-error "parallel-path: no directory mapping matched for profile %s in %s"
                    profile-name path))
      (unless (file-exists-p result)
        (user-error "parallel-path: counterpart does not exist: %s" result))
      (parallel-path--visit result other-window))))

;;;###autoload
(defun parallel-path-toggle-other-window (profile-name)
  "Like `parallel-path-toggle' but open in another window."
  (interactive
   (list (intern (completing-read
                  "Profile: "
                  (mapcar (lambda (p) (symbol-name (plist-get p :name)))
                          parallel-path-profiles)
                  nil t ":"))))
  (parallel-path-toggle profile-name t))

;;;###autoload
(defun parallel-path-toggle-auto (&optional other-window)
  "Toggle to counterpart by auto-detecting the applicable profile.
Tries each profile in `parallel-path-profiles' order and uses the first
one whose directory mappings match the current path AND whose computed
counterpart exists on disk.  Falls back to `completing-read' when no
profile produces a match.

When OTHER-WINDOW is non-nil open in another window."
  (interactive)
  (let* ((path (parallel-path--current-path))
         (result
          (cl-loop for profile in parallel-path-profiles
                   for r = (parallel-path--toggle-with-profile path profile)
                   when (and r (file-exists-p r)) return r)))
    (if result
        (parallel-path--visit result other-window)
      (call-interactively
       (if other-window
           #'parallel-path-toggle-other-window
         #'parallel-path-toggle)))))

;;;###autoload
(defun parallel-path-toggle-auto-other-window ()
  "Like `parallel-path-toggle-auto' but open in another window."
  (interactive)
  (parallel-path-toggle-auto t))

;;;###autoload
(defun parallel-path-bind (fn &optional profile)
  "Return a named interactive command that calls FN with PROFILE.
The returned symbol is interned via `defalias' so that which-key and
`describe-key' display a meaningful name rather than an anonymous lambda.
The symbol is suitable for direct use with `keymap-set'.

PROFILE is a keyword such as :test or :views.  When omitted, FN itself
is returned unchanged.

Generated symbol name: FN-NAME-PROFILE  (colon stripped from profile keyword)

  (parallel-path-bind #\\='parallel-path-toggle :test)
    => interns \\='parallel-path-toggle-test
  (parallel-path-bind #\\='parallel-path-toggle :views)
    => interns \\='parallel-path-toggle-views
  (parallel-path-bind #\\='parallel-path-toggle-auto)
    => returns \\='parallel-path-toggle-auto unchanged

Examples:
  (keymap-set global-map \"C-c t\" (parallel-path-bind #\\='parallel-path-toggle :test))
  (keymap-set global-map \"C-c v\" (parallel-path-bind #\\='parallel-path-toggle :views))
  (keymap-set global-map \"C-c T\" (parallel-path-bind #\\='parallel-path-toggle-auto))"
  (if (null profile)
      fn
    (let* ((fn-name  (symbol-name fn))
           (prof-str (substring (symbol-name profile) 1)) ; strip leading ":"
           (sym      (intern (concat fn-name "-" prof-str)))
           (doc      (format "Call `%s' with profile %s.\nCreated by `parallel-path-bind'."
                             fn-name (symbol-name profile))))
      (defalias sym (lambda () (interactive) (funcall fn profile)) doc)
      sym)))

(provide 'parallel-path)
;;; parallel-path.el ends here
