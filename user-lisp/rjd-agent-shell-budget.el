;;; rjd-agent-shell-budget.el --- Show Claude rate-limit budget in the agent-shell header  -*- lexical-binding: t -*-

;;; Commentary:
;; Adds the remaining Claude subscription budget (5-hour and weekly windows)
;; to the `agent-shell' header, beside the model, mode and context indicator.
;;
;; agent-shell has no budget concept of its own: the ACP `usage_update'
;; notification it consumes carries only context tokens and cost, so the
;; numbers have to be fetched separately from the same endpoint that backs
;; Claude Code's own /usage command.
;;
;; Enable with `rjd/agent-shell-budget-mode'.
;;
;; CAVEAT: this leans on two private interfaces and will break without
;; warning.  It advises `agent-shell--make-header-model' to populate the
;; header model's `:status' field, which agent-shell defines but never
;; fills in from the top-level updater, and it calls the undocumented
;; https://api.anthropic.com/api/oauth/usage endpoint.  Both are internal.
;; If the header loses the budget after an agent-shell or Claude Code
;; upgrade, this file is the first place to look.

;;; Code:

(require 'iso8601)
(require 'seq)
(require 'json)
(require 'map)
(require 'url)

(defvar agent-shell-command-prefix)
;; Defined below by `define-minor-mode', but read by the diagnostics above it.
(defvar rjd/agent-shell-budget-mode)
(declare-function agent-shell--update-header-and-mode-line "agent-shell")


;;; Customization

(defgroup rjd/agent-shell-budget nil
  "Claude rate-limit budget in the agent-shell header."
  :group 'agent-shell)

(defcustom rjd/agent-shell-budget-refresh-interval 300
  "Seconds between budget refreshes.
The underlying utilization figures move slowly, so there is little point
polling hard.  Applies at `rjd/agent-shell-budget-mode' activation."
  :type 'natnum
  :group 'rjd/agent-shell-budget)

(defcustom rjd/agent-shell-budget-show-reset 'both
  "Which reset times to append to the header, as a local clock time.
`both' shows the session and weekly windows, `five-hour' only the session
one, nil neither.  The weekly reset carries its weekday, the session one
does not, since it is always within five hours.

Worth dropping to `five-hour' on a narrow window: agent-shell clips the
header to the window width, so the weekly reset is the first thing lost."
  :type '(choice (const :tag "Five-hour window only" five-hour)
                 (const :tag "Both windows" both)
                 (const :tag "Neither" nil))
  :group 'rjd/agent-shell-budget)

(defcustom rjd/agent-shell-budget-credentials-file "~/.claude/.credentials.json"
  "Path to the Claude Code credentials file.
Read on the Emacs host first, then inside the container when
`rjd/agent-shell-budget-use-command-prefix' is enabled, so it is left
unexpanded and resolved separately on each side."
  :type 'string
  :group 'rjd/agent-shell-budget)

(defcustom rjd/agent-shell-budget-keychain-service "Claude Code-credentials"
  "Keychain service name holding the Claude Code OAuth token, on macOS.
Claude Code builds this name at runtime, so it is a best guess; if the
budget never appears on a macOS host login, check Keychain Access."
  :type 'string
  :group 'rjd/agent-shell-budget)

(defcustom rjd/agent-shell-budget-use-command-prefix t
  "Whether to look for the OAuth token via `agent-shell-command-prefix'.
When the agent runs in a container, the subscription login lives in the
container's volume rather than on the Emacs host, so the token has to be
read through the same prefix agent-shell uses to reach the agent.  Tried
after the host credentials file and Keychain, both of which win when the
host happens to be logged in too."
  :type 'boolean
  :group 'rjd/agent-shell-budget)


;;; Credentials

(defun rjd/agent-shell-budget--parse-credentials (json-string)
  "Return (TOKEN . EXPIRY) from JSON-STRING, or nil if unusable.
JSON-STRING is a Claude Code credentials blob.  EXPIRY is a Lisp time, or
nil when the blob does not say.

An expired token is rejected rather than returned, so that a source which
nobody refreshes falls through to one that is live.  This matters when
the agent runs in a container: Claude Code renews the token wherever it
actually runs, leaving any copy on the Emacs host to go stale within
hours, and a stale copy earning a 401 is indistinguishable from a broken
endpoint at the point where the fetch gives up."
  (ignore-errors
    (let* ((oauth (map-elt (json-parse-string json-string :object-type 'alist)
                           'claudeAiOauth))
           (token (map-elt oauth 'accessToken))
           ;; expiresAt is milliseconds since the epoch.
           (expires (and (numberp (map-elt oauth 'expiresAt))
                         (seconds-to-time (/ (map-elt oauth 'expiresAt) 1000.0)))))
      (when (and (stringp token)
                 (or (null expires) (time-less-p nil expires)))
        (cons token expires)))))

(defun rjd/agent-shell-budget--credentials-from-file ()
  "Return the credentials blob from the file on this host, or nil."
  (let ((file (expand-file-name rjd/agent-shell-budget-credentials-file)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string)))))

(defun rjd/agent-shell-budget--credentials-from-keychain ()
  "Return the credentials blob from the macOS login Keychain, or nil."
  (when (eq system-type 'darwin)
    (with-temp-buffer
      (when (zerop (call-process "security" nil t nil
                                 "find-generic-password"
                                 "-s" rjd/agent-shell-budget-keychain-service
                                 "-w"))
        (buffer-string)))))

(defun rjd/agent-shell-budget--remote-path (path)
  "Return PATH as a shell word safe to expand on the far side of a prefix.
`shell-quote-argument' escapes a leading tilde, which would send the
remote shell looking for a literal \"~\" directory, so expansion is handed
to $HOME there rather than to this host's idea of home."
  (if (string-prefix-p "~/" path)
      (concat "\"$HOME\"/" (shell-quote-argument (substring path 2)))
    (shell-quote-argument path)))

(defun rjd/agent-shell-budget--credentials-from-command-prefix ()
  "Return the credentials blob read through `agent-shell-command-prefix'.
Runs `cat' on the credentials file wherever the prefix lands, which for a
docker prefix is inside the container holding the subscription login.
Nil when the prefix is unset, disabled, or fails.

This spawns a process synchronously, so it is the expensive source; see
`rjd/agent-shell-budget--token' for how often it actually runs."
  (when-let* ((rjd/agent-shell-budget-use-command-prefix)
              ((boundp 'agent-shell-command-prefix))
              (prefix agent-shell-command-prefix)
              (program (car prefix)))
    (with-temp-buffer
      (when (zerop (apply #'call-process program nil t nil
                          (append (cdr prefix)
                                  (list "sh" "-c"
                                        (format "cat %s"
                                                (rjd/agent-shell-budget--remote-path
                                                 rjd/agent-shell-budget-credentials-file))))))
        (buffer-string)))))

(defcustom rjd/agent-shell-budget-credential-sources
  '(rjd/agent-shell-budget--credentials-from-file
    rjd/agent-shell-budget--credentials-from-keychain
    rjd/agent-shell-budget--credentials-from-command-prefix)
  "Functions tried in order for the credentials blob, first usable wins.
Each takes no arguments and returns the contents of a Claude Code
credentials JSON blob, or nil.  A blob whose token has expired is
skipped, so a source that nobody refreshes falls through rather than
shadowing a live one; reorder this only to skip a source outright."
  :type '(repeat function)
  :group 'rjd/agent-shell-budget)

(defvar rjd/agent-shell-budget--token-cache nil
  "Cached (TOKEN . EXPIRY), or nil when the token must be read again.")

(defconst rjd/agent-shell-budget--token-margin 300
  "Seconds before expiry at which a cached token is treated as spent.
Covers the gap between deciding to use a token and the request landing.")

(defun rjd/agent-shell-budget--cached-token ()
  "Return the cached token if it is still comfortably valid, else nil."
  (when-let* ((cached rjd/agent-shell-budget--token-cache)
              (expiry (cdr cached)))
    (and (time-less-p (time-add nil rjd/agent-shell-budget--token-margin) expiry)
         (car cached))))

(defun rjd/agent-shell-budget--invalidate-token ()
  "Drop the cached token so the next fetch reads the sources again.
Called when the endpoint rejects the token, which is the one thing that
proves a token is dead ahead of its stated expiry."
  (setq rjd/agent-shell-budget--token-cache nil))

(defun rjd/agent-shell-budget--read-token ()
  "Read a token from `rjd/agent-shell-budget-credential-sources', or nil.
Errors are swallowed at each step so a missing or unreachable source just
falls through to the next."
  (when-let* ((credentials
               (seq-some (lambda (source)
                           (when-let* ((blob (ignore-errors (funcall source))))
                             (rjd/agent-shell-budget--parse-credentials blob)))
                         rjd/agent-shell-budget-credential-sources)))
    (setq rjd/agent-shell-budget--token-cache credentials)
    (car credentials)))

(defun rjd/agent-shell-budget--token ()
  "Return the Claude Code OAuth access token, or nil if it cannot be found.

Prefers the cached token, since the sources are not all cheap: reaching
the container costs a synchronous process spawn, and on a five-minute
refresh that would freeze Emacs briefly all day for a value that only
changes every few hours.  Tokens carry their own expiry, so the cache is
held until then and dropped early only on a 401."
  (or (rjd/agent-shell-budget--cached-token)
      (rjd/agent-shell-budget--read-token)))


;;; Fetching

(defvar rjd/agent-shell-budget--cache nil
  "Latest budget figures, or nil before the first successful fetch.
An alist with `:five-hour' and `:seven-day' percentages used, and
`:five-hour-resets' and `:seven-day-resets' Lisp timestamps.")

(defvar rjd/agent-shell-budget--timer nil
  "Repeating timer driving `rjd/agent-shell-budget-refresh'.")

(defvar rjd/agent-shell-budget--in-flight nil
  "Time the outstanding fetch started, or nil when none is.
Stops a slow request from stacking up behind the timer.  Held as a
timestamp rather than a flag so a request whose callback never fires --
which would otherwise wedge the flag on and silently disable every later
refresh -- can be abandoned once it is clearly too old.")

(defconst rjd/agent-shell-budget--fetch-timeout 120
  "Seconds after which an outstanding fetch is presumed dead.")

(defconst rjd/agent-shell-budget--endpoint
  "https://api.anthropic.com/api/oauth/usage"
  "Endpoint reporting subscription rate-limit windows.
Undocumented: this is what Claude Code's own /usage command calls.")

(defun rjd/agent-shell-budget--fetch-pending-p ()
  "Return non-nil if a fetch is outstanding and not yet presumed dead."
  (and rjd/agent-shell-budget--in-flight
       (< (float-time (time-subtract nil rjd/agent-shell-budget--in-flight))
          rjd/agent-shell-budget--fetch-timeout)))

(defun rjd/agent-shell-budget--number (value)
  "Return VALUE if it is a number, else nil.
The usage endpoint returns JSON null for windows that do not apply to the
account, and `json-parse-string' renders that as `:null' rather than nil."
  (and (numberp value) value))

(defun rjd/agent-shell-budget--parse-timestamp (string)
  "Return STRING, an ISO 8601 timestamp, as a Lisp time value, or nil."
  (and (stringp string)
       (ignore-errors (encode-time (iso8601-parse string)))))

(defun rjd/agent-shell-budget--parse (json-string)
  "Return a budget cache alist parsed from JSON-STRING, or nil.
JSON-STRING is a response body from the OAuth usage endpoint."
  (when-let* ((body (ignore-errors
                      (json-parse-string json-string :object-type 'alist)))
              (five-hour (map-elt body 'five_hour))
              (seven-day (map-elt body 'seven_day)))
    `((:five-hour . ,(rjd/agent-shell-budget--number
                      (map-elt five-hour 'utilization)))
      (:seven-day . ,(rjd/agent-shell-budget--number
                      (map-elt seven-day 'utilization)))
      (:five-hour-resets . ,(rjd/agent-shell-budget--parse-timestamp
                             (map-elt five-hour 'resets_at)))
      (:seven-day-resets . ,(rjd/agent-shell-budget--parse-timestamp
                             (map-elt seven-day 'resets_at))))))

(defun rjd/agent-shell-budget--refresh-headers ()
  "Rebuild the header in every live agent-shell buffer.
The header only re-renders when agent-shell asks it to, so a background
refresh has to poke each buffer itself or the new figures sit unused in
the cache until the next agent turn."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'agent-shell-mode)
        (ignore-errors (agent-shell--update-header-and-mode-line))))))

(defun rjd/agent-shell-budget--status-code ()
  "Return the HTTP status code of the response in the current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "\\`HTTP/[0-9.]+ \\([0-9]\\{3\\}\\)" nil t)
      (string-to-number (match-string 1)))))

(defun rjd/agent-shell-budget--handle-response (status)
  "Parse the usage response in the current buffer and update the cache.
STATUS is the `url-retrieve' status plist.  Failures are swallowed: a
missing budget should never interrupt a shell, so the header simply keeps
showing the previous figures, or nothing at all.  A 401 additionally
drops the cached token, so the next refresh goes back to the sources
rather than replaying a token the endpoint has already refused."
  (setq rjd/agent-shell-budget--in-flight nil)
  (unwind-protect
      (unless (plist-get status :error)
        (when (eq (rjd/agent-shell-budget--status-code) 401)
          (rjd/agent-shell-budget--invalidate-token))
        (goto-char (point-min))
        (when (re-search-forward "\n\n" nil t)
          (when-let* ((parsed (rjd/agent-shell-budget--parse
                               (buffer-substring-no-properties (point) (point-max)))))
            (setq rjd/agent-shell-budget--cache parsed)
            (rjd/agent-shell-budget--refresh-headers))))
    (kill-buffer (current-buffer))))

;;;###autoload
(defun rjd/agent-shell-budget-refresh ()
  "Fetch the current Claude rate-limit budget asynchronously.
Updates `rjd/agent-shell-budget--cache' and redraws agent-shell headers."
  (interactive)
  (unless (rjd/agent-shell-budget--fetch-pending-p)
    (when-let* ((token (rjd/agent-shell-budget--token)))
      (setq rjd/agent-shell-budget--in-flight (current-time))
      (let ((url-request-method "GET")
            (url-request-extra-headers
             `(("Authorization" . ,(concat "Bearer " token))
               ("anthropic-beta" . "oauth-2025-04-20"))))
        (condition-case nil
            (url-retrieve rjd/agent-shell-budget--endpoint
                          #'rjd/agent-shell-budget--handle-response
                          nil t t)
          (error (setq rjd/agent-shell-budget--in-flight nil)))))))


;;; Diagnostics

(defun rjd/agent-shell-budget--probe (token)
  "Return a one-line description of what the endpoint says to TOKEN.
Fetches synchronously, so this is for `rjd/agent-shell-budget-diagnose'
rather than the refresh path."
  (condition-case err
      (let ((url-request-method "GET")
            (url-request-extra-headers
             `(("Authorization" . ,(concat "Bearer " token))
               ("anthropic-beta" . "oauth-2025-04-20"))))
        (if-let* ((buffer (url-retrieve-synchronously
                           rjd/agent-shell-budget--endpoint t t 30)))
            (unwind-protect
                (with-current-buffer buffer
                  (goto-char (point-min))
                  (let ((line (buffer-substring-no-properties
                               (point) (line-end-position)))
                        (parsed (and (re-search-forward "\n\n" nil t)
                                     (rjd/agent-shell-budget--parse
                                      (buffer-substring-no-properties
                                       (point) (point-max))))))
                    (if parsed
                        (format "%s -> 5h %s%%, 7d %s%%" line
                                (map-elt parsed :five-hour)
                                (map-elt parsed :seven-day))
                      (format "%s (no usable body)" line))))
              (kill-buffer buffer))
          "no response"))
    (error (format "error: %S" err))))

;;;###autoload
(defun rjd/agent-shell-budget-diagnose ()
  "Report why the budget is or is not showing, in a temporary buffer.
Tries every entry in `rjd/agent-shell-budget-credential-sources' against the
endpoint and shows what each says, since the refresh path is deliberately
silent and a stale token looks the same as no token at all.  Tokens
themselves are never printed."
  (interactive)
  (with-current-buffer (get-buffer-create "*agent-shell budget*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "Mode enabled : %s\n" (if rjd/agent-shell-budget-mode "yes" "no"))
              (format "Timer        : %s\n"
                      (if rjd/agent-shell-budget--timer
                          (format "every %ss" rjd/agent-shell-budget-refresh-interval)
                        "none"))
              (format "Fetch pending: %s\n"
                      (if (rjd/agent-shell-budget--fetch-pending-p) "yes" "no"))
              (format "Cached       : %s\n"
                      (or (and rjd/agent-shell-budget--cache
                               (substring-no-properties
                                (rjd/agent-shell-budget-string)))
                          "nothing yet"))
              (format "Token cache  : %s\n\n"
                      (if-let* ((cached rjd/agent-shell-budget--token-cache))
                          (if (cdr cached)
                              (format "held until %s"
                                      (format-time-string "%a %H:%M" (cdr cached)))
                            "held, no stated expiry")
                        "empty, will read sources"))
              "Credential sources, in order:\n")
      (dolist (source rjd/agent-shell-budget-credential-sources)
        (let* ((blob (ignore-errors (funcall source)))
               (credentials (and blob (rjd/agent-shell-budget--parse-credentials blob))))
          (insert (format "  %s\n    %s\n" source
                          (cond ((null blob) "nothing read from this source")
                                ((null credentials) "token present but expired")
                                (t (rjd/agent-shell-budget--probe (car credentials))))))))
      (goto-char (point-min))
      (special-mode))
    (display-buffer (current-buffer))))


;;; Rendering

(defun rjd/agent-shell-budget--face (percentage)
  "Return the face for a window at PERCENTAGE utilization.
Mirrors the thresholds agent-shell uses for its context indicator, so the
two read as one scale."
  (cond ((>= percentage 85) 'agent-shell-error)
        ((>= percentage 60) 'agent-shell-warning)
        (t 'agent-shell-success)))

(defun rjd/agent-shell-budget--format-reset (time &optional with-day)
  "Return TIME as a local clock time, to the nearest minute, or nil.
WITH-DAY prefixes the weekday, for a reset far enough out that the time
alone would be ambiguous.

Rounds rather than truncates: the endpoint reports resets a fraction of a
second before the minute, so truncating would consistently show the
minute before the one the limit actually lifts."
  (when time
    (format-time-string (if with-day "%a %H:%M" "%H:%M")
                        (time-add time 30))))

(defun rjd/agent-shell-budget--format-window (label used resets show-reset
                                                    &optional with-day)
  "Return a propertized \"LABEL N%\" string, or nil when USED is unknown.
USED is a utilization percentage.  RESETS is appended as a clock time
when SHOW-RESET is non-nil, carrying the weekday if WITH-DAY."
  (when (numberp used)
    (let ((reset (and show-reset
                      (rjd/agent-shell-budget--format-reset resets with-day))))
      (propertize (format "%s %d%%%s" label used
                          (if reset (format " (%s)" reset) ""))
                  'face (rjd/agent-shell-budget--face used)))))

(defun rjd/agent-shell-budget-string ()
  "Return the budget string for the agent-shell header, or nil.
Reports utilization used, matching how Claude Code presents these windows.
Nil before the first successful fetch, which leaves the header untouched."
  (when rjd/agent-shell-budget--cache
    (let* ((cache rjd/agent-shell-budget--cache)
           (parts (delq nil
                        (list (rjd/agent-shell-budget--format-window
                               "5h" (map-elt cache :five-hour)
                               (map-elt cache :five-hour-resets)
                               rjd/agent-shell-budget-show-reset)
                              (rjd/agent-shell-budget--format-window
                               "7d" (map-elt cache :seven-day)
                               (map-elt cache :seven-day-resets)
                               (eq rjd/agent-shell-budget-show-reset 'both)
                               t)))))
      (when parts
        ;; Only the face at character 0 survives into the graphical header,
        ;; which reads it to pick an SVG fill colour, so the whole string
        ;; takes the more urgent window's colour rather than colouring each
        ;; half.  The text header would happily show both.
        (let ((worst (apply #'max (seq-filter #'numberp
                                              (list (map-elt cache :five-hour)
                                                    (map-elt cache :seven-day))))))
          (propertize (string-join parts " · ")
                      'face (rjd/agent-shell-budget--face worst)))))))


;;; Mode

(defun rjd/agent-shell-budget--header-advice (result)
  "Add the budget to header model RESULT as its `:status' field.
Advice on `agent-shell--make-header-model'.  Leaves an existing status
alone: agent-shell sets one for headers such as the diff viewer's, and
that caller's label matters more than the budget."
  (unless (map-elt result :status)
    (when-let* ((budget (rjd/agent-shell-budget-string)))
      (map-put! result :status budget)))
  result)

;;;###autoload
(define-minor-mode rjd/agent-shell-budget-mode
  "Show the Claude 5-hour and weekly budget in the agent-shell header."
  :global t
  :group 'rjd/agent-shell-budget
  (if rjd/agent-shell-budget-mode
      (progn
        (advice-add 'agent-shell--make-header-model :filter-return
                    #'rjd/agent-shell-budget--header-advice)
        (setq rjd/agent-shell-budget--timer
              (run-with-timer 0 rjd/agent-shell-budget-refresh-interval
                              #'rjd/agent-shell-budget-refresh)))
    (advice-remove 'agent-shell--make-header-model
                   #'rjd/agent-shell-budget--header-advice)
    (when rjd/agent-shell-budget--timer
      (cancel-timer rjd/agent-shell-budget--timer)
      (setq rjd/agent-shell-budget--timer nil))
    (setq rjd/agent-shell-budget--cache nil)
    (rjd/agent-shell-budget--refresh-headers)))

(provide 'rjd-agent-shell-budget)
;;; rjd-agent-shell-budget.el ends here
