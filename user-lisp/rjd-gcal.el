;;; rjd-gcal.el --- Google Calendar in org-agenda, read-only, via oama  -*- lexical-binding: t; -*-

;;; Commentary:

;; Fetches one Google account's calendar into an org file in the agenda,
;; with org-gcal, and never writes back.  The OAuth token comes from
;; oama, the token store mail already uses, so the calendar needs no
;; login, client or token file of its own.
;;
;; CAVEAT: this leans on oauth2-auto's interface.  org-gcal asks
;; `oauth2-auto-access-token' for every token, with the provider
;; `org-gcal', and waits on the aio promise it returns.  The mode puts
;; `:around' advice on that function which answers for the `org-gcal'
;; provider itself -- running oama's access command through
;; `rjd/mail-command', and returning the output as an already resolved
;; promise -- and lets every other provider through.  If the calendar
;; disappears from the agenda after an org-gcal or oauth2-auto
;; upgrade, that advice is the first place to look: the function may
;; have been renamed, or no longer return a promise, or org-gcal may ask
;; for its token some other way.  If oauth2-auto's own flow is reached
;; instead, it opens a browser for a client that does not exist.
;;
;; Two more things org-gcal does that this works round, both public:
;; its fetch reports completion before any event has arrived, so the
;; end of a fetch is taken from `org-gcal-after-update-entry-functions'
;; going quiet; and it leaves the calendar file's buffer modified, so
;; that is saved then.
;;
;; org-gcal and its dependencies write runtime state into
;; `user-emacs-directory' -- persist/, request/ and
;; .org-generic-id-locations -- none of it an OAuth token.
;;
;; The calendar is fetched only where mail can run, as
;; `rjd/mail-available-p' decides: the token comes from the same tools.
;; Elsewhere `rjd/gcal-active-account' is nil, so there is no timer and
;; no fetch, though the calendar file is still made, empty.
;;
;; Enable with `rjd/gcal-mode'.  Turning it off is the way round a bad
;; upgrade.

;;; Code:

(require 'rjd-mail)

(declare-function aio-promise "aio")
(declare-function aio-resolve "aio")


;;; Customization

(defgroup rjd/gcal nil
  "Google Calendar in org-agenda, read-only."
  :group 'org)

(defcustom rjd/gcal-account nil
  "Address of the Google account whose calendar is fetched, or nil.
oama is asked for this account's token.  Nil leaves the calendar off,
and so does a machine where mail cannot run: see
`rjd/gcal-active-account'."
  :type '(choice (const :tag "None" nil) string)
  :group 'rjd/gcal)

(defun rjd/gcal-active-account ()
  "The account whose calendar is fetched here: `rjd/gcal-account', or nil.
Nil where `rjd/mail-available-p' says mail cannot run, since the token
comes from the same tools, so such a machine fetches nothing."
  (and (rjd/mail-available-p) rjd/gcal-account))

(defcustom rjd/gcal-calendar-id nil
  "ID of the calendar to fetch, or nil for the account's primary calendar.
The primary calendar's ID is the account's address."
  :type '(choice (const :tag "Primary" nil) string)
  :group 'rjd/gcal)

(defcustom rjd/gcal-file "~/org-agenda/gcal.org"
  "The org file the calendar is fetched into.
It belongs to the calendar: each fetch rewrites its entries, and
nothing written there reaches Google.  List it in `org-agenda-files'."
  :type 'file
  :group 'rjd/gcal)

(defcustom rjd/gcal-fetch-interval 900
  "Seconds between fetches while Emacs runs, or nil for none.
Opening the agenda fetches too.  Takes effect when `rjd/gcal-mode' is
next turned on."
  :type '(choice (const :tag "Only when the agenda opens" nil) natnum)
  :group 'rjd/gcal)

(defcustom rjd/gcal-token-command '("oama" "access")
  "Command printing an access token for an account, without the account.
The account is appended, and the whole is run through
`rjd/mail-command', so that it lands where the token store is."
  :type '(repeat string)
  :group 'rjd/gcal)


;;; The token

(defun rjd/gcal--token ()
  "Return a fresh access token for `rjd/gcal-account'.
Signal an error, with the command's own message, if it fails."
  (let ((argv (apply #'rjd/mail-command
                     (append rjd/gcal-token-command (list rjd/gcal-account))))
        (stderr (make-temp-file "rjd-gcal-stderr")))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process (car argv) nil
                               (list t stderr) nil (cdr argv)))
                (output (string-trim (buffer-string))))
            (if (and (eql status 0) (not (string-empty-p output)))
                output
              (error "rjd-gcal: `%s' failed (%s): %s"
                     (string-join argv " ") status
                     (with-temp-buffer
                       (insert-file-contents stderr)
                       (string-trim (buffer-string)))))))
      (delete-file stderr))))

