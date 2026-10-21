;;; rjd-caldav.el --- CalDAV calendars in org-agenda, read-only  -*- lexical-binding: t; -*-

;;; Commentary:

;; Fetches calendars from the CalDAV accounts in `rjd/caldav-accounts'
;; -- iCloud and Fastmail -- into one calendar file each, in
;; `rjd/caldav-directory', and never writes back: every request is a
;; PROPFIND or a REPORT.  No server can enforce that -- iCloud's
;; app-specific password opens every calendar and the contacts, read
;; and write, and Fastmail's is the one org-pa uploads with -- so
;; read-only rests on this file.
;; docs/adr/0002-icloud-calendars-caldav-fetch.md has the reasons, and
;; docs/adr/0003-caldav-accounts.md how they became one fetcher for
;; several accounts.
;;
;; An account is a plist; see `rjd/caldav-accounts'.  Its name prefixes
;; its calendar files, and its password is looked up under its server's
;; host.  Its failures are reported by account: each account's run of
;; failing fetches is reported once, naming it, whatever the others do.
;; Nothing else is kept per account: the timer and the state of a fetch
;; are shared, and a fetch takes every account together.  Two
;; calendars whose files would share a name, in one account or across
;; two, are both refused.
;;
;; A fetch discovers each account's calendars afresh (the principal,
;; then its calendar home, then the calendars in it), matches the
;; configured display names, and asks the server for each calendar's
;; events over a window around today with recurrences expanded by the
;; server, so every occurrence arrives as its own VEVENT, moved and
;; cancelled occurrences already applied.  Each calendar file is then
;; rewritten whole, but only after its calendar's fetch succeeded: a
;; failure keeps the last good file.  Accounts are fetched side by
;; side, and one failing does not stop another.
;;
;; iCloud's expanded events depart from the standards in ways this
;; relies on handling, all recorded by test/caldav-probe.sh:
;;
;; - Times are not converted to UTC, as RFC 4791 asks, but keep the
;;   event's TZID -- with no VTIMEZONE to define it.  The parser takes
;;   such a time as floating, so the TZID is read here and looked up in
;;   the system's time-zone database; see `rjd/caldav--absolute'.
;; - The calendar data has no VERSION or PRODID, and DTSTAMP twice,
;;   which Emacs 31's parser accepts.
;;
;; Fastmail's keep to them: discovery starts at its /dav/ root, its
;; times are in UTC, and the display names it sends as CDATA read as
;; plain text.  The vendor property it adds, X-JMAP-USEDEFAULTALERTS,
;; is ignored.
;;
;; Emacs 31's `icalendar-parser' parses the events; its recurrence code,
;; `icalendar-recur', is deliberately not used, since the servers expand
;; recurrences and that code mishandles COUNT, UTC EXDATEs and
;; RECURRENCE-ID.  If a server stopped expanding, a calendar would show
;; each recurring event once, on its first date.
;;
;; An event may give its length as DURATION rather than its end as
;; DTEND, as Fastmail does for every event and iCloud for some
;; invitations; its end is then worked out here, see
;; `rjd/caldav--end'.
;;
;; An event is left out if cancelled, or declined by the account's
;; user or by any address its :addresses regexp matches, so that a
;; decline made in Fastmail's own calendar, to an alias, takes effect.
;;
;; Each password is from auth-source, under the host of the account's
;; server and the account's user: `caldav.icloud.com' for iCloud, and
;; `caldav.fastmail.com' for Fastmail, the entry org-pa's upload reads.
;; Only a fetch begun by opening the agenda, or by hand, may prompt for
;; one: a timer's fetch leaves encrypted sources out, and skips an
;; account with no password to hand.
;;
;; A calendar fed from org is never fetched, whatever its name: its
;; events would be copies of org's own.  The fetcher knows one by its
;; URL, read from the variables in `rjd/caldav-fed-from-org' --
;; org-pa's `org-pa-caldav-url' -- and compared by decoded path, so the
;; host's form and an encoded @ do not matter.  org-pa loads lazily, so
;; until it has, the URL is the value use-package's `:custom' saved on
;; the symbol, its `saved-value' property; a form that sets it under
;; `:after' saves nothing until then, and so guards nothing until then.
;; This depends on use-package: if it stopped saving `:custom' values
;; that way, org-pa's calendar would be fetched until org-pa loaded,
;; and its events would show twice.  If they ever do, `saved-value' on
;; `org-pa-caldav-url' is the first place to look; see
;; `rjd/caldav--fed-from-org-urls'.
;;
;; Nothing is fetched inside a container, so no agent's Emacs holds a
;; password; `rjd/caldav-enabled' overrides that.
;;
;; Enable with `rjd/caldav-mode'.  Turning it off is the way round a bad
;; upgrade.

;;; Code:

