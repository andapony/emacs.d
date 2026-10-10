;;; rjd-mail-tests.el --- ERT tests for rjd-mail  -*- lexical-binding: t -*-

;;; Commentary:
;; Run from the repository root with
;;
;;   emacs -Q --batch -l user-lisp/test/rjd-mail-tests.el \
;;         -f ert-run-tests-batch-and-exit
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
         "../rjd-mail.el"
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

(provide 'rjd-mail-tests)
;;; rjd-mail-tests.el ends here
