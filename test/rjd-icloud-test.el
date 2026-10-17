;;; rjd-icloud-test.el --- Tests for fetching iCloud calendars into org  -*- lexical-binding: t; -*-

;;; Commentary:

;; Fetching, end to end, against responses recorded from iCloud by
;; test/icloud-probe.sh and sanitised (fixtures/icloud/), with
;; `rjd/icloud-request-function' replaced by a replay of them -- so no
;; network, no account and no password.  probe-expanded.xml is iCloud's
;; expansion of a weekly event with one occurrence moved and one
;; deleted; cases-expanded.xml is made by hand in the same shape, for
;; what the probe did not cover.
;;
;; Times are checked in a fixed local zone, set by
;; `rjd/icloud-test-in-zone', so the results do not depend on the
;; machine's.
;;
;; Run from the repository root with
;;
;;   emacs -Q --batch -L user-lisp -l test/rjd-icloud-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'dom)
(setq load-prefer-newer t)
(require 'rjd-icloud)

(defconst rjd/icloud-test-fixtures
  (expand-file-name "fixtures/icloud/"
                    (file-name-directory
                     (or load-file-name buffer-file-name)))
  "The directory of recorded and hand-made CalDAV responses.")

(defconst rjd/icloud-test-home
  "https://p01-caldav.icloud.com:443/1234567890/calendars/"
  "The calendar home set in the recorded responses.")

(defconst rjd/icloud-test-probe-url
  "https://p01-caldav.icloud.com/1234567890/calendars/PROBE-CALENDAR/"
  "The Probe calendar's URL in the recorded responses.")

(defun rjd/icloud-test-dom (fixture)
  "The parsed XML of FIXTURE, a file name in `rjd/icloud-test-fixtures'."
  (with-temp-buffer
    (insert-file-contents (expand-file-name fixture rjd/icloud-test-fixtures))
    (libxml-parse-xml-region (point-min) (point-max))))

(defmacro rjd/icloud-test-in-zone (zone &rest body)
  "Run BODY with Emacs's local time zone ZONE, a TZ string."
  (declare (indent 1))
  (let ((old (make-symbol "old")))
    `(let ((,old (getenv "TZ")))
       (unwind-protect
           (progn (set-time-zone-rule ,zone) ,@body)
         (set-time-zone-rule ,old)))))

(defvar rjd/icloud-test-requests nil
  "The requests the replay was asked for, newest first.
Each is (METHOD URL AUTHORIZATION).")

(defun rjd/icloud-test-replay (responses)
  "A request function answering from RESPONSES.
RESPONSES is an alist of ((METHOD . URL) . FIXTURE); FIXTURE nil, or a
request missing from it, answers with an error, as a failed request
would.  Each request is recorded in `rjd/icloud-test-requests'."
  (lambda (method url _depth _body authorization callback)
    (push (list method url authorization) rjd/icloud-test-requests)
    (if-let* ((fixture (alist-get (cons method url) responses nil nil #'equal)))
        (funcall callback nil (rjd/icloud-test-dom fixture))
      (funcall callback (format "%s %s: 404" method url) nil))))

(defconst rjd/icloud-test-discovery
  `((("PROPFIND" . "https://caldav.icloud.com/") . "principal.xml")
    (("PROPFIND" . "https://caldav.icloud.com/1234567890/principal/")
     . "home-set.xml")
    (("PROPFIND" . ,rjd/icloud-test-home) . "calendars.xml"))
  "The replies that discover the account's calendars.")

(defmacro rjd/icloud-test-fetching (calendars responses &rest body)
  "Run BODY with `rjd/icloud-mode' state fresh and requests replayed.
CALENDARS is `rjd/icloud-calendars'; RESPONSES are added to the
discovery replies, see `rjd/icloud-test-replay'.  The calendar
directory is a fresh temporary one, `dir' in BODY, and the password
comes from a stub, so auth-source is never asked."
  (declare (indent 2))
  `(let* ((dir (file-name-as-directory (make-temp-file "rjd-icloud" t)))
          (rjd/icloud-directory dir)
          (rjd/icloud-account "user@example.com")
          (rjd/icloud-calendars ,calendars)
          (rjd/icloud-enabled t)
          (rjd/icloud--failing nil)
          (rjd/icloud--fetching nil)
          (rjd/icloud-test-requests nil)
          (rjd/icloud-request-function
           (rjd/icloud-test-replay (append ,responses rjd/icloud-test-discovery)))
          (messages nil))
     (cl-letf (((symbol-function 'rjd/icloud--password)
                (lambda (&optional _may-prompt) "app-specific"))
               ((symbol-function 'message)
                (lambda (format &rest args)
                  (when format (push (apply #'format format args) messages)))))
       (unwind-protect
           (rjd/icloud-test-in-zone "America/Los_Angeles"
             ,@body)
         (delete-directory dir t)))))

(defun rjd/icloud-test-file (dir name)
  "The text of calendar NAME's file in DIR, or nil if there is none."
  (let ((file (expand-file-name (rjd/icloud-file-name name) dir)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string)))))

(defconst rjd/icloud-test-probe-report
  `((("REPORT" . ,rjd/icloud-test-probe-url) . "probe-expanded.xml"))
  "The reply to the Probe calendar's REPORT.")


;;; File names

(ert-deftest rjd/icloud-file-name-is-a-slug-of-the-display-name ()
  (should (equal (rjd/icloud-file-name "Home") "icloud-home.org"))
  (should (equal (rjd/icloud-file-name "Partner/Errands & Appt's")
                 "icloud-partner-errands-appts.org"))
  (should (equal (rjd/icloud-file-name "Reminders ⚠️") "icloud-reminders.org"))
  (should (equal (rjd/icloud-file-name "Trips!") "icloud-trips.org"))
  (should (equal (rjd/icloud-file-name "Shared 2018") "icloud-shared-2018.org")))


;;; Discovery

(ert-deftest rjd/icloud-discovery-finds-calendars-by-display-name ()
  "Every calendar is found, by its decoded name, at its absolute URL.
The home collection, which has a display name of its own, and the
inbox, outbox and notification collections are not calendars."
  (rjd/icloud-test-fetching nil nil
    (let (result)
      (rjd/icloud--discover "auth" (lambda (err calendars)
                                     (setq result (list err calendars))))
      (should-not (car result))
      (let ((calendars (cadr result)))
        (should (equal (alist-get "Probe" calendars nil nil #'equal)
                       rjd/icloud-test-probe-url))
        (should (alist-get "Partner/Errands & Appt's" calendars nil nil #'equal))
        (should (alist-get "Reminders ⚠️" calendars nil nil #'equal))
        (should-not (alist-get "Example User" calendars nil nil #'equal))
        (should (= (length calendars) 15))))))

(ert-deftest rjd/icloud-discovery-reports-a-failed-request ()
  (rjd/icloud-test-fetching nil nil
    (let ((rjd/icloud-request-function (rjd/icloud-test-replay nil))
          result)
      (rjd/icloud--discover "auth" (lambda (err calendars)
                                     (setq result (list err calendars))))
      (should (stringp (car result)))
      (should-not (cadr result)))))


;;; Events

(defun rjd/icloud-test-entries (fixture)
  "The org entries for the events in FIXTURE, as strings."
  (mapcar #'rjd/icloud--org-entry
          (rjd/icloud--events (rjd/icloud-test-dom fixture)
                              "user@example.com")))

(ert-deftest rjd/icloud-probe-occurrences-are-each-an-entry ()
  "iCloud's expansion: five occurrences, the moved one at its new time."
  (rjd/icloud-test-in-zone "America/Los_Angeles"
    (should (equal (rjd/icloud-test-entries "probe-expanded.xml")
                   '("* Probe weekly\n<2026-10-19 Mon 10:00-11:00>\n"
                     "* Probe weekly\n<2026-10-26 Mon 10:00-11:00>\n"
                     "* Probe weekly\n<2026-11-02 Mon 14:00-15:00>\n"
                     "* Probe weekly\n<2026-11-16 Mon 10:00-11:00>\n"
                     "* Probe weekly\n<2026-11-23 Mon 10:00-11:00>\n")))))

(ert-deftest rjd/icloud-times-are-converted-from-the-event-s-zone ()
  "A TZID without a VTIMEZONE is read as the named zone, not as local.
iCloud's expansion sends no VTIMEZONE.  In London, 10:00 in Los Angeles
is 18:00 while both keep summer time, and 14:00 is 22:00 once both
have left it."
  (rjd/icloud-test-in-zone "Europe/London"
    (let ((entries (rjd/icloud-test-entries "probe-expanded.xml")))
      (should (equal (nth 0 entries)
                     "* Probe weekly\n<2026-10-19 Mon 18:00-19:00>\n"))
      (should (equal (nth 2 entries)
                     "* Probe weekly\n<2026-11-02 Mon 22:00-23:00>\n")))))

(ert-deftest rjd/icloud-cases-make-the-expected-entries ()
  "Cancelled and declined events are dropped; the rest are in order."
  (rjd/icloud-test-in-zone "America/Los_Angeles"
    (should (equal (rjd/icloud-test-entries "cases-expanded.xml")
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

(ert-deftest rjd/icloud-floating-and-unknown-zones-are-local ()
  "A floating time, and one in a zone the system does not know, are local.
Read as UTC, which is what `encode-time' does with an unknown zone,
the 08:00 call would move."
  (rjd/icloud-test-in-zone "Europe/London"
    (let ((entries (rjd/icloud-test-entries "cases-expanded.xml")))
      (should (member "* Floating alarm\n<2026-10-27 Tue 07:00>\n" entries))
      (should (member "* Call & review\n<2026-10-28 Wed 08:00-08:30>\n"
                      entries)))))

(ert-deftest rjd/icloud-unparsable-data-yields-nothing-quietly ()
  "Calendar data the parser rejects gives no events and no warning."
  (when (get-buffer "*Warnings*") (kill-buffer "*Warnings*"))
  (should-not (rjd/icloud--calendar-events
               "BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART:garbage\n"
               "user@example.com"))
  (should-not (get-buffer "*Warnings*")))

(ert-deftest rjd/icloud-a-heading-like-summary-stays-one-heading ()
  (should (equal (rjd/icloud--org-entry
                  (list :summary "Line one\nline two" :start '(10 20 2026)))
                 "* Line one line two\n<2026-10-20 Tue>\n")))


;;; Fetching

(ert-deftest rjd/icloud-fetch-writes-the-calendar-file ()
  (rjd/icloud-test-fetching '("Probe") rjd/icloud-test-probe-report
    (rjd/icloud-fetch)
    (let ((text (rjd/icloud-test-file dir "Probe")))
      (should (string-prefix-p "#+CATEGORY: Probe\n#+FETCHED: [" text))
      (should (= (with-temp-buffer
                   (insert text)
                   (how-many "^\\* Probe weekly$" (point-min) (point-max)))
                 5))
      (should (string-search "<2026-11-02 Mon 14:00-15:00>" text)))
    (should-not rjd/icloud--fetching)
    (should-not messages)))

(ert-deftest rjd/icloud-fetch-only-reads ()
  "Every request is a PROPFIND or a REPORT, with the account's Basic auth."
  (rjd/icloud-test-fetching '("Probe") rjd/icloud-test-probe-report
    (rjd/icloud-fetch)
    (should rjd/icloud-test-requests)
    (dolist (request rjd/icloud-test-requests)
      (should (member (car request) '("PROPFIND" "REPORT")))
      (should (equal (nth 2 request)
                     (concat "Basic "
                             (base64-encode-string
                              "user@example.com:app-specific" t)))))))

(ert-deftest rjd/icloud-fetch-rewrites-the-whole-file ()
  "Whatever was in the file before is gone after a fetch."
  (rjd/icloud-test-fetching '("Probe") rjd/icloud-test-probe-report
    (let ((file (expand-file-name "icloud-probe.org" dir)))
      (write-region "* A note typed here\n" nil file nil 'silent)
      (rjd/icloud-fetch)
      (should-not (string-search "A note typed here"
                                 (rjd/icloud-test-file dir "Probe"))))))

(ert-deftest rjd/icloud-fetch-updates-a-buffer-visiting-the-file ()
  (rjd/icloud-test-fetching '("Probe") rjd/icloud-test-probe-report
    (let* ((file (expand-file-name "icloud-probe.org" dir))
           (buffer (progn (write-region "old\n" nil file nil 'silent)
                          (find-file-noselect file))))
      (unwind-protect
          (progn
            (rjd/icloud-fetch)
            (with-current-buffer buffer
              (should (string-prefix-p "#+CATEGORY: Probe" (buffer-string)))
              (should-not (buffer-modified-p))))
        (kill-buffer buffer)))))

(ert-deftest rjd/icloud-failed-fetch-keeps-the-last-good-file ()
  (rjd/icloud-test-fetching '("Probe") nil
    (let ((file (expand-file-name "icloud-probe.org" dir)))
      (write-region "#+CATEGORY: Probe\n* Last good\n" nil file nil 'silent)
      (rjd/icloud-fetch)
      (should (string-search "Last good" (rjd/icloud-test-file dir "Probe")))
      (should (= (length messages) 1))
      (should (string-search "Probe" (car messages))))))

(ert-deftest rjd/icloud-failures-are-reported-once-per-run ()
  "A failure is reported; the same run of failures is not again; a
failure after a success is."
  (rjd/icloud-test-fetching '("Probe") nil
    (rjd/icloud-fetch)
    (rjd/icloud-fetch)
    (should (= (length messages) 1))
    (let ((rjd/icloud-request-function
           (rjd/icloud-test-replay (append rjd/icloud-test-probe-report
                                           rjd/icloud-test-discovery))))
      (rjd/icloud-fetch))
    (should (= (length messages) 1))
    (rjd/icloud-fetch)
    (should (= (length messages) 2))))

(ert-deftest rjd/icloud-unknown-calendar-name-is-reported ()
  "A name no calendar has is reported, and the others are still fetched."
  (rjd/icloud-test-fetching '("Probe" "Renamed") rjd/icloud-test-probe-report
    (rjd/icloud-fetch)
    (should (rjd/icloud-test-file dir "Probe"))
    (should-not (rjd/icloud-test-file dir "Renamed"))
    (should (= (length messages) 1))
    (should (string-search "Renamed" (car messages)))))

(ert-deftest rjd/icloud-colliding-file-names-are-both-refused ()
  (rjd/icloud-test-fetching '("Probe" "probe!") rjd/icloud-test-probe-report
    (rjd/icloud-fetch)
    (should-not (rjd/icloud-test-file dir "Probe"))
    (should-not (seq-some (lambda (request) (equal (car request) "REPORT"))
                          rjd/icloud-test-requests))
    (should (= (length messages) 1))
    (should (string-search "icloud-probe.org" (car messages)))))

(ert-deftest rjd/icloud-fetch-without-a-password-does-nothing ()
  "No password, as from a timer that may not prompt: no request, no message."
  (rjd/icloud-test-fetching '("Probe") rjd/icloud-test-probe-report
    (cl-letf (((symbol-function 'rjd/icloud--password) #'ignore))
      (rjd/icloud-fetch))
    (should-not rjd/icloud-test-requests)
    (should-not messages)
    (should-not rjd/icloud--fetching)))

(ert-deftest rjd/icloud-fetch-while-fetching-does-nothing ()
  (rjd/icloud-test-fetching '("Probe") rjd/icloud-test-probe-report
    (let ((rjd/icloud--fetching t))
      (rjd/icloud-fetch))
    (should-not rjd/icloud-test-requests)))


;;; url.el's responses

(defun rjd/icloud-test-url-response (status code body)
  "What CALLBACK gets for a url.el response of CODE and BODY, with STATUS.
And whether the response buffer survived, which it should not."
  (let ((buffer (generate-new-buffer " *rjd-icloud-http*"))
        result)
    (with-current-buffer buffer
      (insert (format "HTTP/1.1 %s Whatever\r\nContent-Type: text/xml\r\n\r\n"
                      code))
      (setq-local url-http-end-of-headers (point))
      (setq-local url-http-response-status code)
      (insert (encode-coding-string body 'utf-8))
      (set-buffer-multibyte nil)
      (rjd/icloud--url-response status "PROPFIND" "https://x/"
                                (lambda (err dom) (setq result (list err dom)))))
    (append result (list (buffer-live-p buffer)))))

(ert-deftest rjd/icloud-url-response-multistatus-is-parsed ()
  (pcase-let ((`(,err ,dom ,alive)
               (rjd/icloud-test-url-response
                nil 207
                "<multistatus xmlns=\"DAV:\"><response><displayname>Café ⚠️</displayname></response></multistatus>")))
    (should-not err)
    (should (equal (dom-inner-text (car (dom-by-tag dom 'displayname)))
                   "Café ⚠️"))
    (should-not alive)))

(ert-deftest rjd/icloud-url-response-anything-else-is-an-error ()
  (pcase-let ((`(,err ,dom ,alive)
               (rjd/icloud-test-url-response nil 401 "Unauthorized")))
    (should (string-search "HTTP 401" err))
    (should-not dom)
    (should-not alive))
  (pcase-let ((`(,err ,dom ,_)
               (rjd/icloud-test-url-response
                '(:error (error "connection refused")) 207 "")))
    (should (string-search "connection refused" err))
    (should-not dom)))


;;; Password

(ert-deftest rjd/icloud-quiet-auth-sources-leave-out-encrypted-files ()
  "A fetch that may not prompt never reads an encrypted source."
  (let ((auth-sources '("~/.authinfo.gpg" "~/.authinfo"
                        (:source "~/x.gpg") macos-keychain-internet)))
    (should (equal (rjd/icloud--quiet-auth-sources)
                   '("~/.authinfo" macos-keychain-internet)))))


;;; Where it runs

(ert-deftest rjd/icloud-active-p-needs-account-calendars-and-no-container ()
  (let ((rjd/icloud-account "user@example.com")
        (rjd/icloud-calendars '("Home"))
        (rjd/icloud-enabled 'auto))
    (let ((rjd/icloud-container-marker-files '("/nonexistent-rjd-icloud")))
      (should (rjd/icloud-active-p))
      (let ((rjd/icloud-account nil))
        (should-not (rjd/icloud-active-p)))
      (let ((rjd/icloud-calendars nil))
        (should-not (rjd/icloud-active-p)))
      (let ((rjd/icloud-enabled nil))
        (should-not (rjd/icloud-active-p))))
    (let ((rjd/icloud-container-marker-files (list (locate-library "ert"))))
      (should-not (rjd/icloud-active-p))
      (let ((rjd/icloud-enabled t))
        (should (rjd/icloud-active-p))))))

(ert-deftest rjd/icloud-mode-sets-a-timer-only-when-active ()
  (let ((rjd/icloud-account nil)
        (rjd/icloud-enabled t))
    (unwind-protect
        (progn
          (rjd/icloud-mode 1)
          (should (memq #'rjd/icloud--fetch-on-agenda org-agenda-mode-hook))
          (should-not rjd/icloud--timer)
          (let ((rjd/icloud-account "user@example.com")
                (rjd/icloud-calendars '("Home")))
            (rjd/icloud-mode 1)
            (should (timerp rjd/icloud--timer))))
      (rjd/icloud-mode -1))
    (should-not rjd/icloud--timer)
    (should-not (memq #'rjd/icloud--fetch-on-agenda org-agenda-mode-hook))))

;;; rjd-icloud-test.el ends here
