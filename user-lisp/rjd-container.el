;;; rjd-container.el --- Which agent container owns a directory  -*- lexical-binding: t -*-

;;; Commentary:

;; Reads claude-container's container map, which says which agent
;; container owns which directory, so that Emacs picks the same
;; container as claude-container's `container-git' wrapper does: the
;; one git runs in for a repo is the one agent-shell starts in there,
;; and the one Magit's commit editor is signalled in.
;;
;; The map is `rjd/container-map-file', one "DIRECTORY CONTAINER" line
;; per entry.  ~ stands for $HOME; blank lines, # comments and anything
;; after the container's name are ignored.  The longest DIRECTORY
;; containing a directory owns it, and a directory no entry contains
;; has no container.  Without the file the map is the single entry
;; "~/projects claude-dev", which is how everything behaved before
;; there was a map.  CLAUDE_CONTAINER, if set, replaces whichever
;; container the map chose, but never gives an unowned directory one.
;;
;; These are the rules `container-git' applies, written a second time
;; because the wrapper is POSIX sh; claude-container's
;; tests/container-git-test.sh checks the same cases there that
;; test/rjd-container-test.el checks here.  If the two ever disagree, a
;; commit's editor is signalled in a different container from the git
;; that is waiting on it, and git hangs until the buffer is killed.
;;
;; The file is read afresh at every call: it is a few lines, read when
;; a shell starts or a commit message is finished, so an edit to it
;; takes effect at once.

;;; Code:

(defvar rjd/container-map-file "~/.config/claude-container/containers"
  "The container map: which agent container owns which directory.
Must be the file `container-git' reads, which is fixed, so this is
not a user option.  It lives outside every mounted directory so that
no agent can edit it.")

(defconst rjd/container-default-map '(("~/projects" . "claude-dev"))
  "The map in force when `rjd/container-map-file' does not exist.")

(defconst rjd/container-default "claude-dev"
  "The container agent-shell uses for a directory no entry owns.")

(defun rjd/container--parse (text)
  "Return the entries of the container map TEXT as (DIRECTORY . CONTAINER).
Blank lines, comment lines and lines with no container are dropped,
and so is anything after the container's name."
  (let (entries)
    (dolist (line (split-string text "\n"))
      (pcase (split-string line nil t)
        (`(,dir ,container . ,_)
         (unless (string-prefix-p "#" dir)
           (push (cons dir container) entries)))))
    (nreverse entries)))

(defun rjd/container--directory (dir)
  "Return DIR expanded and resolved, as a directory name."
  (file-name-as-directory (file-truename (expand-file-name dir))))

;;;###autoload
(defun rjd/container-map ()
  "Return the container map as a list of (DIRECTORY . CONTAINER).
Each DIRECTORY is expanded, resolved and ends in a slash.  Read from
`rjd/container-map-file', or `rjd/container-default-map' without it."
  (mapcar (lambda (entry)
            (cons (rjd/container--directory (car entry)) (cdr entry)))
          (if (file-exists-p rjd/container-map-file)
              (with-temp-buffer
                (insert-file-contents rjd/container-map-file)
                (rjd/container--parse (buffer-string)))
            rjd/container-default-map)))

(defun rjd/container--override ()
  "Return CLAUDE_CONTAINER, or nil when it is unset or empty."
  (let ((name (getenv "CLAUDE_CONTAINER")))
    (and name (not (string-empty-p name)) name)))

;;;###autoload
(defun rjd/container-for-directory (dir)
  "Return the agent container that owns directory DIR, or nil.
Chosen as `container-git' chooses: the longest map entry containing
DIR, replaced by CLAUDE_CONTAINER when that is set.  A remote DIR,
which no local container can see, has none."
  (unless (file-remote-p dir)
    (let ((dir (rjd/container--directory dir))
          best)
      (dolist (entry (rjd/container-map))
        (when (and (string-prefix-p (car entry) dir)
                   (> (length (car entry)) (length (car best))))
          (setq best entry)))
      (and best (or (rjd/container--override) (cdr best))))))

;;;###autoload
(defun rjd/container-agent-shell-prefix (buffer)
  "Return the command prefix that runs BUFFER's agent in its container.
For `agent-shell-command-prefix', which calls it with the shell's
buffer: the container owning BUFFER's `default-directory', or
`rjd/container-default' when none does -- itself replaced by
CLAUDE_CONTAINER when that is set.  -i is required: acp.el speaks
JSON-RPC over the adapter's stdin."
  (list "docker" "exec" "-i"
        (or (rjd/container-for-directory
             (buffer-local-value 'default-directory buffer))
            (rjd/container--override)
            rjd/container-default)))

(provide 'rjd-container)
;;; rjd-container.el ends here
