;;; rjd-icloud.el --- iCloud calendars in org-agenda, read-only, over CalDAV  -*- lexical-binding: t; -*-

;;; Commentary:

;; Fetches the iCloud calendars named in `rjd/icloud-calendars' into
;; one calendar file each, in `rjd/icloud-directory', and never writes
;; back: every request is a PROPFIND or a REPORT.  iCloud cannot enforce
;; that -- an app-specific password opens every calendar and the
;; contacts, read and write -- so read-only rests on this file.
;; docs/adr/0002-icloud-calendars-caldav-fetch.md has the reasons.
;;
;; A fetch discovers the account's calendars afresh (the principal,
;; then its calendar home, then the calendars in it), matches the
;; configured display names, and asks iCloud for each calendar's events
;; over a window around today with recurrences expanded by the server,
;; so every occurrence arrives as its own VEVENT, moved and cancelled
;; occurrences already applied.  Each calendar file is then rewritten
;; whole, but only after its calendar's fetch succeeded: a failure keeps
;; the last good file.
;;
;; iCloud's expanded events depart from the standards in ways this
;; relies on handling, all recorded by test/icloud-probe.sh:
;;
;; - Times are not converted to UTC, as RFC 4791 asks, but keep the
;;   event's TZID -- with no VTIMEZONE to define it.  The parser takes
;;   such a time as floating, so the TZID is read here and looked up in
;;   the system's time-zone database; see `rjd/icloud--absolute'.
;; - The calendar data has no VERSION or PRODID, and DTSTAMP twice,
;;   which Emacs 31's parser accepts.
;;
;; Emacs 31's `icalendar-parser' parses the events; its recurrence code,
;; `icalendar-recur', is deliberately not used, since iCloud expands
;; recurrences and that code mishandles COUNT, UTC EXDATEs and
;; RECURRENCE-ID.  If iCloud stopped expanding, a calendar would show
;; each recurring event once, on its first date.
;;
;; The password is an app-specific one, from auth-source under the host
;; `caldav.icloud.com' and the account's address.  Only a fetch begun by
;; opening the agenda, or by hand, may prompt for it: a timer's fetch
;; leaves encrypted sources out, and with no password skips its run.
;;
;; Nothing is fetched inside a container, so no agent's Emacs holds the
;; password; `rjd/icloud-enabled' overrides that.
;;
;; Enable with `rjd/icloud-mode'.  Turning it off is the way round a bad
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

