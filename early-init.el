;;; early-init.el --- Settings that must precede package activation  -*- lexical-binding: t; -*-

;;; Commentary:
;; Emacs runs `package-activate-all' between this file and init.el, so
;; anything that has to be in place before third-party packages load
;; belongs here rather than there.

;;; Code:

;; Log native compilation warnings from packages without popping up the
;; *Warnings* buffer.  Visit that buffer manually if you need to review them.
;;
;; Activation loads package autoloads, which queues those files for async
;; native compilation -- so setting this in init.el is already too late for
;; the first batch of warnings.
(setq native-comp-async-report-warnings-errors 'silent)

;; Load whichever of a library's source and compiled file is newer.
;; Emacs 31 recompiles user-lisp/ at startup, one file at a time, and a
;; file compiled early loads its dependencies' stale .elc otherwise:
;; the session then keeps their old definitions until the next restart.
;; `prepare-user-lisp' runs before init.el, so this has to be here.
(setq load-prefer-newer t)

;; Keep test suites and scratch out of every session.  Emacs 31 prepares
;; all of user-lisp/, following symlinks, so a package linked in there
;; from its own checkout -- user-lisp/book-list -> ~/projects/book-list
;; -- would have its test/ compiled, autoloaded and put on `load-path'
;; too.  tmp/ is worse: c2log's holds an old copy of c2log.el, whose
;; autoload cookies would be scraped alongside the real one's, leaving
;; which file a command loads to the order they were written in.  The
;; list is matched against each directory's name, and like
;; `load-prefer-newer' it has to be set before `prepare-user-lisp' runs.
(dolist (dir '("test" "tmp"))
  (add-to-list 'user-lisp-ignored-directories dir))

(provide 'early-init)
;;; early-init.el ends here
