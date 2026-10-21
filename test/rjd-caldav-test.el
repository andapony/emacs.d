;;; rjd-caldav-test.el --- Tests for fetching CalDAV calendars into org  -*- lexical-binding: t; -*-

;;; Commentary:

;; Fetching, end to end, against responses recorded by
;; test/caldav-probe.sh and sanitised, one directory per server under
;; fixtures/caldav/, with `rjd/caldav-request-function' replaced by a
;; replay of them -- so no network, no account and no password.
;;
;; iCloud's (fixtures/caldav/icloud/): probe-expanded.xml is iCloud's
;; expansion of a weekly event with one occurrence moved and one
;; deleted; cases-expanded.xml is made by hand in the same shape, for
;; what the probe did not cover, and durations-expanded.xml likewise,
;; for events that give a DURATION rather than a DTEND.  The iCloud
;; account is declared by `rjd/caldav-test-icloud'.
;;
;; Times are checked in a fixed local zone, set by
;; `rjd/caldav-test-in-zone', so the results do not depend on the
;; machine's.
;;
;; Run from the repository root with
;;
;;   emacs -Q --batch -L user-lisp -l test/rjd-caldav-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'dom)
(setq load-prefer-newer t)
(require 'rjd-caldav)

(defconst rjd/caldav-test-fixtures
  (expand-file-name "fixtures/caldav/icloud/"
                    (file-name-directory
                     (or load-file-name buffer-file-name)))
  "The directory of recorded and hand-made iCloud responses.")

(defun rjd/caldav-test-icloud (calendars)
  "The iCloud account, as `rjd/caldav-accounts' declares it, with CALENDARS."
  (list :name "icloud"
        :server "https://caldav.icloud.com/"
        :user "user@example.com"
        :calendars calendars))

(defconst rjd/caldav-test-home
  "https://p01-caldav.icloud.com:443/1234567890/calendars/"
  "The calendar home set in the recorded responses.")

(defconst rjd/caldav-test-probe-url
  "https://p01-caldav.icloud.com/1234567890/calendars/PROBE-CALENDAR/"
  "The Probe calendar's URL in the recorded responses.")

(defun rjd/caldav-test-dom (fixture)
  "The parsed XML of FIXTURE, a file name in `rjd/caldav-test-fixtures'."
  (with-temp-buffer
    (insert-file-contents (expand-file-name fixture rjd/caldav-test-fixtures))
    (libxml-parse-xml-region (point-min) (point-max))))

