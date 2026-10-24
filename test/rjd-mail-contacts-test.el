;;; rjd-mail-contacts-test.el --- ERT tests for rjd-mail-contacts  -*- lexical-binding: t -*-

;;; Commentary:
;; Run from the repository root with
;;
;;   emacs -Q --batch -l test/rjd-mail-contacts-test.el -f ert-run-tests-batch-and-exit
;;
;; `-Q' keeps the personal config out, and the file loads
;; rjd-mail-contacts from source, for the reason rjd-mail-test.el gives.
;;
;; Every test works on a list in a fresh temporary directory, never the
;; real one, and with made-up addresses.  mu4e is not needed: the two
;; functions the sender command calls are stubbed, and `mu find' is
;; replaced by its recorded output.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'message)

(eval-and-compile
  (load (expand-file-name
         "../user-lisp/rjd-mail-contacts.el"
         (file-name-directory
          (or load-file-name byte-compile-current-file buffer-file-name)))
        nil :nomessage :nosuffix))

(defvar mu4e-compose-complete-addresses)


;;; Fixtures

(defmacro rjd/mail-contacts-test-with-list (&rest body)
  "Run BODY with an empty completion list in a temporary directory.
The user's own address is me@example.net."
  (declare (indent 0) (debug t))
  `(let* ((rjd/mail-contacts-directory
           (file-name-as-directory (make-temp-file "rjd-contacts" t)))
          (ecomplete-database-file (rjd/mail-contacts-file))
          (ecomplete-database nil)
          (user-mail-address "me@example.net"))
     (unwind-protect (progn ,@body)
       (delete-directory rjd/mail-contacts-directory t))))

(defun rjd/mail-contacts-test-saved ()
  "The entries in the list's file, as (ADDRESS COUNT TEXT), by address."
  (let ((ecomplete-database nil)
        (ecomplete-database-file (rjd/mail-contacts-file)))
    (ecomplete-setup)
    (sort (mapcar (pcase-lambda (`(,key ,count ,_time ,text))
                    (list key count text))
                  (cdr (assq 'mail ecomplete-database)))
          :key #'car)))

(defmacro rjd/mail-contacts-test-in-message (headers &rest body)
  "Run BODY in a message-mode buffer whose headers are HEADERS."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,headers mail-header-separator "\nBody.\n")
     (let ((message-mode-hook nil))
       (delay-mode-hooks (message-mode)))
     (goto-char (point-min))
     ,@body))


;;; Writing an address

(ert-deftest rjd/mail-contacts-text-plain-and-quoted ()
  "A bare address stays bare, a plain name is not quoted, an odd one is."
  (should (equal (rjd/mail-contacts--text "a@example.com" nil)
                 "a@example.com"))
  (should (equal (rjd/mail-contacts--text "a@example.com" "")
                 "a@example.com"))
  (should (equal (rjd/mail-contacts--text "a@example.com" "Ann Able")
                 "Ann Able <a@example.com>"))
  (should (equal (rjd/mail-contacts--text "a@example.com" "Able, Ann")
                 "\"Able, Ann\" <a@example.com>")))


;;; Learning from what is sent

(ert-deftest rjd/mail-contacts-learns-to-and-cc-only ()
  "Sending adds To and Cc, not From, Bcc, Reply-To or my own address."
  (rjd/mail-contacts-test-with-list
    (rjd/mail-contacts-test-in-message
        (concat "From: Me <me@example.net>\n"
                "To: Ann Able <Ann@Example.com>, \"Bee, Bo\" <bo@example.org>\n"
                "Cc: cy@example.com, me@example.net\n"
                "Bcc: secret@example.com\n"
                "Reply-To: other@example.net\n"
                "Subject: Hello\n")
      (rjd/mail-contacts-learn-recipients))
    (should (equal (rjd/mail-contacts-test-saved)
                   '(("ann@example.com" 1 "Ann Able <ann@example.com>")
                     ("bo@example.org" 1 "\"Bee, Bo\" <bo@example.org>")
                     ("cy@example.com" 1 "cy@example.com"))))))

