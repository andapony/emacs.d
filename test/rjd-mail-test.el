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
(defvar message-alternative-emails)
(defvar mu4e-sent-folder)
(defvar mu4e-drafts-folder)
(defvar mu4e-trash-folder)
(defvar mu4e-refile-folder)
(defvar mu4e-sent-messages-behavior)
(defvar mu4e-trash-without-flag)
(defvar mu4e-contexts)
(defvar mu4e-get-mail-command)
(defvar mu4e-query-rewrite-function)
(defvar gnus-ignored-from-addresses)
(defvar gnus-icalendar-additional-identities)


;;; Fixtures

;; Mail can run, for every test that does not say otherwise: the tests
;; are about what declared accounts do where they take effect, and the
;; machine running them need not have the mail tools.
(setq rjd/mail-enabled t)

(defconst rjd/mail-test-gmail
  '(:name "gmail-test"
    :address "someone@example.com"
    :full-name "Some One"
    :maildir "/gmail-test")
  "A Gmail account declared with only the required keys.")

(defconst rjd/mail-test-other
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

(defconst rjd/mail-test-fastmail
  '(:name "fastmail-test"
    :address "someone@fastmail.example"
    :full-name "Some One"
    :maildir "/fastmail-test"
    :folders (:inbox "/INBOX" :sent "/Sent" :drafts "/Drafts"
              :trash "/Trash" :refile "/Archive" :spam "/Spam")
    :sent-messages-behavior sent)
  "A Fastmail account, declared as private.el declares the real one.
Fastmail's folders sit at the top level under their own names, and it
does not file mail sent over SMTP, so mu4e must; the rest is default.")

(defconst rjd/mail-test-fastmail-aliases
  (append '(:addresses
            "someone\\+[^@]*@fastmail\\.example\\|[^@]+@someone\\.fastmail\\.example\\|[^@]+@someone\\.example")
          rjd/mail-test-fastmail)
  "The Fastmail account with its aliases as one regexp, as private.el
declares them: plus addresses, subdomain addresses and a catch-all on
the account's own domain.")

(defconst rjd/mail-test-alias-addresses
  '("someone+shop@fastmail.example"
    "shop@someone.fastmail.example"
    "anything@someone.example")
  "One address of each alias form `rjd/mail-test-fastmail-aliases' matches:
plus, subdomain and catch-all.")

(defmacro rjd/mail-test-with-fastmail-defaults (&rest body)
  "Run BODY with the global mail settings as the Fastmail default."
  (declare (indent 0))
  `(let ((user-mail-address "me@fastmail.example")
         (user-full-name "Me Myself")
         (message-send-mail-function 'smtpmail-send-it)
         (message-user-fqdn nil)
         (mu4e-sent-folder "/Sent")
         (mu4e-drafts-folder "/Drafts")
         (mu4e-trash-folder "/Trash")
         (mu4e-refile-folder "/Archive")
         (mu4e-sent-messages-behavior 'sent)
         (mu4e-trash-without-flag nil)
         (rjd/mail--saved nil))
     ,@body))

(defun rjd/mail-test-context (name contexts)
  "The context called NAME among CONTEXTS."
  (seq-find (lambda (c) (equal (mu4e-context-name c) name)) contexts))

(defun rjd/mail-test-enter (context)
  "Enter CONTEXT the way `mu4e-context-switch' does."
  (when (mu4e-context-enter-func context)
    (funcall (mu4e-context-enter-func context)))
  (dolist (cell (mu4e-context-vars context))
    (set (car cell) (cdr cell))))

(defun rjd/mail-test-leave (context)
  "Leave CONTEXT the way `mu4e-context-switch' does."
  (when (mu4e-context-leave-func context)
    (funcall (mu4e-context-leave-func context))))

(defmacro rjd/mail-test-needs-mu4e ()
  "Skip the current test when mu4e's elisp is not installed."
  '(skip-unless (locate-library "mu4e-context")))


;;; The mail command prefix

(ert-deftest rjd/mail-command-without-prefix ()
  (let ((rjd/mail-command-prefix nil))
    (should (equal (rjd/mail-command "mbsync" "gmail-test")
                   '("mbsync" "gmail-test")))))

(ert-deftest rjd/mail-command-with-prefix ()
  (let ((rjd/mail-command-prefix '("docker" "exec" "-i" "mail")))
    (should (equal (rjd/mail-command "mbsync" "gmail-test")
                   '("docker" "exec" "-i" "mail" "mbsync" "gmail-test")))))


;;; Getting mail

;;; Choosing the prefix for this machine

(defmacro rjd/mail-test-on-machine (spec &rest body)
  "Run BODY on a made-up machine described by SPEC.
SPEC is a plist: with :inside-container non-nil the machine is a
container (its marker file exists); with :mail-container non-nil the
host has the mail container's configuration directory."
  (declare (indent 1))
  `(let* ((root (make-temp-file "rjd-mail-machine" t))
          (marker (expand-file-name "dockerenv" root))
          (config (expand-file-name "mail-container" root))
          (rjd/mail-container-marker-files (list marker))
          (rjd/mail-container-directory config))
     (unwind-protect
         (progn
           (when (plist-get ',spec :inside-container)
             (write-region "" nil marker))
           (when (plist-get ',spec :mail-container)
             (make-directory config))
           ,@body)
       (delete-directory root t))))

(ert-deftest rjd/mail-default-prefix-on-a-host-with-the-mail-container ()
  "On the host the mail commands go into the mail container."
  (rjd/mail-test-on-machine (:mail-container t)
    (should (equal (rjd/mail-default-command-prefix)
                   '("docker" "exec" "-i" "mail")))))

(ert-deftest rjd/mail-default-prefix-inside-a-container ()
  "Inside claude-dev the tools run directly, whatever else is there."
  (rjd/mail-test-on-machine (:inside-container t :mail-container t)
    (should-not (rjd/mail-default-command-prefix))))

(ert-deftest rjd/mail-default-prefix-on-a-host-without-the-mail-container ()
  "A machine without the mail container -- leroy, say -- has no prefix."
  (rjd/mail-test-on-machine ()
    (should-not (rjd/mail-default-command-prefix))))

(ert-deftest rjd/mail-default-prefix-names-the-container ()
  (rjd/mail-test-on-machine (:mail-container t)
    (let ((rjd/mail-container-name "post"))
      (should (equal (rjd/mail-default-command-prefix)
                     '("docker" "exec" "-i" "post"))))))


;;; Whether mail can run on this machine

(defmacro rjd/mail-test-with-toolchain (programs &rest body)
  "Run BODY with only PROGRAMS, a list of names, on `exec-path'."
  (declare (indent 1))
  `(let* ((bin (make-temp-file "rjd-mail-bin" t))
          (exec-path (list bin)))
     (unwind-protect
         (progn
           (dolist (program ,programs)
             (let ((file (expand-file-name program bin)))
               (write-region "" nil file)
               (set-file-modes file #o755)))
           ,@body)
       (delete-directory bin t))))

(ert-deftest rjd/mail-available-on-the-host-with-the-mail-container ()
  "The iMac: the tools are in the mail container, so none on the host."
  (rjd/mail-test-on-machine (:mail-container t)
    (rjd/mail-test-with-toolchain nil
      (let ((rjd/mail-enabled 'auto)
            (rjd/mail-command-prefix (rjd/mail-default-command-prefix)))
        (should (rjd/mail-available-p))))))

(ert-deftest rjd/mail-available-in-a-container-with-the-dev-toolchain ()
  "claude-dev, with mbsync installed for development."
  (rjd/mail-test-on-machine (:inside-container t)
    (rjd/mail-test-with-toolchain '("mbsync")
      (let ((rjd/mail-enabled 'auto)
            (rjd/mail-command-prefix (rjd/mail-default-command-prefix)))
        (should (rjd/mail-available-p))))))

(ert-deftest rjd/mail-unavailable-in-a-container-without-the-toolchain ()
  (rjd/mail-test-on-machine (:inside-container t)
    (rjd/mail-test-with-toolchain nil
      (let ((rjd/mail-enabled 'auto)
            (rjd/mail-command-prefix (rjd/mail-default-command-prefix)))
        (should-not (rjd/mail-available-p))))))

(ert-deftest rjd/mail-unavailable-on-a-host-without-the-mail-container ()
  "leroy or bulldog: no mail container, and their own mbsync, if any,
is not set up for these accounts."
  (rjd/mail-test-on-machine ()
    (rjd/mail-test-with-toolchain '("mbsync")
      (let ((rjd/mail-enabled 'auto)
            (rjd/mail-command-prefix (rjd/mail-default-command-prefix)))
        (should-not (rjd/mail-available-p))))))

(ert-deftest rjd/mail-available-when-a-prefix-is-set-by-hand ()
  "A prefix set in private.el says where the tools are."
  (rjd/mail-test-on-machine ()
    (rjd/mail-test-with-toolchain nil
      (let ((rjd/mail-enabled 'auto)
            (rjd/mail-command-prefix '("ssh" "mailhost")))
        (should (rjd/mail-available-p))))))

(ert-deftest rjd/mail-enabled-overrides-the-machine ()
  (rjd/mail-test-on-machine (:mail-container t)
    (let ((rjd/mail-command-prefix (rjd/mail-default-command-prefix)))
      (let ((rjd/mail-enabled nil))
        (should-not (rjd/mail-available-p)))))
  (rjd/mail-test-on-machine ()
    (let ((rjd/mail-command-prefix nil)
          (rjd/mail-enabled t))
      (should (rjd/mail-available-p)))))

(ert-deftest rjd/mail-get-mail-command-without-prefix ()
  (let ((rjd/mail-command-prefix nil)
        (rjd/mail-accounts (list rjd/mail-test-gmail rjd/mail-test-other)))
    (should (equal (rjd/mail-get-mail-command)
                   "mbsync gmail-test other-group"))))

(ert-deftest rjd/mail-get-mail-command-with-prefix ()
  (let ((rjd/mail-command-prefix '("docker" "exec" "-i" "mail box"))
        (rjd/mail-accounts (list rjd/mail-test-gmail)))
    (should (equal (rjd/mail-get-mail-command)
                   "docker exec -i mail\\ box mbsync gmail-test"))))

(ert-deftest rjd/mail-get-mail-command-for-gmail-and-fastmail ()
  "One update syncs both accounts, through the mail container."
  (let ((rjd/mail-command-prefix '("docker" "exec" "-i" "mail"))
        (rjd/mail-accounts (list rjd/mail-test-gmail rjd/mail-test-fastmail)))
    (should (equal (rjd/mail-get-mail-command)
                   "docker exec -i mail mbsync gmail-test fastmail-test"))))

(ert-deftest rjd/mail-get-mail-command-without-accounts ()
  "With nothing declared there is nothing to fetch, only to index."
  (let ((rjd/mail-command-prefix '("docker" "exec" "-i" "mail"))
        (rjd/mail-accounts nil))
    (should (equal (rjd/mail-get-mail-command) "true"))))


;;; Accounts to contexts

(ert-deftest rjd/mail-contexts-one-per-account ()
  (rjd/mail-test-needs-mu4e)
  (let ((contexts (rjd/mail-contexts
                   (list rjd/mail-test-gmail rjd/mail-test-other))))
    (should (equal (mapcar #'mu4e-context-name contexts)
                   '("gmail-test" "other")))))

(ert-deftest rjd/mail-contexts-empty ()
  "No accounts gives no contexts, and needs nothing from mu4e."
  (should (equal (rjd/mail-contexts nil) nil)))

(ert-deftest rjd/mail-entering-gmail-sets-identity-folders-and-sent ()
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-with-fastmail-defaults
    (rjd/mail-test-enter
     (car (rjd/mail-contexts (list rjd/mail-test-gmail))))
    (should (equal user-mail-address "someone@example.com"))
    (should (equal user-full-name "Some One"))
    ;; A Message-ID names the account's domain, not this machine.
    (should (equal message-user-fqdn "example.com"))
    (should (equal mu4e-sent-folder "/gmail-test/sent"))
    (should (equal mu4e-drafts-folder "/gmail-test/drafts"))
    (should (equal (funcall mu4e-trash-folder nil) "/gmail-test/trash"))
    (should (equal (funcall mu4e-refile-folder nil) "/gmail-test/all"))
    (should (eq mu4e-sent-messages-behavior 'delete))
    ;; Trashed mail must reach Gmail's Trash: with the trashed flag,
    ;; mbsync would expunge it instead, and Gmail would only archive it.
    (should (eq mu4e-trash-without-flag t))))

(ert-deftest rjd/mail-entering-sets-declared-folders-and-sent ()
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-with-fastmail-defaults
    (rjd/mail-test-enter
     (car (rjd/mail-contexts (list rjd/mail-test-other))))
    (should (equal user-mail-address "other@example.org"))
    (should (equal mu4e-sent-folder "/other/Sent"))
    (should (equal (funcall mu4e-refile-folder nil) "/other/Archive"))
    (should (eq mu4e-sent-messages-behavior 'sent))
    (should (eq mu4e-trash-without-flag nil))))

(ert-deftest rjd/mail-leaving-restores-fastmail-default ()
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-with-fastmail-defaults
    (let ((context (car (rjd/mail-contexts (list rjd/mail-test-gmail)))))
      (rjd/mail-test-enter context)
      (rjd/mail-test-leave context)
      (should (equal user-mail-address "me@fastmail.example"))
      (should (equal user-full-name "Me Myself"))
      (should (eq message-send-mail-function 'smtpmail-send-it))
      (should-not message-user-fqdn)
      (should (equal mu4e-sent-folder "/Sent"))
      (should (equal mu4e-drafts-folder "/Drafts"))
      (should (equal mu4e-trash-folder "/Trash"))
      (should (equal mu4e-refile-folder "/Archive"))
      (should (eq mu4e-sent-messages-behavior 'sent))
      (should (eq mu4e-trash-without-flag nil)))))

(ert-deftest rjd/mail-switching-between-accounts-then-leaving ()
  "Switching from one account to another still ends on the default."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-with-fastmail-defaults
    (let* ((contexts (rjd/mail-contexts
                      (list rjd/mail-test-gmail rjd/mail-test-other)))
           (gmail (rjd/mail-test-context "gmail-test" contexts))
           (other (rjd/mail-test-context "other" contexts)))
      (rjd/mail-test-enter gmail)
      (rjd/mail-test-leave gmail)
      (rjd/mail-test-enter other)
      (should (equal user-mail-address "other@example.org"))
      (rjd/mail-test-leave other)
      (should (equal user-mail-address "me@fastmail.example"))
      (should (eq mu4e-sent-messages-behavior 'sent)))))

(ert-deftest rjd/mail-entering-gmail-or-fastmail-sets-its-own ()
  "With Gmail and Fastmail declared, each context sets its own account's
folders and sent behaviour, not the other's."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-with-fastmail-defaults
    (let* ((contexts (rjd/mail-contexts
                      (list rjd/mail-test-gmail rjd/mail-test-fastmail)))
           (gmail (rjd/mail-test-context "gmail-test" contexts))
           (fastmail (rjd/mail-test-context "fastmail-test" contexts)))
      (rjd/mail-test-enter fastmail)
      (should (equal user-mail-address "someone@fastmail.example"))
      (should (equal message-user-fqdn "fastmail.example"))
      (should (eq message-send-mail-function #'rjd/mail-send-it))
      (should (equal mu4e-sent-folder "/fastmail-test/Sent"))
      (should (equal mu4e-drafts-folder "/fastmail-test/Drafts"))
      (should (equal (funcall mu4e-trash-folder nil) "/fastmail-test/Trash"))
      (should (equal (funcall mu4e-refile-folder nil) "/fastmail-test/Archive"))
      (should (eq mu4e-sent-messages-behavior 'sent))
      (should (eq mu4e-trash-without-flag t))
      (rjd/mail-test-leave fastmail)
      (rjd/mail-test-enter gmail)
      (should (equal user-mail-address "someone@example.com"))
      (should (equal mu4e-sent-folder "/gmail-test/sent"))
      (should (equal mu4e-drafts-folder "/gmail-test/drafts"))
      (should (equal (funcall mu4e-trash-folder nil) "/gmail-test/trash"))
      (should (equal (funcall mu4e-refile-folder nil) "/gmail-test/all"))
      (should (eq mu4e-sent-messages-behavior 'delete))
      (rjd/mail-test-leave gmail))))

(ert-deftest rjd/mail-leaving-gmail-or-fastmail-restores-the-default ()
  "Leaving either context, Fastmail's included, puts back the global
Fastmail identity and smtpmail, which mail outside mu4e uses."
  (rjd/mail-test-needs-mu4e)
  (dolist (name '("gmail-test" "fastmail-test"))
    (rjd/mail-test-with-fastmail-defaults
      (let ((context (rjd/mail-test-context
                      name (rjd/mail-contexts
                            (list rjd/mail-test-gmail rjd/mail-test-fastmail)))))
        (rjd/mail-test-enter context)
        (rjd/mail-test-leave context)
        (should (equal user-mail-address "me@fastmail.example"))
        (should (equal user-full-name "Me Myself"))
        (should (eq message-send-mail-function 'smtpmail-send-it))
        (should-not message-user-fqdn)
        (should (equal mu4e-sent-folder "/Sent"))
        (should (equal mu4e-drafts-folder "/Drafts"))
        (should (equal mu4e-trash-folder "/Trash"))
        (should (equal mu4e-refile-folder "/Archive"))
        (should (eq mu4e-sent-messages-behavior 'sent))
        (should (eq mu4e-trash-without-flag nil))))))

(ert-deftest rjd/mail-context-matches-its-own-mail ()
  (rjd/mail-test-needs-mu4e)
  (let* ((contexts (rjd/mail-contexts
                    (list rjd/mail-test-gmail rjd/mail-test-other)))
         (gmail (rjd/mail-test-context "gmail-test" contexts))
         (matches (lambda (msg) (funcall (mu4e-context-match-func gmail) msg))))
    (should (funcall matches '(:maildir "/gmail-test/inbox")))
    (should (funcall matches
                     '(:maildir "/elsewhere"
                       :to ((:name "S" :email "Someone@Example.com")))))
    (should-not (funcall matches '(:maildir "/other/INBOX")))
    (should-not (funcall matches '(:maildir "/gmail-test-other/inbox")))
    (should-not (funcall matches nil))))

(ert-deftest rjd/mail-context-matches-mail-to-an-alias ()
  "Mail to a plus, subdomain or catch-all address opens in the account's
context, in To or Cc, whatever its case; a near miss does not."
  (rjd/mail-test-needs-mu4e)
  (let* ((contexts (rjd/mail-contexts
                    (list rjd/mail-test-gmail rjd/mail-test-fastmail-aliases)))
         (fastmail (rjd/mail-test-context "fastmail-test" contexts))
         (matches (lambda (msg) (funcall (mu4e-context-match-func fastmail) msg))))
    (dolist (address rjd/mail-test-alias-addresses)
      (should (funcall matches `(:maildir "/elsewhere"
                                 :to ((:email ,address)))))
      (should (funcall matches `(:maildir "/elsewhere"
                                 :to ((:email "you@example.net"))
                                 :cc ((:email ,(upcase address)))))))
    (should (funcall matches '(:maildir "/elsewhere"
                               :to ((:email "someone@fastmail.example")))))
    (dolist (address '("someone@fastmail.example.org"
                       "anything@notsomeone.example"
                       "someone@example.com"))
      (should-not (funcall matches `(:maildir "/elsewhere"
                                     :to ((:email ,address))))))))


;;; Trashing and refiling

(defmacro rjd/mail-test-with-gmail-and-fastmail-mode (&rest body)
  "Run BODY with Gmail and Fastmail declared and `rjd/mail-mode' on."
  (declare (indent 0))
  `(rjd/mail-test-with-fastmail-defaults
     (let ((rjd/mail-accounts (list rjd/mail-test-gmail rjd/mail-test-fastmail))
           (mu4e-contexts nil)
           (mu4e-get-mail-command "true")
           (rjd/mail-mode nil)
           (rjd/mail--before-mode nil)
           (rjd/mail--fallback-folders nil))
       (rjd/mail-mode 1)
       (unwind-protect
           (progn ,@body)
         (rjd/mail-mode -1)))))

(ert-deftest rjd/mail-trash-goes-to-the-message-s-account ()
  "In either context, a message is trashed and refiled into the folders
of the account whose maildir holds it, not the context's."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-with-gmail-and-fastmail-mode
    (dolist (name '("gmail-test" "fastmail-test"))
      (let ((context (rjd/mail-test-context name mu4e-contexts)))
        (rjd/mail-test-enter context)
        (should (equal (funcall mu4e-trash-folder
                                '(:maildir "/fastmail-test/INBOX"))
                       "/fastmail-test/Trash"))
        (should (equal (funcall mu4e-refile-folder
                                '(:maildir "/fastmail-test/INBOX"))
                       "/fastmail-test/Archive"))
        (should (equal (funcall mu4e-trash-folder
                                '(:maildir "/gmail-test/inbox"))
                       "/gmail-test/trash"))
        (should (equal (funcall mu4e-refile-folder
                                '(:maildir "/gmail-test/inbox"))
                       "/gmail-test/all"))
        (rjd/mail-test-leave context)))))

(ert-deftest rjd/mail-trash-follows-the-maildir-not-the-recipient ()
  "A Fastmail message to the Gmail address matches the Gmail context,
but is still trashed into Fastmail's Trash, where mbsync keeps it."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-with-gmail-and-fastmail-mode
    (let ((msg '(:maildir "/fastmail-test/INBOX"
                 :to ((:email "someone@example.com")))))
      (should (equal (mu4e-context-name (mu4e-context-determine msg))
                     "gmail-test"))
      (rjd/mail-test-enter (rjd/mail-test-context "gmail-test" mu4e-contexts))
      (should (equal (funcall mu4e-trash-folder msg) "/fastmail-test/Trash")))))

(ert-deftest rjd/mail-trash-outside-every-account-s-maildir ()
  "A message in no account's maildir, or none, goes to the context's
folders in a context, and to the global ones outside every context."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-with-gmail-and-fastmail-mode
    (dolist (msg '(nil (:maildir "/elsewhere/INBOX")
                       (:maildir "/gmail-test-other/inbox")))
      (should (equal (funcall mu4e-trash-folder msg) "/Trash"))
      (should (equal (funcall mu4e-refile-folder msg) "/Archive"))
      (let ((gmail (rjd/mail-test-context "gmail-test" mu4e-contexts)))
        (rjd/mail-test-enter gmail)
        (should (equal (funcall mu4e-trash-folder msg) "/gmail-test/trash"))
        (rjd/mail-test-leave gmail)))))

(ert-deftest rjd/mail-trash-outside-every-context-goes-to-the-account ()
  "With no context entered, a message is still trashed into its own
account's folder, not the global /Trash, which is Fastmail's only at
the root of ~/Mail."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-with-gmail-and-fastmail-mode
    (should (equal (funcall mu4e-trash-folder '(:maildir "/fastmail-test/INBOX"))
                   "/fastmail-test/Trash"))
    (should (equal (funcall mu4e-refile-folder '(:maildir "/gmail-test/inbox"))
                   "/gmail-test/all"))))

(ert-deftest rjd/mail-mode-restores-the-folders ()
  "Turning the mode off, from inside a context too, puts the global
folders back as they were."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-with-gmail-and-fastmail-mode
    (rjd/mail-test-enter (car mu4e-contexts))
    (rjd/mail-mode -1)
    (should (equal mu4e-trash-folder "/Trash"))
    (should (equal mu4e-refile-folder "/Archive"))
    (should-not rjd/mail--fallback-folders)))


;;; Sending

(defun rjd/mail-test-file-string (file)
  "The contents of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun rjd/mail-test-send (command message &optional accounts)
  "Send MESSAGE with `rjd/mail-send-it', COMMAND standing in for msmtp.
MESSAGE is as message-mode prepares it, headers and body divided by
`mail-header-separator'.  COMMAND is a shell script, put in
`rjd/mail-command-prefix' in front of the other words of a prefix: it
runs as \"sh -c COMMAND sh exec -i mail msmtp -a ACCOUNT ...\", so its
\"$@\" is the prefixed command line msmtp would get.  ACCOUNTS are
declared; by default, `rjd/mail-test-gmail' and `rjd/mail-test-other'.
Returns the result of sending."
  (require 'sendmail)
  (let ((rjd/mail-command-prefix (list "sh" "-c" command "sh"
                                       "exec" "-i" "mail"))
        (rjd/mail-accounts (or accounts
                               (list rjd/mail-test-gmail rjd/mail-test-other))))
    (with-temp-buffer
      (insert (format message mail-header-separator))
      (rjd/mail-send-it))))

(defmacro rjd/mail-test-with-command-log (&rest body)
  "Run BODY with `args' and `msg' naming files a stand-in msmtp writes.
`log' is the shell script that does it, for `rjd/mail-test-send'."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "rjd-mail-send" t))
          (args (file-name-concat dir "args"))
          (msg (file-name-concat dir "msg"))
          (log (format "printf '%%s\\n' \"$@\" > %s; cat > %s"
                       (shell-quote-argument args)
                       (shell-quote-argument msg))))
     (unwind-protect
         (progn ,@body)
       (delete-directory dir t))))

(ert-deftest rjd/mail-entering-gmail-sends-through-rjd-mail ()
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-with-fastmail-defaults
    (rjd/mail-test-enter
     (car (rjd/mail-contexts (list rjd/mail-test-gmail))))
    (should (eq message-send-mail-function #'rjd/mail-send-it))))

(ert-deftest rjd/mail-send-it-pipes-the-message-to-the-command ()
  "The message reaches msmtp for its From account, behind the prefix.
msmtp reads the recipients from it.  Nothing comes between the
command's own words, as message's sendmail path would put -oi after
the program -- `docker -oi exec ...'."
  (rjd/mail-test-with-command-log
    (rjd/mail-test-send
     log "From: Some One <someone@example.com>\nTo: you@example.net\nSubject: Hi\n%s\nHello.\n")
    (should (equal (rjd/mail-test-file-string args)
                   (concat "exec\n-i\nmail\nmsmtp\n-a\ngmail-test\n"
                           "--read-envelope-from\n-t\n")))
    (should (equal (rjd/mail-test-file-string msg)
                   (concat "From: Some One <someone@example.com>\n"
                           "To: you@example.net\nSubject: Hi\n\nHello.\n")))))

(ert-deftest rjd/mail-send-it-uses-the-msmtp-account ()
  "An account's own :msmtp-account names the msmtp account; else :name."
  (rjd/mail-test-with-command-log
    (let ((rjd/mail-test-other (append '(:msmtp-account "other-msmtp")
                                       rjd/mail-test-other)))
      (rjd/mail-test-send log "From: other@example.org\nTo: you@example.net\n%s\nHi.\n"))
    (should (string-match-p "^-a\nother-msmtp\n"
                            (rjd/mail-test-file-string args)))))

(ert-deftest rjd/mail-send-it-sends-as-the-from-account-not-the-context ()
  "A draft goes out as the account in its From, whatever context is current.
Written in the Gmail context, sent after another context was entered,
it still goes through Gmail's msmtp account."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-with-fastmail-defaults
    (rjd/mail-test-with-command-log
      (rjd/mail-test-enter
       (rjd/mail-test-context
        "other" (rjd/mail-contexts (list rjd/mail-test-gmail rjd/mail-test-other))))
      (rjd/mail-test-send
       log "From: Some One <Someone@Example.com>\nTo: you@example.net\n%s\nHi.\n")
      (should (string-match-p "^-a\ngmail-test\n"
                              (rjd/mail-test-file-string args))))))

(ert-deftest rjd/mail-send-it-from-another-address-sends-as-the-default ()
  "A message from no declared account goes out the default way.
A C-x m draft begun before any context was entered has the Fastmail
From, and message sends it with the global function, which entering a
context made `rjd/mail-send-it'; it must reach smtpmail, not msmtp."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-with-fastmail-defaults
    (rjd/mail-test-with-command-log
      (let* ((sent nil)
             (message-send-mail-function
              (lambda () (setq sent (buffer-string)))))
        (rjd/mail-test-enter
         (car (rjd/mail-contexts (list rjd/mail-test-gmail))))
        (rjd/mail-test-send
         log "From: Me Myself <me@fastmail.example>\nTo: you@example.net\n%s\nHi.\n")
        (should-not (file-exists-p args))
        (should (equal sent (format "From: Me Myself <me@fastmail.example>\nTo: you@example.net\n%s\nHi.\n"
                                    mail-header-separator)))))))

(ert-deftest rjd/mail-send-it-from-an-alias-sends-as-its-account ()
  "A From of a plus, subdomain or catch-all address goes through the
account's msmtp, with that From, so msmtp's envelope follows it."
  (dolist (address rjd/mail-test-alias-addresses)
    (rjd/mail-test-with-command-log
      (rjd/mail-test-send
       log (concat "From: Some One <" address ">\nTo: you@example.net\n%s\nHi.\n")
       (list rjd/mail-test-gmail rjd/mail-test-fastmail-aliases))
      (should (equal (rjd/mail-test-file-string args)
                     (concat "exec\n-i\nmail\nmsmtp\n-a\nfastmail-test\n"
                             "--read-envelope-from\n-t\n")))
      (should (string-prefix-p (concat "From: Some One <" address ">\n")
                               (rjd/mail-test-file-string msg))))))

(ert-deftest rjd/mail-send-it-from-a-near-alias-sends-as-the-default ()
  "A From the aliases do not match whole goes out the default way."
  (rjd/mail-test-needs-mu4e)
  (dolist (address '("someone@fastmail.example.org"
                     "anything@notsomeone.example"
                     "me@fastmail.example"))
    (rjd/mail-test-with-fastmail-defaults
      (rjd/mail-test-with-command-log
        (let* ((sent nil)
               (message-send-mail-function
                (lambda () (setq sent (buffer-string))))
               (accounts (list rjd/mail-test-gmail
                               rjd/mail-test-fastmail-aliases)))
          (rjd/mail-test-enter
           (rjd/mail-test-context "fastmail-test" (rjd/mail-contexts accounts)))
          (rjd/mail-test-send
           log (concat "From: " address "\nTo: you@example.net\n%s\nHi.\n")
           accounts)
          (should-not (file-exists-p args))
          (should (string-prefix-p (concat "From: " address "\n") sent)))))))

(ert-deftest rjd/mail-send-it-resends-to-resent-to ()
  "A resend goes to the Resent-To addresses, not the original recipients."
  (rjd/mail-test-with-command-log
    (rjd/mail-test-send
     log (concat "Resent-To: A <a@example.net>, b@example.net\n"
                 "From: someone@example.com\nTo: you@example.net\n%s\nHello.\n"))
    (should (string-suffix-p "--read-envelope-from\na@example.net\nb@example.net\n"
                             (rjd/mail-test-file-string args)))))

(ert-deftest rjd/mail-send-it-reports-failure ()
  "A command that fails makes sending fail, with what it said."
  (let ((err (should-error
              (rjd/mail-test-send "cat > /dev/null; echo 'no token' >&2; exit 78"
                                  "From: someone@example.com\nTo: you@example.net\n%s\nHello.\n"))))
    (should (string-match-p "no token" (error-message-string err)))))

(ert-deftest rjd/mail-send-it-without-an-account-or-default ()
  "From no declared account, outside every context, there is nothing to
send with: no account, and no default saved to fall back on."
  (let ((rjd/mail--saved nil))
    (should-error (rjd/mail-test-send "cat > /dev/null"
                                      "From: me@fastmail.example\n%s\nHi.\n"))))


;;; Junk

(ert-deftest rjd/mail-without-junk-excludes-spam-and-trash ()
  (let ((rjd/mail-accounts (list rjd/mail-test-gmail rjd/mail-test-other)))
    (should (equal (rjd/mail-without-junk "flag:unread")
                   (concat "(flag:unread) AND NOT (maildir:/gmail-test/spam"
                           " OR maildir:/gmail-test/trash"
                           " OR maildir:/other/Junk OR maildir:/other/Trash)")))))

(ert-deftest rjd/mail-without-junk-without-accounts ()
  (let ((rjd/mail-accounts nil))
    (should (equal (rjd/mail-without-junk "flag:unread") "flag:unread"))))

(defconst rjd/mail-test-junk-clause
  (concat " AND NOT (maildir:/gmail-test/spam OR maildir:/gmail-test/trash"
          " OR maildir:/other/Junk OR maildir:/other/Trash)")
  "What leaving both test accounts' Spam and Trash out adds to a query.")

(defmacro rjd/mail-test-with-both-accounts (&rest body)
  "Run BODY with both test accounts declared."
  (declare (indent 0))
  `(let ((rjd/mail-accounts (list rjd/mail-test-gmail rjd/mail-test-other)))
     ,@body))

(ert-deftest rjd/mail-search-leaves-out-junk ()
  "An ordinary search, typed or a bookmark's, finds no Spam or Trash."
  (rjd/mail-test-with-both-accounts
    (should (equal (rjd/mail-search-query "from:alice")
                   (concat "(from:alice)" rjd/mail-test-junk-clause)))
    (should (equal (rjd/mail-search-query "flag:unread AND NOT flag:trashed")
                   (concat "(flag:unread AND NOT flag:trashed)"
                           rjd/mail-test-junk-clause)))))

(ert-deftest rjd/mail-search-leaves-out-gmail-and-fastmail-junk ()
  "Fastmail's Spam and Trash stay out of searches, as Gmail's do."
  (let ((rjd/mail-accounts (list rjd/mail-test-gmail rjd/mail-test-fastmail)))
    (should (equal (rjd/mail-search-query "flag:unread")
                   (concat "(flag:unread) AND NOT (maildir:/gmail-test/spam"
                           " OR maildir:/gmail-test/trash"
                           " OR maildir:/fastmail-test/Spam"
                           " OR maildir:/fastmail-test/Trash)")))
    (should (equal (rjd/mail-search-query "maildir:/fastmail-test/Spam")
                   "maildir:/fastmail-test/Spam"))))

(ert-deftest rjd/mail-search-naming-junk-is-left-alone ()
  "A search that names a Spam or Trash folder, or trashed mail, finds it."
  (rjd/mail-test-with-both-accounts
    (dolist (query '("maildir:/gmail-test/spam"
                     "maildir:\"/other/Trash\" AND from:bob"
                     "(maildir:/gmail-test/trash)"
                     "flag:trashed"
                     "from:bob AND flag:trashed"))
      (should (equal (rjd/mail-search-query query) query)))))

(ert-deftest rjd/mail-search-only-names-junk-by-whole-folder ()
  "A folder whose name merely starts like a junk folder's is not junk."
  (rjd/mail-test-with-both-accounts
    (should (equal (rjd/mail-search-query "maildir:/gmail-test/spammy")
                   (concat "(maildir:/gmail-test/spammy)"
                           rjd/mail-test-junk-clause)))))

(ert-deftest rjd/mail-search-for-a-message-id-is-left-alone ()
  "Following an org link finds its message wherever it now is."
  (rjd/mail-test-with-both-accounts
    (should (equal (rjd/mail-search-query "msgid:abc@example.com")
                   "msgid:abc@example.com"))))

(ert-deftest rjd/mail-search-is-rewritten-once ()
  "Narrowing searches the query already rewritten, which stays as it is."
  (rjd/mail-test-with-both-accounts
    (let ((once (rjd/mail-search-query "from:alice")))
      (should (equal (rjd/mail-search-query once) once)))))


;;; Flags on unread mail

(defun rjd/mail-test-maildir-files (root)
  "The files under ROOT, relative to it, sorted."
  (sort (mapcar (lambda (file) (file-relative-name file root))
                (directory-files-recursively root ""))
        #'string<))

(ert-deftest rjd/mail-move-flagged-new-to-cur-moves-flagged-unread ()
  "An unread starred message must reach cur/, or mu drops its star.
mbsync files unread mail in new/ with its flags in the name; mu reads
anything in new/ as New alone, so marking it read writes `:2,S' and the
next sync removes Gmail's Starred label (#18)."
  (let* ((root (make-temp-file "rjd-mail-test-" t))
         (rjd/mail-accounts (list rjd/mail-test-gmail)))
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
          (rjd/mail-move-flagged-new-to-cur root)
          (should (equal (rjd/mail-test-maildir-files root)
                         '("gmail-test/all/cur/1.h,U=7:2,FR"
                           "gmail-test/inbox/cur/1.h,U=1:2,F"
                           "gmail-test/inbox/cur/4.h,U=4:2,FS"
                           "gmail-test/inbox/new/2.h,U=2:2,"
                           "gmail-test/inbox/new/3.h"))))
      (delete-directory root t))))

(ert-deftest rjd/mail-move-flagged-new-to-cur-leaves-other-maildirs ()
  "Only the declared accounts' mail is touched."
  (let* ((root (make-temp-file "rjd-mail-test-" t))
         (rjd/mail-accounts (list rjd/mail-test-gmail)))
    (unwind-protect
        (progn
          (make-directory (format "%s/fastmail/INBOX/new" root) t)
          (make-directory (format "%s/fastmail/INBOX/cur" root) t)
          (write-region "" nil (format "%s/fastmail/INBOX/new/1.h:2,F" root))
          (rjd/mail-move-flagged-new-to-cur root)
          (should (equal (rjd/mail-test-maildir-files root)
                         '("fastmail/INBOX/new/1.h:2,F"))))
      (delete-directory root t))))


;;; Syncing from startup

(defmacro rjd/mail-test-recording-mu4e-starts (&rest body)
  "Run BODY with `mu4e' stubbed to record its calls in `starts'.
The stub stands for mu4e itself, which `rjd/mail-start-syncing' starts
in the background; its argument lists are pushed onto `starts'."
  (declare (indent 0))
  `(let ((starts nil))
     (cl-letf (((symbol-function 'mu4e)
                (lambda (&rest args) (push args starts))))
       ,@body)))

(ert-deftest rjd/mail-start-syncing-starts-mu4e-in-the-background ()
  "With accounts active, mu4e starts quietly, so its updates run."
  (rjd/mail-test-recording-mu4e-starts
    (let ((rjd/mail-accounts (list rjd/mail-test-gmail)))
      (rjd/mail-start-syncing)
      (should (equal starts '((t)))))))

(ert-deftest rjd/mail-start-syncing-without-accounts ()
  "Nothing declared: mu4e is not started."
  (rjd/mail-test-recording-mu4e-starts
    (let ((rjd/mail-accounts nil))
      (rjd/mail-start-syncing)
      (should-not starts))))


;;; The mode

(ert-deftest rjd/mail-mode-installs-and-restores ()
  (rjd/mail-test-needs-mu4e)
  (let ((rjd/mail-accounts (list rjd/mail-test-gmail))
        (mu4e-contexts nil)
        (mu4e-get-mail-command "true")
        (mu4e-query-rewrite-function 'identity)
        (mu4e-trash-folder "/Trash")
        (mu4e-refile-folder "/Archive")
        (rjd/mail-mode nil)
        (rjd/mail--before-mode nil))
    (rjd/mail-mode 1)
    (should (equal (mapcar #'mu4e-context-name mu4e-contexts) '("gmail-test")))
    (should (eq mu4e-get-mail-command #'rjd/mail-get-mail-command))
    (should (eq mu4e-query-rewrite-function #'rjd/mail-search-query))
    (rjd/mail-mode -1)
    (should (equal mu4e-contexts nil))
    (should (equal mu4e-get-mail-command "true"))
    (should (eq mu4e-query-rewrite-function 'identity))))

(ert-deftest rjd/mail-mode-moves-flagged-new-before-indexing ()
  "Every index -- after a fetch, or on its own -- sees the flags (#18)."
  (rjd/mail-test-needs-mu4e)
  (require 'mu4e-update)
  (let* ((root (make-temp-file "rjd-mail-test-" t))
         (rjd/mail-accounts (list rjd/mail-test-gmail))
         (mu4e-contexts nil)
         (mu4e-get-mail-command "true")
         (mu4e-trash-folder "/Trash")
         (mu4e-refile-folder "/Archive")
         (rjd/mail-mode nil)
         (rjd/mail--before-mode nil)
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
                             (rjd/mail-test-maildir-files root)))))
            (rjd/mail-mode 1)
            (mu4e-update-index)
            (rjd/mail-mode -1)
            (should (equal indexed-files
                           '("gmail-test/inbox/cur/1.h,U=1:2,F")))
            ;; Off, the mode leaves indexing alone.
            (rename-file (format "%s/gmail-test/inbox/cur/1.h,U=1:2,F" root)
                         (format "%s/gmail-test/inbox/new/" root))
            (mu4e-update-index)
            (should (equal indexed-files
                           '("gmail-test/inbox/new/1.h,U=1:2,F")))))
      (rjd/mail-mode -1)
      (delete-directory root t))))

(ert-deftest rjd/mail-mode-without-accounts ()
  "No accounts: the mode turns on cleanly and adds no contexts."
  (let ((rjd/mail-accounts nil)
        (mu4e-contexts nil)
        (mu4e-get-mail-command "true")
        (rjd/mail-mode nil)
        (rjd/mail--before-mode nil))
    (rjd/mail-mode 1)
    (should (equal mu4e-contexts nil))
    (should (equal (funcall mu4e-get-mail-command) "true"))
    (rjd/mail-mode -1)))

;;; Where mail cannot run

(defmacro rjd/mail-test-where-mail-cannot-run (&rest body)
  "Run BODY with an account declared on a machine where mail cannot run.
The machine is leroy, say: no mail container, no prefix, not a
container -- decided by the machine, not forced."
  (declare (indent 0))
  `(rjd/mail-test-on-machine ()
     (let ((rjd/mail-enabled 'auto)
           (rjd/mail-command-prefix nil)
           (rjd/mail-accounts (list rjd/mail-test-gmail)))
       ,@body)))

(ert-deftest rjd/mail-mode-where-mail-cannot-run ()
  "Declared accounts make no contexts and fetch nothing there."
  (rjd/mail-test-where-mail-cannot-run
    (let ((mu4e-contexts nil)
          (mu4e-get-mail-command "true")
          (rjd/mail-mode nil)
          (rjd/mail--before-mode nil))
      (rjd/mail-mode 1)
      (unwind-protect
          (progn
            (should (equal mu4e-contexts nil))
            (should (equal (funcall mu4e-get-mail-command) "true")))
        (rjd/mail-mode -1)))))

(ert-deftest rjd/mail-mode-where-mail-cannot-run-leaves-the-folders ()
  "With no account active, the global folders stay plain folders."
  (rjd/mail-test-where-mail-cannot-run
    (rjd/mail-test-with-fastmail-defaults
      (let ((mu4e-contexts nil)
            (mu4e-get-mail-command "true")
            (rjd/mail-mode nil)
            (rjd/mail--before-mode nil)
            (rjd/mail--fallback-folders nil))
        (rjd/mail-mode 1)
        (unwind-protect
            (should (equal mu4e-trash-folder "/Trash"))
          (rjd/mail-mode -1))))))

(ert-deftest rjd/mail-without-junk-where-mail-cannot-run ()
  (rjd/mail-test-where-mail-cannot-run
    (should (equal (rjd/mail-without-junk "flag:unread") "flag:unread"))))

(ert-deftest rjd/mail-search-without-active-accounts ()
  (rjd/mail-test-where-mail-cannot-run
    (should (equal (rjd/mail-search-query "from:alice") "from:alice"))))

(ert-deftest rjd/mail-start-syncing-where-mail-cannot-run ()
  "leroy or bulldog: the accounts are declared, but mu4e is not started."
  (rjd/mail-test-where-mail-cannot-run
    (rjd/mail-test-recording-mu4e-starts
      (rjd/mail-start-syncing)
      (should-not starts))))

(ert-deftest rjd/mail-move-flagged-new-to-cur-where-mail-cannot-run ()
  "No account's maildir is touched."
  (rjd/mail-test-where-mail-cannot-run
    (let ((root (make-temp-file "rjd-mail-test-" t)))
      (unwind-protect
          (progn
            (make-directory (format "%s/gmail-test/inbox/new" root) t)
            (make-directory (format "%s/gmail-test/inbox/cur" root) t)
            (write-region "" nil (format "%s/gmail-test/inbox/new/1.h,U=1:2,F"
                                         root))
            (rjd/mail-move-flagged-new-to-cur root)
            (should (equal (rjd/mail-test-maildir-files root)
                           '("gmail-test/inbox/new/1.h,U=1:2,F"))))
        (delete-directory root t)))))


;;; Mail written outside mu4e

(defmacro rjd/mail-test-in-gmail-context (&rest body)
  "Run BODY with `rjd/mail-mode' on and the Gmail context entered."
  (declare (indent 0))
  `(rjd/mail-test-with-fastmail-defaults
     (let ((rjd/mail-accounts (list rjd/mail-test-gmail))
           (rjd/mail-command-prefix nil)
           (mu4e-contexts nil)
           (mu4e-get-mail-command "true")
           (rjd/mail-mode nil)
           (rjd/mail--before-mode nil)
           (message-mode-hook nil))
       (rjd/mail-mode 1)
       (unwind-protect
           (progn
             (rjd/mail-test-enter (car mu4e-contexts))
             ,@body)
         (rjd/mail-mode -1)))))

(ert-deftest rjd/mail-message-mode-outside-mu4e-keeps-fastmail ()
  "Plain message-mode sends as the Fastmail default, inside a context too.
mu4e's context is global and outlives quitting mu4e, so without this
\\[compose-mail] would send as whichever account mu4e last used.  It
sends with `rjd/mail-send-it', the default where accounts are active,
which chooses by From."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-in-gmail-context
    (should (equal user-mail-address "someone@example.com"))
    (with-temp-buffer
      (message-mode)
      (should (equal user-mail-address "me@fastmail.example"))
      (should (equal user-full-name "Me Myself"))
      (should-not message-user-fqdn)
      (should (eq message-send-mail-function #'rjd/mail-send-it)))))

(ert-deftest rjd/mail-mu4e-compose-uses-the-context ()
  "mu4e's own compose buffers send as the context's account."
  (rjd/mail-test-needs-mu4e)
  (require 'mu4e-compose)
  (rjd/mail-test-in-gmail-context
    (with-temp-buffer
      (mu4e-compose-mode)
      (should (equal user-mail-address "someone@example.com"))
      (should (eq message-send-mail-function #'rjd/mail-send-it))
      ;; message prefers a system name with a dot, as the Mac's has, to
      ;; the domain of the address it sends from.
      (cl-letf (((symbol-function 'system-name)
                 (lambda () "somebodys-imac.lan")))
        (should (string-suffix-p "@example.com>"
                                 (message-make-message-id)))))))

(ert-deftest rjd/mail-message-mode-outside-every-context ()
  "With no context entered message-mode is left alone.
It sends with the global default, `rjd/mail-send-it'."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-with-fastmail-defaults
    (let ((rjd/mail-accounts (list rjd/mail-test-gmail))
          (mu4e-contexts nil)
          (rjd/mail-mode nil)
          (rjd/mail--before-mode nil)
          (message-mode-hook nil))
      (rjd/mail-mode 1)
      (unwind-protect
          (with-temp-buffer
            (message-mode)
            (should-not (local-variable-p 'user-mail-address))
            (should (eq message-send-mail-function #'rjd/mail-send-it)))
        (rjd/mail-mode -1)))))

(ert-deftest rjd/mail-aliases-stay-inside-mu4e ()
  "An account's aliases answer for it in mu4e only.
Entering a context with :addresses makes a reply from the alias the
original was sent to.  A message buffer outside mu4e -- while the
context is still entered, as after mu4e quits -- keeps the default,
and leaving the context puts the default back."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-with-fastmail-defaults
    (let ((rjd/mail-accounts (list rjd/mail-test-fastmail-aliases))
          (rjd/mail-command-prefix nil)
          (message-alternative-emails nil)
          (mu4e-contexts nil)
          (mu4e-get-mail-command "true")
          (rjd/mail-mode nil)
          (rjd/mail--before-mode nil)
          (message-mode-hook nil))
      (rjd/mail-mode 1)
      (unwind-protect
          (let ((context (car mu4e-contexts)))
            (rjd/mail-test-enter context)
            (should message-alternative-emails)
            (with-temp-buffer
              (message-mode)
              (should-not message-alternative-emails))
            (rjd/mail-test-leave context)
            (should-not message-alternative-emails))
        (rjd/mail-mode -1)))))

(defconst rjd/mail-test-fastmail-default
  (append '(:address "me@fastmail.example") rjd/mail-test-fastmail)
  "The Fastmail account, its address the global default's, as on the Mac.")

(defmacro rjd/mail-test-outside-mu4e (&rest body)
  "Run BODY with `rjd/mail-mode' on, Gmail and Fastmail declared.
Fastmail's address is the global default's.  smtpmail is stood in for:
`smtpmail-sent' is the message it was handed, or nil.  BODY runs
inside `rjd/mail-test-with-command-log', so `log' stands in for msmtp
and `args' is the file it writes."
  (declare (indent 0))
  `(rjd/mail-test-with-fastmail-defaults
     (rjd/mail-test-with-command-log
       (let* ((smtpmail-sent nil)
              (rjd/mail-accounts (list rjd/mail-test-gmail
                                       rjd/mail-test-fastmail-default))
              (rjd/mail-command-prefix (list "sh" "-c" log "sh"
                                             "exec" "-i" "mail"))
              (mu4e-contexts nil)
              (mu4e-get-mail-command "true")
              (rjd/mail-mode nil)
              (rjd/mail--before-mode nil)
              (message-mode-hook nil))
         (cl-letf (((symbol-function 'smtpmail-send-it)
                    (lambda () (setq smtpmail-sent (buffer-string)))))
           (rjd/mail-mode 1)
           (unwind-protect
               (progn ,@body)
             (rjd/mail-mode -1)))))))

(defun rjd/mail-test-send-outside-mu4e (from)
  "Send a message from FROM as \\[compose-mail] would, outside mu4e.
With whatever `message-send-mail-function' a message-mode buffer gets."
  (require 'sendmail)
  (with-temp-buffer
    (message-mode)
    (insert (format "From: %s\nTo: you@example.net\n%s\nHi.\n"
                    from mail-header-separator))
    (funcall message-send-mail-function)))

(ert-deftest rjd/mail-outside-mu4e-sends-through-the-account-before-any-context ()
  "With no context ever entered, mail from the default address goes
through its account's msmtp, not smtpmail, which has no credentials on
the Mac (#28); mail from no account's address still goes to smtpmail."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-outside-mu4e
    (rjd/mail-test-send-outside-mu4e "Me Myself <me@fastmail.example>")
    (should (string-match-p "^-a\nfastmail-test\n"
                            (rjd/mail-test-file-string args)))
    (should-not smtpmail-sent)
    (delete-file args)
    (rjd/mail-test-send-outside-mu4e "stranger@example.net")
    (should-not (file-exists-p args))
    (should (string-prefix-p "From: stranger@example.net\n" smtpmail-sent))))

(ert-deftest rjd/mail-outside-mu4e-sends-through-the-account-after-a-context ()
  "With a context still entered, as after mu4e quits, and after leaving
it, mail outside mu4e from the default address goes through its
account's msmtp, not back to smtpmail."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-outside-mu4e
    (let ((gmail (rjd/mail-test-context "gmail-test" mu4e-contexts)))
      (rjd/mail-test-enter gmail)
      (rjd/mail-test-send-outside-mu4e "me@fastmail.example")
      (should (string-match-p "^-a\nfastmail-test\n"
                              (rjd/mail-test-file-string args)))
      (delete-file args)
      (rjd/mail-test-leave gmail)
      (rjd/mail-test-send-outside-mu4e "me@fastmail.example")
      (should (string-match-p "^-a\nfastmail-test\n"
                              (rjd/mail-test-file-string args)))
      (should-not smtpmail-sent))))

(ert-deftest rjd/mail-outside-mu4e-without-active-accounts-keeps-smtpmail ()
  "Where no account is active -- leroy, bulldog -- the default stays
smtpmail, with the mode on and after it is turned off."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-where-mail-cannot-run
    (let ((message-send-mail-function 'smtpmail-send-it)
          (mu4e-contexts nil)
          (mu4e-get-mail-command "true")
          (rjd/mail-mode nil)
          (rjd/mail--before-mode nil))
      (rjd/mail-mode 1)
      (unwind-protect
          (should (eq message-send-mail-function 'smtpmail-send-it))
        (rjd/mail-mode -1))
      (should (eq message-send-mail-function 'smtpmail-send-it)))))

(ert-deftest rjd/mail-mode-off-restores-smtpmail ()
  "Turning the mode off puts smtpmail back as the default."
  (rjd/mail-test-needs-mu4e)
  (rjd/mail-test-outside-mu4e
    (should (eq message-send-mail-function #'rjd/mail-send-it))
    (rjd/mail-test-enter (car mu4e-contexts))
    (rjd/mail-mode -1)
    (should (eq message-send-mail-function 'smtpmail-send-it))))


;;; Replies

(defvar mu4e--context-current)
(defvar mu4e-compose-context-policy)
(declare-function mu4e-compose-reply "mu4e-compose")

(defun rjd/mail-test-reply-from (accounts to &optional headers maildir)
  "The From of mu4e's reply to a message addressed to TO.
The message is from you@example.net, with HEADERS, a string of header
lines, besides; it is in MAILDIR, or else in no account's maildir, so
the context is chosen by address alone.  ACCOUNTS are
declared, with `rjd/mail-mode' on and the Fastmail default as the
globals.  The reply is mu4e's own, `mu4e-compose-reply', with the mu
server stood in for: it is not running, and knows no personal
addresses, so only the context can make the reply's From an alias."
  (require 'mu4e)
  (rjd/mail-test-with-fastmail-defaults
    (let* ((root (make-temp-file "rjd-mail-reply" t))
           (parent (expand-file-name "parent" root))
           (msg `(:path ,parent :maildir ,(or maildir "/elsewhere") :subject "Hi"
                  :from ((:name "You" :email "you@example.net"))
                  :to ((:email ,to))))
           (rjd/mail-accounts accounts)
           (rjd/mail-command-prefix nil)
           (mu4e-contexts nil)
           (mu4e--context-current nil)
           (mu4e-compose-context-policy 'pick-first)
           (mu4e-get-mail-command "true")
           (mu4e-query-rewrite-function 'identity)
           (message-alternative-emails nil)
           (rjd/mail-mode nil)
           (rjd/mail--before-mode nil)
           (draft nil))
      (with-temp-file parent
        (insert "From: You <you@example.net>\nTo: " to "\nSubject: Hi\n"
                (or headers "") "Message-Id: <1@example.net>\n"
                "Date: Sun, 11 Oct 2026 10:00:00 +0000\n\nHello.\n"))
      (rjd/mail-mode 1)
      (unwind-protect
          (cl-letf (((symbol-function 'mu4e-running-p) #'always)
                    ((symbol-function 'mu4e-server-properties) #'ignore)
                    ((symbol-function 'mu4e-root-maildir) (lambda () root))
                    ((symbol-function 'mu4e-message-at-point)
                     (lambda (&rest _) msg))
                    ((symbol-function 'mu4e-display-buffer) #'ignore))
            (setq draft (mu4e-compose-reply))
            (with-current-buffer draft
              (save-restriction
                (message-narrow-to-headers)
                (mail-strip-quoted-names (message-fetch-field "from")))))
        (when (buffer-live-p draft)
          (with-current-buffer draft (set-buffer-modified-p nil))
          (kill-buffer draft))
        (rjd/mail-mode -1)
        (delete-directory root t)))))

(ert-deftest rjd/mail-reply-to-an-alias-is-from-that-alias ()
  "The alias someone wrote to is the one they see answering."
  (rjd/mail-test-needs-mu4e)
  (dolist (address rjd/mail-test-alias-addresses)
    (should (equal (rjd/mail-test-reply-from
                    (list rjd/mail-test-gmail rjd/mail-test-fastmail-aliases)
                    address)
                   address))))

(ert-deftest rjd/mail-reply-to-the-account-is-from-the-account ()
  "With or without aliases, mail to the address itself is answered from it."
  (rjd/mail-test-needs-mu4e)
  (dolist (fastmail (list rjd/mail-test-fastmail rjd/mail-test-fastmail-aliases))
    (should (equal (rjd/mail-test-reply-from
                    (list rjd/mail-test-gmail fastmail)
                    "someone@fastmail.example")
                   "someone@fastmail.example"))))


;; Mail Bcc'd to an alias names it only where it was delivered.
(ert-deftest rjd/mail-reply-to-mail-bccd-to-an-alias-is-from-that-alias ()
  "The alias in a delivery header answers when To and Cc name none."
  (rjd/mail-test-needs-mu4e)
  (dolist (header rjd/mail-delivery-headers)
    (dolist (address rjd/mail-test-alias-addresses)
      (should (equal (rjd/mail-test-reply-from
                      (list rjd/mail-test-gmail rjd/mail-test-fastmail-aliases)
                      "else@example.net"
                      (concat header ": " address "\n")
                      "/fastmail-test/INBOX")
                     address)))))

(ert-deftest rjd/mail-reply-prefers-the-alias-in-to ()
  "An alias in To wins over a different one the mail was delivered to."
  (rjd/mail-test-needs-mu4e)
  (should (equal (rjd/mail-test-reply-from
                  (list rjd/mail-test-gmail rjd/mail-test-fastmail-aliases)
                  "shop@someone.fastmail.example"
                  "X-Delivered-to: anything@someone.example\n")
                 "shop@someone.fastmail.example")))

(ert-deftest rjd/mail-reply-ignores-a-delivery-address-not-the-users ()
  "A delivery header naming someone else's address changes nothing."
  (rjd/mail-test-needs-mu4e)
  (should (equal (rjd/mail-test-reply-from
                  (list rjd/mail-test-gmail rjd/mail-test-fastmail-aliases)
                  "else@example.net"
                  "X-Delivered-to: forged@example.net\n"
                  "/fastmail-test/INBOX")
                 "someone@fastmail.example")))


;;; Invitation replies

(defconst rjd/mail-test-invitation
  "BEGIN:VCALENDAR
PRODID:-//Google Inc//Google Calendar 70.9054//EN
VERSION:2.0
CALSCALE:GREGORIAN
METHOD:REQUEST
BEGIN:VEVENT
DTSTART:20261011T003000Z
DTEND:20261011T013000Z
DTSTAMP:20261011T001500Z
ORGANIZER;CN=Org Person:mailto:org@example.com
UID:abc123@google.com
ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=TRUE;CN=Org Person;X-NUM-GUESTS=0:mailto:org@example.com
ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=me@example.net;X-NUM-GUESTS=0:mailto:me@example.net
CREATED:20261011T001500Z
DESCRIPTION:hello
LAST-MODIFIED:20261011T001500Z
LOCATION:
SEQUENCE:0
STATUS:CONFIRMED
SUMMARY:First invitation
TRANSP:OPAQUE
END:VEVENT
END:VCALENDAR
"
  "A Google Calendar invitation, as Google sends it, to me@example.net.
The organiser is an attendee too, as Google always makes them.")

(defun rjd/mail-test-reply (status ids)
  "The lines of the reply to `rjd/mail-test-invitation' with STATUS.
Built by gnus-icalendar for the attendee matching IDS, with
`rjd/mail-mode' on, and stamped at 2026-10-12 09:00 UTC."
  (require 'gnus-icalendar)
  (let ((rjd/mail-accounts nil)
        (mu4e-contexts nil)
        (mu4e-get-mail-command "true")
        (mu4e-query-rewrite-function 'identity)
        (rjd/mail-mode nil)
        (rjd/mail--before-mode nil)
        (user-mail-address "crasher@example.org")
        (user-full-name "Party Crasher")
        (decode-time (symbol-function 'decode-time)))
    (rjd/mail-mode 1)
    (unwind-protect
        (cl-letf (((symbol-function 'decode-time)
                   (lambda (&optional time &rest args)
                     (apply decode-time
                            (or time (encode-time '(0 0 9 12 10 2026 nil nil t)))
                            args))))
          (with-temp-buffer
            (insert rjd/mail-test-invitation)
            (split-string
             (gnus-icalendar-event-reply-from-buffer (current-buffer) status ids)
             "\r?\n" t)))
      (rjd/mail-mode -1))))

(defun rjd/mail-test-attendees (lines)
  "The ATTENDEE lines among LINES."
  (seq-filter (lambda (line) (string-prefix-p "ATTENDEE" line)) lines))

(ert-deftest rjd/mail-reply-carries-only-the-replying-attendee ()
  "Google ignores a REPLY with more than one ATTENDEE (#20)."
  (dolist (case '((accepted . "ACCEPTED")
                  (tentative . "TENTATIVE")
                  (declined . "DECLINED")))
    (let ((reply (rjd/mail-test-reply (car case) '("me@example\\.net"))))
      (should (equal (rjd/mail-test-attendees reply)
                     (list (concat "ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;"
                                   "PARTSTAT=" (cdr case) ";RSVP=TRUE;"
                                   "CN=me@example.net;X-NUM-GUESTS=0:"
                                   "mailto:me@example.net")))))))

(ert-deftest rjd/mail-reply-keeps-the-event-it-answers ()
  "Only the attendees change: the reply still names the same event."
  (let ((reply (rjd/mail-test-reply 'accepted '("me@example\\.net"))))
    (should (member "METHOD:REPLY" reply))
    (should (member "UID:abc123@google.com" reply))
    (should (member "SEQUENCE:0" reply))
    (should (member "ORGANIZER;CN=Org Person:mailto:org@example.com" reply))
    (should (member "DTSTAMP:20261012T090000Z" reply))))

(ert-deftest rjd/mail-reply-without-a-match-carries-only-the-added-attendee ()
  "Invited through a list, say: the reply answers for the added attendee."
  (let ((reply (rjd/mail-test-reply 'accepted '("nobody@example\\.com"))))
    (should (equal (rjd/mail-test-attendees reply)
                   '("ATTENDEE;CN=Party Crasher;PARTSTAT=ACCEPTED:mailto:crasher@example.org")))))

(ert-deftest rjd/mail-reply-is-left-alone-with-the-mode-off ()
  "The fix is the mode's: off, gnus-icalendar builds the reply as it does."
  ;; Turns the mode on and off again, so this is after the mode.
  (rjd/mail-test-reply 'accepted '("me@example\\.net"))
  (with-temp-buffer
    (insert rjd/mail-test-invitation)
    (should (length= (rjd/mail-test-attendees
                      (split-string (gnus-icalendar-event-reply-from-buffer
                                     (current-buffer) 'accepted
                                     '("me@example\\.net"))
                                    "\r?\n" t))
                     2))))


;;; Invitations to an alias

(defconst rjd/mail-test-alias-invitation
  "BEGIN:VCALENDAR
PRODID:-//Fastmail/2020.5/EN
VERSION:2.0
METHOD:REQUEST
BEGIN:VEVENT
DTSTART:20261011T003000Z
DTEND:20261011T013000Z
DTSTAMP:20261011T001500Z
ORGANIZER;CN=Org Person:mailto:org@example.com
UID:def456@fastmail.example
ATTENDEE;CN=Org Person;PARTSTAT=ACCEPTED:mailto:org@example.com
ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:anything@someone.example
SEQUENCE:0
SUMMARY:Invitation to an alias
END:VEVENT
END:VCALENDAR
"
  "An invitation to a Fastmail catch-all alias, with no name to match.")

(defmacro rjd/mail-test-as-gmail (mode &rest body)
  "Run BODY with the globals the Gmail identity and `rjd/mail-mode' MODE.
MODE is 1 or -1.  The accounts are declared only for BODY: the mode is
turned on with none, as making their contexts needs mu4e, which these
tests do without."
  (declare (indent 1))
  `(progn
     (require 'gnus-icalendar)
     (let ((rjd/mail-accounts nil)
           (mu4e-contexts nil)
           (mu4e-get-mail-command "true")
           (mu4e-query-rewrite-function 'identity)
           (rjd/mail-mode nil)
           (rjd/mail--before-mode nil)
           (user-mail-address (plist-get rjd/mail-test-gmail :address))
           (user-full-name (plist-get rjd/mail-test-gmail :full-name))
           (message-alternative-emails nil)
           (gnus-ignored-from-addresses nil)
           (gnus-icalendar-additional-identities nil))
       (rjd/mail-mode ,mode)
       (unwind-protect
           (let ((rjd/mail-accounts (list rjd/mail-test-gmail
                                          rjd/mail-test-fastmail-aliases)))
             ,@body)
         (rjd/mail-mode -1)))))

(defun rjd/mail-test-recognised-p (invitation)
  "Non-nil if gnus-icalendar offers to answer INVITATION.
It offers the Accept, Tentative and Decline buttons when one of
`gnus-icalendar-identities' finds an attendee asked to reply."
  (with-temp-buffer
    (insert invitation)
    (gnus-icalendar-event:rsvp
     (gnus-icalendar-event-from-buffer (current-buffer)
                                       (gnus-icalendar-identities)))))

(ert-deftest rjd/mail-invitation-to-an-alias-is-recognised-in-any-context ()
  "An alias with no name is an identity while the Gmail one is current."
  (rjd/mail-test-as-gmail 1
    (should (rjd/mail-test-recognised-p rjd/mail-test-alias-invitation))))


(ert-deftest rjd/mail-reply-to-an-alias-answers-for-that-alias ()
  "The reply carries the alias's attendee line alone, with the status."
  (dolist (case '((accepted . "ACCEPTED")
                  (tentative . "TENTATIVE")
                  (declined . "DECLINED")))
    (rjd/mail-test-as-gmail 1
      (with-temp-buffer
        (insert rjd/mail-test-alias-invitation)
        (should (equal (rjd/mail-test-attendees
                        (split-string (gnus-icalendar-event-reply-from-buffer
                                       (current-buffer) (car case)
                                       (gnus-icalendar-identities))
                                      "\r?\n" t))
                       (list (concat "ATTENDEE;PARTSTAT=" (cdr case)
                                     ";RSVP=TRUE:mailto:anything@someone.example"))))))))

(defun rjd/mail-test-own-invitation ()
  "An invitation the Gmail account organised, to a Fastmail alias.
Google lists the organiser as the first attendee, and that attendee is
the user's too, by address and by name."
  (let ((gmail (plist-get rjd/mail-test-gmail :address))
        (name (plist-get rjd/mail-test-gmail :full-name)))
    (concat "BEGIN:VCALENDAR
PRODID:-//Google Inc//Google Calendar 70.9054//EN
VERSION:2.0
METHOD:REQUEST
BEGIN:VEVENT
DTSTART:20261011T003000Z
DTEND:20261011T013000Z
DTSTAMP:20261011T001500Z
ORGANIZER;CN=" name ":mailto:" gmail "
UID:ghi789@google.com
ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=TRUE;CN=" name ";X-NUM-GUESTS=0:mailto:" gmail "
ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;X-NUM-GUESTS=0:mailto:anything@someone.example
SEQUENCE:0
SUMMARY:Invitation from yourself
END:VEVENT
END:VCALENDAR
")))

(ert-deftest rjd/mail-reply-never-answers-for-the-organiser ()
  "An invitation you organised from one account, to another's alias, is
answered for the alias: the organiser does not answer their own."
  (rjd/mail-test-as-gmail 1
    (with-temp-buffer
      (insert (rjd/mail-test-own-invitation))
      (should (equal (rjd/mail-test-attendees
                      (split-string (gnus-icalendar-event-reply-from-buffer
                                     (current-buffer) 'accepted
                                     (gnus-icalendar-identities))
                                    "\r?\n" t))
                     (list (concat "ATTENDEE;CUTYPE=INDIVIDUAL;"
                                   "ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;"
                                   "RSVP=TRUE;X-NUM-GUESTS=0:"
                                   "mailto:anything@someone.example")))))))

(ert-deftest rjd/mail-invitation-to-an-alias-needs-the-mode ()
  "Off, the alias is only the current context's, and Gmail's is current."
  ;; On and off again first, so that turning it off is what is tested.
  (rjd/mail-test-as-gmail 1)
  (rjd/mail-test-as-gmail -1
    (should-not (rjd/mail-test-recognised-p rjd/mail-test-alias-invitation))))


(provide 'rjd-mail-test)
;;; rjd-mail-test.el ends here
