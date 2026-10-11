;;; rjd-mail.el --- Mail accounts as mu4e contexts  -*- lexical-binding: t -*-

;;; Commentary:
;; Turns the mail accounts declared in `rjd/mail-accounts' into mu4e
;; contexts, and owns the one place mail commands are built:
;; `rjd/mail-command', which puts `rjd/mail-command-prefix' in front.
;;
;; The accounts are data, one plist each, set in private.el -- the
;; addresses have no place in this public repository.  With none
;; declared, nothing changes: there are no contexts and mu4e only
;; indexes.  So a machine without private.el starts cleanly.
;;
;; Declared accounts count only where mail can run, which
;; `rjd/mail-available-p' decides, for the calendar in rjd-gcal.el
;; too: the host with the mail container, and claude-dev with the
;; development toolchain.  Elsewhere -- leroy, bulldog -- private.el
;; still declares them, but `rjd/mail-active-accounts' is nil, and
;; Emacs starts as it does with none declared rather than running an
;; mbsync that is not set up for them.  `rjd/mail-enabled' overrides
;; the decision.
;;
;; The global settings -- `user-mail-address' and the rest -- stay the
;; Fastmail default that private.el sets, and they are what mail
;; written outside mu4e uses.  The exception is sending: where accounts
;; are active the mode makes `rjd/mail-send-it' the global
;; `message-send-mail-function', in place of smtpmail, which has no
;; credentials on the host (#28).  So mail from the default address
;; goes through its account's msmtp, inside mu4e or out, and any other
;; From still goes to smtpmail.  With no account active, smtpmail stays
;; the default.
;;
;; Entering a context saves whatever values it is about to change and
;; sets the account's; leaving puts the saved ones back.  mu4e itself
;; restores nothing on leaving: its context `vars' are plain `set's.
;; So everything here goes through the enter and leave functions, never
;; `vars'.
;;
;; A context stays entered while mu4e runs, and after it quits, so the
;; globals are then the account's.  A message buffer that is not mu4e's
;; -- C-x m, say -- therefore gets the default identity, sending
;; function and `message-alternative-emails' back as buffer-local
;; values, from `message-mode-hook'.
;;
;; The prefix exists because the tools that authenticate -- mbsync,
;; msmtp and oama -- run in a mail container on the host, reached
;; through `docker exec'; in development they run directly and the
;; prefix is nil.  ADR 0001 has the reasons.  The default is chosen per
;; machine when this file loads: the container's `docker exec -i' on a
;; host where the setup playbook has written the mail container's
;; configuration directory, nil inside a container (claude-dev) and on
;; a machine without the mail container.  If the choice is wrong, set
;; `rjd/mail-command-prefix' in private.el.
;;
;; Every context sends with `rjd/mail-send-it' as
;; `message-send-mail-function', and so, where accounts are active, does
;; mail outside every context.  It decides at send time, from the
;; message's From: an active account's address goes through that
;; account's msmtp, behind the prefix; any other address goes to the
;; sending function the mode replaced, smtpmail.  So a draft sends
;; as the account it was written as, whichever context is current when
;; it is sent.  It is its own function rather than message's sendmail
;; one, which puts "-oi" straight after the program and so would run
;; "docker -oi exec ...".
;;
;; An account's aliases -- Fastmail's plus, subdomain and catch-all
;; addresses -- are one regexp, its :addresses, which `rjd/mail--address-p'
;; matches against whole addresses.  Three things follow from it: mail
;; to an alias, in To or Cc, chooses the account's context; a From of
;; an alias sends through the account's msmtp; and the context sets
;; `message-alternative-emails' to the same test, which message's reply
;; -- mu4e's too -- uses to make the reply's From the address the
;; original was sent to.  Like the address itself, the regexp lives in
;; private.el.  mu needs the aliases as well, for `mu init
;; --my-address', so that it counts mail to them as personal and
;; reply-to-all leaves them out: give one `/.../' pattern per alias
;; form, in syntax PCRE and Emacs regexps share -- no alternation or
;; groups -- because mu matches it as PCRE and mu4e's
;; `mu4e-personal-address-p' as an Emacs regexp.
;;
;; Gmail needs three things from mu4e beyond these contexts:
;; duplicates hidden, because a message in the Inbox is also in All
;; Mail; related messages left out of searches, or a thread's spam and
;; trash come with it -- both set in init.el; and Spam and Trash left
;; out of searches, which the mode does through
;; `mu4e-query-rewrite-function' with `rjd/mail-search-query', unless
;; a search names them.
;;
;; Replies to calendar invitations need one fix to gnus-icalendar,
;; which mu4e-icalendar builds them with.  Emacs 31's
;; `gnus-icalendar-event--build-reply' -- a private function -- copies
;; every ATTENDEE of the invitation into the REPLY, the organiser's
;; included, where RFC 5546 allows only the one replying; and Google
;; ignores such a reply, so the acceptance never reaches the
;; organiser's calendar (#20).  The mode puts
;; `rjd/mail--reply-as-one-attendee' around it, which drops every
;; attendee from the built reply but the one the builder answered for.
;; It hooks the builder rather than the public
;; `gnus-icalendar-event-reply-from-buffer' because only there is the
;; reply still a syntax tree, not text; it finds the replier with the
;; builder's own `gnus-icalendar-event--find-attendee', also private.
;; If either is renamed, or the builder starts copying the attendee
;; nodes rather than reusing them, the advice does nothing -- replies
;; carry every attendee again and Google ignores them, silently -- so
;; if an acceptance stops showing on the organiser's calendar, look
;; here first.  Remove it once Emacs fixes the builder upstream.
;;
;; Enable with `rjd/mail-mode', once mu4e has loaded.

;;; Code:

(require 'seq)

(declare-function make-mu4e-context "mu4e-context")
(declare-function mu4e "mu4e")
(defvar mu4e-contexts)
(defvar mu4e-get-mail-command)
(defvar mu4e-query-rewrite-function)
(defvar message-send-mail-function)
(declare-function mu4e-root-maildir "mu4e-server")
(declare-function message-narrow-to-headers "message")
(declare-function message-fetch-field "message")
(declare-function mail-strip-quoted-names "mail-utils")
(declare-function gnus-icalendar-event--find-attendee "gnus-icalendar")
(declare-function icalendar-ast-node-children "icalendar-ast")
(declare-function icalendar-ast-node-set-children "icalendar-ast")
(declare-function icalendar-ast-node-type "icalendar-ast")
(defvar message-send-coding-system)
(defvar mail-header-separator)


;;; Customization

(defgroup rjd/mail nil
  "Mail accounts as mu4e contexts."
  :group 'mail)

(defcustom rjd/mail-container-name "mail"
  "The name of the mail container, as `docker exec' takes it.
The setup playbook's `mail_container_name'."
  :type 'string
  :group 'rjd/mail)

(defvar rjd/mail-container-directory "~/.config/mail-container"
  "The host directory that holds the mail container's configuration.
The setup playbook writes it, and mounts it into the container, so its
presence is what says this machine has the container.")

(defvar rjd/mail-container-marker-files '("/.dockerenv" "/run/.containerenv")
  "Files whose presence says Emacs itself runs in a container.
Docker's and podman's, as `rjd/container-git' in init.el checks.")

(defun rjd/mail-inside-container-p ()
  "Non-nil if Emacs itself runs in a container, as claude-dev's does.
Told by any of `rjd/mail-container-marker-files' existing."
  (seq-some #'file-exists-p rjd/mail-container-marker-files))

(defun rjd/mail-default-command-prefix ()
  "Return the mail command prefix this machine needs.
On a host with the mail container, the `docker exec -i' that reaches
it -- `-i', because msmtp reads the message on its standard input.
nil inside a container, which is claude-dev in development, where the
tools run directly; and nil on a machine without the mail container,
where there is nothing to reach."
  (and (not (rjd/mail-inside-container-p))
       (file-directory-p rjd/mail-container-directory)
       (list "docker" "exec" "-i" rjd/mail-container-name)))

(defcustom rjd/mail-command-prefix (rjd/mail-default-command-prefix)
  "Command words put in front of every mail command, or nil.
nil runs mbsync, msmtp and oama directly, as in development.  On a
host where they live in a container, the invocation that reaches it,
such as (\"docker\" \"exec\" \"-i\" \"mail\").  The default is chosen
for this machine when the package loads, by
`rjd/mail-default-command-prefix'."
  :type '(choice (const :tag "Run directly" nil)
                 (repeat string))
  :group 'rjd/mail)

(defvar rjd/mail-toolchain-program "mbsync"
  "The program whose presence says the mail tools are installed here.
Inside a container that is claude-dev with the development toolchain;
see `rjd/mail-available-p'.")

(defcustom rjd/mail-enabled 'auto
  "Whether the declared accounts and calendar take effect on this machine.
`auto' asks `rjd/mail-available-p' to decide from the machine; t and
nil force them on or off, from private.el."
  :type '(choice (const :tag "Where mail can run" auto)
                 (const :tag "Always" t)
                 (const :tag "Never" nil))
  :group 'rjd/mail)

(defun rjd/mail-available-p ()
  "Non-nil if mail can run on this machine, so accounts should count.
The one place that decides, for mail and calendar alike.  Unless
`rjd/mail-enabled' forces the answer, mail can run where
`rjd/mail-command-prefix' reaches the tools -- the host with the mail
container, or wherever private.el points it -- and inside a container
with `rjd/mail-toolchain-program' on `exec-path', which is claude-dev
during development.  Not on a host without the mail container, such
as leroy or bulldog: any mbsync there is not set up for these accounts.

Elsewhere `rjd/mail-accounts' and `rjd/gcal-account' are ignored, so
Emacs starts as it would with none declared."
  (if (eq rjd/mail-enabled 'auto)
      (and (or rjd/mail-command-prefix
               (and (rjd/mail-inside-container-p)
                    (executable-find rjd/mail-toolchain-program)))
           t)
    rjd/mail-enabled))

(defconst rjd/mail-gmail-folders
  '(:inbox "/inbox" :sent "/sent" :drafts "/drafts"
    :trash "/trash" :refile "/all" :spam "/spam")
  "Folders of a Gmail account, relative to its maildir.
The local names the mbsync configuration gives Gmail's INBOX, Sent
Mail, Drafts, Trash, All Mail and Spam.  Refiling -- archiving -- goes
to All Mail, so the message leaves the Inbox as it does on the web.")

(defcustom rjd/mail-accounts nil
  "Mail accounts, one plist each, which become mu4e contexts.
Set in private.el.  Each plist has:

  :name       the context's name, and by default its mbsync group
  :address    the address to send as
  :full-name  the name to send as
  :maildir    the account's maildir, relative to mu's root: \"/acct\"

and optionally:

  :folders    a plist of :inbox :sent :drafts :trash :refile :spam,
              each relative to :maildir; default
              `rjd/mail-gmail-folders'
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
              default :name
  :msmtp-account
              the msmtp account that sends as it; default :name
  :addresses  a regexp matching, whole and regardless of case, every
              other address the account receives and may send as --
              plus, subdomain and catch-all aliases.  Mail to one opens
              in the account's context, a From of one sends through
              the account's msmtp, and a reply is from the alias the
              original was sent to.  Default: none, only :address"
  :type '(repeat plist)
  :group 'rjd/mail)


;;; Shell commands

(defun rjd/mail-command (&rest argv)
  "Return ARGV with `rjd/mail-command-prefix' in front.
ARGV is a command and its arguments, as strings; so is the result."
  (append rjd/mail-command-prefix argv))

(defun rjd/mail-run-command (argv &optional start end)
  "Run ARGV, a command and its arguments, and return what it printed.
With START and END, the current buffer's text between them is the
command's standard input.  If the command exits other than 0, signal
an error that names it and its exit status, with what it wrote on
standard error -- which for msmtp, mbsync and oama says what went
wrong."
  (let ((input (current-buffer))
        (stderr (make-temp-file "rjd-mail-stderr")))
    (unwind-protect
        (with-temp-buffer
          (let* ((output (current-buffer))
                 (status
                  (if start
                      (with-current-buffer input
                        (apply #'call-process-region start end (car argv)
                               nil (list output stderr) nil (cdr argv)))
                    (apply #'call-process (car argv) nil (list output stderr)
                           nil (cdr argv)))))
            (unless (eql status 0)
              (error "`%s' failed (%s): %s"
                     (string-join argv " ") status
                     (with-temp-buffer
                       (insert-file-contents stderr)
                       (string-trim (buffer-string)))))
            (buffer-string)))
      (delete-file stderr))))

;;;###autoload
(defun rjd/mail-get-mail-command ()
  "Return the shell command that fetches mail for every active account.
For `mu4e-get-mail-command', which runs it through a shell.  With no
active accounts -- see `rjd/mail-active-accounts' -- it is \"true\",
mu4e's own default, so an update only indexes."
  (if-let* ((accounts (rjd/mail-active-accounts)))
      (mapconcat #'shell-quote-argument
                 (apply #'rjd/mail-command "mbsync"
                        (mapcar #'rjd/mail--mbsync-group accounts))
                 " ")
    "true"))


;;; Accounts

(defun rjd/mail-active-accounts ()
  "The accounts that take effect here: `rjd/mail-accounts', or nil.
Nil where `rjd/mail-available-p' says mail cannot run, so that a
machine without the tools behaves as if none were declared."
  (and (rjd/mail-available-p) rjd/mail-accounts))

(defun rjd/mail--mbsync-group (account)
  "The mbsync channel or group that syncs ACCOUNT."
  (or (plist-get account :mbsync-group) (plist-get account :name)))

(defun rjd/mail--folder (account folder)
  "The maildir of ACCOUNT's FOLDER, a key of `rjd/mail-gmail-folders'."
  (concat (plist-get account :maildir)
          (plist-get (or (plist-get account :folders) rjd/mail-gmail-folders)
                     folder)))

(defun rjd/mail--msmtp-account (account)
  "The msmtp account that sends ACCOUNT's mail."
  (or (plist-get account :msmtp-account) (plist-get account :name)))

(defun rjd/mail--settings (account)
  "The variables a context for ACCOUNT sets, as an alist.
With :addresses, `message-alternative-emails' too, so that a reply is
from the alias the original was sent to; without it, that is left
alone."
  `(,@(when (plist-get account :addresses)
        `((message-alternative-emails
           . ,(lambda (address) (rjd/mail--address-p account address)))))
    (user-mail-address . ,(plist-get account :address))
    (user-full-name . ,(plist-get account :full-name))
    (message-send-mail-function . rjd/mail-send-it)
    (mu4e-sent-folder . ,(rjd/mail--folder account :sent))
    (mu4e-drafts-folder . ,(rjd/mail--folder account :drafts))
    (mu4e-trash-folder . ,(rjd/mail--folder account :trash))
    (mu4e-refile-folder . ,(rjd/mail--folder account :refile))
    (mu4e-sent-messages-behavior
     . ,(or (plist-get account :sent-messages-behavior) 'delete))
    (mu4e-trash-without-flag
     . ,(if (plist-member account :trash-without-flag)
            (plist-get account :trash-without-flag)
          t))))

(defvar rjd/mail--saved nil
  "The global values a context replaced, to restore on leaving it.
An alist of (VARIABLE . VALUE), or nil outside every context.")

(defun rjd/mail--enter (settings)
  "Save the variables SETTINGS names, then set them."
  ;; Save only on the way in from outside every context, so that what
  ;; is restored is always the global default, not another account.
  (unless rjd/mail--saved
    (setq rjd/mail--saved
          (mapcar (lambda (cell)
                    (cons (car cell) (symbol-value (car cell))))
                  settings)))
  (dolist (cell settings)
    (set (car cell) (cdr cell))))

(defun rjd/mail--leave ()
  "Restore the values the current context replaced."
  (dolist (cell rjd/mail--saved)
    (set (car cell) (cdr cell)))
  (setq rjd/mail--saved nil))

(defconst rjd/mail--message-variables
  '(user-mail-address user-full-name message-send-mail-function
    message-alternative-emails)
  "The variables a context sets that decide who a message is from.
`message-alternative-emails' among them: with an account's aliases in
it, a reply outside mu4e would be from an alias.")

(defun rjd/mail--restore-default-identity ()
  "Make a message buffer outside mu4e send as the global default.
For `message-mode-hook'.  A mu4e context sets the identity, sending
function and aliases globally, and keeps them after mu4e quits, so a
plain \\[compose-mail] would otherwise go out as the last account mu4e
used, and a reply from one of its aliases.
Here they are put back, buffer-locally, to what the context replaced.
message copies these locals into the buffer it sends from."
  (when (and rjd/mail--saved (not (derived-mode-p 'mu4e-compose-mode)))
    (dolist (var rjd/mail--message-variables)
      (when-let* ((cell (assq var rjd/mail--saved)))
        (set (make-local-variable var) (cdr cell))))))

(defun rjd/mail--address-p (account address)
  "Non-nil if ADDRESS, a bare address, is one of ACCOUNT's.
That is its :address, or any whole address its :addresses regexp
matches; either way regardless of case."
  (and address
       (or (string-equal-ignore-case address (plist-get account :address))
           (when-let* ((regexp (plist-get account :addresses)))
             (let ((case-fold-search t))
               (string-match-p (concat "\\`\\(?:" regexp "\\)\\'") address))))))

(defun rjd/mail--matcher (account)
  "A mu4e match function for ACCOUNT.
A message matches when it is in the account's maildir, or addressed to
one of the account's addresses in To or Cc; see `rjd/mail--address-p'."
  (let ((prefix (concat (plist-get account :maildir) "/")))
    (lambda (msg)
      (when msg
        (or (string-prefix-p prefix (or (plist-get msg :maildir) ""))
            (seq-some (lambda (contact)
                        (rjd/mail--address-p account (plist-get contact :email)))
                      (append (plist-get msg :to) (plist-get msg :cc))))))))

(defun rjd/mail-contexts (&optional accounts)
  "Return a mu4e context for each of ACCOUNTS.
ACCOUNTS defaults to `rjd/mail-active-accounts'.  With none, nil."
  (let ((accounts (or accounts (rjd/mail-active-accounts))))
    (when accounts
      (require 'mu4e-context)
      (mapcar (lambda (account)
                (make-mu4e-context
                 :name (plist-get account :name)
                 ;; Worked out on entering, so that the sending command
                 ;; is built behind the prefix in force then.
                 :enter-func (lambda ()
                               (rjd/mail--enter (rjd/mail--settings account)))
                 :leave-func #'rjd/mail--leave
                 :match-func (rjd/mail--matcher account)))
              accounts))))


;;; Sending

(defun rjd/mail--account-for-address (address)
  "The active account ADDRESS is one of, or nil.
ADDRESS may carry a name and angle brackets, as a From header does.
One of an account's addresses is its :address or an alias its
:addresses matches; see `rjd/mail--address-p'."
  (when address
    (let ((address (string-trim (mail-strip-quoted-names address))))
      (seq-find (lambda (account) (rjd/mail--address-p account address))
                (rjd/mail-active-accounts)))))

(defun rjd/mail--sendmail-command (account)
  "The command that sends a message as ACCOUNT, built through the prefix.
`rjd/mail-send-it' adds the recipients."
  (rjd/mail-command "msmtp" "-a" (rjd/mail--msmtp-account account)
                    "--read-envelope-from"))

(defvar rjd/mail--fallback-send-function nil
  "The `message-send-mail-function' `rjd/mail-mode' replaced, or nil.
Where accounts are active the mode makes `rjd/mail-send-it' the
global default, and this -- smtpmail -- is what it sends with for a
From that no active account owns.")

(defun rjd/mail-send-it ()
  "Send the prepared message buffer as the account in its From.
A `message-send-mail-function': the global default where accounts are
active, which `rjd/mail-mode' sets, and the one every context sets.
The account is chosen now, from the message, not from the context: a
draft outlives the context it was written in, and mail written outside
mu4e comes here too.

From an active account, the message goes to that account's msmtp,
behind `rjd/mail-command-prefix' as it is now; msmtp reads the
recipients from the message (-t), or for a resend is given those of
its Resent-To.  From any other address it goes to the sending function
the mode replaced, `rjd/mail--fallback-send-function' -- smtpmail -- or
failing that the one a context replaced.

Not `message-send-mail-with-sendmail', which puts \"-oi\" straight
after `sendmail-program': with the program \"docker\" and the rest of
the prefixed command in `message-sendmail-extra-arguments', that makes
\"docker -oi exec ...\"."
  (require 'message)
  (let* ((headers (save-restriction
                    (message-narrow-to-headers)
                    (list (message-fetch-field "from")
                          (message-fetch-field "resent-to"))))
         (account (rjd/mail--account-for-address (nth 0 headers)))
         (resent-to (nth 1 headers)))
    (if (not account)
        (funcall (or rjd/mail--fallback-send-function
                     (alist-get 'message-send-mail-function rjd/mail--saved)
                     (error "No account sends as %s, and no default to send with"
                            (nth 0 headers))))
      ;; The separator line becomes the blank line that ends the headers.
      (goto-char (point-min))
      (re-search-forward (concat "^" (regexp-quote mail-header-separator) "\n"))
      (replace-match "\n")
      (run-hooks 'message-send-mail-hook)
      (let ((default-directory "/")
            (coding-system-for-write message-send-coding-system))
        (rjd/mail-run-command
         (append (rjd/mail--sendmail-command account)
                 (if resent-to
                     (split-string (mail-strip-quoted-names resent-to)
                                   "[ \t\n,]+" t)
                   '("-t")))
         (point-min) (point-max))))))


;;; Queries

(defun rjd/mail--junk-folders (accounts)
  "The maildirs of the Spam and Trash folders of ACCOUNTS."
  (mapcan (lambda (account)
            (list (rjd/mail--folder account :spam)
                  (rjd/mail--folder account :trash)))
          accounts))

(defun rjd/mail-without-junk (query)
  "Return mu QUERY with every active account's Spam and Trash left out.
QUERY itself when no account is active; see `rjd/mail-active-accounts'."
  (if-let* ((accounts (rjd/mail-active-accounts)))
      (format "(%s) AND NOT (%s)"
              query
              (mapconcat (lambda (maildir) (concat "maildir:" maildir))
                         (rjd/mail--junk-folders accounts)
                         " OR "))
    query))

(defun rjd/mail--asks-for-junk-p (query)
  "Non-nil if mu QUERY names junk, so should find it.
That is: it names an active account's Spam or Trash folder, whole, as
a maildir -- which a query already rewritten by `rjd/mail-without-junk'
does too; or it asks for flag:trashed, not NOT flag:trashed; or it
looks a message up by its ID, as following an org link does."
  (or (seq-some (lambda (folder)
                  (string-match-p (concat "maildir:\"?" (regexp-quote folder)
                                          "\\(?:[\")[:space:]]\\|\\'\\)")
                                  query))
                (rjd/mail--junk-folders (rjd/mail-active-accounts)))
      (let ((case-fold-search t)
            (start 0)
            found)
        (while (and (not found)
                    (string-match "\\(\\_<not[[:space:]]+\\|-\\)?flag:trashed"
                                  query start))
          (setq found (not (match-beginning 1))
                start (match-end 0)))
        found)
      (string-match-p "\\_<msgid:" query)))

(defun rjd/mail-search-query (query)
  "Return mu QUERY with junk left out, unless it asks for junk.
For `mu4e-query-rewrite-function', which mu4e applies to every search
-- typed, a bookmark's or a maildir's -- so Spam and Trash stay out of
all of them through `rjd/mail-without-junk'.  A query that names them
is left alone; see `rjd/mail--asks-for-junk-p'."
  (if (rjd/mail--asks-for-junk-p query)
      query
    (rjd/mail-without-junk query)))


;;; Flags on unread mail

(defun rjd/mail-move-flagged-new-to-cur (root)
  "Move the accounts' unread messages that carry flags from new/ to cur/.
ROOT is mu's root maildir.  mbsync files a message it has not seen
read in new/, with the rest of its flags still in the name: a starred
one is `...:2,F'.  mu reads the name of a file in new/ as New and
nothing else, so to it that message is not starred, and marking it read
makes the file `...:2,S' -- whereupon the next sync takes the Starred
label off it in Gmail (#18).  In cur/, mu reads the flags, and the file
is still unread, since it has no S.  mbsync finds a message by the UID
in its name, in new/ or cur/, so the move changes nothing on the server.

Only messages with flags move, so the rest stay New.  Only the maildirs
of `rjd/mail-active-accounts' are searched."
  (dolist (account (rjd/mail-active-accounts))
    (let ((maildir (concat (directory-file-name root)
                           (plist-get account :maildir))))
      (when (file-directory-p maildir)
        (dolist (new (directory-files-recursively
                      maildir "\\`new\\'" t
                      (lambda (dir)
                        (not (member (file-name-nondirectory dir)
                                     '("cur" "new" "tmp"))))))
          (let ((cur (expand-file-name "../cur" new)))
            (when (and (file-directory-p new) (file-directory-p cur))
              (dolist (file (directory-files new t ":2,[[:alpha:]]+\\'"))
                (when (file-regular-p file)
                  (rename-file file (file-name-concat
                                     cur (file-name-nondirectory file))))))))))))

(defun rjd/mail--move-flagged-new-before-index (&rest _)
  "Run `rjd/mail-move-flagged-new-to-cur' on mu's root, as mu4e indexes.
Advice on `mu4e-update-index', which mu4e calls once the fetch is done,
so every index sees the flags of mail mbsync has just put in new/.
Does nothing before mu4e has started and knows the root."
  (when-let* ((root (ignore-errors (mu4e-root-maildir))))
    (rjd/mail-move-flagged-new-to-cur root)))


;;; Invitation replies

(defun rjd/mail--attendees (vcalendar)
  "The ATTENDEE nodes of VCALENDAR's first VEVENT, and that VEVENT."
  (let ((vevent (seq-find (lambda (node)
                            (eq (icalendar-ast-node-type node) 'icalendar-vevent))
                          (icalendar-ast-node-children vcalendar))))
    (cons vevent
          (seq-filter (lambda (node)
                        (eq (icalendar-ast-node-type node) 'icalendar-attendee))
                      (and vevent (icalendar-ast-node-children vevent))))))

(defun rjd/mail--reply-as-one-attendee (build vcalendar status ids &rest args)
  "Call BUILD, then keep only the replying attendee in the reply it returns.
Advice around `gnus-icalendar-event--build-reply', which BUILD is, and
which VCALENDAR, STATUS, IDS and ARGS are passed on to.  It copies
every attendee of the invitation into the reply; RFC 5546 allows only
the one replying, and Google ignores a reply with more (#20).

The replier is the invitation's attendee that IDS match -- found as
BUILD finds it -- or, when none does, the one BUILD adds for
`user-mail-address': the reply's only attendee that is not the
invitation's.  If neither can be told, as when BUILD changes how it
makes the reply, the reply is returned as BUILD made it."
  (let* ((invited (cdr (rjd/mail--attendees vcalendar)))
         (matched (gnus-icalendar-event--find-attendee invited ids))
         (reply (apply build vcalendar status ids args))
         (vevent+attendees (rjd/mail--attendees reply))
         (vevent (car vevent+attendees))
         (attendees (cdr vevent+attendees))
         (replier (if matched
                      (car (memq matched attendees))
                    (let ((added (seq-remove (lambda (a) (memq a invited))
                                             attendees)))
                      (and (length= added 1) (car added))))))
    (when replier
      (apply #'icalendar-ast-node-set-children vevent
             (seq-remove (lambda (node)
                           (and (memq node attendees) (not (eq node replier))))
                         (icalendar-ast-node-children vevent))))
    reply))


;;; Syncing from startup

;;;###autoload
(defun rjd/mail-start-syncing ()
  "Start mu4e in the background, so mail syncs without opening it.
For `emacs-startup-hook'.  mu4e fetches and indexes every
`mu4e-update-interval' seconds, but only once it has started, which
otherwise waits for \\[mu4e].  Started with its BACKGROUND argument,
it shows no window.

Only where accounts are active -- see `rjd/mail-active-accounts' -- so
leroy and bulldog, and a machine with none declared, start nothing."
  (when (rjd/mail-active-accounts)
    ;; An error here would stop the rest of `emacs-startup-hook'.
    (with-demoted-errors "rjd-mail: starting mu4e in the background: %S"
      (mu4e t))))


;;; Mode

(defvar rjd/mail--before-mode nil
  "`mu4e-contexts', `mu4e-get-mail-command' and
`mu4e-query-rewrite-function' before the mode was on.")

;;;###autoload
(define-minor-mode rjd/mail-mode
  "Make each account in `rjd/mail-active-accounts' a mu4e context.
Also fetch mail for them through `rjd/mail-get-mail-command', leave
their Spam and Trash out of every search that does not ask for them,
through `rjd/mail-search-query', and keep message buffers outside mu4e
on the global default identity.  With accounts active, make
`rjd/mail-send-it' the global `message-send-mail-function', so mail
from an account's address goes through its msmtp wherever it was
written; it hands any other From to the function it replaced.
Turning the mode off puts back the contexts, fetch command, query
rewriting and sending function it replaced, and the global defaults
if a context was entered.

While on, each mu4e index first moves the accounts' unread mail that
carries flags out of new/; see `rjd/mail-move-flagged-new-to-cur'.
And a reply to a calendar invitation carries only the attendee who
replies; see `rjd/mail--reply-as-one-attendee'."
  :global t
  :group 'rjd/mail
  (if rjd/mail-mode
      (progn
        (unless rjd/mail--before-mode
          (setq rjd/mail--before-mode
                (list (bound-and-true-p mu4e-contexts)
                      (bound-and-true-p mu4e-get-mail-command)
                      (if (boundp 'mu4e-query-rewrite-function)
                          mu4e-query-rewrite-function
                        #'identity))))
        (setq mu4e-contexts (rjd/mail-contexts)
              mu4e-get-mail-command #'rjd/mail-get-mail-command
              mu4e-query-rewrite-function #'rjd/mail-search-query)
        (when (and (rjd/mail-active-accounts)
                   (not rjd/mail--fallback-send-function))
          (setq rjd/mail--fallback-send-function message-send-mail-function
                message-send-mail-function #'rjd/mail-send-it))
        (add-hook 'message-mode-hook #'rjd/mail--restore-default-identity)
        (advice-add 'mu4e-update-index :before
                    #'rjd/mail--move-flagged-new-before-index)
        (advice-add 'gnus-icalendar-event--build-reply :around
                    #'rjd/mail--reply-as-one-attendee))
    (remove-hook 'message-mode-hook #'rjd/mail--restore-default-identity)
    (advice-remove 'mu4e-update-index
                   #'rjd/mail--move-flagged-new-before-index)
    (advice-remove 'gnus-icalendar-event--build-reply
                   #'rjd/mail--reply-as-one-attendee)
    (when rjd/mail--before-mode
      (rjd/mail--leave)
      (setq mu4e-contexts (nth 0 rjd/mail--before-mode)
            mu4e-get-mail-command (nth 1 rjd/mail--before-mode)
            mu4e-query-rewrite-function (nth 2 rjd/mail--before-mode)
            rjd/mail--before-mode nil))
    (when rjd/mail--fallback-send-function
      (setq message-send-mail-function rjd/mail--fallback-send-function
            rjd/mail--fallback-send-function nil))))

(provide 'rjd-mail)
;;; rjd-mail.el ends here