(require 'auth-source)
(require 'dom)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'warnings)
(require 'icalendar-parser)
(require 'icalendar-utils)
(eval-when-compile (require 'icalendar-macs))

(declare-function org-agenda-redo "org-agenda")
(defvar org-agenda-mode-hook)
(defvar url-http-end-of-headers)
(defvar url-http-response-status)


;;; Customization

(defgroup rjd/caldav nil
  "CalDAV calendars in org-agenda, read-only."
  :group 'org)

(defcustom rjd/caldav-accounts nil
  "The CalDAV accounts whose calendars are fetched.
Each is a plist:

  :name       the account's name, such as \"icloud\", which begins
              each of its calendar files' names; see
              `rjd/caldav-file-name'.
  :server     the URL where discovery starts, such as
              \"https://caldav.icloud.com/\", or Fastmail's
              \"https://caldav.fastmail.com/dav/\".
  :user       the account's user name, usually its address.  Its
              password is looked up in auth-source under this user and
              the host of :server.
  :calendars  the display names of the calendars to fetch, as the
              server has them; \\[rjd/caldav-list-calendars] lists an
              account's.  The display name is also the category that
              labels the calendar's entries in the agenda, unless the
              calendar is given as (NAME . CATEGORY): a name wider than
              the agenda's category column pushes the rest of the line
              over.
  :addresses  optionally, a regexp matching, whole and regardless of
              case, the account's other addresses -- plus, subdomain
              and catch-all aliases -- as `rjd/mail-accounts' has
              them.  An event declined by an attendee at :user, or at
              an address this matches, is left out.

An account without a :user or :calendars is not fetched.  Calendars
whose files would share a name, in one account or across two, are all
refused.  A calendar fed from org must not be named either: its events
would come back into the agenda as copies of org's own.  org-pa's is
refused even if named, see `rjd/caldav-fed-from-org'; one fed
otherwise, such as by beorg, is not known to be."
  :type '(repeat
          (plist :tag "Account"
                 :options
                 ((:name string)
                  (:server string)
                  (:user string)
                  (:calendars
                   (repeat (choice (string :tag "Display name")
                                   (cons :tag "Display name and category"
                                         (string :tag "Display name")
                                         (string :tag "Category")))))
                  (:addresses regexp))))
  :group 'rjd/caldav)

(defcustom rjd/caldav-directory "~/org-agenda/calendars/"
  "The directory each calendar file is written into.
The agenda should list the directory; see `rjd/calendar-directory' in
init.el."
  :type 'directory
  :group 'rjd/caldav)

(defcustom rjd/caldav-fetch-interval 900
  "Seconds between fetches while Emacs runs, or nil for none.
Opening the agenda fetches too.  Takes effect when `rjd/caldav-mode'
is next turned on."
  :type '(choice (const :tag "Only when the agenda opens" nil) natnum)
  :group 'rjd/caldav)

(defcustom rjd/caldav-days-back 30
  "Days before today from which events are fetched."
  :type 'natnum
  :group 'rjd/caldav)

(defcustom rjd/caldav-days-ahead 365
  "Days after today up to which events are fetched."
  :type 'natnum
  :group 'rjd/caldav)

(defcustom rjd/caldav-enabled 'auto
  "Whether calendars are fetched on this machine.
`auto' fetches unless Emacs runs in a container; t and nil force it."
  :type '(choice (const :tag "Unless in a container" auto)
                 (const :tag "Always" t)
                 (const :tag "Never" nil))
  :group 'rjd/caldav)

(defvar rjd/caldav-container-marker-files '("/.dockerenv" "/run/.containerenv")
  "Files whose presence says Emacs itself runs in a container.
Docker's and podman's, as `rjd/container-git' in init.el checks.")

(defvar rjd/caldav-fed-from-org '(org-pa-caldav-url)
  "Variables holding the URL of a calendar fed from org, never fetched.
Such a calendar's events are copies of org's own, so fetching it would
show them twice; it is refused even if `rjd/caldav-accounts' names it.
Each is read from the variable once its package has loaded, and
before that from the value Custom saved for it, as use-package's
`:custom' does at once for a deferred package.  The URLs are compared
by their decoded paths.")

(defvar rjd/caldav-request-function #'rjd/caldav--url-request
  "The function that makes a CalDAV request.
Called with METHOD, URL, DEPTH, BODY, AUTHORIZATION and CALLBACK; it
calls CALLBACK with an error and nil, or nil and the response's parsed
XML.  The error is a message, or `unauthorized' if the server refused
the password: the request knows no account, so cannot say whose.
Tests replace it.")


;;; State

(defvar rjd/caldav--timer nil
  "The timer that fetches every `rjd/caldav-fetch-interval' seconds.")

(defvar rjd/caldav--fetching nil
  "Non-nil while a fetch runs, so that another does not start.
A fetch takes every account together, so this is not per account.")

(defvar rjd/caldav--failing nil
  "The accounts whose failing has been reported, by name.
An account's failure is reported only when its name is not here, so a
run of its failing timer fetches says so once, whatever the other
accounts do; its next success takes it off.  Calendars refused for
sharing a file are no one account's, and are kept here as nil.")

(defvar rjd/caldav--last-fetch nil
  "When the last fetch began, or nil.")

(defconst rjd/caldav--agenda-quiet-period 120
  "Seconds after a fetch during which opening the agenda fetches no more.
A finished fetch redoes the agenda, which runs `org-agenda-mode-hook'
again, so without this each fetch would set off the next.")


;;; Where it runs

(defun rjd/caldav--accounts (&optional without-calendars)
  "The accounts in `rjd/caldav-accounts' that have calendars to fetch.
That is, those with a :name, a :server, a :user and :calendars; or,
if WITHOUT-CALENDARS, those with the first three, whether or not
they name any calendar."
  (seq-filter (lambda (account)
                (and (plist-get account :name)
                     (plist-get account :server)
                     (plist-get account :user)
                     (or without-calendars (plist-get account :calendars))))
              rjd/caldav-accounts))

(defun rjd/caldav--account-host (account)
  "The host of ACCOUNT's server, under which its password is filed."
  (url-host (url-generic-parse-url (plist-get account :server))))

(defun rjd/caldav-active-p ()
  "Non-nil if calendars are to be fetched on this machine.
That needs an account in `rjd/caldav-accounts' with calendars, and
Emacs outside a container unless `rjd/caldav-enabled' says otherwise."
  (and (rjd/caldav--accounts)
       (if (eq rjd/caldav-enabled 'auto)
           (not (seq-some #'file-exists-p rjd/caldav-container-marker-files))
         rjd/caldav-enabled)
       t))


;;; Files

(defun rjd/caldav--names (account)
  "The display names of ACCOUNT's calendars; see `rjd/caldav-accounts'."
  (mapcar (lambda (calendar) (if (consp calendar) (car calendar) calendar))
          (plist-get account :calendars)))

(defun rjd/caldav--category (account name)
  "The category of ACCOUNT's calendar called NAME; see `rjd/caldav-accounts'."
  (or (cdr (assoc name (seq-filter #'consp (plist-get account :calendars))))
      name))

(defun rjd/caldav-file-name (account-name name)
  "The name of the calendar file for the calendar called NAME.
ACCOUNT-NAME-SLUG.org, ACCOUNT-NAME being its account's :name, such as
icloud-home.org; SLUG is NAME in lower case, without apostrophes,
and with every other run of characters but letters and digits made
one hyphen.  Letters and digits are told by their Unicode category, not
`[:alnum:]', which counts such marks as the variation selector after an
emoji."
  (let* ((slug (mapconcat
                (lambda (char)
                  (if (memq (get-char-code-property char 'general-category)
                            '(Lu Ll Lt Lm Lo Nd Nl No))
                      (string char)
                    "-"))
                (downcase (replace-regexp-in-string "['’]" "" name))
                ""))
         (slug (replace-regexp-in-string "-+" "-" slug))
         (slug (string-trim slug "-" "-")))
    (format "%s-%s.org" account-name
            (if (string-empty-p slug) "calendar" slug))))

(defun rjd/caldav--file (account name)
  "The name of the calendar file of ACCOUNT's calendar called NAME.
See `rjd/caldav-file-name'."
  (rjd/caldav-file-name (plist-get account :name) name))

(defun rjd/caldav--write (account name text)
  "Make TEXT the calendar file of ACCOUNT's calendar called NAME.
Written beside it and renamed over it, so the agenda never reads half
a file; the temporary name does not end in .org, so the agenda never
lists it.  A buffer visiting the file is reverted, discarding any edit:
the file is the calendar's."
  (let* ((file (expand-file-name (rjd/caldav--file account name)
                                 rjd/caldav-directory))
         (temp (concat file ".part"))
         (coding-system-for-write 'utf-8-unix))
    (write-region text nil temp nil 'silent)
    (rename-file temp file t)
    (when-let* ((buffer (find-buffer-visiting file)))
      (with-current-buffer buffer
        (revert-buffer :ignore-auto :noconfirm :preserve-modes)))))

(defun rjd/caldav--file-contents (account name events)
  "The text of the calendar file of ACCOUNT's calendar NAME, holding EVENTS."
  (concat (format "#+CATEGORY: %s\n" (rjd/caldav--category account name))
          (format-time-string "#+FETCHED: [%F %a %H:%M]\n")
          (format "# Fetched from %s by rjd-caldav, and rewritten whole by every\n"
                  (plist-get account :name))
          "# fetch: anything written here is lost.\n\n"
          (mapconcat #'rjd/caldav--org-entry events "")))


;;; Events

(defun rjd/caldav--known-zone-p (tzid)
  "Non-nil if TZID names a zone in the system's time-zone database.
A name it lacks, such as Exchange's \"Pacific Standard Time\", would be
taken by `encode-time' as UTC, silently."
  (and (string-match-p "\\`[[:alnum:]_+-]+\\(?:/[[:alnum:]_+-]+\\)*\\'" tzid)
       (file-exists-p (expand-file-name
                       tzid (or (getenv "TZDIR") "/usr/share/zoneinfo")))))

(defun rjd/caldav--absolute (time tzid)
  "TIME, a decoded date-time from the parser, as seconds since the epoch.
A TIME with an offset, from a VTIMEZONE, or in UTC, is used as it is.
One without -- floating to the parser -- is in TZID if the system knows
that zone, as it does iCloud's; otherwise it is taken as local time."
  (let ((zone (decoded-time-zone time)))
    (float-time
     (encode-time
      (append (seq-take time 6)
              (list nil -1
                    (cond ((or (integerp zone) (eq zone t)) zone)
                          ((and tzid (rjd/caldav--known-zone-p tzid)) tzid))))))))

(defun rjd/caldav--time (vevent property)
  "VEVENT's PROPERTY, `icalendar-dtstart' or `icalendar-dtend', or nil.
A date is (MONTH DAY YEAR), as the parser gives it; a date-time is
seconds since the epoch, see `rjd/caldav--absolute'."
  (when-let* ((node (icalendar-ast-node-first-child-of property vevent))
              (value (icalendar-ast-node-value
                      (icalendar-ast-node-value node))))
    (if (= (length value) 3)
        value
      (rjd/caldav--absolute value (icalendar-property-tzid node)))))

(defun rjd/caldav--end (vevent start)
  "The end of VEVENT, which starts at START, or nil if it gives none.
It is VEVENT's `icalendar-dtend', or else START plus its
`icalendar-duration'; see `rjd/caldav--time'.  A duration's days and
weeks are calendar days in the local zone, so a day across a change of
the clocks still ends at the time of day it began; its hours, minutes
and seconds are exact.  From a date, the end is the date the days and
weeks give, exclusive as a DTEND's is."
  (or (rjd/caldav--time vevent 'icalendar-dtend)
      (when-let* ((node (icalendar-ast-node-first-child-of
                         'icalendar-duration vevent))
                  (duration (icalendar-ast-node-value
                             (icalendar-ast-node-value node))))
        (let ((days (if (integerp duration)
                        (* 7 duration)
                      (or (decoded-time-day duration) 0)))
              (seconds (if (integerp duration)
                           0
                         (+ (* 3600 (or (decoded-time-hour duration) 0))
                            (* 60 (or (decoded-time-minute duration) 0))
                            (or (decoded-time-second duration) 0)))))
          (if (numberp start)
              (let ((local (decode-time start)))
                (setf (decoded-time-day local) (+ (decoded-time-day local) days)
                      (decoded-time-dst local) -1
                      (decoded-time-zone local) nil)
                (+ (float-time (encode-time local)) seconds))
            (let ((end (decode-time (rjd/caldav--date-time start days))))
              (list (decoded-time-month end) (decoded-time-day end)
                    (decoded-time-year end))))))))

(defun rjd/caldav--account-address-p (account address)
  "Non-nil if ADDRESS, a bare address, is ACCOUNT's.
That is its :user, or any whole address its :addresses regexp matches;
either way regardless of case, as `rjd/mail--address-p' has it."
  (and address
       (or (string-equal-ignore-case address (plist-get account :user))
           (when-let* ((regexp (plist-get account :addresses)))
             (let ((case-fold-search t))
               (string-match-p (concat "\\`\\(?:" regexp "\\)\\'")
                               address))))))

(defun rjd/caldav--declined-p (vevent account)
  "Non-nil if one of ACCOUNT's addresses has declined VEVENT.
See `rjd/caldav--account-address-p'."
  (seq-some (lambda (attendee)
              (and (equal (icalendar-with-param-of attendee
                              'icalendar-partstatparam)
                          "DECLINED")
                   (rjd/caldav--account-address-p
                    account
                    (icalendar-strip-mailto
                     (icalendar-ast-node-value
                      (icalendar-ast-node-value attendee))))))
            (icalendar-ast-node-children-of 'icalendar-attendee vevent)))

(defun rjd/caldav--event (vevent account)
  "VEVENT as a plist, or nil if it is not to be shown.
Cancelled events are not, nor those ACCOUNT has declined, nor any
without a start.  The plist has :summary, :start and :end, see
`rjd/caldav--time', :location and :description."
  (let ((start (rjd/caldav--time vevent 'icalendar-dtstart)))
    (unless (or (null start)
                (equal (icalendar-with-property-of vevent 'icalendar-status)
                       "CANCELLED")
                (rjd/caldav--declined-p vevent account))
      (list :summary (icalendar-component-summary vevent)
            :start start
            :end (rjd/caldav--end vevent start)
            :location (icalendar-with-property-of vevent 'icalendar-location)
            :description (icalendar-component-description vevent)))))

(defun rjd/caldav--calendar-events (text account)
  "The events in TEXT, an iCalendar object, as plists; see `rjd/caldav--event'.
ACCOUNT's declined events are left out.
Lines are unfolded here, in place: given folded lines the parser
unfolds them into a buffer of its own, and never kills it.  Its
warnings about data it cannot parse are kept quiet, since a fetch runs
from a timer; such data yields no events."
  (with-temp-buffer
    (insert (string-replace "\r" "" text))
    (icalendar-unfold-region (point-min) (point-max))
    (goto-char (point-min))
    (when-let* ((calendar (let ((warning-minimum-level :emergency)
                                (warning-minimum-log-level :emergency))
                            (icalendar-parse))))
      (delq nil (mapcar (lambda (vevent) (rjd/caldav--event vevent account))
                        (icalendar-ast-node-children-of 'icalendar-vevent
                                                        calendar))))))

(defun rjd/caldav--sort-key (event)
  "Seconds since the epoch at which EVENT starts, a date at local midnight."
  (let ((start (plist-get event :start)))
    (if (numberp start)
        start
      (float-time (rjd/caldav--date-time start 0)))))

(defun rjd/caldav--events (dom account)
  "The events in DOM, a REPORT response, as plists in order of start.
Events ACCOUNT has declined are left out; see `rjd/caldav--event'."
  (sort (mapcan (lambda (data)
                  (rjd/caldav--calendar-events (dom-inner-text data) account))
                (dom-by-tag dom 'calendar-data))
        :key #'rjd/caldav--sort-key))


;;; Org entries

(defun rjd/caldav--date-time (date &optional days)
  "Local noon on DATE, (MONTH DAY YEAR), DAYS later, as a Lisp time.
Noon, so a day's length changing with summer time cannot move it to
another date."
  (pcase-let ((`(,month ,day ,year) date))
    (encode-time (list 0 0 12 (+ day (or days 0)) month year nil -1 nil))))

(defun rjd/caldav--timestamp (start end)
  "The org timestamp of an event from START to END; see `rjd/caldav--time'.
END is exclusive for a date, as iCalendar has it, and may be nil."
  (if (numberp start)
      (let ((day (format-time-string "%F %a" start))
            (from (format-time-string "%H:%M" start)))
        (cond ((or (not (numberp end)) (<= end start))
               (format "<%s %s>" day from))
              ((equal day (format-time-string "%F %a" end))
               (format "<%s %s-%s>" day from (format-time-string "%H:%M" end)))
              (t
               (format "<%s %s>--<%s>" day from
                       (format-time-string "%F %a %H:%M" end)))))
    (let ((first (rjd/caldav--date-time start))
          (last (and (consp end) (rjd/caldav--date-time end -1))))
      (if (and last (time-less-p first last))
          (format "<%s>--<%s>" (format-time-string "%F %a" first)
                  (format-time-string "%F %a" last))
        (format "<%s>" (format-time-string "%F %a" first))))))

(defun rjd/caldav--org-entry (event)
  "EVENT, a plist from `rjd/caldav--event', as an org entry.
The summary is made one line, so it stays one heading; the description
is indented, so no line of it can start a heading of its own."
  (let ((summary (string-clean-whitespace (or (plist-get event :summary) "")))
        (location (plist-get event :location))
        (description (plist-get event :description)))
    (concat "* " (if (string-empty-p summary) "(no title)" summary) "\n"
            (when (and location (not (string-blank-p location)))
              (format ":PROPERTIES:\n:LOCATION: %s\n:END:\n"
                      (string-clean-whitespace location)))
            (rjd/caldav--timestamp (plist-get event :start)
                                   (plist-get event :end))
            "\n"
            (when (and description (not (string-blank-p description)))
              (concat (mapconcat (lambda (line)
                                   (if (string-blank-p line) "" (concat "  " line)))
                                 (split-string (string-trim-right description)
                                               "\n")
                                 "\n")
                      "\n")))))


;;; Requests

(defun rjd/caldav--quiet-auth-sources ()
  "`auth-sources' without the encrypted files, which may ask for a passphrase."
  (seq-remove (lambda (source)
                (let ((file (cond ((stringp source) source)
                                  ((consp source) (plist-get source :source)))))
                  (and (stringp file) (string-suffix-p ".gpg" file))))
              auth-sources))

(defun rjd/caldav--password (account &optional may-prompt)
  "ACCOUNT's password, or nil.
It is filed in auth-source under the host of the account's server and
its user.  Unless MAY-PROMPT, encrypted sources are not read, so
nothing can ask for a passphrase; a password auth-source already
remembers is still found."
  (let ((auth-sources (if may-prompt
                          auth-sources
                        (rjd/caldav--quiet-auth-sources))))
    (auth-source-pick-first-password :host (rjd/caldav--account-host account)
                                     :user (plist-get account :user))))

(defun rjd/caldav--no-password (account)
  "The message for ACCOUNT having no password in auth-source."
  (format "no password for %s at %s in auth-source"
          (plist-get account :user) (rjd/caldav--account-host account)))

(defun rjd/caldav--authorization (account password)
  "The Basic Authorization header value for ACCOUNT and its PASSWORD."
  (concat "Basic "
          (base64-encode-string
           (encode-coding-string (concat (plist-get account :user) ":" password)
                                 'utf-8)
           t)))

(defun rjd/caldav--url-request (method url depth body authorization callback)
  "Make a CalDAV request with url.el, in the background.
See `rjd/caldav-request-function' for METHOD, URL, DEPTH, BODY,
AUTHORIZATION and CALLBACK.  url.el is kept from prompting: the
credentials go in the header, and a refusal is an error like any other."
  (let ((url-request-method method)
        (url-request-extra-headers
         `(("Depth" . ,depth)
           ("Content-Type" . "application/xml; charset=utf-8")
           ("Authorization" . ,authorization)))
        (url-request-data (encode-coding-string body 'utf-8))
        (url-request-noninteractive t))
    (condition-case err
        (url-retrieve url
                      (lambda (status)
                        (rjd/caldav--url-response status method url callback))
                      nil t t)
      (error (funcall callback
                      (format "%s %s: %s" method url (error-message-string err))
                      nil)))))

(defun rjd/caldav--url-response (status method url callback)
  "Hand the response in the current buffer to CALLBACK, and kill it.
STATUS is url.el's; METHOD and URL are the request's.  Anything but a
207 Multi-Status is an error.  A 401 is told apart, since it is the
password: auth-source keeps one it has found, so a corrected password
is not read until its cache is cleared, which the fetch says, naming
the account; here it is just `unauthorized'."
  (let ((buffer (current-buffer))
        err dom)
    (unwind-protect
        (progn
          (setq err (cond ((eql url-http-response-status 401)
                           'unauthorized)
                          ((plist-get status :error)
                           (format "%s %s: %S" method url
                                   (plist-get status :error)))
                          ((not (eql url-http-response-status 207))
                           (format "%s %s: HTTP %s" method url
                                   url-http-response-status))))
          (unless err
            ;; `url-http-end-of-headers' is the end of the last header
            ;; line, before the blank line; anything before an XML
            ;; declaration, even that newline, makes libxml reject it.
            (let ((text (decode-coding-string
                         (buffer-substring-no-properties
                          (save-excursion
                            (goto-char url-http-end-of-headers)
                            (skip-chars-forward "\r\n")
                            (point))
                          (point-max))
                         'utf-8)))
              (setq dom (with-temp-buffer
                          (insert text)
                          (libxml-parse-xml-region (point-min) (point-max))))
              (unless dom
                (setq err (format "%s %s: unreadable response, beginning %S"
                                  method url
                                  (truncate-string-to-width text 60 nil nil "…")))))))
      (kill-buffer buffer))
    (funcall callback err dom)))

(defun rjd/caldav--refused (account)
  "The message for ACCOUNT's server refusing its password."
  (format "the server refused the password for %s; check it at %s in \
auth-source, and after changing it run `auth-source-forget-all-cached'"
          (plist-get account :user) (rjd/caldav--account-host account)))

(defun rjd/caldav--request (account authorization method url depth body
                                    on-success callback)
  "Make a request for ACCOUNT, and call ON-SUCCESS with its parsed response.
A failed request calls CALLBACK with its error message and nil instead.
See `rjd/caldav-request-function' for AUTHORIZATION, METHOD, URL, DEPTH
and BODY."
  (funcall rjd/caldav-request-function method url depth body authorization
           (lambda (err dom)
             (cond ((eq err 'unauthorized)
                    (funcall callback (rjd/caldav--refused account) nil))
                   (err (funcall callback err nil))
                   (t (funcall on-success dom))))))


;;; Discovery

(defconst rjd/caldav--principal-body
  "<d:propfind xmlns:d=\"DAV:\"><d:prop><d:current-user-principal/></d:prop></d:propfind>"
  "Asks for the account's principal.")

(defconst rjd/caldav--home-set-body
  "<d:propfind xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\"><d:prop><c:calendar-home-set/></d:prop></d:propfind>"
  "Asks a principal for its calendar home.")

(defconst rjd/caldav--calendars-body
  "<d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/></d:prop></d:propfind>"
  "Asks a calendar home for its collections' names and types.")

(defun rjd/caldav--href-in (dom tag base)
  "The URL in the first href inside DOM's first TAG, resolved against BASE.
Or nil.  iCloud sends some absolute, some relative; and the host of a
relative one is sometimes caldav.icloud.com, sometimes the account's
own, so each is resolved against the URL its response came from."
  (when-let* ((node (car (dom-by-tag dom tag)))
              (href (car (dom-by-tag node 'href))))
    (url-expand-file-name (string-trim (dom-inner-text href)) base)))

(defun rjd/caldav--calendars-in (dom base)
  "The calendars in DOM, a calendar home's PROPFIND response from BASE.
An alist of (NAME . URL).  A collection is a calendar if its resource
type says so: the home itself, and its inbox, outbox and notifications,
are not."
  (let (calendars)
    (dolist (response (dom-by-tag dom 'response))
      (when (dom-by-tag (car (dom-by-tag response 'resourcetype)) 'calendar)
        (let ((name (dom-inner-text (car (dom-by-tag response 'displayname))))
              (href (dom-inner-text (car (dom-by-tag response 'href)))))
          (push (cons (string-trim name)
                      (url-expand-file-name (string-trim href) base))
                calendars))))
    (nreverse calendars)))

(defun rjd/caldav--discover (account authorization callback)
  "Find ACCOUNT's calendars, and call CALLBACK with them.
CALLBACK gets nil and an alist of (NAME . URL), or an error and nil.
AUTHORIZATION is the header value to send."
  (let ((fail (lambda (what) (funcall callback (concat "no " what) nil)))
        (server (plist-get account :server)))
    (rjd/caldav--request
     account authorization
     "PROPFIND" server "0" rjd/caldav--principal-body
     (lambda (dom)
       (if-let* ((principal (rjd/caldav--href-in dom 'current-user-principal
                                                 server)))
           (rjd/caldav--request
            account authorization
            "PROPFIND" principal "0" rjd/caldav--home-set-body
            (lambda (dom)
              (if-let* ((home (rjd/caldav--href-in dom 'calendar-home-set
                                                   principal)))
                  (rjd/caldav--request
                   account authorization
                   "PROPFIND" home "1" rjd/caldav--calendars-body
                   (lambda (dom)
                     (funcall callback nil (rjd/caldav--calendars-in dom home)))
                   callback)
                (funcall fail "calendar home")))
            callback)
         (funcall fail "principal")))
     callback)))


;;; Fetching

(defun rjd/caldav--report-body ()
  "Asks a calendar for its events in the window, recurrences expanded."
  (let ((start (format-time-string
                "%Y%m%dT000000Z"
                (time-subtract nil (days-to-time rjd/caldav-days-back)) t))
        (end (format-time-string
              "%Y%m%dT000000Z"
              (time-add nil (days-to-time rjd/caldav-days-ahead)) t)))
    (format "<c:calendar-query xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\">\
<d:prop><c:calendar-data><c:expand start=\"%s\" end=\"%s\"/></c:calendar-data></d:prop>\
<c:filter><c:comp-filter name=\"VCALENDAR\"><c:comp-filter name=\"VEVENT\">\
<c:time-range start=\"%s\" end=\"%s\"/></c:comp-filter></c:comp-filter></c:filter>\
</c:calendar-query>"
            start end start end)))

(defun rjd/caldav--fed-from-org-urls ()
  "The URLs of the calendars fed from org, from `rjd/caldav-fed-from-org'.
A variable not yet defined, its package not yet loaded, is read from
the value Custom has saved for it, as use-package's `:custom' does at
once for a deferred package; a value that cannot be had is no URL."
  (seq-filter #'stringp
              (mapcar (lambda (variable)
                        (cond ((boundp variable) (symbol-value variable))
                              ((get variable 'saved-value)
                               (ignore-errors
                                 (eval (car (get variable 'saved-value)) t)))))
                      rjd/caldav-fed-from-org)))

(defun rjd/caldav--path (url)
  "URL's path, decoded and ending in a slash, to compare calendars by."
  (file-name-as-directory
   (decode-coding-string
    (url-unhex-string (car (url-path-and-query (url-generic-parse-url url))))
    'utf-8)))

(defun rjd/caldav--fed-from-org-p (url)
  "Non-nil if the calendar at URL is fed from org; see `rjd/caldav-fed-from-org'."
  (member (rjd/caldav--path url)
          (mapcar #'rjd/caldav--path (rjd/caldav--fed-from-org-urls))))

(defun rjd/caldav--collisions (accounts)
  "The calendar files ACCOUNTS' calendars would share, and why.
Returns (FILES . ERRORS): FILES the names of the files two or more
calendars would be written to, within an account or across accounts,
and ERRORS a message for each.  Every calendar of such a file is
refused, so that none overwrites another's."
  (let ((groups (seq-group-by
                 #'car
                 (mapcan (lambda (account)
                           (let ((account-name (plist-get account :name)))
                             (mapcar (lambda (name)
                                       (list (rjd/caldav-file-name account-name
                                                                   name)
                                             account-name name))
                                     (rjd/caldav--names account))))
                         accounts)))
        files errors)
    (pcase-dolist (`(,file . ,calendars) groups)
      (when (cdr calendars)
        (push file files)
        (push (format "%s would all be %s"
                      (mapconcat (pcase-lambda (`(,_ ,account-name ,name))
                                   (format "%s in %s" name account-name))
                                 calendars ", ")
                      file)
              errors)))
    (cons (nreverse files) (nreverse errors))))

(defun rjd/caldav--wanted (account calendars refused)
  "ACCOUNT's calendars found in CALENDARS, and what is wrong with the rest.
CALENDARS is discovery's alist.  Returns (WANTED . ERRORS), WANTED an
alist of (NAME . URL).  A name no calendar has is an error, and so is a
calendar fed from org, which is refused whatever its name.  A name
whose file is in REFUSED, see `rjd/caldav--collisions', is left out
silently, since the collision is reported once for every account."
  (let (wanted errors)
    (dolist (name (rjd/caldav--names account))
      (let ((calendar (assoc name calendars)))
        (cond ((member (rjd/caldav--file account name) refused))
              ((and calendar (rjd/caldav--fed-from-org-p (cdr calendar)))
               (push (format "%s is fed from org, so is never fetched" name)
                     errors))
              (calendar
               (push calendar wanted))
              (t
               (push (format "no calendar is called %s" name) errors)))))
    (cons (nreverse wanted) (nreverse errors))))

(defun rjd/caldav--redo-agendas ()
  "Redo every agenda buffer, so it shows what was fetched."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'org-agenda-mode)
        (org-agenda-redo t)))))

(defun rjd/caldav--finish (results)
  "End a fetch whose RESULTS are an alist of (ACCOUNT-NAME . ERRORS).
ERRORS are messages, nil for an account that succeeded; the
ACCOUNT-NAME of the collisions is nil.  Each account's errors are
reported only at the start of its own run of failing fetches; see
`rjd/caldav--failing'."
  (setq rjd/caldav--fetching nil)
  (let (new)
    (pcase-dolist (`(,account-name . ,errors) results)
      (cond ((not errors)
             (setq rjd/caldav--failing
                   (delete account-name rjd/caldav--failing)))
            ((not (member account-name rjd/caldav--failing))
             (push account-name rjd/caldav--failing)
             (setq new (append new errors)))))
    (when new
      (message "rjd-caldav: fetching failed: %s" (string-join new "; "))))
  (rjd/caldav--redo-agendas))

(defun rjd/caldav--fetch-calendars (account calendars refused authorization
                                            done)
  "Fetch each of ACCOUNT's wanted calendars of CALENDARS into its file.
CALENDARS is discovery's alist; REFUSED the files no calendar may be
written to, see `rjd/caldav--wanted'; AUTHORIZATION the header value.
DONE is called once every calendar is, with a list of error messages."
  (pcase-let* ((`(,wanted . ,errors)
                (rjd/caldav--wanted account calendars refused))
               (pending (length wanted)))
    (if (null wanted)
        (funcall done errors)
      (pcase-dolist (`(,name . ,url) wanted)
        (let ((finished (lambda (err)
                          (when err (push (format "%s: %s" name err) errors))
                          (when (zerop (setq pending (1- pending)))
                            (funcall done (reverse errors))))))
          (rjd/caldav--request
           account authorization
           "REPORT" url "1" (rjd/caldav--report-body)
           (lambda (dom)
             (funcall finished
                      (condition-case err
                          (progn
                            (rjd/caldav--write
                             account name
                             (rjd/caldav--file-contents
                              account name
                              (rjd/caldav--events dom account)))
                            nil)
                        (error (error-message-string err)))))
           (lambda (err _) (funcall finished err))))))))

(defun rjd/caldav--fetch-account (account refused authorization done)
  "Fetch ACCOUNT's calendars but those whose files are REFUSED.
AUTHORIZATION is sent with each request.  DONE is called once they are
all fetched, with a list of error messages, each naming the account."
  (let ((named (lambda (errors)
                 (funcall done
                          (mapcar (lambda (err)
                                    (format "%s: %s" (plist-get account :name) err))
                                  errors)))))
    (rjd/caldav--discover
     account authorization
     (lambda (err calendars)
       (if err
           (funcall named (list err))
         (rjd/caldav--fetch-calendars account calendars refused
                                      authorization named))))))

;;;###autoload
(defun rjd/caldav-fetch (&optional may-prompt)
  "Fetch the calendars of every account in `rjd/caldav-accounts'.
Only ever reads from the servers.  The fetch runs in the background,
the accounts side by side; each calendar's file is rewritten once its
events have arrived, and every agenda redone once all have.  Unless
MAY-PROMPT, as from a timer, no passphrase is asked for, and an account
with no password to hand is skipped -- silently, unless the fetch was
begun by hand.  Does nothing where `rjd/caldav-active-p' says no, or
while a fetch runs."
  (interactive (list t))
  (let ((interactive (called-interactively-p 'any)))
    (cond
     ((not (rjd/caldav-active-p))
      (when interactive
        (user-error "No CalDAV calendars on this machine; see `rjd/caldav-active-p'")))
     (rjd/caldav--fetching
      (when interactive
        (message "rjd-caldav: a fetch is already running")))
     (t
      (pcase-let ((`(,refused . ,collisions)
                   (rjd/caldav--collisions (rjd/caldav--accounts)))
                  (ready nil)
                  (results nil))
        (dolist (account (rjd/caldav--accounts))
          (if-let* ((password (rjd/caldav--password account may-prompt)))
              (push (cons account (rjd/caldav--authorization account password))
                    ready)
            (let ((name (plist-get account :name)))
              (push (list name (format "%s: %s" name
                                       (rjd/caldav--no-password account)))
                    results))))
        (setq ready (nreverse ready)
              results (cons (cons nil collisions)
                            (and interactive (nreverse results))))
        (if (null ready)
            (when interactive
              (user-error "%s" (string-join (mapcan (lambda (result)
                                                      (copy-sequence
                                                       (cdr result)))
                                                    results)
                                            "; ")))
          (let ((pending (length ready)))
            (setq rjd/caldav--fetching t
                  rjd/caldav--last-fetch (current-time))
            (when interactive
              (setq rjd/caldav--failing nil))
            (pcase-dolist (`(,account . ,authorization) ready)
              (rjd/caldav--fetch-account
               account refused authorization
               (lambda (account-errors)
                 (setq results (append results
                                       (list (cons (plist-get account :name)
                                                   account-errors))))
                 (when (zerop (setq pending (1- pending)))
                   (rjd/caldav--finish results))))))))))))

;;;###autoload
(defun rjd/caldav-list-calendars (account)
  "Show the display names of ACCOUNT's calendars.
Interactively, ACCOUNT is asked for by name, unless there is just one,
among the accounts in `rjd/caldav-accounts' with a name, a server and
a user, whether or not they name any calendars yet."
  (interactive
   (let ((accounts (rjd/caldav--accounts t)))
     (list (cond ((null accounts)
                  (user-error "No account in `rjd/caldav-accounts'"))
                 ((null (cdr accounts)) (car accounts))
                 (t (let ((name (completing-read
                                 "Account: "
                                 (mapcar (lambda (account)
                                           (plist-get account :name))
                                         accounts)
                                 nil t)))
                      (seq-find (lambda (account)
                                  (equal (plist-get account :name) name))
                                accounts)))))))
  (let ((password (or (rjd/caldav--password account t)
                      (user-error "%s" (capitalize (rjd/caldav--no-password
                                                    account)))))
        (name (plist-get account :name)))
    (rjd/caldav--discover
     account (rjd/caldav--authorization account password)
     (lambda (err calendars)
       (if err
           (message "rjd-caldav: %s: %s" name err)
         (message "%s calendars: %s" name
                  (mapconcat #'car calendars ", ")))))))

(defun rjd/caldav--fetch-on-agenda ()
  "Fetch, unless one just ran; on `org-agenda-mode-hook'.
Opening the agenda is the user's doing, so this fetch may prompt."
  (unless (and rjd/caldav--last-fetch
               (< (float-time (time-since rjd/caldav--last-fetch))
                  rjd/caldav--agenda-quiet-period))
    (rjd/caldav-fetch t)))


;;; The mode

;;;###autoload
(define-minor-mode rjd/caldav-mode
  "Fetch CalDAV calendars into org-agenda, read-only.
The calendars of the accounts in `rjd/caldav-accounts' are fetched
into `rjd/caldav-directory' when the agenda opens, and every
`rjd/caldav-fetch-interval' seconds -- the timer only if
`rjd/caldav-active-p' when the mode is turned on."
  :global t
  :group 'rjd/caldav
  (when (timerp rjd/caldav--timer)
    (cancel-timer rjd/caldav--timer))
  (setq rjd/caldav--timer nil)
  (if rjd/caldav-mode
      (progn
        (add-hook 'org-agenda-mode-hook #'rjd/caldav--fetch-on-agenda)
        (when (and rjd/caldav-fetch-interval (rjd/caldav-active-p))
          (setq rjd/caldav--timer
                (run-at-time rjd/caldav-fetch-interval rjd/caldav-fetch-interval
                             #'rjd/caldav-fetch))))
    (remove-hook 'org-agenda-mode-hook #'rjd/caldav--fetch-on-agenda)))

(provide 'rjd-caldav)

;;; rjd-caldav.el ends here