(defmacro rjd/caldav-test-in-zone (zone &rest body)
  "Run BODY with Emacs's local time zone ZONE, a TZ string."
  (declare (indent 1))
  (let ((old (make-symbol "old")))
    `(let ((,old (getenv "TZ")))
       (unwind-protect
           (progn (set-time-zone-rule ,zone) ,@body)
         (set-time-zone-rule ,old)))))

(defvar rjd/caldav-test-requests nil
  "The requests the replay was asked for, newest first.
Each is (METHOD URL AUTHORIZATION).")

(defun rjd/caldav-test-replay (responses)
  "A request function answering from RESPONSES.
RESPONSES is an alist of ((METHOD . URL) . FIXTURE); FIXTURE nil, or a
request missing from it, answers with an error, as a failed request
would, and FIXTURE `unauthorized' as a refused password does.  Each request is recorded in `rjd/caldav-test-requests'."
  (lambda (method url _depth _body authorization callback)
    (push (list method url authorization) rjd/caldav-test-requests)
    (let ((fixture (alist-get (cons method url) responses nil nil #'equal)))
      (cond ((eq fixture 'unauthorized) (funcall callback 'unauthorized nil))
            (fixture (funcall callback nil (rjd/caldav-test-dom fixture)))
            (t (funcall callback (format "%s %s: 404" method url) nil))))))

(defconst rjd/caldav-test-discovery
  `((("PROPFIND" . "https://caldav.icloud.com/") . "principal.xml")
    (("PROPFIND" . "https://caldav.icloud.com/1234567890/principal/")
     . "home-set.xml")
    (("PROPFIND" . ,rjd/caldav-test-home) . "calendars.xml"))
  "The replies that discover the account's calendars.")

(defmacro rjd/caldav-test-fetching (calendars responses &rest body)
  "Run BODY with `rjd/caldav-mode' state fresh and requests replayed.
CALENDARS are the iCloud account's, its only one; RESPONSES are added to the
discovery replies, see `rjd/caldav-test-replay'.  The calendar
directory is a fresh temporary one, `dir' in BODY, and the password
comes from a stub, so auth-source is never asked."
  (declare (indent 2))
  `(let* ((dir (file-name-as-directory (make-temp-file "rjd-caldav" t)))
          (rjd/caldav-directory dir)
          (rjd/caldav-accounts (list (rjd/caldav-test-icloud ,calendars)))
          (rjd/caldav-enabled t)
          (rjd/caldav--failing nil)
          (rjd/caldav--fetching nil)
          (rjd/caldav-test-requests nil)
          (rjd/caldav-request-function
           (rjd/caldav-test-replay (append ,responses rjd/caldav-test-discovery)))
          (messages nil))
     (cl-letf (((symbol-function 'rjd/caldav--password)
                (lambda (_account &optional _may-prompt) "app-specific"))
               ((symbol-function 'message)
                (lambda (format &rest args)
                  (when format (push (apply #'format format args) messages)))))
       (unwind-protect
           (rjd/caldav-test-in-zone "America/Los_Angeles"
             ,@body)
         (delete-directory dir t)))))

(defun rjd/caldav-test-file (dir name)
  "The text of iCloud calendar NAME's file in DIR, or nil if there is none."
  (let ((file (expand-file-name (rjd/caldav-file-name "icloud" name) dir)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string)))))

(defconst rjd/caldav-test-probe-report
  `((("REPORT" . ,rjd/caldav-test-probe-url) . "probe-expanded.xml"))
  "The reply to the Probe calendar's REPORT.")


;;; File names

(ert-deftest rjd/caldav-file-name-is-the-account-and-a-slug-of-the-name ()
  (should (equal (rjd/caldav-file-name "icloud" "Home") "icloud-home.org"))
  (should (equal (rjd/caldav-file-name "icloud" "Partner/Errands & Appt's")
                 "icloud-partner-errands-appts.org"))
  (should (equal (rjd/caldav-file-name "icloud" "Reminders ⚠️") "icloud-reminders.org"))
  (should (equal (rjd/caldav-file-name "icloud" "Trips!") "icloud-trips.org"))
  (should (equal (rjd/caldav-file-name "icloud" "Shared 2018") "icloud-shared-2018.org")))


;;; Discovery

(ert-deftest rjd/caldav-discovery-finds-calendars-by-display-name ()
  "Every calendar is found, by its decoded name, at its absolute URL.
The home collection, which has a display name of its own, and the
inbox, outbox and notification collections are not calendars."
  (rjd/caldav-test-fetching nil nil
    (let (result)
      (rjd/caldav--discover (rjd/caldav-test-icloud nil) "auth"
                            (lambda (err calendars)
                              (setq result (list err calendars))))
      (should-not (car result))
      (let ((calendars (cadr result)))
        (should (equal (alist-get "Probe" calendars nil nil #'equal)
                       rjd/caldav-test-probe-url))
        (should (alist-get "Partner/Errands & Appt's" calendars nil nil #'equal))
        (should (alist-get "Reminders ⚠️" calendars nil nil #'equal))
        (should-not (alist-get "Example User" calendars nil nil #'equal))
        (should (= (length calendars) 15))))))

(ert-deftest rjd/caldav-discovery-reports-a-failed-request ()
  (rjd/caldav-test-fetching nil nil
    (let ((rjd/caldav-request-function (rjd/caldav-test-replay nil))
          result)
      (rjd/caldav--discover (rjd/caldav-test-icloud nil) "auth"
                            (lambda (err calendars)
                              (setq result (list err calendars))))
      (should (stringp (car result)))
      (should-not (cadr result)))))


;;; Events

(defun rjd/caldav-test-entries (fixture)
  "The org entries for the events in FIXTURE, as strings."
  (mapcar #'rjd/caldav--org-entry
          (rjd/caldav--events (rjd/caldav-test-dom fixture)
                              "user@example.com")))

(ert-deftest rjd/caldav-probe-occurrences-are-each-an-entry ()
  "iCloud's expansion: five occurrences, the moved one at its new time."
  (rjd/caldav-test-in-zone "America/Los_Angeles"
    (should (equal (rjd/caldav-test-entries "probe-expanded.xml")
                   '("* Probe weekly\n<2026-10-19 Mon 10:00-11:00>\n"
                     "* Probe weekly\n<2026-10-26 Mon 10:00-11:00>\n"
                     "* Probe weekly\n<2026-11-02 Mon 14:00-15:00>\n"
                     "* Probe weekly\n<2026-11-16 Mon 10:00-11:00>\n"
                     "* Probe weekly\n<2026-11-23 Mon 10:00-11:00>\n")))))

(ert-deftest rjd/caldav-times-are-converted-from-the-event-s-zone ()
  "A TZID without a VTIMEZONE is read as the named zone, not as local.
iCloud's expansion sends no VTIMEZONE.  In London, 10:00 in Los Angeles
is 18:00 while both keep summer time, and 14:00 is 22:00 once both
have left it."
  (rjd/caldav-test-in-zone "Europe/London"
    (let ((entries (rjd/caldav-test-entries "probe-expanded.xml")))
      (should (equal (nth 0 entries)
                     "* Probe weekly\n<2026-10-19 Mon 18:00-19:00>\n"))
      (should (equal (nth 2 entries)
                     "* Probe weekly\n<2026-11-02 Mon 22:00-23:00>\n")))))

(ert-deftest rjd/caldav-cases-make-the-expected-entries ()
  "Cancelled and declined events are dropped; the rest are in order."
  (rjd/caldav-test-in-zone "America/Los_Angeles"
    (should (equal (rjd/caldav-test-entries "cases-expanded.xml")
                   '("* Dentist
:PROPERTIES:
:LOCATION: 12 Main St, Springfield
:END:
<2026-10-21 Wed 09:30-10:15>
  Bring the form.
  * not a heading

  Last line.
"
                     "* Bin day\n<2026-10-22 Thu>\n"
                     "* Accepted dinner\n<2026-10-25 Sun 23:00>--<2026-10-26 Mon 00:30>\n"
                     "* Floating alarm\n<2026-10-27 Tue 07:00>\n"
                     "* Call & review\n<2026-10-28 Wed 08:00-08:30>\n"
                     "* Long weekend\n<2026-11-20 Fri>--<2026-11-22 Sun>\n")))))

(ert-deftest rjd/caldav-floating-and-unknown-zones-are-local ()
  "A floating time, and one in a zone the system does not know, are local.
Read as UTC, which is what `encode-time' does with an unknown zone,
the 08:00 call would move."
  (rjd/caldav-test-in-zone "Europe/London"
    (let ((entries (rjd/caldav-test-entries "cases-expanded.xml")))
      (should (member "* Floating alarm\n<2026-10-27 Tue 07:00>\n" entries))
      (should (member "* Call & review\n<2026-10-28 Wed 08:00-08:30>\n"
                      entries)))))

(ert-deftest rjd/caldav-unparsable-data-yields-nothing-quietly ()
  "Calendar data the parser rejects gives no events and no warning."
  (when (get-buffer "*Warnings*") (kill-buffer "*Warnings*"))
  (should-not (rjd/caldav--calendar-events
               "BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART:garbage\n"
               "user@example.com"))
  (should-not (get-buffer "*Warnings*")))

(ert-deftest rjd/caldav-a-heading-like-summary-stays-one-heading ()
  (should (equal (rjd/caldav--org-entry
                  (list :summary "Line one\nline two" :start '(10 20 2026)))
                 "* Line one line two\n<2026-10-20 Tue>\n")))


;;; Durations

(defconst rjd/caldav-test-durations-report
  `((("REPORT" . ,rjd/caldav-test-probe-url) . "durations-expanded.xml"))
  "The reply to the Probe calendar's REPORT, every event with a DURATION.")

(defun rjd/caldav-test-fetch-durations (zone)
  "The Probe calendar's file, fetched with local time ZONE, from
durations-expanded.xml."
  (rjd/caldav-test-fetching '("Probe") rjd/caldav-test-durations-report
    (rjd/caldav-test-in-zone zone
      (rjd/caldav-fetch)
      (should-not messages)
      (rjd/caldav-test-file dir "Probe"))))

(ert-deftest rjd/caldav-a-duration-gives-a-timed-event-its-end ()
  "A one-hour DURATION ends the event an hour after it starts, on the day."
  (should (string-search "* Standup\n<2026-10-21 Wed 09:00-10:00>\n"
                         (rjd/caldav-test-fetch-durations
                          "America/Los_Angeles"))))


(ert-deftest rjd/caldav-a-duration-past-midnight-gives-a-range ()
  "A timed event whose DURATION crosses midnight spans two dates."
  (should (string-search
           "* Late show\n<2026-10-23 Fri 22:00>--<2026-10-24 Sat 01:00>\n"
           (rjd/caldav-test-fetch-durations "America/Los_Angeles"))))

(ert-deftest rjd/caldav-a-duration-s-days-are-calendar-days ()
  "A day of DURATION ends at the same local time the next day, though
the clocks go back between them: Los Angeles leaves summer time on 1
November 2026, so the day is 25 hours long."
  (should (string-search
           "* Retreat\n<2026-10-31 Sat 09:00>--<2026-11-01 Sun 09:00>\n"
           (rjd/caldav-test-fetch-durations "America/Los_Angeles"))))

(ert-deftest rjd/caldav-an-all-day-duration-spans-its-days ()
  "An all-day event's DURATION, in days or in weeks, gives the exclusive
end date, as DTEND does: three days from 30 November, a week from 28
December."
  (let ((text (rjd/caldav-test-fetch-durations "America/Los_Angeles")))
    (should (string-search
             "* Conference\n<2026-11-30 Mon>--<2026-12-02 Wed>\n" text))
    (should (string-search
             "* Holiday\n<2026-12-28 Mon>--<2027-01-03 Sun>\n" text))))

(ert-deftest rjd/caldav-durations-in-london ()
  "The same events seen from London.  The UTC night flight now crosses
midnight and the late show does not; London has already left summer
time by the retreat, so its day is 24 hours long."
  (should (string-suffix-p
           (concat "\n\n"
                   "* Standup\n<2026-10-21 Wed 17:00-18:00>\n"
                   "* Late show\n<2026-10-24 Sat 06:00-09:00>\n"
                   "* Night flight\n<2026-10-30 Fri 23:00>--<2026-10-31 Sat 01:00>\n"
                   "* Retreat\n<2026-10-31 Sat 16:00>--<2026-11-01 Sun 16:00>\n"
                   "* Conference\n<2026-11-30 Mon>--<2026-12-02 Wed>\n"
                   "* Holiday\n<2026-12-28 Mon>--<2027-01-03 Sun>\n")
           (rjd/caldav-test-fetch-durations "Europe/London"))))

;;; Fetching

(ert-deftest rjd/caldav-fetch-writes-the-calendar-file ()
  (rjd/caldav-test-fetching '("Probe") rjd/caldav-test-probe-report
    (rjd/caldav-fetch)
    (let ((text (rjd/caldav-test-file dir "Probe")))
      (should (string-prefix-p "#+CATEGORY: Probe\n#+FETCHED: [" text))
      (should (= (with-temp-buffer
                   (insert text)
                   (how-many "^\\* Probe weekly$" (point-min) (point-max)))
                 5))
      (should (string-search "<2026-11-02 Mon 14:00-15:00>" text)))
    (should-not rjd/caldav--fetching)
    (should-not messages)))

(ert-deftest rjd/caldav-fetch-writes-a-calendar-s-own-category ()
  "A calendar given as (NAME . CATEGORY) is labelled CATEGORY, but its
file is still named for NAME."
  (rjd/caldav-test-fetching '(("Probe" . "P.")) rjd/caldav-test-probe-report
    (rjd/caldav-fetch)
    (should (string-prefix-p "#+CATEGORY: P.\n"
                             (rjd/caldav-test-file dir "Probe")))
    (should-not messages)))

(ert-deftest rjd/caldav-fetch-only-reads ()
  "Every request is a PROPFIND or a REPORT, with the account's Basic auth."
  (rjd/caldav-test-fetching '("Probe") rjd/caldav-test-probe-report
    (rjd/caldav-fetch)
    (should rjd/caldav-test-requests)
    (dolist (request rjd/caldav-test-requests)
      (should (member (car request) '("PROPFIND" "REPORT")))
      (should (equal (nth 2 request)
                     (concat "Basic "
                             (base64-encode-string
                              "user@example.com:app-specific" t)))))))

(ert-deftest rjd/caldav-fetch-rewrites-the-whole-file ()
  "Whatever was in the file before is gone after a fetch."
  (rjd/caldav-test-fetching '("Probe") rjd/caldav-test-probe-report
    (let ((file (expand-file-name "icloud-probe.org" dir)))
      (write-region "* A note typed here\n" nil file nil 'silent)
      (rjd/caldav-fetch)
      (should-not (string-search "A note typed here"
                                 (rjd/caldav-test-file dir "Probe"))))))

(ert-deftest rjd/caldav-fetch-updates-a-buffer-visiting-the-file ()
  (rjd/caldav-test-fetching '("Probe") rjd/caldav-test-probe-report
    (let* ((file (expand-file-name "icloud-probe.org" dir))
           (buffer (progn (write-region "old\n" nil file nil 'silent)
                          (find-file-noselect file))))
      (unwind-protect
          (progn
            (rjd/caldav-fetch)
            (with-current-buffer buffer
              (should (string-prefix-p "#+CATEGORY: Probe" (buffer-string)))
              (should-not (buffer-modified-p))))
        (kill-buffer buffer)))))

(ert-deftest rjd/caldav-failed-fetch-keeps-the-last-good-file ()
  (rjd/caldav-test-fetching '("Probe") nil
    (let ((file (expand-file-name "icloud-probe.org" dir)))
      (write-region "#+CATEGORY: Probe\n* Last good\n" nil file nil 'silent)
      (rjd/caldav-fetch)
      (should (string-search "Last good" (rjd/caldav-test-file dir "Probe")))
      (should (= (length messages) 1))
      (should (string-search "Probe" (car messages))))))

(ert-deftest rjd/caldav-failures-are-reported-once-per-run ()
  "A failure is reported; the same run of failures is not again; a
failure after a success is."
  (rjd/caldav-test-fetching '("Probe") nil
    (rjd/caldav-fetch)
    (rjd/caldav-fetch)
    (should (= (length messages) 1))
    (let ((rjd/caldav-request-function
           (rjd/caldav-test-replay (append rjd/caldav-test-probe-report
                                           rjd/caldav-test-discovery))))
      (rjd/caldav-fetch))
    (should (= (length messages) 1))
    (rjd/caldav-fetch)
    (should (= (length messages) 2))))

(ert-deftest rjd/caldav-unknown-calendar-name-is-reported ()
  "A name no calendar has is reported, and the others are still fetched."
  (rjd/caldav-test-fetching '("Probe" "Renamed") rjd/caldav-test-probe-report
    (rjd/caldav-fetch)
    (should (rjd/caldav-test-file dir "Probe"))
    (should-not (rjd/caldav-test-file dir "Renamed"))
    (should (= (length messages) 1))
    (should (string-search "Renamed" (car messages)))))

(ert-deftest rjd/caldav-colliding-file-names-are-both-refused ()
  (rjd/caldav-test-fetching '("Probe" "probe!") rjd/caldav-test-probe-report
    (rjd/caldav-fetch)
    (should-not (rjd/caldav-test-file dir "Probe"))
    (should-not (seq-some (lambda (request) (equal (car request) "REPORT"))
                          rjd/caldav-test-requests))
    (should (= (length messages) 1))
    (should (string-search "icloud-probe.org" (car messages)))))

(ert-deftest rjd/caldav-fetch-without-a-password-does-nothing ()
  "No password, as from a timer that may not prompt: no request, no message."
  (rjd/caldav-test-fetching '("Probe") rjd/caldav-test-probe-report
    (cl-letf (((symbol-function 'rjd/caldav--password) #'ignore))
      (rjd/caldav-fetch))
    (should-not rjd/caldav-test-requests)
    (should-not messages)
    (should-not rjd/caldav--fetching)))

(ert-deftest rjd/caldav-fetch-while-fetching-does-nothing ()
  (rjd/caldav-test-fetching '("Probe") rjd/caldav-test-probe-report
    (let ((rjd/caldav--fetching t))
      (rjd/caldav-fetch))
    (should-not rjd/caldav-test-requests)))


;;; url.el's responses

(defun rjd/caldav-test-url-response (status code body)
  "What CALLBACK gets for a url.el response of CODE and BODY, with STATUS.
And whether the response buffer survived, which it should not.  The
buffer is as url.el leaves it: headers stripped of their carriage
returns, and `url-http-end-of-headers' a marker at the end of the last
header line -- before the blank line, not after it."
  (let ((buffer (generate-new-buffer " *rjd-caldav-http*"))
        result)
    (with-current-buffer buffer
      (insert (format "HTTP/1.1 %s Whatever\nContent-Type: text/xml" code))
      (setq-local url-http-end-of-headers (point-marker))
      (insert "\n\n")
      (setq-local url-http-response-status code)
      (insert (encode-coding-string body 'utf-8))
      (set-buffer-multibyte nil)
      (rjd/caldav--url-response status "PROPFIND" "https://x/"
                                (lambda (err dom) (setq result (list err dom)))))
    (append result (list (buffer-live-p buffer)))))

(ert-deftest rjd/caldav-url-response-multistatus-is-parsed ()
  (pcase-let ((`(,err ,dom ,alive)
               (rjd/caldav-test-url-response
                nil 207
                (concat "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                        "<multistatus xmlns=\"DAV:\"><response><displayname>"
                        "Café ⚠️</displayname></response></multistatus>"))))
    (should-not err)
    (should (equal (dom-inner-text (car (dom-by-tag dom 'displayname)))
                   "Café ⚠️"))
    (should-not alive)))

(ert-deftest rjd/caldav-url-response-401-says-the-password-was-refused ()
  "A 401, as url.el reports it, is a refused password, told apart.
The request knows no account, so it cannot say whose; the fetch does."
  (pcase-let ((`(,err ,dom ,_)
               (rjd/caldav-test-url-response
                '(:error (error http 401)) 401 "Unauthorized")))
    (should (eq err 'unauthorized))
    (should-not dom)))

(ert-deftest rjd/caldav-refused-password-names-the-host-and-the-cache ()
  "A refused password is reported with its auth-source host and user.
auth-source keeps a password it has found, so a corrected one is not
read until the cache is cleared, and the message says how."
  (rjd/caldav-test-fetching '("Probe")
      '((("PROPFIND" . "https://caldav.icloud.com/") . unauthorized))
    (rjd/caldav-fetch)
    (should (= (length messages) 1))
    (should (string-search "icloud" (car messages)))
    (should (string-search "refused" (car messages)))
    (should (string-search "caldav.icloud.com" (car messages)))
    (should (string-search "user@example.com" (car messages)))
    (should (string-search "auth-source-forget-all-cached" (car messages)))))

(ert-deftest rjd/caldav-url-response-anything-else-is-an-error ()
  (pcase-let ((`(,err ,dom ,alive)
               (rjd/caldav-test-url-response nil 500 "Internal Server Error")))
    (should (string-search "HTTP 500" err))
    (should-not dom)
    (should-not alive))
  (pcase-let ((`(,err ,dom ,_)
               (rjd/caldav-test-url-response
                '(:error (error "connection refused")) 207 "")))
    (should (string-search "connection refused" err))
    (should-not dom)))


(defun rjd/caldav-test-serve (fixture)
  "Start a local HTTP server answering every request with FIXTURE, as 207.
Returns the server process; its port is in its `:service' contact."
  (let ((body (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert-file-contents-literally
                 (expand-file-name fixture rjd/caldav-test-fixtures))
                (buffer-string))))
    (make-network-process
     :name "rjd-caldav-test-server" :server t :host 'local :service t
     :family 'ipv4 :coding 'binary
     :filter (lambda (process input)
               ;; Answer once the request's body has arrived: url.el
               ;; sends it after the headers' blank line.
               (when (string-search "</d:propfind>" input)
                 (process-send-string
                  process
                  (concat "HTTP/1.1 207 Multi-Status\r\n"
                          "Content-Type: text/xml; charset=UTF-8\r\n"
                          (format "Content-Length: %d\r\n" (length body))
                          "Connection: close\r\n\r\n"
                          body))
                 (process-send-eof process))))))

(ert-deftest rjd/caldav-url-request-reads-a-real-response ()
  "A request through url.el, to a local server, comes back parsed.
The other tests replace the request function, so only this one shows
the body is found where url.el leaves it."
  (let* ((server (rjd/caldav-test-serve "principal.xml"))
         (port (process-contact server :service))
         result)
    (unwind-protect
        (progn
          (rjd/caldav--url-request
           "PROPFIND" (format "http://127.0.0.1:%d/" port) "0"
           rjd/caldav--principal-body "Basic eA=="
           (lambda (err dom) (setq result (list err dom))))
          (with-timeout (10 (ert-fail "no response within 10 seconds"))
            (while (not result)
              (accept-process-output nil 0.05)))
          (should-not (car result))
          (should (equal (rjd/caldav--href-in (cadr result)
                                              'current-user-principal
                                              "https://caldav.icloud.com/")
                         "https://caldav.icloud.com/1234567890/principal/")))
      (delete-process server))))


;;; Password

(ert-deftest rjd/caldav-quiet-auth-sources-leave-out-encrypted-files ()
  "A fetch that may not prompt never reads an encrypted source."
  (let ((auth-sources '("~/.authinfo.gpg" "~/.authinfo"
                        (:source "~/x.gpg") macos-keychain-internet)))
    (should (equal (rjd/caldav--quiet-auth-sources)
                   '("~/.authinfo" macos-keychain-internet)))))


(ert-deftest rjd/caldav-password-is-found-under-the-server-s-host-and-user ()
  "Each account's password is looked up under its server's host and its
user, from auth-source itself, and sent only to that account's server."
  (let* ((auth-dir (make-temp-file "rjd-caldav-auth" t))
         (authinfo (expand-file-name "authinfo" auth-dir))
         (auth-sources (list authinfo))
         (other (list :name "other" :server "https://dav.example.net/dav/"
                      :user "me@example.net" :calendars '("Home")))
         (password (symbol-function 'rjd/caldav--password)))
    (write-region (concat "machine caldav.icloud.com login user@example.com"
                          " password icloud-pw\n"
                          "machine dav.example.net login me@example.net"
                          " password other-pw\n"
                          "machine dav.example.net login someone@example.net"
                          " password wrong\n")
                  nil authinfo nil 'silent)
    (auth-source-forget-all-cached)
    (unwind-protect
        (rjd/caldav-test-fetching '("Probe") rjd/caldav-test-probe-report
          (cl-letf (((symbol-function 'rjd/caldav--password) password))
            (let ((rjd/caldav-accounts (append rjd/caldav-accounts
                                               (list other))))
              (rjd/caldav-fetch)))
          (should (rjd/caldav-test-file dir "Probe"))
          (dolist (request rjd/caldav-test-requests)
            (should (equal (nth 2 request)
                           (concat "Basic "
                                   (base64-encode-string
                                    (if (string-prefix-p "https://dav.example.net/"
                                                         (nth 1 request))
                                        "me@example.net:other-pw"
                                      "user@example.com:icloud-pw")
                                    t)))))
          (should (seq-some (lambda (request)
                              (equal (nth 1 request) "https://dav.example.net/dav/"))
                            rjd/caldav-test-requests)))
      (auth-source-forget-all-cached)
      (delete-directory auth-dir t))))


;;; Where it runs

(ert-deftest rjd/caldav-active-p-needs-account-calendars-and-no-container ()
  (let ((rjd/caldav-accounts (list (rjd/caldav-test-icloud '("Home"))))
        (rjd/caldav-enabled 'auto))
    (let ((rjd/caldav-container-marker-files '("/nonexistent-rjd-caldav")))
      (should (rjd/caldav-active-p))
      (let ((rjd/caldav-accounts nil))
        (should-not (rjd/caldav-active-p)))
      (let ((rjd/caldav-accounts (list (rjd/caldav-test-icloud nil))))
        (should-not (rjd/caldav-active-p)))
      (let ((rjd/caldav-enabled nil))
        (should-not (rjd/caldav-active-p))))
    (let ((rjd/caldav-container-marker-files (list (locate-library "ert"))))
      (should-not (rjd/caldav-active-p))
      (let ((rjd/caldav-enabled t))
        (should (rjd/caldav-active-p))))))

(ert-deftest rjd/caldav-mode-sets-a-timer-only-when-active ()
  (let ((rjd/caldav-accounts nil)
        (rjd/caldav-enabled t))
    (unwind-protect
        (progn
          (rjd/caldav-mode 1)
          (should (memq #'rjd/caldav--fetch-on-agenda org-agenda-mode-hook))
          (should-not rjd/caldav--timer)
          (let ((rjd/caldav-accounts (list (rjd/caldav-test-icloud '("Home")))))
            (rjd/caldav-mode 1)
            (should (timerp rjd/caldav--timer))))
      (rjd/caldav-mode -1))
    (should-not rjd/caldav--timer)
    (should-not (memq #'rjd/caldav--fetch-on-agenda org-agenda-mode-hook))))

;;; rjd-caldav-test.el ends here
