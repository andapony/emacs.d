;;; rjd-container-test.el --- ERT tests for rjd-container  -*- lexical-binding: t -*-

;;; Commentary:
;; Run from the repository root with
;;
;;   emacs -Q --batch -l test/rjd-container-test.el -f ert-run-tests-batch-and-exit
;;
;; `-Q' keeps the personal config out, and the file loads rjd-container
;; from source, for the reason rjd-mail-test.el gives.
;;
;; Every test runs with HOME a fresh temporary directory and
;; CLAUDE_CONTAINER unset unless the test sets it, so the real
;; ~/.config/claude-container is never read.  The cases mirror
;; claude-container's tests/container-git-test.sh, since the two must
;; choose alike.

;;; Code:

(require 'ert)

(eval-and-compile
  (load (expand-file-name
         "../user-lisp/rjd-container.el"
         (file-name-directory
          (or load-file-name byte-compile-current-file buffer-file-name)))
        nil :nomessage :nosuffix))


;;; Fixtures

(defmacro rjd/container-test-with-home (map &rest body)
  "Run BODY with HOME a temporary directory holding container map MAP.
MAP is the file's text, or nil for no file.  Within BODY `home' is the
temporary HOME, resolved, and the directories projects/repo,
projects/work/repo, projects-old/repo, client/repo and elsewhere/repo
exist under it."
  (declare (indent 1) (debug t))
  `(let* ((home (file-name-as-directory
                 (file-truename (make-temp-file "rjd-container" t))))
          (process-environment
           (append (list (concat "HOME=" (directory-file-name home))
                         "CLAUDE_CONTAINER")
                   process-environment))
          (rjd/container-map-file
           (expand-file-name ".config/claude-container/containers" home)))
     (unwind-protect
         (progn
           (dolist (dir '("projects/repo" "projects/work/repo"
                          "projects-old/repo" "client/repo" "elsewhere/repo"))
             (make-directory (expand-file-name dir home) t))
           (when ,map
             (make-directory (file-name-directory rjd/container-map-file) t)
             (with-temp-file rjd/container-map-file (insert ,map)))
           ,@body)
       (delete-directory home t))))

(defun rjd/container-test-owner (dir)
  "Return the container owning DIR, relative to HOME."
  (rjd/container-for-directory (expand-file-name dir (getenv "HOME"))))

(defun rjd/container-test-prefix (dir)
  "Return the agent-shell prefix for a buffer in DIR, relative to HOME."
  (with-temp-buffer
    (setq default-directory
          (file-name-as-directory (expand-file-name dir (getenv "HOME"))))
    (rjd/container-agent-shell-prefix (current-buffer))))

(defconst rjd/container-test-map
  "# The personal container.
~/projects claude-dev

   # An indented comment, and a trailing slash on the entry.
~/projects/work/   claude-work
~/client claude-client   # a trailing comment
~/half-entry
"
  "A map with nested entries, comments, blank lines and odd spellings.")


;;; Without a map file

(ert-deftest rjd/container-no-map-gives-projects-to-claude-dev ()
  "Without the file, ~/projects and below belong to claude-dev."
  (rjd/container-test-with-home nil
    (should (equal (rjd/container-test-owner "projects") "claude-dev"))
    (should (equal (rjd/container-test-owner "projects/repo") "claude-dev"))))

(ert-deftest rjd/container-no-map-leaves-the-rest-unowned ()
  "Without the file, nothing outside ~/projects has a container.
That includes a sibling whose name only starts with \"projects\"."
  (rjd/container-test-with-home nil
    (should-not (rjd/container-test-owner "elsewhere/repo"))
    (should-not (rjd/container-test-owner "projects-old/repo"))))

(ert-deftest rjd/container-no-map-honours-claude-container ()
  "CLAUDE_CONTAINER replaces claude-dev but owns nothing more."
  (rjd/container-test-with-home nil
    (setenv "CLAUDE_CONTAINER" "other")
    (should (equal (rjd/container-test-owner "projects/repo") "other"))
    (should-not (rjd/container-test-owner "elsewhere/repo"))))


;;; With a map file

(ert-deftest rjd/container-map-longest-entry-wins ()
  "A directory belongs to the longest entry containing it."
  (rjd/container-test-with-home rjd/container-test-map
    (should (equal (rjd/container-test-owner "projects/repo") "claude-dev"))
    (should (equal (rjd/container-test-owner "projects/work/repo")
                   "claude-work"))
    (should (equal (rjd/container-test-owner "projects/work") "claude-work"))
    (should (equal (rjd/container-test-owner "client/repo") "claude-client"))))

(ert-deftest rjd/container-map-leaves-unlisted-directories-unowned ()
  "A directory no entry contains has no container."
  (rjd/container-test-with-home rjd/container-test-map
    (should-not (rjd/container-test-owner "elsewhere/repo"))
    (should-not (rjd/container-test-owner "projects-old/repo"))
    (should-not (rjd/container-test-owner "half-entry"))))

(ert-deftest rjd/container-map-without-projects-owns-none-of-it ()
  "A map that leaves ~/projects out gives it no container.
The last line has no newline, as a hand-edited file may not."
  (rjd/container-test-with-home "~/client claude-client"
    (should-not (rjd/container-test-owner "projects/repo"))
    (should (equal (rjd/container-test-owner "client/repo") "claude-client")))
  ;; An empty map is a map: it owns nothing, rather than meaning no map.
  (rjd/container-test-with-home ""
    (should-not (rjd/container-test-owner "projects/repo"))))

(ert-deftest rjd/container-map-is-overridden-by-claude-container ()
  "CLAUDE_CONTAINER replaces the map's choice, not its silence.
Empty, it counts as unset, as it does to the wrapper's sh."
  (rjd/container-test-with-home rjd/container-test-map
    (setenv "CLAUDE_CONTAINER" "other")
    (should (equal (rjd/container-test-owner "projects/work/repo") "other"))
    (should-not (rjd/container-test-owner "elsewhere/repo"))
    (setenv "CLAUDE_CONTAINER" "")
    (should (equal (rjd/container-test-owner "projects/work/repo")
                   "claude-work"))))

(ert-deftest rjd/container-map-entries-resolve-symlinks ()
  "An entry reached through a symlink matches the directory's true name.
`container-git' sees the cwd only by its physical path, so the map's
directories are compared by theirs."
  (rjd/container-test-with-home "~/link claude-link\n"
    (make-symbolic-link (expand-file-name "client" home)
                        (expand-file-name "link" home))
    (should (equal (rjd/container-test-owner "client/repo") "claude-link"))
    (should (equal (rjd/container-test-owner "link/repo") "claude-link"))))

