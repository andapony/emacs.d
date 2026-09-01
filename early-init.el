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

(provide 'early-init)
;;; early-init.el ends here