(defgroup rjd/icloud nil
  "iCloud calendars in org-agenda, read-only."
  :group 'org)

(defcustom rjd/icloud-account nil
  "The Apple Account address whose calendars are fetched, or nil for none.
Its app-specific password is looked up in auth-source under the host
`caldav.icloud.com' and this address."
  :type '(choice (const :tag "None" nil) string)
  :group 'rjd/icloud)

(defcustom rjd/icloud-calendars nil
  "Display names of the iCloud calendars to fetch, as iCloud shows them.
\\[rjd/icloud-list-calendars] lists the account's.  A calendar fed from
org, such as one beorg writes, must not be named here: its events would
come back into the agenda as copies of org's own."
  :type '(repeat string)
  :group 'rjd/icloud)

(defcustom rjd/icloud-directory "~/org-agenda/calendars/"
  "The directory each calendar file is written into.
The agenda should list the directory; see `rjd/calendar-directory' in
init.el."
  :type 'directory
  :group 'rjd/icloud)

(defcustom rjd/icloud-fetch-interval 900
  "Seconds between fetches while Emacs runs, or nil for none.
Opening the agenda fetches too.  Takes effect when `rjd/icloud-mode'
is next turned on."
  :type '(choice (const :tag "Only when the agenda opens" nil) natnum)
  :group 'rjd/icloud)

(defcustom rjd/icloud-days-back 30
  "Days before today from which events are fetched."
  :type 'natnum
  :group 'rjd/icloud)

(defcustom rjd/icloud-days-ahead 365
  "Days after today up to which events are fetched."
  :type 'natnum
  :group 'rjd/icloud)

(defcustom rjd/icloud-enabled 'auto
  "Whether calendars are fetched on this machine.
`auto' fetches unless Emacs runs in a container; t and nil force it."
  :type '(choice (const :tag "Unless in a container" auto)
                 (const :tag "Always" t)
                 (const :tag "Never" nil))
  :group 'rjd/icloud)

(defvar rjd/icloud-container-marker-files '("/.dockerenv" "/run/.containerenv")
  "Files whose presence says Emacs itself runs in a container.
Docker's and podman's, as `rjd/container-git' in init.el checks.")

(defconst rjd/icloud-server "https://caldav.icloud.com/"
  "Where discovery starts.")

(defconst rjd/icloud-auth-host "caldav.icloud.com"
  "The host the password is filed under in auth-source.")

(defvar rjd/icloud-request-function #'rjd/icloud--url-request
  "The function that makes a CalDAV request.
Called with METHOD, URL, DEPTH, BODY, AUTHORIZATION and CALLBACK; it
calls CALLBACK with an error message and nil, or nil and the response's
parsed XML.  Tests replace it.")


;;; State

(defvar rjd/icloud--timer nil
  "The timer that fetches every `rjd/icloud-fetch-interval' seconds.")

(defvar rjd/icloud--fetching nil
  "Non-nil while a fetch runs, so that another does not start.")

(defvar rjd/icloud--failing nil
  "Non-nil once a fetch has failed, until one succeeds.
A failure is reported only when this was nil, so a run of failing
timer fetches says so once.")

(defvar rjd/icloud--last-fetch nil
  "When the last fetch began, or nil.")

(defconst rjd/icloud--agenda-quiet-period 120
  "Seconds after a fetch during which opening the agenda fetches no more.
A finished fetch redoes the agenda, which runs `org-agenda-mode-hook'
again, so without this each fetch would set off the next.")


;;; Where it runs

(defun rjd/icloud-active-p ()
  "Non-nil if calendars are to be fetched on this machine.
That needs `rjd/icloud-account' and `rjd/icloud-calendars', and Emacs
outside a container unless `rjd/icloud-enabled' says otherwise."
  (and rjd/icloud-account
       rjd/icloud-calendars
       (if (eq rjd/icloud-enabled 'auto)
           (not (seq-some #'file-exists-p rjd/icloud-container-marker-files))
         rjd/icloud-enabled)
       t))


;;; Files

(defun rjd/icloud-file-name (name)
  "The name of the calendar file for the calendar called NAME.
icloud-SLUG.org, where SLUG is NAME in lower case, without apostrophes,
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
    (format "icloud-%s.org" (if (string-empty-p slug) "calendar" slug))))

(defun rjd/icloud--write (name text)
  "Make TEXT the calendar file of the calendar called NAME.
Written beside it and renamed over it, so the agenda never reads half
a file; the temporary name does not end in .org, so the agenda never
lists it.  A buffer visiting the file is reverted, discarding any edit:
the file is the calendar's."
  (let* ((file (expand-file-name (rjd/icloud-file-name name)
                                 rjd/icloud-directory))
         (temp (concat file ".part"))
         (coding-system-for-write 'utf-8-unix))
    (write-region text nil temp nil 'silent)
    (rename-file temp file t)
    (when-let* ((buffer (find-buffer-visiting file)))
      (with-current-buffer buffer
        (revert-buffer :ignore-auto :noconfirm :preserve-modes)))))

(defun rjd/icloud--file-contents (name events)
  "The text of the calendar file of the calendar NAME, holding EVENTS."
  (concat (format "#+CATEGORY: %s\n" name)
          (format-time-string "#+FETCHED: [%F %a %H:%M]\n")
          "# Fetched from iCloud by rjd-icloud, and rewritten whole by every\n"
          "# fetch: anything written here is lost.\n\n"
          (mapconcat #'rjd/icloud--org-entry events "")))


;;; Events

(defun rjd/icloud--known-zone-p (tzid)
  "Non-nil if TZID names a zone in the system's time-zone database.
A name it lacks, such as Exchange's \"Pacific Standard Time\", would be
taken by `encode-time' as UTC, silently."
  (and (string-match-p "\\`[[:alnum:]_+-]+\\(?:/[[:alnum:]_+-]+\\)*\\'" tzid)
       (file-exists-p (expand-file-name
                       tzid (or (getenv "TZDIR") "/usr/share/zoneinfo")))))

(defun rjd/icloud--absolute (time tzid)
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
                          ((and tzid (rjd/icloud--known-zone-p tzid)) tzid))))))))

