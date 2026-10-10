;;; rjd-mail.el --- Mail accounts as mu4e contexts  -*- lexical-binding: t -*-

;;; Commentary:
;; Turns the mail accounts declared in `rjd-mail-accounts' into mu4e
;; contexts, and owns the one place mail commands are built:
;; `rjd-mail-command', which puts `rjd-mail-command-prefix' in front.
;;
;; The accounts are data, one plist each, set in private.el -- the
;; addresses have no place in this public repository.  With none
;; declared, nothing changes: there are no contexts and mu4e only
;; indexes.  So a machine without private.el starts cleanly.
;;
;; The global settings -- `user-mail-address', smtpmail and the rest --
;; stay the Fastmail default that private.el sets, and they are what
;; mail written outside mu4e uses.  Entering a context saves whatever
;; values it is about to change and sets the account's; leaving puts
;; the saved ones back.  mu4e itself restores nothing on leaving: its
;; context `vars' are plain `set's.  So everything here goes through
;; the enter and leave functions, never `vars'.
;;
;; The prefix exists because the tools that authenticate -- mbsync,
;; msmtp and oama -- run in a mail container on the host, reached
;; through `docker exec'; in development they run directly and the
;; prefix is nil.  ADR 0001 has the reasons.
;;
;; Gmail needs three things from mu4e beyond these contexts, set in
;; init.el: duplicates hidden, because a message in the Inbox is also in
;; All Mail; related messages left out of searches, or a thread's spam
;; and trash come with it; and bookmarks that leave Spam and Trash out,
;; for which `rjd-mail-without-junk' builds the query.
;;
;; Enable with `rjd-mail-mode', once mu4e has loaded.

;;; Code:

(require 'seq)

(declare-function make-mu4e-context "mu4e-context")
(defvar mu4e-contexts)
(defvar mu4e-get-mail-command)


;;; Customization

(defgroup rjd-mail nil
  "Mail accounts as mu4e contexts."
  :group 'mail)

(defcustom rjd-mail-command-prefix nil
  "Command words put in front of every mail command, or nil.
nil runs mbsync, msmtp and oama directly, as in development.  On a
host where they live in a container, the invocation that reaches it,
such as (\"docker\" \"exec\" \"-i\" \"mail\")."
  :type '(choice (const :tag "Run directly" nil)
                 (repeat string))
  :group 'rjd-mail)

(defconst rjd-mail-gmail-folders
  '(:inbox "/inbox" :sent "/sent" :drafts "/drafts"
    :trash "/trash" :refile "/all" :spam "/spam")
  "Folders of a Gmail account, relative to its maildir.
The local names the mbsync configuration gives Gmail's INBOX, Sent
Mail, Drafts, Trash, All Mail and Spam.  Refiling -- archiving -- goes
to All Mail, so the message leaves the Inbox as it does on the web.")

(defcustom rjd-mail-accounts nil
  "Mail accounts, one plist each, which become mu4e contexts.
Set in private.el.  Each plist has:

  :name       the context's name, and by default its mbsync group
  :address    the address to send as
  :full-name  the name to send as
  :maildir    the account's maildir, relative to mu's root: \"/acct\"

and optionally:

  :folders    a plist of :inbox :sent :drafts :trash :refile :spam,
              each relative to :maildir; default
              `rjd-mail-gmail-folders'
  :sent-messages-behavior
              `mu4e-sent-messages-behavior' in this context; default
              `delete', since Gmail files sent mail itself
  :trash-without-flag
              `mu4e-trash-without-flag' in this context; default t.
              Gmail needs it: a message moved to Trash with the trashed
              flag is expunged by mbsync rather than uploaded, so on the
              server it would only leave the Inbox, not reach Trash
  :mbsync-group
              the mbsync channel or group that syncs the account;
              default :name"
  :type '(repeat plist)
  :group 'rjd-mail)


;;; Commands

(defun rjd-mail-command (&rest argv)
  "Return ARGV with `rjd-mail-command-prefix' in front.
ARGV is a command and its arguments, as strings; so is the result."
  (append rjd-mail-command-prefix argv))

;;;###autoload
(defun rjd-mail-get-mail-command ()
  "Return the shell command that fetches mail for every declared account.
For `mu4e-get-mail-command', which runs it through a shell.  With no
accounts it is \"true\", mu4e's own default, so an update only indexes."
  (if rjd-mail-accounts
      (mapconcat #'shell-quote-argument
                 (apply #'rjd-mail-command "mbsync"
                        (mapcar #'rjd-mail--mbsync-group rjd-mail-accounts))
                 " ")
    "true"))


;;; Accounts

(defun rjd-mail--mbsync-group (account)
  "The mbsync channel or group that syncs ACCOUNT."
  (or (plist-get account :mbsync-group) (plist-get account :name)))

(defun rjd-mail--folder (account folder)
  "The maildir of ACCOUNT's FOLDER, a key of `rjd-mail-gmail-folders'."
  (concat (plist-get account :maildir)
          (plist-get (or (plist-get account :folders) rjd-mail-gmail-folders)
                     folder)))

(defun rjd-mail--settings (account)
  "The variables a context for ACCOUNT sets, as an alist."
  `((user-mail-address . ,(plist-get account :address))
    (user-full-name . ,(plist-get account :full-name))
    (mu4e-sent-folder . ,(rjd-mail--folder account :sent))
    (mu4e-drafts-folder . ,(rjd-mail--folder account :drafts))
    (mu4e-trash-folder . ,(rjd-mail--folder account :trash))
    (mu4e-refile-folder . ,(rjd-mail--folder account :refile))
    (mu4e-sent-messages-behavior
     . ,(or (plist-get account :sent-messages-behavior) 'delete))
    (mu4e-trash-without-flag
     . ,(if (plist-member account :trash-without-flag)
            (plist-get account :trash-without-flag)
          t))))

(defvar rjd-mail--saved nil
  "The global values a context replaced, to restore on leaving it.
An alist of (VARIABLE . VALUE), or nil outside every context.")

(defun rjd-mail--enter (settings)
  "Save the variables SETTINGS names, then set them."
  ;; Save only on the way in from outside every context, so that what
  ;; is restored is always the global default, not another account.
  (unless rjd-mail--saved
    (setq rjd-mail--saved
          (mapcar (lambda (cell)
                    (cons (car cell) (symbol-value (car cell))))
                  settings)))
  (dolist (cell settings)
    (set (car cell) (cdr cell))))

(defun rjd-mail--leave ()
  "Restore the values the current context replaced."
  (dolist (cell rjd-mail--saved)
    (set (car cell) (cdr cell)))
  (setq rjd-mail--saved nil))

(defun rjd-mail--matcher (account)
  "A mu4e match function for ACCOUNT.
A message matches when it is in the account's maildir, or addressed to
the account in To or Cc."
  (let ((prefix (concat (plist-get account :maildir) "/"))
        (address (downcase (plist-get account :address))))
    (lambda (msg)
      (when msg
        (or (string-prefix-p prefix (or (plist-get msg :maildir) ""))
            (seq-some (lambda (contact)
                        (equal (downcase (or (plist-get contact :email) ""))
                               address))
                      (append (plist-get msg :to) (plist-get msg :cc))))))))

(defun rjd-mail-contexts (&optional accounts)
  "Return a mu4e context for each of ACCOUNTS.
ACCOUNTS defaults to `rjd-mail-accounts'.  With none, nil."
  (let ((accounts (or accounts rjd-mail-accounts)))
    (when accounts
      (require 'mu4e-context)
      (mapcar (lambda (account)
                (let ((settings (rjd-mail--settings account)))
                  (make-mu4e-context
                   :name (plist-get account :name)
                   :enter-func (lambda () (rjd-mail--enter settings))
                   :leave-func #'rjd-mail--leave
                   :match-func (rjd-mail--matcher account))))
              accounts))))


;;; Queries

;;;###autoload
(defun rjd-mail-without-junk (query)
  "Return mu QUERY with every declared account's Spam and Trash left out.
QUERY itself when no account is declared."
  (if rjd-mail-accounts
      (format "(%s) AND NOT (%s)"
              query
              (mapconcat (lambda (maildir) (concat "maildir:" maildir))
                         (mapcan (lambda (account)
                                   (list (rjd-mail--folder account :spam)
                                         (rjd-mail--folder account :trash)))
                                 rjd-mail-accounts)
                         " OR "))
    query))


;;; Mode

(defvar rjd-mail--before-mode nil
  "`mu4e-contexts' and `mu4e-get-mail-command' before the mode was on.")

;;;###autoload
(define-minor-mode rjd-mail-mode
  "Make each account in `rjd-mail-accounts' a mu4e context.
Also fetch mail for them through `rjd-mail-get-mail-command'.  Turning
the mode off puts back the contexts and fetch command it replaced, and
the global defaults if a context was entered."
  :global t
  :group 'rjd-mail
  (if rjd-mail-mode
      (progn
        (unless rjd-mail--before-mode
          (setq rjd-mail--before-mode
                (list (bound-and-true-p mu4e-contexts)
                      (bound-and-true-p mu4e-get-mail-command))))
        (setq mu4e-contexts (rjd-mail-contexts)
              mu4e-get-mail-command #'rjd-mail-get-mail-command))
    (when rjd-mail--before-mode
      (rjd-mail--leave)
      (setq mu4e-contexts (nth 0 rjd-mail--before-mode)
            mu4e-get-mail-command (nth 1 rjd-mail--before-mode)
            rjd-mail--before-mode nil))))

(provide 'rjd-mail)
;;; rjd-mail.el ends here
