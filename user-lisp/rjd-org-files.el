;;; rjd-org-files.el --- The agenda's org files, from org-sync's list  -*- lexical-binding: t; -*-

;;; Commentary:

;; Which org files this machine's agenda and capture use, taken from
;; the list org-sync syncs, so that a machine syncing a different set
;; -- a work one, with the cetos- files -- needs no change here.
;;
;; The list is `rjd/org-files-list-file', ~/.config/org-sync/files,
;; written by the setup repo's org-sync role: one file name per line,
;; each a file in `rjd/org-files-directory', ~/org-agenda/.  Blank lines
;; and lines starting with `#' are ignored, and so is any name with a
;; `/' in it, which could only reach outside that directory.  Without
;; the file the names are `rjd/org-files-personal', the personal four,
;; so a machine the setup repo has not written one for is as before.
;;
;; Two of the names are inboxes, `inbox.org' and `cetos-inbox.org'.
;; Capture goes to the personal one where it is listed and to the Cetos
;; one where only that is, and where both are, init.el adds a template
;; for the Cetos one too.
;;
;; Nothing here caches: each function reads the list afresh.  init.el
;; calls them once, as org, org-agenda and org-capture load, so a
;; change to the list takes effect at the next start.  Its tests are in
;; test/rjd-org-files-test.el.

;;; Code:

(require 'seq)
(require 'subr-x)


;;; Customization

(defgroup rjd/org-files nil
  "The agenda's org files, from org-sync's list."
  :group 'org)

(defcustom rjd/org-files-list-file "~/.config/org-sync/files"
  "The file listing the org files this machine syncs, one name per line.
Written by the setup repo's org-sync role.  Without it the names are
`rjd/org-files-personal'."
  :type 'file
  :group 'rjd/org-files)

(defcustom rjd/org-files-directory "~/org-agenda/"
  "The directory that holds every file `rjd/org-files-list-file' names."
  :type 'directory
  :group 'rjd/org-files)

(defconst rjd/org-files-personal
  '("inbox.org" "projects.org" "areas.org" "someday.org")
  "The org files used without a list: the personal four, in agenda order.")

(defconst rjd/org-files-inbox-names '("inbox.org" "cetos-inbox.org")
  "The names of the inboxes, the personal one first.")


;;; The list

(defun rjd/org-files-names ()
  "The names of the org files in use, in the list's order.
Those `rjd/org-files-list-file' names, without blank lines, `#'
comments, or any name with a `/'; or, without that file,
`rjd/org-files-personal'."
  (if (not (file-readable-p rjd/org-files-list-file))
      (copy-sequence rjd/org-files-personal)
    (with-temp-buffer
      (insert-file-contents rjd/org-files-list-file)
      (seq-remove (lambda (name)
                    (or (string-empty-p name)
                        (string-prefix-p "#" name)
                        (string-search "/" name)))
                  (mapcar #'string-trim
                          (split-string (buffer-string) "\n"))))))

(defun rjd/org-files--path (name)
  "The file NAME in `rjd/org-files-directory'."
  (file-name-concat rjd/org-files-directory name))

;;;###autoload
(defun rjd/org-files-agenda-files ()
  "The org files in use, each in `rjd/org-files-directory'.
For `org-agenda-files', in the list's order."
  (mapcar #'rjd/org-files--path (rjd/org-files-names)))

;;;###autoload
(defun rjd/org-files-inboxes ()
  "Every inbox in use, the personal one first.
For the agenda's view of what is still to process."
  (let ((names (rjd/org-files-names)))
    (mapcar #'rjd/org-files--path
            (seq-filter (lambda (inbox) (member inbox names))
                        rjd/org-files-inbox-names))))

;;;###autoload
(defun rjd/org-files-capture-inbox ()
  "The inbox capture goes to: the personal one, unless only the Cetos one is used.
A list naming neither inbox still gets the personal one, as without a
list, so capture always has a target."
  (rjd/org-files--path
   (or (car (seq-intersection rjd/org-files-inbox-names
                              (rjd/org-files-names)))
       (car rjd/org-files-inbox-names))))

;;;###autoload
(defun rjd/org-files-cetos-inbox ()
  "The Cetos inbox where both inboxes are in use, or nil.
Only then is it not where `rjd/org-files-capture-inbox' already goes,
and so in need of a capture template of its own."
  (let ((inboxes (rjd/org-files-inboxes)))
    (and (cdr inboxes) (cadr inboxes))))

(provide 'rjd-org-files)
;;; rjd-org-files.el ends here