(defun rjd/icloud--time (vevent property)
  "VEVENT's PROPERTY, `icalendar-dtstart' or `icalendar-dtend', or nil.
A date is (MONTH DAY YEAR), as the parser gives it; a date-time is
seconds since the epoch, see `rjd/icloud--absolute'."
  (when-let* ((node (icalendar-ast-node-first-child-of property vevent))
              (value (icalendar-ast-node-value
                      (icalendar-ast-node-value node))))
    (if (= (length value) 3)
        value
      (rjd/icloud--absolute value (icalendar-property-tzid node)))))

(defun rjd/icloud--declined-p (vevent account)
  "Non-nil if ACCOUNT is an attendee of VEVENT and has declined it."
  (seq-some (lambda (attendee)
              (and (equal (icalendar-with-param-of attendee
                              'icalendar-partstatparam)
                          "DECLINED")
                   (string-equal-ignore-case
                    (icalendar-strip-mailto
                     (icalendar-ast-node-value
                      (icalendar-ast-node-value attendee)))
                    account)))
            (icalendar-ast-node-children-of 'icalendar-attendee vevent)))

(defun rjd/icloud--event (vevent account)
  "VEVENT as a plist, or nil if it is not to be shown.
Cancelled events are not, nor those ACCOUNT has declined, nor any
without a start.  The plist has :summary, :start and :end, see
`rjd/icloud--time', :location and :description."
  (let ((start (rjd/icloud--time vevent 'icalendar-dtstart)))
    (unless (or (null start)
                (equal (icalendar-with-property-of vevent 'icalendar-status)
                       "CANCELLED")
                (rjd/icloud--declined-p vevent account))
      (list :summary (icalendar-component-summary vevent)
            :start start
            :end (rjd/icloud--time vevent 'icalendar-dtend)
            :location (icalendar-with-property-of vevent 'icalendar-location)
            :description (icalendar-component-description vevent)))))

(defun rjd/icloud--calendar-events (text account)
  "The events in TEXT, an iCalendar object, as plists; see `rjd/icloud--event'.
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
      (delq nil (mapcar (lambda (vevent) (rjd/icloud--event vevent account))
                        (icalendar-ast-node-children-of 'icalendar-vevent
                                                        calendar))))))

(defun rjd/icloud--sort-key (event)
  "Seconds since the epoch at which EVENT starts, a date at local midnight."
  (let ((start (plist-get event :start)))
    (if (numberp start)
        start
      (float-time (rjd/icloud--date-time start 0)))))

(defun rjd/icloud--events (dom account)
  "The events in DOM, a REPORT response, as plists in order of start.
ACCOUNT's declined events are left out; see `rjd/icloud--event'."
  (sort (mapcan (lambda (data)
                  (rjd/icloud--calendar-events (dom-inner-text data) account))
                (dom-by-tag dom 'calendar-data))
        :key #'rjd/icloud--sort-key))


;;; Org entries

(defun rjd/icloud--date-time (date &optional days)
  "Local noon on DATE, (MONTH DAY YEAR), DAYS later, as a Lisp time.
Noon, so a day's length changing with summer time cannot move it to
another date."
  (pcase-let ((`(,month ,day ,year) date))
    (encode-time (list 0 0 12 (+ day (or days 0)) month year nil -1 nil))))

(defun rjd/icloud--timestamp (start end)
  "The org timestamp of an event from START to END; see `rjd/icloud--time'.
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
    (let ((first (rjd/icloud--date-time start))
          (last (and (consp end) (rjd/icloud--date-time end -1))))
      (if (and last (time-less-p first last))
          (format "<%s>--<%s>" (format-time-string "%F %a" first)
                  (format-time-string "%F %a" last))
        (format "<%s>" (format-time-string "%F %a" first))))))

(defun rjd/icloud--org-entry (event)
  "EVENT, a plist from `rjd/icloud--event', as an org entry.
The summary is made one line, so it stays one heading; the description
is indented, so no line of it can start a heading of its own."
  (let ((summary (string-clean-whitespace (or (plist-get event :summary) "")))
        (location (plist-get event :location))
        (description (plist-get event :description)))
    (concat "* " (if (string-empty-p summary) "(no title)" summary) "\n"
            (when (and location (not (string-blank-p location)))
              (format ":PROPERTIES:\n:LOCATION: %s\n:END:\n"
                      (string-clean-whitespace location)))
            (rjd/icloud--timestamp (plist-get event :start)
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

(defun rjd/icloud--quiet-auth-sources ()
  "`auth-sources' without the encrypted files, which may ask for a passphrase."
  (seq-remove (lambda (source)
                (let ((file (cond ((stringp source) source)
                                  ((consp source) (plist-get source :source)))))
                  (and (stringp file) (string-suffix-p ".gpg" file))))
              auth-sources))

(defun rjd/icloud--password (&optional may-prompt)
  "The app-specific password of `rjd/icloud-account', or nil.
Unless MAY-PROMPT, encrypted sources are not read, so nothing can ask
for a passphrase; a password auth-source already remembers is still
found."
  (let ((auth-sources (if may-prompt
                          auth-sources
                        (rjd/icloud--quiet-auth-sources))))
    (auth-source-pick-first-password :host rjd/icloud-auth-host
                                     :user rjd/icloud-account)))

(defun rjd/icloud--authorization (password)
  "The Basic Authorization header value for the account and PASSWORD."
  (concat "Basic "
          (base64-encode-string
           (encode-coding-string (concat rjd/icloud-account ":" password)
                                 'utf-8)
           t)))

(defun rjd/icloud--url-request (method url depth body authorization callback)
  "Make a CalDAV request with url.el, in the background.
See `rjd/icloud-request-function' for METHOD, URL, DEPTH, BODY,
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
                        (rjd/icloud--url-response status method url callback))
                      nil t t)
      (error (funcall callback
                      (format "%s %s: %s" method url (error-message-string err))
                      nil)))))

(defun rjd/icloud--url-response (status method url callback)
  "Hand the response in the current buffer to CALLBACK, and kill it.
STATUS is url.el's; METHOD and URL are the request's.  Anything but a
207 Multi-Status is an error."
  (let ((buffer (current-buffer))
        err dom)
    (unwind-protect
        (progn
          (setq err (cond ((plist-get status :error)
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

(defun rjd/icloud--request (method url depth body authorization on-success callback)
  "Make a request, and call ON-SUCCESS with its parsed response.
A failed request calls CALLBACK with its error and nil instead.  See
`rjd/icloud-request-function' for METHOD, URL, DEPTH, BODY and
AUTHORIZATION."
  (funcall rjd/icloud-request-function method url depth body authorization
           (lambda (err dom)
             (if err
                 (funcall callback err nil)
               (funcall on-success dom)))))


;;; Discovery

(defconst rjd/icloud--principal-body
  "<d:propfind xmlns:d=\"DAV:\"><d:prop><d:current-user-principal/></d:prop></d:propfind>"
  "Asks for the account's principal.")

(defconst rjd/icloud--home-set-body
  "<d:propfind xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\"><d:prop><c:calendar-home-set/></d:prop></d:propfind>"
  "Asks a principal for its calendar home.")

(defconst rjd/icloud--calendars-body
  "<d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/></d:prop></d:propfind>"
  "Asks a calendar home for its collections' names and types.")

(defun rjd/icloud--href-in (dom tag base)
  "The URL in the first href inside DOM's first TAG, resolved against BASE.
Or nil.  iCloud sends some absolute, some relative; and the host of a
relative one is sometimes caldav.icloud.com, sometimes the account's
own, so each is resolved against the URL its response came from."
  (when-let* ((node (car (dom-by-tag dom tag)))
              (href (car (dom-by-tag node 'href))))
    (url-expand-file-name (string-trim (dom-inner-text href)) base)))

(defun rjd/icloud--calendars-in (dom base)
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

(defun rjd/icloud--discover (authorization callback)
  "Find the account's calendars, and call CALLBACK with them.
CALLBACK gets nil and an alist of (NAME . URL), or an error and nil.
AUTHORIZATION is the header value to send."
  (let ((fail (lambda (what) (funcall callback (concat "no " what) nil))))
    (rjd/icloud--request
     "PROPFIND" rjd/icloud-server "0" rjd/icloud--principal-body authorization
     (lambda (dom)
       (if-let* ((principal (rjd/icloud--href-in dom 'current-user-principal
                                                 rjd/icloud-server)))
           (rjd/icloud--request
            "PROPFIND" principal "0" rjd/icloud--home-set-body authorization
            (lambda (dom)
              (if-let* ((home (rjd/icloud--href-in dom 'calendar-home-set
                                                   principal)))
                  (rjd/icloud--request
                   "PROPFIND" home "1" rjd/icloud--calendars-body authorization
                   (lambda (dom)
                     (funcall callback nil (rjd/icloud--calendars-in dom home)))
                   callback)
                (funcall fail "calendar home")))
            callback)
         (funcall fail "principal")))
     callback)))


;;; Fetching

(defun rjd/icloud--report-body ()
  "Asks a calendar for its events in the window, recurrences expanded."
  (let ((start (format-time-string
                "%Y%m%dT000000Z"
                (time-subtract nil (days-to-time rjd/icloud-days-back)) t))
        (end (format-time-string
              "%Y%m%dT000000Z"
              (time-add nil (days-to-time rjd/icloud-days-ahead)) t)))
    (format "<c:calendar-query xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\">\
<d:prop><c:calendar-data><c:expand start=\"%s\" end=\"%s\"/></c:calendar-data></d:prop>\
<c:filter><c:comp-filter name=\"VCALENDAR\"><c:comp-filter name=\"VEVENT\">\
<c:time-range start=\"%s\" end=\"%s\"/></c:comp-filter></c:comp-filter></c:filter>\
</c:calendar-query>"
            start end start end)))

(defun rjd/icloud--wanted (calendars)
  "The configured calendars found in CALENDARS, and what is wrong with the rest.
CALENDARS is discovery's alist.  Returns (WANTED . ERRORS), WANTED an
alist of (NAME . URL).  A name no calendar has is an error, and so are
names that would share a file, which are all refused."
  (let ((groups (seq-group-by #'rjd/icloud-file-name rjd/icloud-calendars))
        wanted errors)
    (pcase-dolist (`(,file . ,names) groups)
      (cond ((cdr names)
             (push (format "%s would all be %s" (string-join names ", ") file)
                   errors))
            ((assoc (car names) calendars)
             (push (assoc (car names) calendars) wanted))
            (t
             (push (format "no calendar is called %s" (car names)) errors))))
    (cons (nreverse wanted) (nreverse errors))))

(defun rjd/icloud--redo-agendas ()
  "Redo every agenda buffer, so it shows what was fetched."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'org-agenda-mode)
        (org-agenda-redo t)))))

(defun rjd/icloud--finish (errors)
  "End a fetch that met ERRORS, a list of messages, nil if none.
Errors are reported only at the start of a run of failing fetches."
  (setq rjd/icloud--fetching nil)
  (if (not errors)
      (setq rjd/icloud--failing nil)
    (unless rjd/icloud--failing
      (setq rjd/icloud--failing t)
      (message "rjd-icloud: fetching failed: %s" (string-join errors "; "))))
  (rjd/icloud--redo-agendas))

(defun rjd/icloud--fetch-calendars (calendars authorization)
  "Fetch each wanted calendar of CALENDARS into its file.
CALENDARS is discovery's alist; AUTHORIZATION the header value."
  (pcase-let* ((`(,wanted . ,errors) (rjd/icloud--wanted calendars))
               (pending (length wanted)))
    (if (null wanted)
        (rjd/icloud--finish errors)
      (pcase-dolist (`(,name . ,url) wanted)
        (let ((done (lambda (err)
                      (when err (push (format "%s: %s" name err) errors))
                      (when (zerop (setq pending (1- pending)))
                        (rjd/icloud--finish (reverse errors))))))
          (rjd/icloud--request
           "REPORT" url "1" (rjd/icloud--report-body) authorization
           (lambda (dom)
             (funcall done
                      (condition-case err
                          (progn
                            (rjd/icloud--write
                             name (rjd/icloud--file-contents
                                   name (rjd/icloud--events
                                         dom rjd/icloud-account)))
                            nil)
                        (error (error-message-string err)))))
           (lambda (err _) (funcall done err))))))))

;;;###autoload
(defun rjd/icloud-fetch (&optional may-prompt)
  "Fetch the calendars in `rjd/icloud-calendars' into their files.
Only ever reads from iCloud.  The fetch runs in the background; each
calendar's file is rewritten once its events have arrived, and every
agenda then redone.  Unless MAY-PROMPT, as from a timer, no passphrase
is asked for, and with no password to hand nothing is fetched.  Does
nothing where `rjd/icloud-active-p' says no, or while a fetch runs."
  (interactive (list t))
  (let ((interactive (called-interactively-p 'any)))
    (cond
     ((not (rjd/icloud-active-p))
      (when interactive
        (user-error "No iCloud calendars on this machine; see `rjd/icloud-active-p'")))
     (rjd/icloud--fetching
      (when interactive
        (message "rjd-icloud: a fetch is already running")))
     (t
      (if-let* ((password (rjd/icloud--password may-prompt)))
          (let ((authorization (rjd/icloud--authorization password)))
            (setq rjd/icloud--fetching t
                  rjd/icloud--last-fetch (current-time))
            (when interactive
              (setq rjd/icloud--failing nil))
            (rjd/icloud--discover
             authorization
             (lambda (err calendars)
               (if err
                   (rjd/icloud--finish (list err))
                 (rjd/icloud--fetch-calendars calendars authorization)))))
        (when interactive
          (user-error "No password for %s at %s in auth-source"
                      rjd/icloud-account rjd/icloud-auth-host)))))))

;;;###autoload
(defun rjd/icloud-list-calendars ()
  "Show the display names of the account's iCloud calendars."
  (interactive)
  (unless rjd/icloud-account
    (user-error "`rjd/icloud-account' is not set"))
  (let ((password (or (rjd/icloud--password t)
                      (user-error "No password for %s at %s in auth-source"
                                  rjd/icloud-account rjd/icloud-auth-host))))
    (rjd/icloud--discover
     (rjd/icloud--authorization password)
     (lambda (err calendars)
       (if err
           (message "rjd-icloud: %s" err)
         (message "iCloud calendars: %s"
                  (mapconcat #'car calendars ", ")))))))

(defun rjd/icloud--fetch-on-agenda ()
  "Fetch, unless one just ran; on `org-agenda-mode-hook'.
Opening the agenda is the user's doing, so this fetch may prompt."
  (unless (and rjd/icloud--last-fetch
               (< (float-time (time-since rjd/icloud--last-fetch))
                  rjd/icloud--agenda-quiet-period))
    (rjd/icloud-fetch t)))


;;; The mode

;;;###autoload
(define-minor-mode rjd/icloud-mode
  "Fetch iCloud calendars into org-agenda, read-only.
The calendars in `rjd/icloud-calendars' are fetched into
`rjd/icloud-directory' when the agenda opens, and every
`rjd/icloud-fetch-interval' seconds -- the timer only if
`rjd/icloud-active-p' when the mode is turned on."
  :global t
  :group 'rjd/icloud
  (when (timerp rjd/icloud--timer)
    (cancel-timer rjd/icloud--timer))
  (setq rjd/icloud--timer nil)
  (if rjd/icloud-mode
      (progn
        (add-hook 'org-agenda-mode-hook #'rjd/icloud--fetch-on-agenda)
        (when (and rjd/icloud-fetch-interval (rjd/icloud-active-p))
          (setq rjd/icloud--timer
                (run-at-time rjd/icloud-fetch-interval rjd/icloud-fetch-interval
                             #'rjd/icloud-fetch))))
    (remove-hook 'org-agenda-mode-hook #'rjd/icloud--fetch-on-agenda)))

(provide 'rjd-icloud)

;;; rjd-icloud.el ends here
