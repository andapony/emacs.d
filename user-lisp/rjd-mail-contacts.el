;;; rjd-mail-contacts.el --- Address completion from the people I write to  -*- lexical-binding: t -*-

;;; Commentary:
;; Address completion in a message offers only the people the user has
;; written to, or has chosen to add -- not everyone mu has ever seen in
;; a header, which is what mu4e's own completion offers, the senders of
;; every newsletter and every stranger on a long Cc included.
;;
;; The list is ecomplete's database, one file,
;; `rjd/mail-contacts-file'.  It fills three ways:
;;
;; - Each message sent adds its To and Cc, from `message-sent-hook',
;;   which runs only once sending has succeeded: `rjd/mail-send-it'
;;   and smtpmail both signal when they fail.  From, Reply-To and Bcc
;;   are left out, and so is any of the user's own addresses.  A
;;   recipient already listed has their count raised, so the people
;;   written to most come first; ecomplete lowers an entry 5% for each
;;   week it goes unused.
;; - `rjd/mail-contacts-add-sender', in a mu4e view or headers buffer,
;;   adds the sender of the message at point: someone heard from but
;;   not yet written to.
;; - `rjd/mail-contacts-seed', once, fills the list from the mail
;;   already sent, by asking `mu find' for the To and Cc of every
;;   message in each account's Sent folder.
;;
;; message.el's own learning, `message-mail-alias-type' `ecomplete', is
;; not used: it learns From and Reply-To, so the user's own addresses
;; are offered, and Bcc, and it shows matches in the echo area on every
;; keystroke in To and Cc, beside `completion-preview'.  So the mode
;; leaves that variable alone and reads the database through message's
;; standard completion instead, `message-expand-name-standard-ui', which
;; reads ecomplete's file whatever the alias type.  It reads it afresh
;; on each completion, so an entry synced in from another machine is
;; offered without restarting.  For the same reason every addition
;; here reads the file before writing it back, rather than saving a
;; copy loaded hours ago over another machine's additions.
;;
;; mu4e's completion is turned off, `mu4e-compose-complete-addresses'
;; nil: it comes before message's in a compose buffer and would offer
;; every contact again.
;;
;; The file lives in `rjd/mail-contacts-directory', `~/Sync/emacs/'
;; where ~/Sync is a Syncthing folder, so the list is the same on every
;; machine; elsewhere -- a work machine, or the claude-dev container,
;; which does not mount ~/Sync -- it is kept in ~/.  Never in
;; `user-emacs-directory', ecomplete's default: that is this public
;; repository's working tree, and the file is a list of addresses.
;; Saving rewrites the whole file, so two machines adding within one
;; sync interval leave a Syncthing conflict copy beside it.
;;
;; Enable with `rjd/mail-contacts-mode'.  Its tests are in
;; test/rjd-mail-contacts-test.el.

;;; Code:

