;;; rjd-gcal-test.el --- Tests for the calendar's oama token  -*- lexical-binding: t; -*-

;;; Commentary:

;; What `oauth2-auto-access-token' hands back once `rjd/gcal-mode' is
;; on: the org-gcal provider's token comes from the mail command, every
;; other provider's from oauth2-auto as before.  No network, no oama,
;; no Docker: the mail command is replaced by `echo', and oauth2-auto's
;; own answer by a stub.
;;
;; Run from the checkout under test, with MAIN the main checkout, whose
;; elpa/ holds oauth2-auto and aio:
;;
;;   emacs --batch --init-directory=MAIN -L user-lisp \
;;     -l test/rjd-gcal-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'package)
(setq load-prefer-newer t)
(package-activate-all)
(require 'aio)
(require 'oauth2-auto)
(require 'rjd-gcal)

(defmacro rjd/gcal-test-with-mode (&rest body)
  "Run BODY with `rjd/gcal-mode' on and oauth2-auto's own answer stubbed.
The stub stands for oauth2-auto's original function, innermost, so
whatever reaches it shows as (ORIGINAL USERNAME PROVIDER)."
  (declare (indent 0))
  `(let ((stub (lambda (username provider)
                 (list 'original username provider)))
         (rjd/gcal-account "someone@example.com")
         (rjd-mail-command-prefix '("echo")))
     (advice-add 'oauth2-auto-access-token :override stub '((depth . 100)))
     (unwind-protect
         (progn (rjd/gcal-mode 1) ,@body)
       (rjd/gcal-mode -1)
       (advice-remove 'oauth2-auto-access-token stub))))

(ert-deftest rjd/gcal-org-gcal-token-comes-from-the-mail-command ()
  "The org-gcal provider gets a resolved promise of the command's output.
The prefix `echo' turns the command into its own output, so the token
shows the command run: oama's access subcommand for the account, put
through the mail command prefix."
  (rjd/gcal-test-with-mode
    (let ((promise (oauth2-auto-access-token "calendar-id" 'org-gcal)))
      (should (aio-promise-p promise))
      (should (aio-result promise))
      (should (equal (funcall (aio-result promise))
                     "oama access someone@example.com")))))

(ert-deftest rjd/gcal-other-providers-reach-oauth2-auto ()
  "Any provider but org-gcal is answered by oauth2-auto, untouched."
  (rjd/gcal-test-with-mode
    (should (equal (oauth2-auto-access-token "someone@example.com" 'google)
                   '(original "someone@example.com" google)))))

(ert-deftest rjd/gcal-failed-token-command-signals-where-awaited ()
  "A failing command gives a promise that signals, not a bogus token.
org-gcal waits on the promise, so the error reaches its fetch."
  (rjd/gcal-test-with-mode
    (let* ((rjd-mail-command-prefix '("false"))
           (promise (oauth2-auto-access-token "calendar-id" 'org-gcal)))
      (should (aio-result promise))
      (should-error (funcall (aio-result promise))))))

(provide 'rjd-gcal-test)

;;; rjd-gcal-test.el ends here
