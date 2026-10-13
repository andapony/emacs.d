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

(defvar rjd/smoke-features-after-init nil
  "The features loaded once init.el had loaded, before any test ran.")

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
          (load user-init-file nil :nomessage)
          (setq rjd/smoke-features-after-init (copy-sequence features)))
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


;;; Mail

(ert-deftest rjd/smoke-mu4e-goes-through-rjd-mail ()
  "Loading mu4e turns on `rjd/mail-mode', and mail is fetched through it.
Skipped where mu4e is not installed.  Whether accounts are declared
depends on the private.el in use, so the contexts are not checked."
  (skip-unless (locate-library "mu4e"))
  (require 'mu4e)
  (should rjd/mail-mode)
  (should (eq mu4e-get-mail-command #'rjd/mail-get-mail-command))
  (should (eq mu4e-search-skip-duplicates t))
  (should (eq mu4e-search-include-related nil))
  (should (eq mu4e-context-policy 'pick-first))
  (should (eq mu4e-compose-context-policy 'ask))
  (should (eq mu4e-query-rewrite-function #'rjd/mail-search-query)))

(defconst rjd/smoke-invitation
  (concat "MIME-Version: 1.0\n"
          "Content-Type: text/calendar; charset=UTF-8; method=REQUEST\n"
          "\n"
          "BEGIN:VCALENDAR\r\n"
          "PRODID:-//rjd smoke test//EN\r\n"
          "VERSION:2.0\r\n"
          "METHOD:REQUEST\r\n"
          "BEGIN:VEVENT\r\n"
          "DTSTART:20261012T170000Z\r\n"
          "DTEND:20261012T173000Z\r\n"
          "DTSTAMP:20261010T120000Z\r\n"
          "ORGANIZER;CN=Organiser:mailto:organiser@test.invalid\r\n"
          "UID:rjd-smoke-invitation@test.invalid\r\n"
          "ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;"
          "RSVP=TRUE;CN=me@test.invalid:mailto:me@test.invalid\r\n"
          "SEQUENCE:0\r\n"
          "STATUS:CONFIRMED\r\n"
          "SUMMARY:Smoke test meeting\r\n"
          "END:VEVENT\r\n"
          "END:VCALENDAR\r\n")
  "A message that is a meeting invitation to me@test.invalid.")

(defun rjd/smoke-render-invitation ()
  "Render `rjd/smoke-invitation' as a mu4e view shows it inline.
Return the labels of the buttons it carries, in order.  The invitation
is addressed to `user-mail-address', which is let-bound to its attendee
as entering that account's context would."
  (let ((user-mail-address "me@test.invalid")
        (handle (with-temp-buffer
                  (insert rjd/smoke-invitation)
                  (mm-dissect-buffer t))))
    (with-temp-buffer
      (should (mm-inlinable-p handle))
      (mm-display-inline handle)
      (let ((labels nil)
            (pos (point-min)))
        (while (setq pos (text-property-not-all pos (point-max)
                                                'gnus-callback nil))
          (let ((end (next-single-property-change pos 'gnus-callback
                                                  nil (point-max))))
            (push (string-trim (buffer-substring-no-properties pos end)
                               "\\[ " " \\]")
                  labels)
            (setq pos end)))
        (nreverse labels)))))

(ert-deftest rjd/smoke-mu4e-invitations-are-answered-from-mu4e ()
  "An invitation in mu4e offers Accept, Tentative and Decline.
Loading mu4e loads mu4e-icalendar, so that pressing one replies from
mu4e -- the button's function is Gnus's, which mu4e-icalendar takes
over in a mu4e view.  Skipped where mu4e is not installed."
  (skip-unless (locate-library "mu4e"))
  (require 'mu4e)
  (should (featurep 'mu4e-icalendar))
  (should (equal (rjd/smoke-render-invitation)
                 '("Accept" "Tentative" "Decline"))))

(ert-deftest rjd/smoke-mu4e-invitations-make-no-org-entry ()
  "Answering an invitation adds it neither to org nor to the diary.
The calendar fetch brings accepted events into the agenda; an entry
written on accepting would duplicate them.  Gnus's org integration
would also put Export to Org and Show Agenda buttons on the
invitation.  Skipped where mu4e is not installed."
  (skip-unless (locate-library "mu4e"))
  (require 'mu4e)
  (should (featurep 'mu4e-icalendar))
  (should-not gnus-icalendar-org-enabled-p)
  (should-not mu4e-icalendar-diary-file)
  (should-not (seq-intersection (rjd/smoke-render-invitation)
                                '("Export to Org" "Update Org Entry"
                                  "Show Agenda" "Show Org Entry"))))

(ert-deftest rjd/smoke-mail-syncs-from-startup ()
  "Starting Emacs starts mu4e's background updates, through rjd-mail.
Whether mu4e starts is for `rjd/mail-start-syncing' to decide, by the
machine and the accounts, so only the hook is checked; batch Emacs
never runs `emacs-startup-hook'."
  (should (memq #'rjd/mail-start-syncing emacs-startup-hook))
  (should (fboundp 'rjd/mail-start-syncing)))

(ert-deftest rjd/smoke-mail-is-written-in-mu4e ()
  "C-x m opens mu4e's compose, whose agent is defined before mu4e loads.
Checked against the features init.el alone loaded, since other tests
load mu4e.  Skipped where mu4e is not installed."
  (skip-unless (locate-library "mu4e"))
  (should (eq mail-user-agent 'mu4e-user-agent))
  (should (eq (get 'mu4e-user-agent 'composefunc) #'mu4e-compose-mail))
  (should-not (memq 'mu4e rjd/smoke-features-after-init)))

(ert-deftest rjd/smoke-mu4e-links-follow-before-mu4e-loads ()
  "An org mu4e: link is followed by `mu4e-org-open', autoloaded."
  (require 'org)
  (should (eq (org-link-get-parameter "mu4e" :follow) #'mu4e-org-open))
  (should (fboundp 'mu4e-org-open)))

(ert-deftest rjd/smoke-mail-is-spell-checked-before-sending ()
  "Sending a message runs jinx over it, and skips its MML tags."
  (require 'message)
  (require 'jinx)
  (should (memq #'rjd/jinx-correct-before-send message-send-hook))
  (should (memq 'message-mml (alist-get 'message-mode jinx-exclude-faces)))
  ;; jinx's own exclusions for message-mode are kept alongside.
  (should (memq 'message-cited-text-1
                (alist-get 'message-mode jinx-exclude-faces))))

(ert-deftest rjd/smoke-mu4e-composes-format-flowed ()
  "mu4e's compose wraps on screen and sends format=flowed, unfilled.
Skipped where mu4e is not installed."
  (skip-unless (locate-library "mu4e"))
  (require 'mu4e)
  (with-temp-buffer
    (mu4e-compose-mode)
    (should-not auto-fill-function)
    (should visual-line-mode)
    (should use-hard-newlines)
    (should mml-enable-flowed)))

(ert-deftest rjd/smoke-no-completion-preview-in-prose ()
  "The completion preview is on in code but off in text-mode buffers.
Mail composition derives from text-mode, so it is covered too."
  (should global-completion-preview-mode)
  (with-temp-buffer
    (emacs-lisp-mode)
    (should completion-preview-mode))
  (dolist (mode '(text-mode message-mode))
    (with-temp-buffer
      (funcall mode)
      (should-not completion-preview-mode))))

(defun rjd/smoke-send-with-body (body)
  "Run `message-send-hook' on a draft with BODY, and say what happened.
Return (:prompted P :sent S): P the word the corrections opened on,
or nil if they did not, and S if the hook let the message go.
Quitting at the first correction stands in for the user doing so.
Point is left at the end of the draft, where it is after writing it.
The draft also has an attachment's MML tag and a quoted line, each
with a misspelling that must not count.  The draft is shown in the
selected window, as when it is sent, since the corrections recenter
it."
  (with-temp-buffer
    (set-window-buffer nil (current-buffer))
    (message-mode)
    (jinx-mode 1)
    (insert "To: someone@example.com\nSubject: Hello\n"
            mail-header-separator "\n" body "\n"
            "<#part type=\"text/plain\" filename=\"/tmp/invte.ics\">\n"
            "> a quoted mispeling\n")
    (font-lock-ensure)
    (let (prompted)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _)
                   (setq prompted (current-word t))
                   (signal 'quit nil))))
        (condition-case nil
            (progn (run-hooks 'message-send-hook)
                   (list :prompted prompted :sent t))
          (quit (list :prompted prompted :sent nil)))))))

(ert-deftest rjd/smoke-mail-spell-check-sends-clean-mail ()
  "A message with nothing to correct is sent without a prompt."
  (require 'message)
  (require 'jinx)
  (should (equal (rjd/smoke-send-with-body "This is a test of the spelling.")
                 '(:prompted nil :sent t))))

(ert-deftest rjd/smoke-mail-spell-check-stops-on-quit ()
  "Misspellings open the corrections at the first, and quitting stops the send."
  (require 'message)
  (require 'jinx)
  (should (equal (rjd/smoke-send-with-body "This is a tset of the speling.")
                 '(:prompted "tset" :sent nil))))


;;; Capture

(defun rjd/smoke-capture-cetos (from &optional mail-link)
  "Capture an empty Cetos task as if from buffer FROM, and return it.
The task is the text the capture adds to its target, as a string.
With MAIL-LINK, an org link to a message, capture as if from that
message in mu4e: the link is handed to `org-capture' already stored,
as it would be by mu4e-org, which is how org-protocol and the like
pass a link in too.  Without it, capture stores a link to FROM as
usual.  The template is init.el's \"c\" one, aimed at a temporary
file, and the capture is dated 2026-10-10 09:30."
  (let* ((target (make-temp-file "rjd-smoke-cetos" nil ".org"))
         (cetos (assoc "c" org-capture-templates))
         (org-capture-templates
          (list (append (seq-take cetos 3)
                        (list (list 'file+headline target "Cetos"))
                        (seq-drop cetos 4))))
         (org-overriding-default-time
          (encode-time '(0 30 9 10 10 2026 nil -1 nil)))
         (org-capture-link-is-already-stored (and mail-link t))
         (org-store-link-plist (and mail-link
                                    (list :type "mu4e"
                                          :annotation mail-link))))
    (unwind-protect
        (with-current-buffer from
          (org-capture nil "c")
          (org-capture-finalize)
          (with-current-buffer (find-buffer-visiting target)
            (prog1 (buffer-substring-no-properties (point-min) (point-max))
              (set-buffer-modified-p nil)
              (kill-buffer))))
      (delete-file target))))

(ert-deftest rjd/smoke-cetos-capture-keeps-its-key-and-target ()
  "The Cetos template is still `c', filed under Cetos in projects.org."
  (require 'org-capture)
  (let ((cetos (assoc "c" org-capture-templates)))
    (should (equal (seq-take cetos 4)
                   '("c" "Cetos task" entry
                     (file+headline "~/org-agenda/projects.org" "Cetos"))))
    (should (equal (seq-drop cetos 5) '(:prepend nil :empty-lines 1)))))

(ert-deftest rjd/smoke-cetos-capture-from-elsewhere-is-unchanged ()
  "Captured from a file, a Cetos task is just the TODO and its date.
The link org stores to the file is left out, as it always was."
  (require 'org-capture)
  (let ((file (make-temp-file "rjd-smoke-notes" nil ".txt" "Some notes\n")))
    (unwind-protect
        (let ((buffer (find-file-noselect file)))
          (unwind-protect
              (should (equal (rjd/smoke-capture-cetos buffer)
                             "* Cetos\n\n** TODO \n  [2026-10-10 Sat 09:30]\n\n"))
            (kill-buffer buffer)))
      (delete-file file))))

(ert-deftest rjd/smoke-cetos-capture-from-a-message-links-to-it ()
  "Captured from a mu4e message, a Cetos task links back to it."
  (require 'org-capture)
  (with-temp-buffer
    (should (equal (rjd/smoke-capture-cetos
                    (current-buffer)
                    "[[mu4e:msgid:rjd9@test.invalid][Budget for Q4]]")
                   (concat "* Cetos\n\n** TODO \n  [2026-10-10 Sat 09:30]\n"
                           "  [[mu4e:msgid:rjd9@test.invalid][Budget for Q4]]\n\n")))))


;;; Google Calendar

(ert-deftest rjd/smoke-gcal-fetches-into-the-agenda-s-calendar-file ()
  "The calendar is fetched into the file the agenda lists, and is on.
It is turned on, through its autoload, once the agenda loads, and is
not loaded before then."
  (should-not (memq 'rjd-gcal rjd/smoke-features-after-init))
  (require 'org-agenda)
  (should rjd/gcal-mode)
  (should (equal rjd/gcal-file "~/org-agenda/gcal-gmail-personal.org")))

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