(defun rjd/gcal--access-token (access-token username provider)
  "Answer for the `org-gcal' PROVIDER with a token from oama.
Advice around `oauth2-auto-access-token', which ACCESS-TOKEN is.  For
`org-gcal', return an aio promise already resolved to the token, as
that function's own would be once it had one; USERNAME, the calendar
ID, plays no part, since oama keys tokens by account.  A failure is
kept in the promise, so it is signalled where the token is awaited.
Any other provider goes to ACCESS-TOKEN."
  (if (not (eq provider 'org-gcal))
      (funcall access-token username provider)
    (let ((promise (aio-promise))
          (result (condition-case err
                      (let ((token (rjd/gcal--token)))
                        (lambda () token))
                    (error (lambda () (signal (car err) (cdr err)))))))
      (aio-resolve promise result)
      promise)))


;;; Fetching

(defvar rjd/gcal--timer nil
  "The timer fetching every `rjd/gcal-fetch-interval' seconds, or nil.")

(defvar rjd/gcal--settle-timer nil
  "The timer that finishes a fetch once its updates stop, or nil.")

(defvar rjd/gcal--last-fetch nil
  "When the last fetch started, or nil.")

(defconst rjd/gcal--agenda-quiet-period 120
  "Seconds after a fetch during which opening the agenda fetches no more.
Redoing the agenda runs `org-agenda-mode-hook' again, and a finished
fetch redoes it, so without this each fetch would set off the next.")

(defconst rjd/gcal--settle-delay 2
  "Seconds without an updated event after which a fetch counts as done.")

(defvar org-gcal-fetch-file-alist)
(declare-function org-gcal-fetch "org-gcal")
(declare-function org-agenda-redo "org-agenda")

;;;###autoload
(defun rjd/gcal-file-p (file)
  "Non-nil if FILE is the calendar file, `rjd/gcal-file'."
  (and rjd/gcal-file
       (string= (expand-file-name file) (expand-file-name rjd/gcal-file))))

(defun rjd/gcal--ensure-file ()
  "Create `rjd/gcal-file', empty, if it is missing and its directory is not.
The agenda asks what to do about a missing agenda file every time it
opens, and the file is missing until a fetch has succeeded -- for
good, on a machine whose fetch cannot."
  (let ((file (expand-file-name rjd/gcal-file)))
    (when (and (not (file-exists-p file))
               (file-directory-p (file-name-directory file)))
      (write-region "" nil file nil 'silent))))

(defun rjd/gcal--settled ()
  "Finish a fetch: save the calendar file, and redo every agenda.
org-gcal leaves the file's buffer modified, which would otherwise be
asked about when Emacs exits, and an agenda already showing would not
show the new events."
  (setq rjd/gcal--settle-timer nil)
  (when-let* ((buffer (find-buffer-visiting rjd/gcal-file)))
    (with-current-buffer buffer
      (when (buffer-modified-p)
        (let ((save-silently t))
          (save-buffer)))))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'org-agenda-mode)
        (org-agenda-redo t)))))

(defun rjd/gcal--event-updated (&rest _)
  "Finish the fetch once events have stopped arriving for a moment.
On `org-gcal-after-update-entry-functions'.  org-gcal's fetch returns
a deferred chain that completes before the events arrive -- its loop
over calendars drops each calendar's own chain -- so the updates are
the only sign of progress there is."
  (when (timerp rjd/gcal--settle-timer)
    (cancel-timer rjd/gcal--settle-timer))
  (setq rjd/gcal--settle-timer
        (run-at-time rjd/gcal--settle-delay nil #'rjd/gcal--settled)))

;;;###autoload
(defun rjd/gcal-fetch ()
  "Fetch the calendar of `rjd/gcal-active-account' into `rjd/gcal-file'.
Only ever reads from Google: this is `org-gcal-fetch', which is
org-gcal's sync with the export step skipped, and the token's scope is
read-only besides.  The fetch runs in the background; once its events
have arrived the file is saved and any agenda redone.  Does nothing
without an account, or where mail cannot run."
  (interactive)
  (if-let* ((account (rjd/gcal-active-account)))
      (progn
        (require 'org-gcal)
        (rjd/gcal--ensure-file)
        (setq org-gcal-fetch-file-alist
              (list (cons (or rjd/gcal-calendar-id account)
                          (expand-file-name rjd/gcal-file))))
        (setq rjd/gcal--last-fetch (current-time))
        (condition-case err
            (org-gcal-fetch)
          (error (message "rjd-gcal: fetching the calendar failed: %s"
                          (error-message-string err)))))
    (when (called-interactively-p 'any)
      (user-error (if rjd/gcal-account
                      "No calendar: mail cannot run on this machine"
                    "No calendar: `rjd/gcal-account' is not set")))))

(defun rjd/gcal--fetch-on-agenda ()
  "Make sure the calendar file exists, and fetch unless one just ran.
On `org-agenda-mode-hook', which runs before the agenda reads its files."
  (rjd/gcal--ensure-file)
  (unless (and rjd/gcal--last-fetch
               (< (float-time (time-since rjd/gcal--last-fetch))
                  rjd/gcal--agenda-quiet-period))
    (rjd/gcal-fetch)))


;;; The mode

;;;###autoload
(define-minor-mode rjd/gcal-mode
  "Fetch Google Calendar into org-agenda, read-only, with tokens from oama.
The calendar of `rjd/gcal-active-account' is fetched into
`rjd/gcal-file' when the agenda opens, and every
`rjd/gcal-fetch-interval' seconds -- the timer only if there is an
active account when the mode is turned on.  org-gcal
asks for its token through `oauth2-auto-access-token', which this
advises to answer from oama -- see the commentary of rjd-gcal.el."
  :global t
  :group 'rjd/gcal
  (dolist (timer (list rjd/gcal--timer rjd/gcal--settle-timer))
    (when (timerp timer)
      (cancel-timer timer)))
  (setq rjd/gcal--timer nil
        rjd/gcal--settle-timer nil)
  (if rjd/gcal-mode
      (progn
        (advice-add 'oauth2-auto-access-token :around #'rjd/gcal--access-token)
        (add-hook 'org-agenda-mode-hook #'rjd/gcal--fetch-on-agenda)
        (add-hook 'org-gcal-after-update-entry-functions
                  #'rjd/gcal--event-updated)
        (when (and rjd/gcal-fetch-interval (rjd/gcal-active-account))
          (setq rjd/gcal--timer
                (run-at-time rjd/gcal-fetch-interval rjd/gcal-fetch-interval
                             #'rjd/gcal-fetch))))
    (advice-remove 'oauth2-auto-access-token #'rjd/gcal--access-token)
    (remove-hook 'org-agenda-mode-hook #'rjd/gcal--fetch-on-agenda)
    (remove-hook 'org-gcal-after-update-entry-functions
                 #'rjd/gcal--event-updated)))

(provide 'rjd-gcal)

;;; rjd-gcal.el ends here
