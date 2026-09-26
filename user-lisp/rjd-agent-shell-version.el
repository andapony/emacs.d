;;; rjd-agent-shell-version.el --- Show the Claude Code version in the agent-shell header  -*- lexical-binding: t -*-

;;; Commentary:
;; Appends the running Claude Code version to the agent name in the
;; `agent-shell' header, so it reads "Claude v2.1.232 ➤ Opus 5 ➤ ...",
;; and flags when a newer ACP adapter release is available.
;;
;; agent-shell never learns the version itself.  The ACP `initialize'
;; response may carry an `agentInfo' object naming the agent and its
;; version, but agent-shell reads only `agentCapabilities' and `modes'
;; from that response and drops the rest, so there is nothing in the
;; session state to read.
;;
;; Which binary is "the" Claude Code needs care.  agent-shell does not
;; run the `claude' on PATH: the ACP adapter spawns a binary bundled
;; inside its own dependency tree, pinned by
;; `@agentclientprotocol/claude-agent-acp' to an exact
;; `@anthropic-ai/claude-agent-sdk' release.  The default command below
;; therefore resolves that bundled binary from the adapter's location and
;; only falls back to PATH, so it reports what is actually serving the
;; shell rather than whatever else happens to be installed.
;;
;; That pin is also why an update indicator is worth having: the version
;; is fixed for the life of the container and moves only when the adapter
;; publishes a release bumping its SDK pin.  There is nothing to poll for
;; frequently and nothing a restart will change -- the signal is "a
;; rebuild would now get you something newer", checked daily.
;; `rjd/agent-shell-version-install-update' acts on it without the
;; rebuild, by installing the new adapter into the running container.
;;
;; Enable with `rjd/agent-shell-version-mode'.
;;
;; CAVEAT: like `rjd-agent-shell-budget', this leans on a private
;; interface.  It advises `agent-shell--make-header-model' to extend the
;; header model's `:buffer-name' field.  If the version disappears from
;; the header after an agent-shell upgrade, that advice is the first
;; place to look.

;;; Code:

(require 'map)
(require 'seq)

(defvar agent-shell-command-prefix)
(declare-function agent-shell--update-header-and-mode-line "agent-shell")


;;; Customization

(defgroup rjd/agent-shell-version nil
  "Claude Code version in the agent-shell header."
  :group 'agent-shell)

(defcustom rjd/agent-shell-version-command
  '("sh" "-c"
    "p=$(command -v claude-agent-acp 2>/dev/null); b=; \
if [ -n \"$p\" ]; then p=$(readlink -f \"$p\"); \
b=$(ls \"$(dirname \"$p\")\"/../node_modules/@anthropic-ai/claude-agent-sdk-*/claude 2>/dev/null | head -1); fi; \
exec \"${b:-claude}\" --version")
  "Command asking Claude Code for its version.
Run through `agent-shell-command-prefix' when that is set, so it lands
wherever the agent itself runs.

Resolves the binary the ACP adapter actually spawns -- bundled in the
adapter's own `node_modules' -- rather than trusting PATH, which in a
container that also installs `@anthropic-ai/claude-code' holds a
different and usually newer build.  Falls back to PATH when the adapter
cannot be located, which is also correct when the bundled binary is what
PATH points at."
  :type '(repeat string)
  :group 'rjd/agent-shell-version)

(defcustom rjd/agent-shell-version-ttl 3600
  "Seconds a fetched version is trusted before being asked for again.
The version is pinned by the installed adapter, so this only needs to be
short enough to notice a package upgrade under a running Emacs."
  :type 'natnum
  :group 'rjd/agent-shell-version)

(defcustom rjd/agent-shell-version-format "v%s"
  "Format string applied to the version before it joins the agent name.
Takes the bare version number, e.g. \"2.1.232\"."
  :type 'string
  :group 'rjd/agent-shell-version)

(defcustom rjd/agent-shell-version-update-command
  '("sh" "-c"
    "r=$(npm root -g 2>/dev/null); \
node -p \"require('$r/@agentclientprotocol/claude-agent-acp/package.json').version\" 2>/dev/null; \
npm view @agentclientprotocol/claude-agent-acp version 2>/dev/null")
  "Command reporting the installed and latest ACP adapter versions.
Prints the installed version on the first line and the registry's latest
on the second.  The adapter is the only input that decides which Claude
Code serves a shell, so comparing those two answers \"would rebuilding
the container get me anything?\".

The second line needs network access; without it the command still
prints the first line and the indicator simply stays hidden."
  :type '(repeat string)
  :group 'rjd/agent-shell-version)

(defcustom rjd/agent-shell-version-update-ttl 86400
  "Seconds between checks for a newer ACP adapter release.
Daily is generous: the answer changes only when the adapter publishes,
and acting on it means reinstalling the adapter under running shells,
which is not something to prompt for hourly."
  :type 'natnum
  :group 'rjd/agent-shell-version)

(defcustom rjd/agent-shell-version-update-indicator "⇧"
  "Marker appended to the version when a newer adapter release exists.
Deliberately a bare glyph rather than the new version number: what is
available is an adapter version, which is not the Claude Code version
sitting next to it, and showing both invites reading one as the other."
  :type 'string
  :group 'rjd/agent-shell-version)

(defcustom rjd/agent-shell-version-install-command
  '("sh" "-c"
    "npm install -g @agentclientprotocol/claude-agent-acp@latest && claude --version")
  "Command installing the latest ACP adapter where the agent runs.
Used by `rjd/agent-shell-version-install-update'.  The trailing
`claude --version' proves the `claude' on PATH still resolves: in the
container it is a symlink into the adapter's own `node_modules', which
the install replaces wholesale."
  :type '(repeat string)
  :group 'rjd/agent-shell-version)


;;; Fetching

(defvar rjd/agent-shell-version--cache nil
  "Cons of (VERSION . FETCH-TIME), or nil before the first fetch.")

(defvar rjd/agent-shell-version--update-cache nil
  "Cons of ((INSTALLED . LATEST) . FETCH-TIME), or nil before the first fetch.")

(defvar rjd/agent-shell-version--in-flight nil
  "Non-nil while a version fetch is outstanding.")

(defvar rjd/agent-shell-version--update-in-flight nil
  "Non-nil while an adapter update check is outstanding.
Separate from `rjd/agent-shell-version--in-flight' so the slow,
network-bound check cannot block the cheap local one behind it.")

(defvar rjd/agent-shell-version--install-in-flight nil
  "Non-nil while an adapter install is running.")

(defun rjd/agent-shell-version--stale-p (cache ttl)
  "Return non-nil when CACHE was fetched more than TTL seconds ago.
A nil CACHE is stale, so the first call always fetches."
  (or (null cache)
      (> (float-time (time-subtract nil (cdr cache))) ttl)))

(defun rjd/agent-shell-version--parse (output)
  "Return the version number in OUTPUT, or nil.
`claude --version' answers \"2.1.232 (Claude Code)\", so the leading
dotted-numeric token is taken and the product name discarded."
  (when (and (stringp output)
             (string-match "\\([0-9]+\\(?:\\.[0-9]+\\)+[^ \t\n]*\\)" output))
    (match-string 1 output)))

(defun rjd/agent-shell-version--parse-update (output)
  "Return (INSTALLED . LATEST) from OUTPUT, or nil.
OUTPUT is two lines from `rjd/agent-shell-version-update-command'.  A
missing second line means the registry could not be reached, which is
reported as nil rather than as \"up to date\": an unreachable registry
says nothing either way."
  (when-let* ((lines (and (stringp output)
                          (seq-remove #'string-empty-p
                                      (split-string output "\n" t "[ \t\r]+"))))
              ((= (length lines) 2)))
    (cons (nth 0 lines) (nth 1 lines))))

(defun rjd/agent-shell-version--refresh-headers ()
  "Rebuild the header in every live agent-shell buffer.
A header only re-renders when agent-shell asks it to, so a value that
arrives from a background process has to poke each buffer itself."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'agent-shell-mode)
        (ignore-errors (agent-shell--update-header-and-mode-line))))))

(defun rjd/agent-shell-version--run (name command callback)
  "Run COMMAND asynchronously under NAME and call CALLBACK with its output.
COMMAND is prefixed with `agent-shell-command-prefix' so it lands
wherever the agent runs.  CALLBACK receives the collected stdout, or nil
if the process failed to start or exited non-zero -- so a caller has a
single place to clear its in-flight flag and stamp its cache.

Asynchronous because the prefix may be a `docker exec', and the update
check additionally talks to a registry; either would be felt on the
redisplay path that renders the header."
  (let ((full (append (and (boundp 'agent-shell-command-prefix)
                           agent-shell-command-prefix)
                      command))
        (output ""))
    (condition-case nil
        (make-process
         :name name
         :command full
         :noquery t
         :connection-type 'pipe
         ;; stderr is discarded rather than mixed into the output: an npm
         ;; warning printed alongside a version would otherwise stand a
         ;; chance of matching the version regexp.
         :stderr (make-pipe-process :name (concat name "-stderr")
                                    :noquery t
                                    :filter #'ignore)
         :filter (lambda (_process chunk) (setq output (concat output chunk)))
         :sentinel (lambda (process _event)
                     (unless (process-live-p process)
                       (funcall callback
                                (and (zerop (process-exit-status process))
                                     output)))))
      (error (funcall callback nil)))
    nil))

;;;###autoload
(defun rjd/agent-shell-version-refresh ()
  "Ask Claude Code for its version asynchronously and redraw the headers."
  (interactive)
  (unless rjd/agent-shell-version--in-flight
    (setq rjd/agent-shell-version--in-flight t)
    (rjd/agent-shell-version--run
     "rjd-agent-shell-version"
     rjd/agent-shell-version-command
     (lambda (output)
       (setq rjd/agent-shell-version--in-flight nil)
       ;; A failed fetch still stamps the cache, so a host with no agent
       ;; installed retries once per TTL rather than on every render.
       (setq rjd/agent-shell-version--cache
             (cons (rjd/agent-shell-version--parse output) (current-time)))
       (rjd/agent-shell-version--refresh-headers)))))

;;;###autoload
(defun rjd/agent-shell-version-check-update (&optional report)
  "Check whether a newer ACP adapter release is available.
With REPORT, which is always set interactively, echo the outcome when
it arrives.  The header shows only a bare indicator, and the graphical
header cannot carry the tooltip that names the versions, so this is
where they can be read."
  (interactive (list t))
  (if rjd/agent-shell-version--update-in-flight
      (when report
        (message "An adapter update check is already running"))
    (setq rjd/agent-shell-version--update-in-flight t)
    (rjd/agent-shell-version--run
     "rjd-agent-shell-version-update"
     rjd/agent-shell-version-update-command
     (lambda (output)
       (let ((pair (rjd/agent-shell-version--parse-update output)))
         (setq rjd/agent-shell-version--update-in-flight nil)
         (setq rjd/agent-shell-version--update-cache (cons pair (current-time)))
         (rjd/agent-shell-version--refresh-headers)
         (when report
           (cond ((null pair)
                  (message "Could not compare adapter versions; is the npm registry reachable?"))
                 ((equal (car pair) (cdr pair))
                  (message "claude-agent-acp %s is the latest release" (car pair)))
                 (t
                  (message "claude-agent-acp %s available (installed %s); M-x rjd/agent-shell-version-install-update"
                           (cdr pair) (car pair))))))))))

(defun rjd/agent-shell-version-update-available-p ()
  "Return the newer adapter version when one exists, else nil.
Kicks off a check when the cached answer has aged out."
  (when (rjd/agent-shell-version--stale-p rjd/agent-shell-version--update-cache
                                          rjd/agent-shell-version-update-ttl)
    (rjd/agent-shell-version-check-update))
  (when-let* ((pair (car rjd/agent-shell-version--update-cache))
              ((not (equal (car pair) (cdr pair)))))
    (cdr pair)))

;;;###autoload
(defun rjd/agent-shell-version-install-update ()
  "Install the latest ACP adapter where the agent runs.
Runs `rjd/agent-shell-version-install-command' through
`agent-shell-command-prefix', showing its output in a buffer, then
re-checks the version and the update indicator.

This updates the running container in place rather than recreating it,
which would kill every open session.  The change lives in the
container's writable layer, so recreating the container undoes it --
harmlessly, since a fresh image build installs the latest adapter too.

Shells already open keep the adapter process they started with; only
shells started afterwards use the new one.

Asks first, naming the versions from the last update check.  That check
can be up to `rjd/agent-shell-version-update-ttl' old, and the install
takes whatever is latest now, so the version named is a floor."
  (interactive)
  (when rjd/agent-shell-version--install-in-flight
    (user-error "An adapter install is already running"))
  (let ((pair (car rjd/agent-shell-version--update-cache)))
    (unless (y-or-n-p
             (cond ((null pair)
                    "Latest adapter version unknown; install claude-agent-acp@latest anyway? ")
                   ((equal (car pair) (cdr pair))
                    (format "claude-agent-acp %s is already the latest; reinstall? "
                            (car pair)))
                   (t
                    (format "Install claude-agent-acp %s (installed %s)? "
                            (cdr pair) (car pair)))))
      (user-error "Adapter install cancelled")))
  (let ((buffer (get-buffer-create "*rjd-agent-shell-version-install*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer))
      (special-mode))
    (display-buffer buffer)
    (setq rjd/agent-shell-version--install-in-flight t)
    (condition-case err
        (make-process
         :name "rjd-agent-shell-version-install"
         :buffer buffer
         :command (append (and (boundp 'agent-shell-command-prefix)
                               agent-shell-command-prefix)
                          rjd/agent-shell-version-install-command)
         :noquery t
         :connection-type 'pipe
         ;; `special-mode' makes the buffer read-only, so output has to
         ;; be inserted past that rather than by the default filter.
         :filter (lambda (process chunk)
                   (when (buffer-live-p (process-buffer process))
                     (with-current-buffer (process-buffer process)
                       (let ((inhibit-read-only t))
                         (goto-char (point-max))
                         (insert chunk)))))
         :sentinel
         (lambda (process _event)
           (unless (process-live-p process)
             (setq rjd/agent-shell-version--install-in-flight nil)
             (if (not (zerop (process-exit-status process)))
                 (message "ACP adapter install failed; see %s"
                          (buffer-name buffer))
               (rjd/agent-shell-version-refresh)
               (rjd/agent-shell-version-check-update)
               (let ((open (seq-count (lambda (b)
                                        (with-current-buffer b
                                          (derived-mode-p 'agent-shell-mode)))
                                      (buffer-list))))
                 (message "ACP adapter updated%s"
                          (if (zerop open)
                              ""
                            (format "; restart %d open shell%s to use it"
                                    open (if (= open 1) "" "s")))))))))
      (error
       (setq rjd/agent-shell-version--install-in-flight nil)
       (signal (car err) (cdr err))))))

(defun rjd/agent-shell-version-string ()
  "Return the formatted Claude Code version, or nil if it is not known yet.
Carries the update indicator when a newer adapter release is available.

Kicks off a refresh when the cached value has aged out, and answers from
the cache meanwhile, so the header shows the previous version rather than
flickering empty while the new one is fetched."
  (when (rjd/agent-shell-version--stale-p rjd/agent-shell-version--cache
                                          rjd/agent-shell-version-ttl)
    (rjd/agent-shell-version-refresh))
  (when-let* ((version (car rjd/agent-shell-version--cache)))
    (concat (format rjd/agent-shell-version-format version)
            ;; help-echo reaches the text header only: the graphical
            ;; header rasterises to an SVG image, which carries no text
            ;; properties.  The glyph has to read on its own there.
            (when-let* ((latest (rjd/agent-shell-version-update-available-p)))
              (concat " " (propertize rjd/agent-shell-version-update-indicator
                                      'help-echo
                                      (format "claude-agent-acp %s available; M-x rjd/agent-shell-version-install-update"
                                              latest)))))))


;;; Mode

(defun rjd/agent-shell-version--header-advice (result)
  "Append the Claude Code version to header model RESULT's agent name.
Advice on `agent-shell--make-header-model'.  The name is extended rather
than a field of its own being used: the header model has no spare slot
\(`rjd-agent-shell-budget' already claims `:status'), and the version
belongs beside the agent it describes.

Only Claude shells are touched, since the version is Claude Code's.  The
graphical header draws `:buffer-name' as a single run in one colour, so
the version arrives in the agent name's face rather than its own."
  (when-let* ((name (map-elt result :buffer-name))
              ((string-prefix-p "Claude" name))
              (version (rjd/agent-shell-version-string)))
    (map-put! result :buffer-name (concat name " " version)))
  result)

;;;###autoload
(define-minor-mode rjd/agent-shell-version-mode
  "Show the running Claude Code version in the agent-shell header."
  :global t
  :group 'rjd/agent-shell-version
  (if rjd/agent-shell-version-mode
      (progn
        (advice-add 'agent-shell--make-header-model :filter-return
                    #'rjd/agent-shell-version--header-advice)
        (rjd/agent-shell-version-refresh)
        (rjd/agent-shell-version-check-update))
    (advice-remove 'agent-shell--make-header-model
                   #'rjd/agent-shell-version--header-advice)
    (setq rjd/agent-shell-version--cache nil
          rjd/agent-shell-version--update-cache nil)
    (rjd/agent-shell-version--refresh-headers)))

(provide 'rjd-agent-shell-version)
;;; rjd-agent-shell-version.el ends here
