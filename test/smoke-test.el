;;; smoke-test.el --- Batch smoke test of the whole configuration  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loads this checkout's early-init.el and init.el the way a real
;; session would, then checks what the loaded configuration actually
;; says.  Run it from the checkout under test, which may be a worktree:
;;
;;   emacs --batch --init-directory=MAIN -l test/smoke-test.el
;;
;; where MAIN is the main checkout: the one Emacs runs from, whose
;; elpa/ holds the installed packages.  Run without it, the error
;; names the main checkout of the repository this file is in.
;;
;; It exits non-zero if any test fails.
;;
;; Two directories are in play.  `--init-directory' names the one that
;; holds the runtime state -- elpa/, custom.el, private.el -- and must
;; be the main checkout, since a worktree has none of it.  The config
;; files themselves, and user-lisp/, are taken from the checkout this
;; file sits in, so a worktree tests its own changes against the
;; installed packages.  In a worktree the linked packages (book-list
;; and friends) are absent from user-lisp/, which the config tolerates.
;;
;; The batch-loading traps, each handled below and each silent if not:
;;
;; - `--batch' loads no init file, and the container's ~/.emacs.d is
;;   not the config, so `--init-directory' is required.  The file
;;   refuses to run without it rather than test a bare Emacs.
;; - `--batch' skips early-init.el, package activation and the
;;   preparation of user-lisp/, and leaves `user-init-file' nil, which
;;   makes Customize set where it would save.  All are done here, in
;;   startup's order: early-init.el sets `user-lisp-ignored-directories',
;;   and user-lisp/ needs the packages on `load-path' to compile.
;; - `:custom' values stay void until their package loads, so a test
;;   `require's the package before reading one.
;; - `kill-emacs-hook' would write the main checkout's recentf, history
;;   and other state back on exit, after recentf has pruned every path
;;   the container cannot see.  It is cleared once init.el has loaded,
;;   even if the load fails.
;;
;; Native compilation is turned off, along with the native compilation
;; `prepare-user-lisp' queues, so the run writes nothing into the main
;; checkout's eln-cache/.  Byte-compiling user-lisp/ still writes
;; .elc files and the autoload file beside the sources, as starting
;; Emacs does; all are gitignored.
;;
;; To add a check, add an `ert-deftest' below the load.  Name it
;; `rjd/smoke-...', `require' the package whose settings it reads, and
;; compare against a literal: the point is to catch init.el's intent
;; being overridden, so the expected value must not be read back from
;; the configuration.  A test that has to change state should
;; let-bind it, and must never save into the real custom.el.

;;; Code:

(require 'cl-lib)
(require 'ert)

(defconst rjd/smoke-checkout
  (file-name-directory
   (directory-file-name (file-name-directory (or load-file-name
                                                 buffer-file-name))))
  "The checkout whose config is under test: the parent of test/.")

(defvar rjd/smoke-load-warnings nil
  "Warnings displayed while init.el was loading, as (TYPE MESSAGE).")

(defvar rjd/smoke-load-error nil
  "The error that interrupted loading init.el, or nil.")

(defun rjd/smoke-tolerated-warning-p (type)
  "Whether a warning of TYPE is the environment's, not the config's.
Runtime state files such as recentf and history were written by the
host's Emacs, which may predate the `lexical-binding' cookie that 31.1
warns about.  They have no .el extension, unlike any file of the config.
TYPE for that warning is (files missing-lexbind-cookie FILE)."
  (pcase type
    (`(files missing-lexbind-cookie ,(and (pred stringp) file))
     (not (string-suffix-p ".el" file)))))

(defun rjd/smoke-record-warning (type message &rest _)
  "Record a warning of TYPE with MESSAGE in `rjd/smoke-load-warnings'.
Warnings that `rjd/smoke-tolerated-warning-p' accepts are left out."
  (unless (rjd/smoke-tolerated-warning-p type)
    (push (list type message) rjd/smoke-load-warnings)))

(defun rjd/smoke-run-due-timers ()
  "Run every timer that is due, as returning to the command loop would.
One wait on process output runs only the first due timer before it
returns, and other timers fall due in a long run -- org-persist's
hourly one, for instance -- so wait until none is left, for at most a
second."
  (let ((deadline (+ (float-time) 1)))
    (while (and (< (float-time) deadline)
                (seq-some (lambda (timer)
                            (time-less-p (timer--time timer) nil))
                          timer-list))
      (accept-process-output nil 0.05))))

(defun rjd/smoke-main-checkout ()
  "The main checkout of the repository holding `rjd/smoke-checkout'.
That is the parent of git's common directory, which a worktree shares
with it.  Nil if git cannot say."
  (let ((default-directory rjd/smoke-checkout))
    (with-temp-buffer
      (when (eql 0 (ignore-errors
                     (call-process "git" nil t nil "rev-parse"
                                   "--path-format=absolute"
                                   "--git-common-dir")))
        (file-name-directory
         (directory-file-name (string-trim (buffer-string))))))))

(unless (file-directory-p (file-name-concat user-emacs-directory "elpa"))
  (error "No elpa/ in %s: run with --init-directory=%s"
         user-emacs-directory
         (or (rjd/smoke-main-checkout)
             "the main checkout, the one Emacs runs from")))

(setq native-comp-jit-compilation nil)
(setq user-lisp-directory (file-name-concat rjd/smoke-checkout "user-lisp/"))

;; The steps `command-line' takes in an interactive session and skips in
;; batch, in its order: early-init.el, the user init file (without which
;; Customize sets rather than saves), packages, then user-lisp/.
(advice-add 'display-warning :before #'rjd/smoke-record-warning)
(unwind-protect
    (condition-case err
        (progn
          (load (file-name-concat rjd/smoke-checkout "early-init.el")
                nil :nomessage)
          (setq user-init-file (file-name-concat rjd/smoke-checkout "init.el"))
          (package-activate-all)
          (cl-letf (((symbol-function 'native-compile-async) #'ignore))
            (prepare-user-lisp))
          (load user-init-file nil :nomessage))
      (error (setq rjd/smoke-load-error err)))
  (setq kill-emacs-hook nil)
  (advice-remove 'display-warning #'rjd/smoke-record-warning))


;;; Loading

(ert-deftest rjd/smoke-init-loads-cleanly ()
  "init.el loads without an error or a warning."
  (should-not rjd/smoke-load-error)
  (should-not rjd/smoke-load-warnings))


;;; Org agenda files

(ert-deftest rjd/smoke-org-agenda-files-are-init-el-s ()
  "`org-agenda-files' is exactly the list init.el declares.
A value saved in custom.el would win over init.el's `:custom'."
  (require 'org)
  (should (equal org-agenda-files
                 '("~/org-agenda/inbox.org"
                   "~/org-agenda/projects.org"
                   "~/org-agenda/areas.org"
                   "~/org-agenda/someday.org"
                   "~/org-agenda/gcal-gmail-personal.org"))))

(ert-deftest rjd/smoke-org-agenda-file-commands-do-not-save ()
  "Removing an agenda file changes the session but saves nothing.
Org's `C-c ]', and the [R]emove answer to its prompt about a missing
agenda file, otherwise save the whole list into custom.el.  The user
is told the change lasts only for this session, and where the
permanent list is, by the last message once the command is over: Org's
own message about the change comes after the list is stored, and would
otherwise replace the note in the echo area.  Waiting on process output
lets timers run, as returning to the command loop would; see
`rjd/smoke-run-due-timers'."
  (require 'org)
  (let* ((custom-file (make-temp-file "rjd-smoke-custom" nil ".el"))
         (org-agenda-files org-agenda-files)
         (inbox (expand-file-name "~/org-agenda/inbox.org"))
         (messages nil)
         (record (lambda (format-string &rest args)
                   (when format-string
                     (push (apply #'format-message format-string args)
                           messages)))))
    (unwind-protect
        (progn
          (advice-add 'message :before record)
          (org-remove-file inbox)
          (rjd/smoke-run-due-timers)
          (advice-remove 'message record)
          (should-not (member inbox (org-agenda-files t)))
          (should (string-match-p "this session" (car messages)))
          (should (string-match-p "init\\.el" (car messages)))
          (should-not (with-temp-buffer
                        (insert-file-contents custom-file)
                        (search-forward "org-agenda-files" nil t))))
      (advice-remove 'message record)
      (delete-file custom-file))))



;;; Google Calendar

(ert-deftest rjd/smoke-gcal-fetches-into-the-agenda-s-calendar-file ()
  "The calendar is fetched into the file the agenda lists, and is on."
  (require 'rjd-gcal)
  (should (equal rjd/gcal-file "~/org-agenda/gcal-gmail-personal.org"))
  (should rjd/gcal-mode))

(ert-deftest rjd/smoke-gcal-file-is-not-in-the-ics-export ()
  "The combined iCalendar export leaves the calendar file out.
Its events came from Google, and would otherwise go back into another
calendar through the exported .ics."
  (require 'ox-icalendar)
  (require 'rjd-gcal)
  (let* ((dir (make-temp-file "rjd-smoke-ics" t))
         (tasks (file-name-concat dir "tasks.org"))
         (calendar (file-name-concat dir "calendar.org"))
         (rjd/gcal-file calendar)
         (org-agenda-files (list tasks calendar))
         (org-icalendar-combined-agenda-file
          (file-name-concat dir "agenda.ics")))
    (unwind-protect
        (progn
          (write-region "* Meeting from org\n<2026-10-12 Mon 10:00>\n"
                        nil tasks nil 'silent)
          (write-region "* Meeting from Google\n<2026-10-13 Tue 10:00>\n"
                        nil calendar nil 'silent)
          (org-icalendar-combine-agenda-files)
          (let ((ics (with-temp-buffer
                       (insert-file-contents org-icalendar-combined-agenda-file)
                       (buffer-string))))
            (should (string-search "Meeting from org" ics))
            (should-not (string-search "Meeting from Google" ics))))
      (delete-directory dir t))))

(ert-run-tests-batch-and-exit)

;;; smoke-test.el ends here
