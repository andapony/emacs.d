;;; rjd-mail.el --- Mail accounts as mu4e contexts  -*- lexical-binding: t; -*-

;;; Commentary:

;; Stub of the interface ticket #7 owns, so that the calendar (#11) can
;; build on it in parallel.  #7's version replaces this file on merge.

;;; Code:

(defcustom rjd-mail-command-prefix nil
  "Command words put before every mail command, or nil to run it directly."
  :type '(choice (const :tag "None" nil) (repeat string))
  :group 'mail)

(defun rjd-mail-command (&rest argv)
  "Return ARGV with `rjd-mail-command-prefix' prepended."
  (append rjd-mail-command-prefix argv))

(provide 'rjd-mail)

;;; rjd-mail.el ends here
