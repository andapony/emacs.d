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
;; Each container's figures are its own.  The budget belongs to the
;; Claude account a shell is logged in as, and two containers can be
;; logged in as two accounts -- claude-dev as the personal one and
;; claude-cetos as the company's -- so the token, the figures and the
;; fetch in flight are all kept per container, keyed by the command
;; prefix that reaches it (`rjd/agent-shell-budget--command-prefix'),
;; and each shell's header shows its own container's.  The timer
;; refreshes every container an open shell runs in, not whichever the
;; current buffer happens to name.
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
Read on the Emacs host for a shell whose agent runs here, and inside the
container for one whose agent runs there, when
`rjd/agent-shell-budget-use-command-prefix' is enabled; so it is left
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
read through the same prefix agent-shell uses to reach the agent.  The
host's credentials file and Keychain are not tried for such a shell: the
host may be logged in as another account, whose budget is not this
shell's."
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

(defun rjd/agent-shell-budget--credentials-from-file (prefix)
  "Return the credentials blob from the file on this host, or nil.
Nil unless PREFIX is nil: only an agent running on this host is logged
in with this host's credentials."
  (let ((file (expand-file-name rjd/agent-shell-budget-credentials-file)))
    (when (and (null prefix) (file-readable-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string)))))

(defun rjd/agent-shell-budget--credentials-from-keychain (prefix)
  "Return the credentials blob from the macOS login Keychain, or nil.
Nil unless PREFIX is nil, as for the host's credentials file."
  (when (and (null prefix) (eq system-type 'darwin))
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

(defun rjd/agent-shell-budget--command-prefix (&optional buffer)
  "Return `agent-shell-command-prefix' as a list, for BUFFER.
BUFFER defaults to the current buffer.  agent-shell takes a function of
the buffer there as well as a list, and calls it with the shell's
buffer; this calls it with BUFFER, which outside a shell gives the
prefix for that buffer's directory.

The prefix names the container the agent runs in, so it is also the key
every cache here is held under: nil, for an agent on this host, is a
key like any other."
  (when (boundp 'agent-shell-command-prefix)
    (if (functionp agent-shell-command-prefix)
        (funcall agent-shell-command-prefix (or buffer (current-buffer)))
      agent-shell-command-prefix)))

(defun rjd/agent-shell-budget--credentials-from-command-prefix (prefix)
  "Return the credentials blob read through command PREFIX, or nil.
Runs `cat' on the credentials file wherever PREFIX lands, which for a
docker prefix is inside the container holding the subscription login.
Nil when PREFIX is nil, the source is disabled, or the command fails.

This spawns a process synchronously, so it is the expensive source; see
`rjd/agent-shell-budget--token' for how often it actually runs."
  (when-let* ((rjd/agent-shell-budget-use-command-prefix)
              (prefix)
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
Each takes the command prefix of the shell whose budget is wanted, nil
for an agent on this host, and returns the contents of a Claude Code
credentials JSON blob for that agent's login, or nil.  A source that
cannot read that login -- the host's, for a container's shell -- returns
nil, so it never answers with another account.  A blob whose token
has expired is skipped, so a source that nobody refreshes falls through
rather than shadowing a live one; reorder this only to skip a source
outright."
  :type '(repeat function)
  :group 'rjd/agent-shell-budget)

(defvar rjd/agent-shell-budget--token-cache nil
  "Alist of (PREFIX TOKEN . EXPIRY), one per container.
A container with no entry has its token read again.")

(defconst rjd/agent-shell-budget--token-margin 300
  "Seconds before expiry at which a cached token is treated as spent.
Covers the gap between deciding to use a token and the request landing.")

(defun rjd/agent-shell-budget--cached-token (prefix)
  "Return PREFIX's cached token if it is still comfortably valid, else nil."
  (when-let* ((cached (alist-get prefix rjd/agent-shell-budget--token-cache
                                 nil nil #'equal))
              (expiry (cdr cached)))
    (and (time-less-p (time-add nil rjd/agent-shell-budget--token-margin) expiry)
         (car cached))))

(defun rjd/agent-shell-budget--invalidate-token (prefix)
  "Drop PREFIX's cached token so its next fetch reads the sources again.
Called when the endpoint rejects the token, which is the one thing that
proves a token is dead ahead of its stated expiry."
  (setf (alist-get prefix rjd/agent-shell-budget--token-cache
                   nil 'remove #'equal)
        nil))

(defun rjd/agent-shell-budget--read-token (prefix)
  "Read PREFIX's token from `rjd/agent-shell-budget-credential-sources'.
Return nil if none has one.  Errors are swallowed at each step so a
missing or unreachable source just falls through to the next."
  (when-let* ((credentials
               (seq-some (lambda (source)
                           (when-let* ((blob (ignore-errors (funcall source prefix))))
                             (rjd/agent-shell-budget--parse-credentials blob)))
                         rjd/agent-shell-budget-credential-sources)))
    (setf (alist-get prefix rjd/agent-shell-budget--token-cache
                     nil nil #'equal)
          credentials)
    (car credentials)))

(defun rjd/agent-shell-budget--token (prefix)
  "Return the OAuth access token of PREFIX's agent, or nil if not found.

Prefers the cached token, since the sources are not all cheap: reaching
the container costs a synchronous process spawn, and on a five-minute
refresh that would freeze Emacs briefly all day for a value that only
changes every few hours.  Tokens carry their own expiry, so the cache is
held until then and dropped early only on a 401."
  (or (rjd/agent-shell-budget--cached-token prefix)
      (rjd/agent-shell-budget--read-token prefix)))


;;; Fetching

(defvar rjd/agent-shell-budget--cache nil
  "Alist of (PREFIX . FIGURES), each container's latest budget.
A container has no entry before its first successful fetch.  FIGURES is
an alist with `:five-hour' and `:seven-day' percentages used, and
`:five-hour-resets' and `:seven-day-resets' Lisp timestamps.")

(defvar rjd/agent-shell-budget--tried nil
  "Prefixes a header has asked for since the mode was enabled.
A shell's first header starts its container's first fetch, rather than
leaving it blank until the timer next fires; this list makes that
happen once per container, and the timer does the rest.")

(defvar rjd/agent-shell-budget--timer nil
  "Repeating timer driving `rjd/agent-shell-budget-refresh'.")

(defvar rjd/agent-shell-budget--in-flight nil
  "Alist of (PREFIX . TIME), when each container's outstanding fetch began.
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

(defun rjd/agent-shell-budget--fetch-pending-p (prefix)
  "Return non-nil if PREFIX's fetch is outstanding and not presumed dead."
  (when-let* ((started (alist-get prefix rjd/agent-shell-budget--in-flight
                                  nil nil #'equal)))
    (< (float-time (time-subtract nil started))
       rjd/agent-shell-budget--fetch-timeout)))

(defun rjd/agent-shell-budget--set-in-flight (prefix time)
  "Record TIME as when PREFIX's fetch began; nil TIME clears it."
  (setf (alist-get prefix rjd/agent-shell-budget--in-flight
                   nil 'remove #'equal)
        time))

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

(defun rjd/agent-shell-budget--shells ()
  "Return the live agent-shell buffers."
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer
                  (derived-mode-p 'agent-shell-mode)))
              (buffer-list)))

(defun rjd/agent-shell-budget--refresh-headers ()
  "Rebuild the header in every live agent-shell buffer.
The header only re-renders when agent-shell asks it to, so a background
refresh has to poke each buffer itself or the new figures sit unused in
the cache until the next agent turn."
  (dolist (buffer (rjd/agent-shell-budget--shells))
    (with-current-buffer buffer
      (ignore-errors (agent-shell--update-header-and-mode-line)))))

(defun rjd/agent-shell-budget--status-code ()
  "Return the HTTP status code of the response in the current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "\\`HTTP/[0-9.]+ \\([0-9]\\{3\\}\\)" nil t)
      (string-to-number (match-string 1)))))

(defun rjd/agent-shell-budget--handle-response (status prefix)
  "Parse the usage response in the current buffer into PREFIX's figures.
STATUS is the `url-retrieve' status plist, and PREFIX the container the
token came from.  Failures are swallowed: a missing budget should never
interrupt a shell, so the header simply keeps showing the previous
figures, or nothing at all.  A 401 additionally drops PREFIX's cached
token, so its next refresh goes back to the sources rather than
replaying a token the endpoint has already refused."
  (rjd/agent-shell-budget--set-in-flight prefix nil)
  (unwind-protect
      (unless (plist-get status :error)
        (when (eq (rjd/agent-shell-budget--status-code) 401)
          (rjd/agent-shell-budget--invalidate-token prefix))
        (goto-char (point-min))
        (when (re-search-forward "\n\n" nil t)
          (when-let* ((parsed (rjd/agent-shell-budget--parse
                               (buffer-substring-no-properties (point) (point-max)))))
            (setf (alist-get prefix rjd/agent-shell-budget--cache
                             nil nil #'equal)
                  parsed)
            (rjd/agent-shell-budget--refresh-headers))))
    (kill-buffer (current-buffer))))

(defun rjd/agent-shell-budget--fetch (prefix)
  "Fetch the budget of PREFIX's agent asynchronously, unless one is pending."
  (unless (rjd/agent-shell-budget--fetch-pending-p prefix)
    (when-let* ((token (rjd/agent-shell-budget--token prefix)))
      (rjd/agent-shell-budget--set-in-flight prefix (current-time))
      (let ((url-request-method "GET")
            (url-request-extra-headers
             `(("Authorization" . ,(concat "Bearer " token))
               ("anthropic-beta" . "oauth-2025-04-20"))))
        (condition-case nil
            (url-retrieve rjd/agent-shell-budget--endpoint
                          #'rjd/agent-shell-budget--handle-response
                          (list prefix) t t)
          (error (rjd/agent-shell-budget--set-in-flight prefix nil)))))))

(defun rjd/agent-shell-budget--prefixes ()
  "Return the distinct command prefixes of the live agent-shell buffers."
  (seq-uniq (mapcar #'rjd/agent-shell-budget--command-prefix
                    (rjd/agent-shell-budget--shells))))

;;;###autoload
(defun rjd/agent-shell-budget-refresh ()
  "Fetch the Claude rate-limit budget of every open shell's container.
Asynchronous.  Each container is fetched once, however many shells run
in it, with its own token, and its figures go to its own entry in
`rjd/agent-shell-budget--cache'; the headers are redrawn as each one
arrives.  With no shell open there is nothing to fetch."
  (interactive)
  (mapc #'rjd/agent-shell-budget--fetch (rjd/agent-shell-budget--prefixes)))


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
  (let ((prefix (rjd/agent-shell-budget--command-prefix)))
    (with-current-buffer (get-buffer-create "*agent-shell budget*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Container    : %s\n"
                        (if prefix (string-join prefix " ") "this host"))
                (format "Mode enabled : %s\n" (if rjd/agent-shell-budget-mode "yes" "no"))
                (format "Timer        : %s\n"
                        (if rjd/agent-shell-budget--timer
                            (format "every %ss" rjd/agent-shell-budget-refresh-interval)
                          "none"))
                (format "Fetch pending: %s\n"
                        (if (rjd/agent-shell-budget--fetch-pending-p prefix) "yes" "no"))
                (format "Cached       : %s\n"
                        (if-let* ((string (rjd/agent-shell-budget--string prefix)))
                            (substring-no-properties string)
                          "nothing yet"))
                (format "Token cache  : %s\n\n"
                        (if-let* ((cached (alist-get prefix rjd/agent-shell-budget--token-cache
                                                     nil nil #'equal)))
                            (if (cdr cached)
                                (format "held until %s"
                                        (format-time-string "%a %H:%M" (cdr cached)))
                              "held, no stated expiry")
                          "empty, will read sources"))
                "Credential sources, in order:\n")
        (dolist (source rjd/agent-shell-budget-credential-sources)
          (let* ((blob (ignore-errors (funcall source prefix)))
                 (credentials (and blob (rjd/agent-shell-budget--parse-credentials blob))))
            (insert (format "  %s\n    %s\n" source
                            (cond ((null blob) "nothing read from this source")
                                  ((null credentials) "token present but expired")
                                  (t (rjd/agent-shell-budget--probe (car credentials))))))))
        (goto-char (point-min))
        (special-mode))
      (display-buffer (current-buffer)))))


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
  "Return the budget string for the current buffer's header, or nil.
The budget is that of the container the buffer's shell runs in.  Nil
before that container's first successful fetch, which leaves the header
untouched; the first time a container is asked for, its fetch starts."
  (let ((prefix (rjd/agent-shell-budget--command-prefix)))
    (unless (member prefix rjd/agent-shell-budget--tried)
      (push prefix rjd/agent-shell-budget--tried)
      ;; From a timer, not here: reading the token may be a synchronous
      ;; `docker exec', which has no place on the redisplay path.
      (run-at-time 0 nil #'rjd/agent-shell-budget--fetch prefix))
    (rjd/agent-shell-budget--string prefix)))

(defun rjd/agent-shell-budget--string (prefix)
  "Return the budget string for PREFIX's container, or nil.
Reports utilization used, matching how Claude Code presents these windows.
Nil before that container's first successful fetch."
  (when-let* ((cache (alist-get prefix rjd/agent-shell-budget--cache
                                nil nil #'equal)))
    (let* ((parts (delq nil
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
    (setq rjd/agent-shell-budget--cache nil
          rjd/agent-shell-budget--token-cache nil
          rjd/agent-shell-budget--in-flight nil
          rjd/agent-shell-budget--tried nil)
    (rjd/agent-shell-budget--refresh-headers)))

(provide 'rjd-agent-shell-budget)
;;; rjd-agent-shell-budget.el ends here
