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

(provide 'early-init)
;;; early-init.el ends here