(ert-deftest rjd/mail-contacts-learning-raises-the-count ()
  "Writing to someone again counts, and a name learned later is kept."
  (rjd/mail-contacts-test-with-list
    (rjd/mail-contacts-test-in-message "To: ann@example.com\n"
      (rjd/mail-contacts-learn-recipients))
    (rjd/mail-contacts-test-in-message "To: Ann Able <ann@example.com>\n"
      (rjd/mail-contacts-learn-recipients))
    (should (equal (rjd/mail-contacts-test-saved)
                   '(("ann@example.com" 2 "Ann Able <ann@example.com>"))))))

(ert-deftest rjd/mail-contacts-adding-rereads-the-file ()
  "An entry another machine synced into the file survives an addition."
  (rjd/mail-contacts-test-with-list
    (rjd/mail-contacts-add '(("ann@example.com" . "Ann")))
    ;; Another machine rewrites the file; this one still holds the old
    ;; list in memory.
    (with-temp-file (rjd/mail-contacts-file)
      (insert "((mail\n"
              "(\"ann@example.com\" 1 0 \"Ann <ann@example.com>\")\n"
              "(\"far@example.com\" 1 0 \"far@example.com\")\n"
              "))"))
    (rjd/mail-contacts-add '(("cy@example.com" . nil)))
    (should (equal (mapcar #'car (rjd/mail-contacts-test-saved))
                   '("ann@example.com" "cy@example.com" "far@example.com")))))

(ert-deftest rjd/mail-contacts-only-a-successful-send-learns ()
  "Through `message-send': a failed send adds nothing, a sent one adds."
  (rjd/mail-contacts-test-with-list
    (let ((message-sent-hook nil)
          (rjd/mail-contacts--saved nil)
          (message-expand-name-standard-ui nil)
          (message-interactive nil)
          (message-generate-headers-first nil)
          (message-required-mail-headers '(From Subject Date Message-ID))
          (message-send-mail-function
           (lambda () (error "Simulated failure"))))
      (unwind-protect
          (progn
            (rjd/mail-contacts-mode 1)
            (rjd/mail-contacts-test-in-message
                "From: me@example.net\nTo: ann@example.com\nSubject: Hi\n"
              (should-error (message-send))
              (should-not (file-exists-p (rjd/mail-contacts-file)))
              (setq message-send-mail-function #'ignore)
              (message-send))
            (should (equal (mapcar #'car (rjd/mail-contacts-test-saved))
                           '("ann@example.com"))))
        (rjd/mail-contacts-mode -1)))))


;;; Completing

(ert-deftest rjd/mail-contacts-completes-only-the-list ()
  "In To, message's completion offers the list's entries and no others."
  (rjd/mail-contacts-test-with-list
    (rjd/mail-contacts-add '(("ann@example.com" . "Ann Able")
                             ("andy@example.org" . nil)))
    (let ((rjd/mail-contacts--saved nil)
          (message-expand-name-standard-ui nil))
      (unwind-protect
          (progn
            (rjd/mail-contacts-mode 1)
            (should (null mu4e-compose-complete-addresses))
            (rjd/mail-contacts-test-in-message "To: An\n"
              (end-of-line)
              (let* ((capf (message-completion-function))
                     (data (if (functionp capf) (funcall capf) capf)))
                (should data)
                (should (equal (sort (all-completions
                                      "An" (nth 2 data))
                                     #'string<)
                               '("Ann Able <ann@example.com>")))
                (should (equal (all-completions "and" (nth 2 data))
                               '("andy@example.org"))))))
        (rjd/mail-contacts-mode -1)))))


;;; Adding a sender

(ert-deftest rjd/mail-contacts-add-sender-adds-from ()
  "The sender of the message at point is added, with their name."
  (rjd/mail-contacts-test-with-list
    (cl-letf (((symbol-function 'mu4e-message-at-point) (lambda () 'msg))
              ((symbol-function 'mu4e-message-field)
               (lambda (msg field)
                 (should (eq msg 'msg))
                 (should (eq field :from))
                 '((:email "Dee@Example.com" :name "Dee Dee")))))
      (rjd/mail-contacts-add-sender))
    (should (equal (rjd/mail-contacts-test-saved)
                   '(("dee@example.com" 1 "Dee Dee <dee@example.com>"))))))

(ert-deftest rjd/mail-contacts-add-sender-refuses-my-own ()
  "A message from me adds nothing, and says so."
  (rjd/mail-contacts-test-with-list
    (cl-letf (((symbol-function 'mu4e-message-at-point) (lambda () 'msg))
              ((symbol-function 'mu4e-message-field)
               (lambda (_msg _field) '((:email "me@example.net" :name "Me")))))
      (should-error (rjd/mail-contacts-add-sender) :type 'user-error))
    (should-not (file-exists-p (rjd/mail-contacts-file)))))


;;; Seeding from sent mail

(defconst rjd/mail-contacts-test-mu-output
  (concat
   "(:subject \"one\" :date (26000 0 0)"
   " :from ((:email \"me@example.net\" :name \"Me\"))"
   " :to ((:email \"ann@example.com\" :name \"Ann\"))"
   " :cc ((:email \"me@example.net\") (:email \"bo@example.org\")))\n"
   "(:subject \"two\" :date (26100 0 0)"
   " :to ((:email \"Ann@example.com\" :name \"Ann Able\")))\n")
  "What `mu find --format=sexp' writes for two sent messages.")

(ert-deftest rjd/mail-contacts-tally-counts-and-dates ()
  "Each recipient's count, latest date and latest name; mine left out."
  (with-temp-buffer
    (insert rjd/mail-contacts-test-mu-output)
    (goto-char (point-min))
    (let ((user-mail-address "me@example.net"))
      (should (equal (rjd/mail-contacts--tally
                      (rjd/mail-contacts--parse-messages))
                     `(("ann@example.com" 2
                        ,(time-convert '(26100 0 0) 'integer) "Ann Able")
                       ("bo@example.org" 1
                        ,(time-convert '(26000 0 0) 'integer) nil)))))))

(ert-deftest rjd/mail-contacts-seeding-twice-counts-once ()
  "Seeding keeps the larger count, so the same mail never counts twice."
  (rjd/mail-contacts-test-with-list
    (let ((tally '(("ann@example.com" 2 1700000000 "Ann Able"))))
      (rjd/mail-contacts-seed-from tally)
      (rjd/mail-contacts-seed-from tally)
      (let ((ecomplete-database nil))
        (rjd/mail-contacts--load)
        (should (equal (ecomplete-get-item 'mail "ann@example.com")
                       '("ann@example.com" 2 1700000000
                         "Ann Able <ann@example.com>")))))))

(ert-deftest rjd/mail-contacts-seed-runs-mu-on-the-sent-folders ()
  "The command asks mu for the Sent folders' messages and merges them."
  (rjd/mail-contacts-test-with-list
    (let (args)
      (cl-letf (((symbol-function 'rjd/mail-contacts--sent-folders)
                 (lambda () '("/one/Sent" "/two/[Gmail]/Sent Mail")))
                ((symbol-function 'call-process)
                 (lambda (_program _infile _destination _display &rest rest)
                   (setq args rest)
                   (insert rjd/mail-contacts-test-mu-output)
                   0)))
        (rjd/mail-contacts-seed))
      (should (equal args
                     '("find" "--format=sexp" "--skip-dups"
                       "maildir:\"/one/Sent\" OR maildir:\"/two/[Gmail]/Sent Mail\"")))
      (should (equal (mapcar #'car (rjd/mail-contacts-test-saved))
                     '("ann@example.com" "bo@example.org"))))))


;;; The mode

(ert-deftest rjd/mail-contacts-mode-off-puts-back ()
  "Turning the mode off restores what it set, unbinding what was unbound."
  (let ((rjd/mail-contacts--saved nil)
        (message-sent-hook nil)
        (message-expand-name-standard-ui nil)
        (ecomplete-database-file "/somewhere/else"))
    (when (boundp 'mu4e-compose-complete-addresses)
      (makunbound 'mu4e-compose-complete-addresses))
    (rjd/mail-contacts-mode 1)
    (should (eq message-expand-name-standard-ui t))
    (should (equal ecomplete-database-file (rjd/mail-contacts-file)))
    (should (memq #'rjd/mail-contacts-learn-recipients message-sent-hook))
    (rjd/mail-contacts-mode -1)
    (should (eq message-expand-name-standard-ui nil))
    (should (equal ecomplete-database-file "/somewhere/else"))
    (should-not (boundp 'mu4e-compose-complete-addresses))
    (should-not (memq #'rjd/mail-contacts-learn-recipients
                      message-sent-hook))))

(provide 'rjd-mail-contacts-test)
;;; rjd-mail-contacts-test.el ends here
