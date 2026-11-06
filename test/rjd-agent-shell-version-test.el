;;; rjd-agent-shell-version-test.el --- ERT tests for rjd-agent-shell-version  -*- lexical-binding: t -*-

;;; Commentary:
;; Run from the repository root with
;;
;;   emacs -Q --batch -l test/rjd-agent-shell-version-test.el -f ert-run-tests-batch-and-exit
;;
;; `-Q' keeps the personal config out, and the file loads
;; rjd-agent-shell-version from source, for the reason rjd-mail-test.el
;; gives.  agent-shell itself is not loaded.
;;
;; These cover the version being kept per container: two containers
;; built at different times run different Claude Codes, and a shell's
;; header must show its own container's.  The containers are stood in
;; for by prefixes of `env TAG=...', so the commands really run, on this
;; host, and each answers with its own TAG; nothing touches Docker or
;; the npm registry.

;;; Code:

(require 'ert)
(require 'cl-lib)

(eval-and-compile
  (load (expand-file-name
         "../user-lisp/rjd-agent-shell-version.el"
         (file-name-directory
          (or load-file-name byte-compile-current-file buffer-file-name)))
        nil :nomessage :nosuffix))

(defvar agent-shell-command-prefix nil)


;;; Fixtures

(defvar-local rjd/version-test-tag nil
  "What this test buffer's container answers with.")

(defun rjd/version-test-prefix (buffer)
  "BUFFER's command prefix: `env' setting TAG to its container's answer."
  (list "env" (concat "TAG=" (buffer-local-value 'rjd/version-test-tag buffer))))

(defmacro rjd/version-test-with-containers (&rest body)
  "Run BODY with fresh caches and two containers, old and new.
Within BODY `old' and `new' are shell buffers whose containers answer
the version command with 2.1.100 and 2.1.200, and the update check with
an installed adapter of 0.80.0 and 0.81.0, the latest being 0.81.0."
  (declare (indent 0) (debug t))
  `(let ((rjd/agent-shell-version--cache nil)
         (rjd/agent-shell-version--update-cache nil)
         (rjd/agent-shell-version--in-flight nil)
         (rjd/agent-shell-version--update-in-flight nil)
         (agent-shell-command-prefix #'rjd/version-test-prefix)
         (rjd/agent-shell-version-command
          '("sh" "-c" "echo \"${TAG%:*} (Claude Code)\""))
         (rjd/agent-shell-version-update-command
          '("sh" "-c" "echo \"${TAG#*:}\"; echo 0.81.0"))
         (old (generate-new-buffer " *old shell*"))
         (new (generate-new-buffer " *new shell*")))
     (with-current-buffer old (setq rjd/version-test-tag "2.1.100:0.80.0"))
     (with-current-buffer new (setq rjd/version-test-tag "2.1.200:0.81.0"))
     (unwind-protect
         (progn ,@body)
       (kill-buffer old)
       (kill-buffer new))))

(defun rjd/version-test-settle ()
  "Wait until no version fetch or update check is outstanding."
  (with-timeout (10 (error "Version commands still running"))
    (while (or rjd/agent-shell-version--in-flight
               rjd/agent-shell-version--update-in-flight)
      (accept-process-output nil 0.05))))

(defun rjd/version-test-render (&rest buffers)
  "Draw each of BUFFERS' headers until their answers stop changing.
The first draw asks for the version; the update check is asked for
once a version is known, so it takes a second."
  (dotimes (_ 2)
    (dolist (buffer buffers)
      (with-current-buffer buffer (rjd/agent-shell-version-string)))
    (rjd/version-test-settle)))

(defun rjd/version-test-string (buffer)
  "BUFFER's header version string, without properties, or nil."
  (with-current-buffer buffer
    (when-let* ((string (rjd/agent-shell-version-string)))
      (substring-no-properties string))))


;;; Tests

(ert-deftest rjd/version-each-header-shows-its-own-container ()
  "Each shell's header shows its own container's version.
The first header in each starts that container's fetch; neither answer
lands in the other's cache."
  (rjd/version-test-with-containers
    (should-not (rjd/version-test-string old))
    (should-not (rjd/version-test-string new))
    (rjd/version-test-render old new)
    (should (equal (rjd/version-test-string old) "v2.1.100 ⇧"))
    (should (equal (rjd/version-test-string new) "v2.1.200"))))

(ert-deftest rjd/version-refresh-from-elsewhere-goes-to-the-named-container ()
  "A refresh given a prefix keeps its answer as that container's,
whichever buffer is current when it is called or when it answers."
  (rjd/version-test-with-containers
    (with-temp-buffer
      (rjd/agent-shell-version-refresh (rjd/version-test-prefix new)))
    (rjd/version-test-settle)
    (should (equal (car (rjd/agent-shell-version--get
                         rjd/agent-shell-version--cache
                         (rjd/version-test-prefix new)))
                   "2.1.200"))
    (should-not (rjd/agent-shell-version--get
                 rjd/agent-shell-version--cache
                 (rjd/version-test-prefix old)))))

(ert-deftest rjd/version-a-pending-fetch-blocks-only-its-container ()
  "An outstanding fetch for one container doesn't hold up the other's,
and a second one for the same container is not started."
  (rjd/version-test-with-containers
    (let (runs)
      (cl-letf (((symbol-function 'rjd/agent-shell-version--run)
                 (lambda (_name prefix _command _callback)
                   (push prefix runs))))
        (rjd/agent-shell-version-refresh (rjd/version-test-prefix old))
        (rjd/agent-shell-version-refresh (rjd/version-test-prefix old))
        (rjd/agent-shell-version-refresh (rjd/version-test-prefix new))
        (should (equal runs (list (rjd/version-test-prefix new)
                                  (rjd/version-test-prefix old))))))))

(ert-deftest rjd/version-update-check-is-per-container ()
  "The update indicator reflects each container's own adapter."
  (rjd/version-test-with-containers
    (with-current-buffer old (rjd/agent-shell-version-check-update))
    (with-current-buffer new (rjd/agent-shell-version-check-update))
    (rjd/version-test-settle)
    (with-current-buffer old
      (should (equal (rjd/agent-shell-version-update-available-p) "0.81.0")))
    (with-current-buffer new
      (should-not (rjd/agent-shell-version-update-available-p)))))

(ert-deftest rjd/version-a-fresh-answer-is-not-asked-again ()
  "A container's cached version is used until its TTL runs out."
  (rjd/version-test-with-containers
    (rjd/version-test-render old)
    (let (runs)
      (cl-letf (((symbol-function 'rjd/agent-shell-version--run)
                 (lambda (_name prefix _command _callback)
                   (push prefix runs))))
        (should (equal (rjd/version-test-string old) "v2.1.100 ⇧"))
        (should-not runs)
        ;; The other container has nothing cached, so it is asked.
        (rjd/version-test-string new)
        (should (member (rjd/version-test-prefix new) runs))))))

;;; rjd-agent-shell-version-test.el ends here