(require 'ecomplete)
(require 'seq)

(declare-function mail-header-parse-addresses "mail-parse")
(declare-function message-field-value "message")
(declare-function mu4e-message-at-point "mu4e-message")
(declare-function mu4e-message-field "mu4e-message")
(declare-function mu4e-personal-address-p "mu4e-contacts")
(declare-function rjd/mail-own-address-p "rjd-mail")
(declare-function rjd/mail-active-accounts "rjd-mail")
(declare-function rjd/mail--folder "rjd-mail")
(defvar message-expand-name-standard-ui)
(defvar mu4e-compose-complete-addresses)
(defvar mu4e-mu-binary)
(defvar mu4e-sent-folder)


;;; Customization

(defgroup rjd/mail-contacts nil
  "Address completion from the people written to."
  :group 'mail)

(defcustom rjd/mail-contacts-directory
  (if (file-exists-p "~/Sync/.stfolder") "~/Sync/emacs/" "~/")
  "The directory that holds the completion list, `rjd/mail-contacts-file'.
By default ~/Sync/emacs/ where ~/Sync is a Syncthing folder, so that
every machine completes the same addresses, and ~/ elsewhere.  The
test is Syncthing's own marker rather than the directory, which other
configuration creates even where nothing syncs it."
  :type 'directory
  :group 'rjd/mail-contacts)

(defun rjd/mail-contacts-file ()
  "The file of the completion list, in `rjd/mail-contacts-directory'."
  (expand-file-name "ecompleterc" rjd/mail-contacts-directory))


;;; Addresses

(defun rjd/mail-contacts--own-p (address)
  "Non-nil if ADDRESS, a bare address, is one of the user's own.
Any active account's address or alias, as rjd-mail knows them; any
address mu counts as personal; or `user-mail-address'."
  (or (and (fboundp 'rjd/mail-own-address-p)
           (rjd/mail-own-address-p address))
      (and (fboundp 'mu4e-personal-address-p)
           (ignore-errors (mu4e-personal-address-p address)))
      (and user-mail-address
           (string-equal-ignore-case address user-mail-address))))

(defun rjd/mail-contacts--text (address name)
  "ADDRESS with NAME, as a recipient is written in a header.
A name that is not a plain phrase -- one with a comma, say -- is
quoted, so the completed text parses back to the same recipient."
  (if (or (null name) (string-blank-p name))
      address
    (format "%s <%s>"
            (if (string-match-p "[][()<>@,;:\\\".]" name)
                (prin1-to-string name)
              name)
            address)))

(defun rjd/mail-contacts--wanted (contacts)
  "CONTACTS, a list of (ADDRESS . NAME), less the user's own and empties.
Each ADDRESS is downcased, so that one person is one entry however a
header capitalised them."
  (seq-keep (pcase-lambda (`(,address . ,name))
              (when (and address
                         (string-match-p "@" address)
                         (not (rjd/mail-contacts--own-p address)))
                (cons (downcase address) name)))
            contacts))


;;; The database

(defun rjd/mail-contacts--load ()
  "Read the list from its file, if the file exists.
Done before every change, so that what is saved includes anything
another machine has synced in since the last read."
  (let ((ecomplete-database-file (rjd/mail-contacts-file)))
    (ecomplete-setup)))

(defun rjd/mail-contacts--save ()
  "Write the list to its file, making its directory first if need be."
  (let ((ecomplete-database-file (rjd/mail-contacts-file)))
    (make-directory (file-name-directory ecomplete-database-file) t)
    (ecomplete-save)))

(defun rjd/mail-contacts-add (contacts)
  "Add CONTACTS, a list of (ADDRESS . NAME), to the completion list.
An address already listed has its count raised.  The user's own
addresses are skipped.  Return the contacts added."
  (let ((wanted (rjd/mail-contacts--wanted contacts)))
    (when wanted
      (rjd/mail-contacts--load)
      (pcase-dolist (`(,address . ,name) wanted)
        (ecomplete-add-item 'mail address
                            (rjd/mail-contacts--text address name)))
      (rjd/mail-contacts--save))
    wanted))


;;; Learning from what is sent

(defun rjd/mail-contacts-learn-recipients ()
  "Add the To and Cc of the message being sent to the completion list.
For `message-sent-hook', which runs once sending has succeeded."
  (require 'mail-parse)
  (rjd/mail-contacts-add
   (mapcan (lambda (header)
             (let ((value (message-field-value header)))
               (and value (mail-header-parse-addresses value))))
           '("to" "cc"))))


;;; Adding a sender

;;;###autoload
(defun rjd/mail-contacts-add-sender ()
  "Add the sender of the mu4e message at point to the completion list."
  (interactive)
  (let* ((from (mu4e-message-field (mu4e-message-at-point) :from))
         (added (rjd/mail-contacts-add
                 (mapcar (lambda (contact)
                           (cons (plist-get contact :email)
                                 (plist-get contact :name)))
                         from))))
    (if added
        (message "Completing %s"
                 (mapconcat (pcase-lambda (`(,address . ,name))
                              (rjd/mail-contacts--text address name))
                            added ", "))
      (user-error "No sender here to add, other than one of your own"))))


;;; Seeding from sent mail

(defun rjd/mail-contacts--sent-folders ()
  "The Sent folder of each active account, or mu4e's global one."
  (or (and (fboundp 'rjd/mail-active-accounts)
           (mapcar (lambda (account) (rjd/mail--folder account :sent))
                   (rjd/mail-active-accounts)))
      (list (if (boundp 'mu4e-sent-folder) mu4e-sent-folder "/Sent"))))

(defun rjd/mail-contacts--sent-query (folders)
  "A mu query for the messages in FOLDERS."
  (mapconcat (lambda (folder) (format "maildir:%S" folder))
             folders " OR "))

(defun rjd/mail-contacts--parse-messages ()
  "The messages `mu find --format=sexp' wrote into the current buffer.
A list of plists, read one after another from point."
  (let (messages)
    (condition-case nil
        (while t (push (read (current-buffer)) messages))
      (end-of-file nil))
    (nreverse messages)))

(defun rjd/mail-contacts--tally (messages)
  "An alist of (ADDRESS COUNT TIME NAME) for the To and Cc of MESSAGES.
COUNT is how many of MESSAGES were to ADDRESS, TIME the latest of
their dates in seconds, and NAME the name the latest gave it.  The
user's own addresses are left out."
  (let ((tally (make-hash-table :test #'equal)))
    (dolist (msg messages)
      (let ((time (pcase (plist-get msg :date)
                    ((and (pred consp) date) (time-convert date 'integer))
                    ((and (pred integerp) date) date)
                    (_ 0))))
        (pcase-dolist (`(,address . ,name)
                       (rjd/mail-contacts--wanted
                        (mapcar (lambda (contact)
                                  (cons (plist-get contact :email)
                                        (plist-get contact :name)))
                                (append (plist-get msg :to)
                                        (plist-get msg :cc)))))
          (pcase (gethash address tally)
            ('nil (puthash address (list 1 time name) tally))
            (`(,count ,latest ,known)
             (puthash address
                      (if (> time latest)
                          (list (1+ count) time (or name known))
                        (list (1+ count) latest (or known name)))
                      tally))))))
    (let (result)
      (maphash (lambda (address entry) (push (cons address entry) result))
               tally)
      (sort result :key #'car))))

(defun rjd/mail-contacts-seed-from (tally)
  "Merge TALLY, from `rjd/mail-contacts--tally', into the list, and save.
An address not yet listed comes in with its count and its latest date,
so the ranking starts from the mail already sent rather than from
today.  One already listed keeps the larger count and the later date,
so seeding twice does not count the same mail twice."
  (rjd/mail-contacts--load)
  (pcase-dolist (`(,address ,count ,time ,name) tally)
    ;; The entry is (KEY COUNT TIME TEXT), the format ecomplete's
    ;; commentary documents.  Adding stamps a new one with today, which
    ;; the tally's date replaces.
    (let ((new (not (ecomplete-get-item 'mail address))))
      (when new
        (ecomplete-add-item 'mail address
                            (rjd/mail-contacts--text address name)))
      (let ((entry (ecomplete-get-item 'mail address)))
        (setcar (nthcdr 1 entry) (if new count (max count (nth 1 entry))))
        (setcar (nthcdr 2 entry) (if new time (max time (nth 2 entry)))))))
  (rjd/mail-contacts--save)
  (length tally))

;;;###autoload
(defun rjd/mail-contacts-seed ()
  "Fill the completion list from the To and Cc of mail already sent.
Asks `mu find' for every message in each active account's Sent folder.
Meant to be run once; running it again adds only what is new."
  (interactive)
  (let* ((mu (or (bound-and-true-p mu4e-mu-binary) "mu"))
         (query (rjd/mail-contacts--sent-query
                 (rjd/mail-contacts--sent-folders)))
         (messages
          (with-temp-buffer
            (let ((status (call-process mu nil (list t nil) nil
                                        "find" "--format=sexp"
                                        "--skip-dups" query)))
              ;; mu exits non-zero, with nothing written, when nothing
              ;; matches; any other failure leaves the buffer empty too,
              ;; and is reported below.
              (goto-char (point-min))
              (or (rjd/mail-contacts--parse-messages)
                  (unless (eql status 0)
                    (user-error "`%s find %s' found nothing (exit %s)"
                                mu query status))))))
         (count (rjd/mail-contacts-seed-from
                 (rjd/mail-contacts--tally messages))))
    (message "Completion list seeded with %d addresses from %d sent messages"
             count (length messages))))


;;; The mode

(defvar rjd/mail-contacts--saved nil
  "The values `rjd/mail-contacts-mode' replaced, to put back when it is off.
An alist of (VARIABLE . SAVED), SAVED being (t . VALUE), or nil
for a variable that was unbound: mu4e's variable is unbound until
mu4e loads, and is made unbound again rather than set to nil, so that
mu4e's own default applies once it does.")

(defconst rjd/mail-contacts--settings
  '((message-expand-name-standard-ui . t)
    (mu4e-compose-complete-addresses . nil))
  "The variables `rjd/mail-contacts-mode' sets, and to what.")

;;;###autoload
(define-minor-mode rjd/mail-contacts-mode
  "Complete addresses only from the people written to, or added.
Each message sent adds its To and Cc to the list in
`rjd/mail-contacts-file'; `rjd/mail-contacts-add-sender' adds the
sender of a message received.  See rjd-mail-contacts.el's commentary."
  :global t
  :group 'rjd/mail-contacts
  (if rjd/mail-contacts-mode
      (progn
        (unless rjd/mail-contacts--saved
          (setq rjd/mail-contacts--saved
                (mapcar (lambda (var)
                          (cons var (and (boundp var)
                                         (cons t (default-value var)))))
                        (cons 'ecomplete-database-file
                              (mapcar #'car rjd/mail-contacts--settings)))))
        (pcase-dolist (`(,var . ,value) rjd/mail-contacts--settings)
          (set-default var value))
        ;; Completion reads `ecomplete-database-file' itself, so it must
        ;; name the list too, and the copy read from any other file goes.
        (setq ecomplete-database-file (rjd/mail-contacts-file)
              ecomplete-database nil)
        (add-hook 'message-sent-hook #'rjd/mail-contacts-learn-recipients))
    (remove-hook 'message-sent-hook #'rjd/mail-contacts-learn-recipients)
    (pcase-dolist (`(,var . ,saved) rjd/mail-contacts--saved)
      (if saved
          (set-default var (cdr saved))
        (makunbound var)))
    (setq rjd/mail-contacts--saved nil
          ecomplete-database nil)))

(provide 'rjd-mail-contacts)
;;; rjd-mail-contacts.el ends here
