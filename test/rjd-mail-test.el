;;; rjd-mail-test.el --- ERT tests for rjd-mail  -*- lexical-binding: t -*-

;;; Commentary:
;; Run from the repository root with
;;
;;   emacs -Q --batch -l test/rjd-mail-test.el -f ert-run-tests-batch-and-exit
;;
;; `-Q' keeps the personal config out.  This file loads rjd-mail from
;; source by its full name, because user-lisp/ also holds the `.elc'
;; Emacs 31 writes there, and under `-Q' a `require' would take that
;; compiled copy even when it is older than the source.
;;
;; The contexts are mu4e structures, so mu4e's elisp has to be findable.
;; The directories mu4e is installed in on the machines this config runs
;; on are tried below; if none holds it, the tests that need it skip.
;;
;; Nothing here touches the network, a real account or Docker: the
;; accounts are made up, and commands are only built, never run.

;;; Code:

(require 'ert)

(eval-and-compile
  (dolist (dir '("~/.local/mu/share/emacs/site-lisp/mu4e" ; claude-dev build
                 "/opt/homebrew/share/emacs/site-lisp/mu/mu4e"
                 "/usr/local/share/emacs/site-lisp/mu/mu4e"
                 "/usr/share/emacs/site-lisp/elpa-src/mu4e"
                 "/usr/share/emacs/site-lisp/mu4e"))
    (when (file-directory-p (expand-file-name dir))
      (add-to-list 'load-path (expand-file-name dir))))
  (require 'mu4e-context nil :noerror)
  (load (expand-file-name
         "../user-lisp/rjd-mail.el"
         (file-name-directory
          (or load-file-name byte-compile-current-file buffer-file-name)))
        nil :nomessage :nosuffix))

;; Bound with `let' below, so they must be special even when mu4e and
;; message are not loaded.
(defvar message-send-mail-function)
(defvar mu4e-sent-folder)
(defvar mu4e-drafts-folder)
(defvar mu4e-trash-folder)
(defvar mu4e-refile-folder)
(defvar mu4e-sent-messages-behavior)
(defvar mu4e-trash-without-flag)
(defvar mu4e-contexts)
(defvar mu4e-get-mail-command)


;;; Fixtures

(defconst rjd-mail-tests--gmail
  '(:name "gmail-test"
    :address "someone@example.com"
    :full-name "Some One"
    :maildir "/gmail-test")
  "A Gmail account declared with only the required keys.")

(defconst rjd-mail-tests--other
  '(:name "other"
    :address "other@example.org"
    :full-name "Other Person"
    :maildir "/other"
    :folders (:inbox "/INBOX" :sent "/Sent" :drafts "/Drafts"
              :trash "/Trash" :refile "/Archive" :spam "/Junk")
    :sent-messages-behavior sent
    :trash-without-flag nil
    :mbsync-group "other-group")
  "An account that overrides every default.")

(defmacro rjd-mail-tests--with-fastmail-defaults (&rest body)
  "Run BODY with the global mail settings as the Fastmail default."
  (declare (indent 0))
  `(let ((user-mail-address "me@fastmail.example")
         (user-full-name "Me Myself")
         (message-send-mail-function 'smtpmail-send-it)
         (rjd-mail-sendmail-command nil)
         (mu4e-sent-folder "/Sent")
         (mu4e-drafts-folder "/Drafts")
         (mu4e-trash-folder "/Trash")
         (mu4e-refile-folder "/Archive")
         (mu4e-sent-messages-behavior 'sent)
         (mu4e-trash-without-flag nil)
         (rjd-mail--saved nil))
     ,@body))

(defun rjd-mail-tests--context (name contexts)
  "The context called NAME among CONTEXTS."
  (seq-find (lambda (c) (equal (mu4e-context-name c) name)) contexts))

(defun rjd-mail-tests--enter (context)
  "Enter CONTEXT the way `mu4e-context-switch' does."
  (when (mu4e-context-enter-func context)
    (funcall (mu4e-context-enter-func context)))
  (dolist (cell (mu4e-context-vars context))
    (set (car cell) (cdr cell))))

(defun rjd-mail-tests--leave (context)
  "Leave CONTEXT the way `mu4e-context-switch' does."
  (when (mu4e-context-leave-func context)
    (funcall (mu4e-context-leave-func context))))

(defmacro rjd-mail-tests--needs-mu4e ()
  "Skip the current test when mu4e's elisp is not installed."
  '(skip-unless (locate-library "mu4e-context")))


;;; The mail command prefix

(ert-deftest rjd-mail-command-without-prefix ()
  (let ((rjd-mail-command-prefix nil))
    (should (equal (rjd-mail-command "mbsync" "gmail-test")
                   '("mbsync" "gmail-test")))))

(ert-deftest rjd-mail-command-with-prefix ()
  (let ((rjd-mail-command-prefix '("docker" "exec" "-i" "mail")))
    (should (equal (rjd-mail-command "mbsync" "gmail-test")
                   '("docker" "exec" "-i" "mail" "mbsync" "gmail-test")))))


;;; Getting mail

;;; Choosing the prefix for this machine

(defmacro rjd-mail-tests--on-machine (spec &rest body)
  "Run BODY on a made-up machine described by SPEC.
SPEC is a plist: with :inside-container non-nil the machine is a
container (its marker file exists); with :mail-container non-nil the
host has the mail container's configuration directory."
  (declare (indent 1))
  `(let* ((root (make-temp-file "rjd-mail-machine" t))
          (marker (expand-file-name "dockerenv" root))
          (config (expand-file-name "mail-container" root))
          (rjd-mail-container-marker-files (list marker))
          (rjd-mail-container-directory config))
     (unwind-protect
         (progn
           (when (plist-get ',spec :inside-container)
             (write-region "" nil marker))
           (when (plist-get ',spec :mail-container)
             (make-directory config))
           ,@body)
       (delete-directory root t))))

(ert-deftest rjd-mail-default-prefix-on-a-host-with-the-mail-container ()
  "On the host the mail commands go into the mail container."
  (rjd-mail-tests--on-machine (:mail-container t)
    (should (equal (rjd-mail-default-command-prefix)
                   '("docker" "exec" "-i" "mail")))))

(ert-deftest rjd-mail-default-prefix-inside-a-container ()
  "Inside claude-dev the tools run directly, whatever else is there."
  (rjd-mail-tests--on-machine (:inside-container t :mail-container t)
    (should-not (rjd-mail-default-command-prefix))))

(ert-deftest rjd-mail-default-prefix-on-a-host-without-the-mail-container ()
  "A machine without the mail container -- leroy, say -- has no prefix."
  (rjd-mail-tests--on-machine ()
    (should-not (rjd-mail-default-command-prefix))))

(ert-deftest rjd-mail-default-prefix-names-the-container ()
  (rjd-mail-tests--on-machine (:mail-container t)
    (let ((rjd-mail-container-name "post"))
      (should (equal (rjd-mail-default-command-prefix)
                     '("docker" "exec" "-i" "post"))))))

(ert-deftest rjd-mail-get-mail-command-without-prefix ()
  (let ((rjd-mail-command-prefix nil)
        (rjd-mail-accounts (list rjd-mail-tests--gmail rjd-mail-tests--other)))
    (should (equal (rjd-mail-get-mail-command)
                   "mbsync gmail-test other-group"))))

(ert-deftest rjd-mail-get-mail-command-with-prefix ()
  (let ((rjd-mail-command-prefix '("docker" "exec" "-i" "mail box"))
        (rjd-mail-accounts (list rjd-mail-tests--gmail)))
    (should (equal (rjd-mail-get-mail-command)
                   "docker exec -i mail\\ box mbsync gmail-test"))))

(ert-deftest rjd-mail-get-mail-command-without-accounts ()
  "With nothing declared there is nothing to fetch, only to index."
  (let ((rjd-mail-command-prefix '("docker" "exec" "-i" "mail"))
        (rjd-mail-accounts nil))
    (should (equal (rjd-mail-get-mail-command) "true"))))


;;; Accounts to contexts

(ert-deftest rjd-mail-contexts-one-per-account ()
  (rjd-mail-tests--needs-mu4e)
  (let ((contexts (rjd-mail-contexts
                   (list rjd-mail-tests--gmail rjd-mail-tests--other))))
    (should (equal (mapcar #'mu4e-context-name contexts)
                   '("gmail-test" "other")))))

(ert-deftest rjd-mail-contexts-empty ()
  "No accounts gives no contexts, and needs nothing from mu4e."
  (should (equal (rjd-mail-contexts nil) nil)))

(ert-deftest rjd-mail-entering-gmail-sets-identity-folders-and-sent ()
  (rjd-mail-tests--needs-mu4e)
  (rjd-mail-tests--with-fastmail-defaults
    (rjd-mail-tests--enter
     (car (rjd-mail-contexts (list rjd-mail-tests--gmail))))
    (should (equal user-mail-address "someone@example.com"))
    (should (equal user-full-name "Some One"))
    (should (equal mu4e-sent-folder "/gmail-test/sent"))
    (should (equal mu4e-drafts-folder "/gmail-test/drafts"))
    (should (equal mu4e-trash-folder "/gmail-test/trash"))
    (should (equal mu4e-refile-folder "/gmail-test/all"))
    (should (eq mu4e-sent-messages-behavior 'delete))
    ;; Trashed mail must reach Gmail's Trash: with the trashed flag,
    ;; mbsync would expunge it instead, and Gmail would only archive it.
    (should (eq mu4e-trash-without-flag t))))

(ert-deftest rjd-mail-entering-sets-declared-folders-and-sent ()
  (rjd-mail-tests--needs-mu4e)
  (rjd-mail-tests--with-fastmail-defaults
    (rjd-mail-tests--enter
     (car (rjd-mail-contexts (list rjd-mail-tests--other))))
    (should (equal user-mail-address "other@example.org"))
    (should (equal mu4e-sent-folder "/other/Sent"))
    (should (equal mu4e-refile-folder "/other/Archive"))
    (should (eq mu4e-sent-messages-behavior 'sent))
    (should (eq mu4e-trash-without-flag nil))))

(ert-deftest rjd-mail-leaving-restores-fastmail-default ()
  (rjd-mail-tests--needs-mu4e)
  (rjd-mail-tests--with-fastmail-defaults
    (let ((context (car (rjd-mail-contexts (list rjd-mail-tests--gmail)))))
      (rjd-mail-tests--enter context)
      (rjd-mail-tests--leave context)
      (should (equal user-mail-address "me@fastmail.example"))
      (should (equal user-full-name "Me Myself"))
      (should (eq message-send-mail-function 'smtpmail-send-it))
      (should (equal rjd-mail-sendmail-command nil))
      (should (equal mu4e-sent-folder "/Sent"))
      (should (equal mu4e-drafts-folder "/Drafts"))
      (should (equal mu4e-trash-folder "/Trash"))
      (should (equal mu4e-refile-folder "/Archive"))
      (should (eq mu4e-sent-messages-behavior 'sent))
      (should (eq mu4e-trash-without-flag nil)))))

(ert-deftest rjd-mail-switching-between-accounts-then-leaving ()
  "Switching from one account to another still ends on the default."
  (rjd-mail-tests--needs-mu4e)
  (rjd-mail-tests--with-fastmail-defaults
    (let* ((contexts (rjd-mail-contexts
                      (list rjd-mail-tests--gmail rjd-mail-tests--other)))
           (gmail (rjd-mail-tests--context "gmail-test" contexts))
           (other (rjd-mail-tests--context "other" contexts)))
      (rjd-mail-tests--enter gmail)
      (rjd-mail-tests--leave gmail)
      (rjd-mail-tests--enter other)
      (should (equal user-mail-address "other@example.org"))
      (rjd-mail-tests--leave other)
      (should (equal user-mail-address "me@fastmail.example"))
      (should (eq mu4e-sent-messages-behavior 'sent)))))

(ert-deftest rjd-mail-context-matches-its-own-mail ()
  (rjd-mail-tests--needs-mu4e)
  (let* ((contexts (rjd-mail-contexts
                    (list rjd-mail-tests--gmail rjd-mail-tests--other)))
         (gmail (rjd-mail-tests--context "gmail-test" contexts))
         (matches (lambda (msg) (funcall (mu4e-context-match-func gmail) msg))))
    (should (funcall matches '(:maildir "/gmail-test/inbox")))
    (should (funcall matches
                     '(:maildir "/elsewhere"
                       :to ((:name "S" :email "Someone@Example.com")))))
    (should-not (funcall matches '(:maildir "/other/INBOX")))
    (should-not (funcall matches '(:maildir "/gmail-test-other/inbox")))
    (should-not (funcall matches nil))))


;;; Sending

(ert-deftest rjd-mail-entering-gmail-sends-through-msmtp ()
  (rjd-mail-tests--needs-mu4e)
  (rjd-mail-tests--with-fastmail-defaults
    (let ((rjd-mail-command-prefix nil))
      (rjd-mail-tests--enter
       (car (rjd-mail-contexts (list rjd-mail-tests--gmail))))
      (should (eq message-send-mail-function #'rjd-mail-send-it))
      (should (equal rjd-mail-sendmail-command
                     '("msmtp" "-a" "gmail-test" "--read-envelope-from"))))))

(ert-deftest rjd-mail-entering-sends-through-the-prefix ()
  "The prefix in force on entering a context is the one msmtp runs behind.
On the host it reaches the mail container; the -oi that message's own
sendmail path puts before any extra argument must not land in it."
  (rjd-mail-tests--needs-mu4e)
  (rjd-mail-tests--with-fastmail-defaults
    (let* ((rjd-mail-command-prefix nil)
           (context (car (rjd-mail-contexts (list rjd-mail-tests--other)))))
      (setq rjd-mail-command-prefix '("docker" "exec" "-i" "mail"))
      (rjd-mail-tests--enter context)
      (should (eq message-send-mail-function #'rjd-mail-send-it))
      (should (equal rjd-mail-sendmail-command
                     '("docker" "exec" "-i" "mail"
                       "msmtp" "-a" "other" "--read-envelope-from"))))))

(defun rjd-mail-tests--file-string (file)
  "The contents of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun rjd-mail-tests--send (command message)
  "Send MESSAGE with `rjd-mail-send-it', COMMAND standing in for msmtp.
MESSAGE is as message-mode prepares it, headers and body divided by
`mail-header-separator'.  COMMAND is a shell script; it runs as
\"sh -c COMMAND sh exec -i mail msmtp -a gmail-test ...\", so its
\"$@\" is the prefixed command line msmtp would get.  Returns the
result of sending."
  (require 'sendmail)
  (let ((rjd-mail-sendmail-command
         (list "sh" "-c" command "sh"
               "exec" "-i" "mail" "msmtp" "-a" "gmail-test"
               "--read-envelope-from")))
    (with-temp-buffer
      (insert (format message mail-header-separator))
      (rjd-mail-send-it))))

(ert-deftest rjd-mail-send-it-pipes-the-message-to-the-command ()
  "The message reaches the command, which reads its recipients from it.
Nothing comes between the command's own words, as message's sendmail
path would put -oi after the program -- `docker -oi exec ...'."
  (let* ((dir (make-temp-file "rjd-mail-send" t))
         (args (file-name-concat dir "args"))
         (msg (file-name-concat dir "msg")))
    (unwind-protect
        (progn
          (rjd-mail-tests--send
           (format "printf '%%s\\n' \"$@\" > %s; cat > %s"
                   (shell-quote-argument args) (shell-quote-argument msg))
           "To: you@example.net\nSubject: Hi\n%s\nHello.\n")
          (should (equal (rjd-mail-tests--file-string args)
                         (concat "exec\n-i\nmail\nmsmtp\n-a\ngmail-test\n"
                                 "--read-envelope-from\n-t\n")))
          (should (equal (rjd-mail-tests--file-string msg)
                         "To: you@example.net\nSubject: Hi\n\nHello.\n")))
      (delete-directory dir t))))

(ert-deftest rjd-mail-send-it-resends-to-resent-to ()
  "A resend goes to the Resent-To addresses, not the original recipients."
  (let ((args (make-temp-file "rjd-mail-send-args")))
    (unwind-protect
        (progn
          (rjd-mail-tests--send
           (format "printf '%%s\\n' \"$@\" > %s; cat > /dev/null"
                   (shell-quote-argument args))
           (concat "Resent-To: A <a@example.net>, b@example.net\n"
                   "To: you@example.net\n%s\nHello.\n"))
          (should (string-suffix-p "--read-envelope-from\na@example.net\nb@example.net\n"
                                   (rjd-mail-tests--file-string args))))
      (delete-file args))))

(ert-deftest rjd-mail-send-it-reports-failure ()
  "A command that fails makes sending fail, with what it said."
  (let ((err (should-error
              (rjd-mail-tests--send "cat > /dev/null; echo 'no token' >&2; exit 78"
                                    "To: you@example.net\n%s\nHello.\n"))))
    (should (string-match-p "no token" (error-message-string err)))))

(ert-deftest rjd-mail-send-it-needs-a-context ()
  "Outside every context there is no account to send as."
  (let ((rjd-mail-sendmail-command nil))
    (with-temp-buffer
      (should-error (rjd-mail-send-it)))))


;;; Junk

(ert-deftest rjd-mail-without-junk-excludes-spam-and-trash ()
  (let ((rjd-mail-accounts (list rjd-mail-tests--gmail rjd-mail-tests--other)))
    (should (equal (rjd-mail-without-junk "flag:unread")
                   (concat "(flag:unread) AND NOT (maildir:/gmail-test/spam"
                           " OR maildir:/gmail-test/trash"
                           " OR maildir:/other/Junk OR maildir:/other/Trash)")))))

(ert-deftest rjd-mail-without-junk-without-accounts ()
  (let ((rjd-mail-accounts nil))
    (should (equal (rjd-mail-without-junk "flag:unread") "flag:unread"))))


;;; Flags on unread mail

(defun rjd-mail-tests--maildir-files (root)
  "The files under ROOT, relative to it, sorted."
  (sort (mapcar (lambda (file) (file-relative-name file root))
                (directory-files-recursively root ""))
        #'string<))

(ert-deftest rjd-mail-file-flagged-new-moves-flagged-unread-to-cur ()
  "An unread starred message must reach cur/, or mu drops its star.
mbsync files unread mail in new/ with its flags in the name; mu reads
anything in new/ as New alone, so marking it read writes `:2,S' and the
next sync removes Gmail's Starred label (#18)."
  (let* ((root (make-temp-file "rjd-mail-test-" t))
         (rjd-mail-accounts (list rjd-mail-tests--gmail)))
    (unwind-protect
        (progn
          (dolist (dir '("inbox" "all"))
            (dolist (sub '("cur" "new" "tmp"))
              (make-directory (format "%s/gmail-test/%s/%s" root dir sub) t)))
          (dolist (file '("inbox/new/1.h,U=1:2,F"    ; starred, unread
                          "all/new/1.h,U=7:2,FR"     ; and replied to
                          "inbox/new/2.h,U=2:2,"     ; unread, nothing else
                          "inbox/new/3.h"            ; no info at all
                          "inbox/cur/4.h,U=4:2,FS")) ; read already
            (write-region "" nil (format "%s/gmail-test/%s" root file)))
          (rjd-mail-file-flagged-new root)
          (should (equal (rjd-mail-tests--maildir-files root)
                         '("gmail-test/all/cur/1.h,U=7:2,FR"
                           "gmail-test/inbox/cur/1.h,U=1:2,F"
                           "gmail-test/inbox/cur/4.h,U=4:2,FS"
                           "gmail-test/inbox/new/2.h,U=2:2,"
                           "gmail-test/inbox/new/3.h"))))
      (delete-directory root t))))

(ert-deftest rjd-mail-file-flagged-new-leaves-other-maildirs ()
  "Only the declared accounts' mail is touched."
  (let* ((root (make-temp-file "rjd-mail-test-" t))
         (rjd-mail-accounts (list rjd-mail-tests--gmail)))
    (unwind-protect
        (progn
          (make-directory (format "%s/fastmail/INBOX/new" root) t)
          (make-directory (format "%s/fastmail/INBOX/cur" root) t)
          (write-region "" nil (format "%s/fastmail/INBOX/new/1.h:2,F" root))
          (rjd-mail-file-flagged-new root)
          (should (equal (rjd-mail-tests--maildir-files root)
                         '("fastmail/INBOX/new/1.h:2,F"))))
      (delete-directory root t))))


;;; The mode

(ert-deftest rjd-mail-mode-installs-and-restores ()
  (rjd-mail-tests--needs-mu4e)
  (let ((rjd-mail-accounts (list rjd-mail-tests--gmail))
        (mu4e-contexts nil)
        (mu4e-get-mail-command "true")
        (rjd-mail-mode nil)
        (rjd-mail--before-mode nil))
    (rjd-mail-mode 1)
    (should (equal (mapcar #'mu4e-context-name mu4e-contexts) '("gmail-test")))
    (should (eq mu4e-get-mail-command #'rjd-mail-get-mail-command))
    (rjd-mail-mode -1)
    (should (equal mu4e-contexts nil))
    (should (equal mu4e-get-mail-command "true"))))

(ert-deftest rjd-mail-mode-files-flagged-new-before-indexing ()
  "Every index -- after a fetch, or on its own -- sees the flags (#18)."
  (rjd-mail-tests--needs-mu4e)
  (require 'mu4e-update)
  (let* ((root (make-temp-file "rjd-mail-test-" t))
         (rjd-mail-accounts (list rjd-mail-tests--gmail))
         (mu4e-contexts nil)
         (mu4e-get-mail-command "true")
         (rjd-mail-mode nil)
         (rjd-mail--before-mode nil)
         indexed-files)
    (unwind-protect
        (progn
          (make-directory (format "%s/gmail-test/inbox/new" root) t)
          (make-directory (format "%s/gmail-test/inbox/cur" root) t)
          (write-region "" nil (format "%s/gmail-test/inbox/new/1.h,U=1:2,F"
                                       root))
          (cl-letf (((symbol-function 'mu4e-root-maildir) (lambda () root))
                    ((symbol-function 'mu4e--server-index)
                     (lambda (&rest _)
                       (setq indexed-files
                             (rjd-mail-tests--maildir-files root)))))
            (rjd-mail-mode 1)
            (mu4e-update-index)
            (rjd-mail-mode -1)
            (should (equal indexed-files
                           '("gmail-test/inbox/cur/1.h,U=1:2,F")))
            ;; Off, the mode leaves indexing alone.
            (rename-file (format "%s/gmail-test/inbox/cur/1.h,U=1:2,F" root)
                         (format "%s/gmail-test/inbox/new/" root))
            (mu4e-update-index)
            (should (equal indexed-files
                           '("gmail-test/inbox/new/1.h,U=1:2,F")))))
      (rjd-mail-mode -1)
      (delete-directory root t))))

(ert-deftest rjd-mail-mode-without-accounts ()
  "No accounts: the mode turns on cleanly and adds no contexts."
  (let ((rjd-mail-accounts nil)
        (mu4e-contexts nil)
        (mu4e-get-mail-command "true")
        (rjd-mail-mode nil)
        (rjd-mail--before-mode nil))
    (rjd-mail-mode 1)
    (should (equal mu4e-contexts nil))
    (should (equal (funcall mu4e-get-mail-command) "true"))
    (rjd-mail-mode -1)))

;;; Mail written outside mu4e

(defmacro rjd-mail-tests--in-gmail-context (&rest body)
  "Run BODY with `rjd-mail-mode' on and the Gmail context entered."
  (declare (indent 0))
  `(rjd-mail-tests--with-fastmail-defaults
     (let ((rjd-mail-accounts (list rjd-mail-tests--gmail))
           (rjd-mail-command-prefix nil)
           (mu4e-contexts nil)
           (mu4e-get-mail-command "true")
           (rjd-mail-mode nil)
           (rjd-mail--before-mode nil)
           (message-mode-hook nil))
       (rjd-mail-mode 1)
       (unwind-protect
           (progn
             (rjd-mail-tests--enter (car mu4e-contexts))
             ,@body)
         (rjd-mail-mode -1)))))

(ert-deftest rjd-mail-message-mode-outside-mu4e-keeps-fastmail ()
  "Plain message-mode sends as the Fastmail default, inside a context too.
mu4e's context is global and outlives quitting mu4e, so without this
\\[compose-mail] would send as whichever account mu4e last used."
  (rjd-mail-tests--needs-mu4e)
  (rjd-mail-tests--in-gmail-context
    (should (equal user-mail-address "someone@example.com"))
    (with-temp-buffer
      (message-mode)
      (should (equal user-mail-address "me@fastmail.example"))
      (should (equal user-full-name "Me Myself"))
      (should (eq message-send-mail-function 'smtpmail-send-it)))))

(ert-deftest rjd-mail-mu4e-compose-uses-the-context ()
  "mu4e's own compose buffers send as the context's account."
  (rjd-mail-tests--needs-mu4e)
  (require 'mu4e-compose)
  (rjd-mail-tests--in-gmail-context
    (with-temp-buffer
      (mu4e-compose-mode)
      (should (equal user-mail-address "someone@example.com"))
      (should (eq message-send-mail-function #'rjd-mail-send-it)))))

(ert-deftest rjd-mail-message-mode-outside-every-context ()
  "With no context entered message-mode is left alone."
  (rjd-mail-tests--needs-mu4e)
  (rjd-mail-tests--with-fastmail-defaults
    (let ((rjd-mail-accounts (list rjd-mail-tests--gmail))
          (mu4e-contexts nil)
          (rjd-mail-mode nil)
          (rjd-mail--before-mode nil)
          (message-mode-hook nil))
      (rjd-mail-mode 1)
      (unwind-protect
          (with-temp-buffer
            (message-mode)
            (should-not (local-variable-p 'user-mail-address))
            (should (eq message-send-mail-function 'smtpmail-send-it)))
        (rjd-mail-mode -1)))))


(provide 'rjd-mail-test)
;;; rjd-mail-test.el ends here
