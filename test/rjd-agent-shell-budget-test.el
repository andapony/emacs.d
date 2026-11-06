;;; rjd-agent-shell-budget-test.el --- ERT tests for rjd-agent-shell-budget  -*- lexical-binding: t -*-

;;; Commentary:
;; Run from the repository root with
;;
;;   emacs -Q --batch -l test/rjd-agent-shell-budget-test.el -f ert-run-tests-batch-and-exit
;;
;; `-Q' keeps the personal config out, and the file loads
;; rjd-agent-shell-budget from source, for the reason rjd-mail-test.el
;; gives.  agent-shell itself is not loaded.
;;
;; These cover the budget being kept per container: two containers can
;; be logged in as two Claude accounts, and a shell's header must show
;; its own container's figures, never the other's.  Each test gives
;; `agent-shell-command-prefix' a function reading a buffer-local
;; container name, as `rjd/container-agent-shell-prefix' reads the map,
;; and stubs `url-retrieve', so nothing touches the network, Docker or
;; a real login.

;;; Code:

(require 'ert)
(require 'cl-lib)

(eval-and-compile
  (load (expand-file-name
         "../user-lisp/rjd-agent-shell-budget.el"
         (file-name-directory
          (or load-file-name byte-compile-current-file buffer-file-name)))
        nil :nomessage :nosuffix))

(defvar agent-shell-command-prefix nil)


;;; Fixtures

(defvar-local rjd/budget-test-container nil
  "The container this test buffer's shell runs in.")

(defun rjd/budget-test-prefix (buffer)
  "The command prefix for BUFFER, as `rjd/container-agent-shell-prefix' gives."
  (list "docker" "exec" "-i"
        (or (buffer-local-value 'rjd/budget-test-container buffer)
            "claude-dev")))

(defun rjd/budget-test-credentials (token)
  "A credentials blob holding TOKEN, valid for another hour."
  (format "{\"claudeAiOauth\":{\"accessToken\":%S,\"expiresAt\":%d}}"
          token (* 1000 (+ (truncate (float-time)) 3600))))

(defun rjd/budget-test-body (five-hour seven-day)
  "A usage endpoint response body with FIVE-HOUR and SEVEN-DAY used."
  (format "{\"five_hour\":{\"utilization\":%d,\"resets_at\":null},\
\"seven_day\":{\"utilization\":%d,\"resets_at\":null}}"
          five-hour seven-day))

(defmacro rjd/budget-test-with-containers (&rest body)
  "Run BODY with fresh caches, and claude-dev and claude-cetos logged in.
Within BODY:
- `dev' and `cetos' are shell buffers in each container;
- the one credential source answers each container's prefix with a
  token named after it, and counts its calls in `reads';
- `requests' lists each `url-retrieve' as (TOKEN CALLBACK CBARGS),
  newest first, and nothing is fetched;
- `scheduled' lists each `run-at-time' as (FUNCTION ARGS), unrun;
- `rjd/agent-shell-budget--shells' gives the two shell buffers."
  (declare (indent 0) (debug t))
  `(let* ((rjd/agent-shell-budget--cache nil)
          (rjd/agent-shell-budget--token-cache nil)
          (rjd/agent-shell-budget--in-flight nil)
          (rjd/agent-shell-budget--tried nil)
          (agent-shell-command-prefix #'rjd/budget-test-prefix)
          (reads 0)
          (requests nil)
          (scheduled nil)
          (rjd/agent-shell-budget-credential-sources
           (list (lambda (prefix)
                   (setq reads (1+ reads))
                   (rjd/budget-test-credentials
                    (concat "token-" (car (last prefix)))))))
          (dev (generate-new-buffer " *dev shell*"))
          (cetos (generate-new-buffer " *cetos shell*")))
     (ignore reads requests scheduled)
     (with-current-buffer cetos (setq rjd/budget-test-container "claude-cetos"))
     (unwind-protect
         (cl-letf (((symbol-function 'url-retrieve)
                    (lambda (_url callback &optional cbargs &rest _)
                      (push (list (cdr (assoc "Authorization"
                                              url-request-extra-headers))
                                  callback cbargs)
                            requests)))
                   ((symbol-function 'run-at-time)
                    (lambda (_time _repeat function &rest args)
                      (push (list function args) scheduled)))
                   ((symbol-function 'rjd/agent-shell-budget--shells)
                    (lambda () (list dev cetos))))
           ,@body)
       (kill-buffer dev)
       (kill-buffer cetos))))

(defun rjd/budget-test-respond (request status body)
  "Answer REQUEST, from `requests', with HTTP STATUS and BODY."
  (with-current-buffer (generate-new-buffer " *usage response*")
    (insert (format "HTTP/1.1 %d OK\nContent-Type: application/json\n\n%s"
                    status body))
    (apply (nth 1 request) nil (nth 2 request))))

(defun rjd/budget-test-request-for (token requests)
  "The request in REQUESTS made with TOKEN."
  (seq-find (lambda (r) (equal (car r) (concat "Bearer " token))) requests))

(defun rjd/budget-test-string (buffer)
  "BUFFER's header budget string, without properties, or nil."
  (with-current-buffer buffer
    (when-let* ((string (rjd/agent-shell-budget-string)))
      (substring-no-properties string))))


;;; Tokens

(ert-deftest rjd/budget-reads-each-container-s-own-token ()
  "Each container's token is read through its own prefix, once."
  (rjd/budget-test-with-containers
    (should (equal (rjd/agent-shell-budget--token
                    (rjd/budget-test-prefix dev))
                   "token-claude-dev"))
    (should (equal (rjd/agent-shell-budget--token
                    (rjd/budget-test-prefix cetos))
                   "token-claude-cetos"))
    (should (= reads 2))
    ;; Both are cached now, each under its own container.
    (should (equal (rjd/agent-shell-budget--token
                    (rjd/budget-test-prefix dev))
                   "token-claude-dev"))
    (should (equal (rjd/agent-shell-budget--token
                    (rjd/budget-test-prefix cetos))
                   "token-claude-cetos"))
    (should (= reads 2))))

(ert-deftest rjd/budget-invalidating-a-token-leaves-the-other ()
  "Dropping one container's token leaves the other's cached."
  (rjd/budget-test-with-containers
    (let ((d (rjd/budget-test-prefix dev))
          (c (rjd/budget-test-prefix cetos)))
      (rjd/agent-shell-budget--token d)
      (rjd/agent-shell-budget--token c)
      (rjd/agent-shell-budget--invalidate-token c)
      (should (rjd/agent-shell-budget--cached-token d))
      (should-not (rjd/agent-shell-budget--cached-token c)))))

(ert-deftest rjd/budget-host-sources-answer-only-a-host-agent ()
  "The host's credentials file is read for an agent on the host alone.
For a container's shell it says nothing, since the host may be logged
in as another account."
  (let ((rjd/agent-shell-budget-credentials-file
         (make-temp-file "rjd-budget-credentials" nil ".json"
                         (rjd/budget-test-credentials "host-token"))))
    (unwind-protect
        (progn
          (should (string-match-p
                   "host-token"
                   (rjd/agent-shell-budget--credentials-from-file nil)))
          (should-not (rjd/agent-shell-budget--credentials-from-file
                       '("docker" "exec" "-i" "claude-cetos")))
          (should-not (rjd/agent-shell-budget--credentials-from-keychain
                       '("docker" "exec" "-i" "claude-cetos"))))
      (delete-file rjd/agent-shell-budget-credentials-file))))

(ert-deftest rjd/budget-command-prefix-source-uses-the-prefix-given ()
  "The container source runs its command through the prefix it is given.
Here the prefix is `env', so the command runs on this host, reading a
file named by the variable it sets."
  (let* ((file (make-temp-file "rjd-budget-credentials" nil ".json"
                               (rjd/budget-test-credentials "inside")))
         (rjd/agent-shell-budget-credentials-file file))
    (unwind-protect
        (progn
          (should (string-match-p
                   "inside"
                   (rjd/agent-shell-budget--credentials-from-command-prefix
                    '("env" "X=1"))))
          (should-not (rjd/agent-shell-budget--credentials-from-command-prefix
                       nil)))
      (delete-file file))))


;;; Fetching and the header

(ert-deftest rjd/budget-refresh-fetches-each-container-once ()
  "The timer's refresh fetches every open shell's container, each with
its own token, however many shells run in it."
  (rjd/budget-test-with-containers
    (let ((second-dev (generate-new-buffer " *dev shell 2*")))
      (unwind-protect
          (cl-letf (((symbol-function 'rjd/agent-shell-budget--shells)
                     (lambda () (list dev cetos second-dev))))
            (rjd/agent-shell-budget-refresh)
            (should (= (length requests) 2))
            (should (rjd/budget-test-request-for "token-claude-dev" requests))
            (should (rjd/budget-test-request-for "token-claude-cetos" requests)))
        (kill-buffer second-dev)))))

(ert-deftest rjd/budget-each-header-shows-its-own-container ()
  "Each shell's header shows its own container's figures, whichever
answered first, and whichever buffer was current when the timer fired."
  (rjd/budget-test-with-containers
    (with-temp-buffer                   ; not a shell: the timer's buffer
      (rjd/agent-shell-budget-refresh))
    (rjd/budget-test-respond
     (rjd/budget-test-request-for "token-claude-cetos" requests)
     200 (rjd/budget-test-body 90 50))
    (should (equal (rjd/budget-test-string cetos) "5h 90% · 7d 50%"))
    (should-not (rjd/budget-test-string dev))
    (rjd/budget-test-respond
     (rjd/budget-test-request-for "token-claude-dev" requests)
     200 (rjd/budget-test-body 10 20))
    (should (equal (rjd/budget-test-string dev) "5h 10% · 7d 20%"))
    (should (equal (rjd/budget-test-string cetos) "5h 90% · 7d 50%"))))

(ert-deftest rjd/budget-a-pending-fetch-blocks-only-its-container ()
  "An outstanding fetch for one container doesn't hold up the other's."
  (rjd/budget-test-with-containers
    (rjd/agent-shell-budget--fetch (rjd/budget-test-prefix cetos))
    (rjd/agent-shell-budget--fetch (rjd/budget-test-prefix cetos))
    (should (= (length requests) 1))
    (rjd/agent-shell-budget--fetch (rjd/budget-test-prefix dev))
    (should (= (length requests) 2))
    ;; The answer clears its own container's flag, and only that.
    (rjd/budget-test-respond
     (rjd/budget-test-request-for "token-claude-cetos" requests)
     200 (rjd/budget-test-body 1 1))
    (should-not (rjd/agent-shell-budget--fetch-pending-p
                 (rjd/budget-test-prefix cetos)))
    (should (rjd/agent-shell-budget--fetch-pending-p
             (rjd/budget-test-prefix dev)))))

(ert-deftest rjd/budget-a-401-drops-only-its-container-s-token ()
  "A refused token is dropped for its own container, not the other's."
  (rjd/budget-test-with-containers
    (rjd/agent-shell-budget-refresh)
    (rjd/budget-test-respond
     (rjd/budget-test-request-for "token-claude-cetos" requests)
     401 "{}")
    (should-not (rjd/agent-shell-budget--cached-token
                 (rjd/budget-test-prefix cetos)))
    (should (rjd/agent-shell-budget--cached-token
             (rjd/budget-test-prefix dev)))))

(ert-deftest rjd/budget-first-header-starts-its-container-s-fetch ()
  "A container's first header schedules its fetch, once.
The fetch runs from a timer, not on the redisplay path."
  (rjd/budget-test-with-containers
    (should-not (rjd/budget-test-string cetos))
    (should-not (rjd/budget-test-string cetos))
    (should (equal scheduled
                   `((rjd/agent-shell-budget--fetch
                      (,(rjd/budget-test-prefix cetos))))))
    (should-not requests)
    (should-not (rjd/budget-test-string dev))
    (should (= (length scheduled) 2))))

(ert-deftest rjd/budget-a-list-prefix-is-one-container ()
  "A prefix given as a list, not a function, is one container for all."
  (rjd/budget-test-with-containers
    (let ((agent-shell-command-prefix '("docker" "exec" "-i" "claude-dev")))
      (rjd/agent-shell-budget-refresh)
      (should (= (length requests) 1))
      (rjd/budget-test-respond (car requests) 200 (rjd/budget-test-body 5 6))
      (should (equal (rjd/budget-test-string dev) "5h 5% · 7d 6%"))
      (should (equal (rjd/budget-test-string cetos) "5h 5% · 7d 6%")))))

;;; rjd-agent-shell-budget-test.el ends here