(ert-deftest rjd/container-remote-directories-are-unowned ()
  "A remote directory has no local container, and is never resolved."
  (rjd/container-test-with-home rjd/container-test-map
    (should-not (rjd/container-for-directory "/ssh:somehost:/tmp/"))))


;;; The agent-shell prefix

(ert-deftest rjd/container-prefix-follows-the-buffer-directory ()
  "A shell starts in the container owning its buffer's directory."
  (rjd/container-test-with-home rjd/container-test-map
    (should (equal (rjd/container-test-prefix "projects/repo")
                   '("docker" "exec" "-i" "claude-dev")))
    (should (equal (rjd/container-test-prefix "projects/work/repo")
                   '("docker" "exec" "-i" "claude-work")))
    (should (equal (rjd/container-test-prefix "client/repo")
                   '("docker" "exec" "-i" "claude-client")))))

(ert-deftest rjd/container-prefix-falls-back-to-claude-dev ()
  "A shell in an unowned directory starts in claude-dev, map or no map."
  (rjd/container-test-with-home rjd/container-test-map
    (should (equal (rjd/container-test-prefix "elsewhere/repo")
                   '("docker" "exec" "-i" "claude-dev"))))
  (rjd/container-test-with-home nil
    (should (equal (rjd/container-test-prefix "elsewhere/repo")
                   '("docker" "exec" "-i" "claude-dev")))
    (should (equal (rjd/container-test-prefix "projects/repo")
                   '("docker" "exec" "-i" "claude-dev")))))

(ert-deftest rjd/container-prefix-fallback-honours-claude-container ()
  "With CLAUDE_CONTAINER set, even the fallback is that container."
  (rjd/container-test-with-home rjd/container-test-map
    (setenv "CLAUDE_CONTAINER" "other")
    (should (equal (rjd/container-test-prefix "elsewhere/repo")
                   '("docker" "exec" "-i" "other")))))

(provide 'rjd-container-test)
;;; rjd-container-test.el ends here
