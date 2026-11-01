;;; parallel-path-test.el --- ERT tests for parallel-path -*- lexical-binding: t -*-

;; Copyright (C) 2026 Michael Graham
;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for parallel-path.el.  All tests are batch-safe: no graphical
;; display is required and no external packages are loaded.
;;
;; Running:
;;   make test          # from the project root

;;; Code:

;; Add project root to load-path so (require 'parallel-path) works when
;; running from the test/ subdirectory or via emacs --batch.
(let ((root (expand-file-name ".." (file-name-directory load-file-name))))
  (unless (member root load-path)
    (push root load-path)))

(require 'ert)
(require 'cl-lib)
(require 'parallel-path)

;;;; Helpers

(defmacro parallel-path-test--with-temp-tree (dirs &rest body)
  "Create a temporary directory tree, run BODY, then clean up.
DIRS is a list of relative paths to create as directories.
The variable `root' is bound to the temp root inside BODY."
  (declare (indent 1))
  `(let ((root (make-temp-file "parallel-path-test-" t)))
     (unwind-protect
         (progn
           (dolist (d ',dirs)
             (make-directory (expand-file-name d root) t))
           ,@body)
       (delete-directory root t))))

;;;; parallel-path--fmt-to-regexp

(ert-deftest parallel-path/fmt-to-regexp/suffix ()
  "Suffix pattern: %s_spec matches user_spec and captures user."
  (let ((re (parallel-path--fmt-to-regexp "%s_spec")))
    (should (string-match re "user_spec"))
    (should (equal (match-string 1 "user_spec") "user"))
    (should-not (string-match re "user_spec_extra"))
    (should-not (string-match re "user"))))

(ert-deftest parallel-path/fmt-to-regexp/prefix ()
  "Prefix pattern: test_%s matches test_user and captures user."
  (let ((re (parallel-path--fmt-to-regexp "test_%s")))
    (should (string-match re "test_user"))
    (should (equal (match-string 1 "test_user") "user"))
    (should-not (string-match re "user"))))

(ert-deftest parallel-path/fmt-to-regexp/infix-dot ()
  "Infix pattern with dot: %s.test — dot is quoted in regexp."
  (let ((re (parallel-path--fmt-to-regexp "%s.test")))
    (should (string-match re "user.test"))
    (should (equal (match-string 1 "user.test") "user"))
    ;; dot must be literal — "userXtest" should NOT match
    (should-not (string-match re "userXtest"))))

(ert-deftest parallel-path/fmt-to-regexp/hyphen-suffix ()
  "Hyphen suffix: %s-test matches pkg-test and captures pkg."
  (let ((re (parallel-path--fmt-to-regexp "%s-test")))
    (should (string-match re "pkg-test"))
    (should (equal (match-string 1 "pkg-test") "pkg"))))

;;;; parallel-path--strip-root

(ert-deftest parallel-path/strip-root/basic ()
  (should (equal (parallel-path--strip-root "/a/b/c/d" "/a/b") "c/d")))

(ert-deftest parallel-path/strip-root/trailing-slash-on-root ()
  "Root with a trailing slash is handled correctly."
  (should (equal (parallel-path--strip-root "/a/b/c/d" "/a/b/") "c/d")))

(ert-deftest parallel-path/strip-root/not-under-root ()
  (should-not (parallel-path--strip-root "/x/y/z" "/a/b")))

(ert-deftest parallel-path/strip-root/exact-match ()
  "Path equal to root returns empty string (trailing slash on path required)."
  (should (equal (parallel-path--strip-root "/a/b/" "/a/b") "")))

;;;; parallel-path--apply-root

(ert-deftest parallel-path/apply-root/same-prefix ()
  (should (equal (parallel-path--apply-root
                  "/worktrees/main/src/foo.el"
                  "/worktrees/main"
                  "/worktrees/branch")
                 "/worktrees/branch/src/foo.el")))

(ert-deftest parallel-path/apply-root/arbitrary-roots ()
  "Source and target roots with no common prefix."
  (should (equal (parallel-path--apply-root
                  "/Users/me/Projects/acme/main/src/foo.el"
                  "/Users/me/Projects/acme/main"
                  "/Backups/acme")
                 "/Backups/acme/src/foo.el")))

(ert-deftest parallel-path/apply-root/not-under-source ()
  (should-not (parallel-path--apply-root "/other/path/foo.el" "/src/main" "/src/branch")))

(ert-deftest parallel-path/apply-root/directory-path ()
  (should (equal (parallel-path--apply-root
                  "/worktrees/main/src/"
                  "/worktrees/main"
                  "/worktrees/branch")
                 "/worktrees/branch/src/")))

;;;; parallel-path--test-file-p

(ert-deftest parallel-path/test-file-p/spec-suffix ()
  (should (equal (parallel-path--test-file-p "user_spec") "user")))

(ert-deftest parallel-path/test-file-p/test-suffix ()
  (should (equal (parallel-path--test-file-p "user_test") "user")))

(ert-deftest parallel-path/test-file-p/test-prefix ()
  (should (equal (parallel-path--test-file-p "test_user") "user")))

(ert-deftest parallel-path/test-file-p/dot-test ()
  (should (equal (parallel-path--test-file-p "user.test") "user")))

(ert-deftest parallel-path/test-file-p/dot-spec ()
  (should (equal (parallel-path--test-file-p "user.spec") "user")))

(ert-deftest parallel-path/test-file-p/hyphen-test ()
  (should (equal (parallel-path--test-file-p "pkg-test") "pkg")))

(ert-deftest parallel-path/test-file-p/impl-file ()
  "Plain impl name should not match any test pattern."
  (should-not (parallel-path--test-file-p "user")))

(ert-deftest parallel-path/test-file-p/custom-patterns ()
  "Custom patterns override the default."
  (should (equal (parallel-path--test-file-p "foo_SPEC"
                                              '(("%s_SPEC" . "%s")))
                 "foo"))
  ;; Matching is case-sensitive: _SPEC pattern must not match _spec
  (should-not (parallel-path--test-file-p "foo_spec"
                                           '(("%s_SPEC" . "%s"))))
  ;; Completely different pattern must not match
  (should-not (parallel-path--test-file-p "foo_spec"
                                           '(("%s_xyzzy" . "%s")))))

;;;; parallel-path--filename-transform

(ert-deftest parallel-path/filename-transform/to-test ()
  (should (equal (parallel-path--filename-transform "user" ".rb" :a-to-b)
                 "user_spec.rb")))

(ert-deftest parallel-path/filename-transform/to-impl-spec ()
  (should (equal (parallel-path--filename-transform "user_spec" ".rb" :b-to-a)
                 "user.rb")))

(ert-deftest parallel-path/filename-transform/to-impl-test-prefix ()
  (should (equal (parallel-path--filename-transform "test_user" ".py" :b-to-a)
                 "user.py")))

(ert-deftest parallel-path/filename-transform/to-impl-dot-test ()
  (should (equal (parallel-path--filename-transform "user.test" ".js" :b-to-a)
                 "user.js")))

(ert-deftest parallel-path/filename-transform/no-extension ()
  (should (equal (parallel-path--filename-transform "user" "" :a-to-b)
                 "user_spec")))

(ert-deftest parallel-path/filename-transform/impl-does-not-match ()
  "Calling :b-to-a on a non-test name returns nil."
  (should-not (parallel-path--filename-transform "user" ".rb" :b-to-a)))

;;;; parallel-path--directory-transform

(defvar parallel-path-test--mappings
  '(("/lib/"  . "/spec/lib/")
    ("/app/"  . "/spec/")))

(ert-deftest parallel-path/directory-transform/app-to-spec ()
  (should (equal (parallel-path--directory-transform
                  "/project/app/models/"
                  parallel-path-test--mappings :a-to-b)
                 "/project/spec/models/")))

(ert-deftest parallel-path/directory-transform/spec-to-app ()
  (should (equal (parallel-path--directory-transform
                  "/project/spec/models/"
                  parallel-path-test--mappings :b-to-a)
                 "/project/app/models/")))

(ert-deftest parallel-path/directory-transform/lib-to-spec-lib ()
  "The /lib/ rule produces /spec/lib/, not /spec/ (ordering matters)."
  (should (equal (parallel-path--directory-transform
                  "/project/lib/utils/"
                  parallel-path-test--mappings :a-to-b)
                 "/project/spec/lib/utils/")))

(ert-deftest parallel-path/directory-transform/spec-lib-to-lib ()
  "The /spec/lib/ rule is checked before /spec/ in :b-to-a direction."
  (should (equal (parallel-path--directory-transform
                  "/project/spec/lib/utils/"
                  parallel-path-test--mappings :b-to-a)
                 "/project/lib/utils/")))

(ert-deftest parallel-path/directory-transform/no-match ()
  (should-not (parallel-path--directory-transform
               "/project/config/"
               parallel-path-test--mappings :a-to-b)))

;;;; parallel-path--toggle-with-profile (end-to-end, string-only)

(defvar parallel-path-test--test-profile
  '(:name :test
    :directory-mappings (("/lib/"  . "/spec/lib/")
                         ("/app/"  . "/spec/"))
    :name-patterns      (("%s_spec" . "%s")
                         ("%s_test" . "%s")
                         ("test_%s" . "%s"))))

(ert-deftest parallel-path/toggle-with-profile/impl-to-test-file ()
  "app/models/user.rb -> spec/models/user_spec.rb"
  ;; We bypass the file-exists check here by testing the transform logic.
  ;; Use cl-letf to stub file-directory-p.
  (cl-letf (((symbol-function 'file-directory-p) (lambda (_) nil)))
    (should (equal (parallel-path--toggle-with-profile
                    "/project/app/models/user.rb"
                    parallel-path-test--test-profile)
                   "/project/spec/models/user_spec.rb"))))

(ert-deftest parallel-path/toggle-with-profile/test-to-impl-file ()
  "spec/models/user_spec.rb -> app/models/user.rb"
  (cl-letf (((symbol-function 'file-directory-p) (lambda (_) nil)))
    (should (equal (parallel-path--toggle-with-profile
                    "/project/spec/models/user_spec.rb"
                    parallel-path-test--test-profile)
                   "/project/app/models/user.rb"))))

(ert-deftest parallel-path/toggle-with-profile/lib-file ()
  "lib/foo.rb -> spec/lib/foo_spec.rb (asymmetric directory rule)"
  (cl-letf (((symbol-function 'file-directory-p) (lambda (_) nil)))
    (should (equal (parallel-path--toggle-with-profile
                    "/project/lib/foo.rb"
                    parallel-path-test--test-profile)
                   "/project/spec/lib/foo_spec.rb"))))

(ert-deftest parallel-path/toggle-with-profile/directory-only-profile ()
  "Profile with no :name-patterns remaps directory, preserves filename."
  (let ((views-profile '(:name :views
                         :directory-mappings (("/app/models/" . "/app/views/")))))
    (cl-letf (((symbol-function 'file-directory-p) (lambda (_) nil)))
      (should (equal (parallel-path--toggle-with-profile
                      "/project/app/models/user.rb"
                      views-profile)
                     "/project/app/views/user.rb")))))

(ert-deftest parallel-path/toggle-with-profile/no-match ()
  (cl-letf (((symbol-function 'file-directory-p) (lambda (_) nil)))
    (should-not (parallel-path--toggle-with-profile
                 "/project/config/routes.rb"
                 parallel-path-test--test-profile))))

(ert-deftest parallel-path/toggle-with-profile/impl-dir-to-test-dir ()
  "app/models/ -> spec/models/ (a-to-b for directory on the A side)"
  (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t)))
    (should (equal (parallel-path--toggle-with-profile
                    "/project/app/models/"
                    parallel-path-test--test-profile)
                   "/project/spec/models/"))))

(ert-deftest parallel-path/toggle-with-profile/test-dir-to-impl-dir ()
  "spec/models/ -> app/models/ (b-to-a for directory on the B side)"
  (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t)))
    (should (equal (parallel-path--toggle-with-profile
                    "/project/spec/models/"
                    parallel-path-test--test-profile)
                   "/project/app/models/"))))

(ert-deftest parallel-path/toggle-with-profile/spec-lib-dir-to-lib-dir ()
  "spec/lib/ -> lib/ (respects asymmetric /spec/lib/ rule)"
  (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t)))
    (should (equal (parallel-path--toggle-with-profile
                    "/project/spec/lib/"
                    parallel-path-test--test-profile)
                   "/project/lib/"))))

;;;; parallel-path--apply-root (end-to-end with temp filesystem)

(ert-deftest parallel-path/apply-root/filesystem-roundtrip ()
  "Root substitution roundtrips correctly on real temp directories."
  (parallel-path-test--with-temp-tree
      ("main/src/foo" "branch/src/foo")
    (let* ((src-file (expand-file-name "main/src/foo/bar.el" root))
           (result   (parallel-path--apply-root
                      src-file
                      (expand-file-name "main" root)
                      (expand-file-name "branch" root))))
      (should (equal result (expand-file-name "branch/src/foo/bar.el" root))))))

;;;; parallel-path-bind

(ert-deftest parallel-path/bind/interns-named-symbol ()
  "parallel-path-bind interns a symbol with the expected name."
  (let ((sym (parallel-path-bind #'parallel-path-toggle :test)))
    (should (eq sym 'parallel-path-toggle-test))
    (should (commandp sym))))

(ert-deftest parallel-path/bind/no-profile-returns-fn ()
  "parallel-path-bind with no profile returns the function unchanged."
  (should (eq (parallel-path-bind #'parallel-path-toggle-auto)
              'parallel-path-toggle-auto)))

(ert-deftest parallel-path/bind/views-profile ()
  (let ((sym (parallel-path-bind #'parallel-path-toggle :views)))
    (should (eq sym 'parallel-path-toggle-views))
    (should (commandp sym))))

(provide 'parallel-path-test)
;;; parallel-path-test.el ends here
