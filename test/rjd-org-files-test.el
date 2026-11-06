;;; rjd-org-files-test.el --- Tests for the agenda's files from org-sync's list  -*- lexical-binding: t; -*-

;;; Commentary:

;; Which files the agenda, its inbox view and capture use, for each
;; list a machine might have: every file, the Cetos four only, the
;; personal four, and no list at all.  Every list is a temporary file,
;; never ~/.config/org-sync/files, and nothing is read from or written
;; to ~/org-agenda.
;;
;; Run from the checkout under test:
;;
;;   emacs -Q --batch -L user-lisp -l test/rjd-org-files-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(setq load-prefer-newer t)
(require 'rjd-org-files)

(defconst rjd/org-files-test-all
  "inbox.org\nprojects.org\nareas.org\nsomeday.org
cetos-inbox.org\ncetos-projects.org\ncetos-areas.org\ncetos-someday.org\n"
  "A list file naming all eight files.")

(defconst rjd/org-files-test-cetos
  "# Synced on the work machine\n\ncetos-inbox.org\ncetos-projects.org
  cetos-areas.org  \ncetos-someday.org\n\n"
  "A list file naming the Cetos four, with a comment and stray blanks.")

(defconst rjd/org-files-test-personal
  "inbox.org\nprojects.org\nareas.org\nsomeday.org\n"
  "A list file naming the personal four.")

(defmacro rjd/org-files-test-with-list (contents &rest body)
  "Run BODY with a list file holding CONTENTS, or with none if CONTENTS is nil."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "rjd-org-files" t))
          (rjd/org-files-list-file (file-name-concat dir "files"))
          (rjd/org-files-directory "~/org-agenda/"))
     (unwind-protect
         (progn
           (when ,contents
             (write-region ,contents nil rjd/org-files-list-file nil 'silent))
           ,@body)
       (delete-directory dir t))))

(defun rjd/org-files-test-paths (&rest names)
  "NAMES, each in ~/org-agenda/."
  (mapcar (lambda (name) (concat "~/org-agenda/" name)) names))


;;; Every file

(ert-deftest rjd/org-files-all-eight ()
  "With every file listed, the agenda reads all eight, in the list's order."
  (rjd/org-files-test-with-list rjd/org-files-test-all
    (should (equal (rjd/org-files-agenda-files)
                   (rjd/org-files-test-paths
                    "inbox.org" "projects.org" "areas.org" "someday.org"
                    "cetos-inbox.org" "cetos-projects.org"
                    "cetos-areas.org" "cetos-someday.org")))
    (should (equal (rjd/org-files-inboxes)
                   (rjd/org-files-test-paths "inbox.org" "cetos-inbox.org")))))

(ert-deftest rjd/org-files-all-eight-capture ()
  "With both inboxes listed, capture goes to the personal one.
The Cetos inbox is given for a template of its own."
  (rjd/org-files-test-with-list rjd/org-files-test-all
    (should (equal (rjd/org-files-capture-inbox) "~/org-agenda/inbox.org"))
    (should (equal (rjd/org-files-cetos-inbox)
                   "~/org-agenda/cetos-inbox.org"))))


;;; The Cetos four

(ert-deftest rjd/org-files-cetos-only ()
  "With only the Cetos four listed, the agenda and inbox are theirs.
The comment and the blank lines are not files, and the space round a
name is not part of it."
  (rjd/org-files-test-with-list rjd/org-files-test-cetos
    (should (equal (rjd/org-files-agenda-files)
                   (rjd/org-files-test-paths
                    "cetos-inbox.org" "cetos-projects.org"
                    "cetos-areas.org" "cetos-someday.org")))
    (should (equal (rjd/org-files-inboxes)
                   (rjd/org-files-test-paths "cetos-inbox.org")))))

(ert-deftest rjd/org-files-cetos-only-capture ()
  "With only the Cetos inbox listed, capture goes there, with no second one."
  (rjd/org-files-test-with-list rjd/org-files-test-cetos
    (should (equal (rjd/org-files-capture-inbox)
                   "~/org-agenda/cetos-inbox.org"))
    (should-not (rjd/org-files-cetos-inbox))))


;;; The personal four

(ert-deftest rjd/org-files-personal-four ()
  "With the personal four listed, the agenda is as it always was."
  (rjd/org-files-test-with-list rjd/org-files-test-personal
    (should (equal (rjd/org-files-agenda-files)
                   (rjd/org-files-test-paths
                    "inbox.org" "projects.org" "areas.org" "someday.org")))
    (should (equal (rjd/org-files-inboxes)
                   (rjd/org-files-test-paths "inbox.org")))))

(ert-deftest rjd/org-files-personal-four-capture ()
  "With the personal four listed, capture goes to inbox.org, with no second."
  (rjd/org-files-test-with-list rjd/org-files-test-personal
    (should (equal (rjd/org-files-capture-inbox) "~/org-agenda/inbox.org"))
    (should-not (rjd/org-files-cetos-inbox))))


;;; No list

(ert-deftest rjd/org-files-no-list ()
  "Without a list, the agenda is the personal four, in today's order."
  (rjd/org-files-test-with-list nil
    (should-not (file-exists-p rjd/org-files-list-file))
    (should (equal (rjd/org-files-agenda-files)
                   (rjd/org-files-test-paths
                    "inbox.org" "projects.org" "areas.org" "someday.org")))
    (should (equal (rjd/org-files-inboxes)
                   (rjd/org-files-test-paths "inbox.org")))))

(ert-deftest rjd/org-files-no-list-capture ()
  "Without a list, capture goes to inbox.org, with no second inbox."
  (rjd/org-files-test-with-list nil
    (should (equal (rjd/org-files-capture-inbox) "~/org-agenda/inbox.org"))
    (should-not (rjd/org-files-cetos-inbox))))

(ert-deftest rjd/org-files-no-list-is-not-shared ()
  "The fallback is a fresh list, so a caller changing it changes no default."
  (rjd/org-files-test-with-list nil
    (setcar (rjd/org-files-names) "changed.org")
    (should (equal (car (rjd/org-files-names)) "inbox.org"))))


;;; Odd lists

(ert-deftest rjd/org-files-names-with-a-slash-are-ignored ()
  "A name with a `/' could reach outside ~/org-agenda, so is not a file."
  (rjd/org-files-test-with-list "inbox.org\n../secret.org\n/etc/passwd\n"
    (should (equal (rjd/org-files-agenda-files)
                   (rjd/org-files-test-paths "inbox.org")))))

(ert-deftest rjd/org-files-no-inbox-listed-captures-to-inbox ()
  "A list naming neither inbox still captures into inbox.org."
  (rjd/org-files-test-with-list "projects.org\n"
    (should-not (rjd/org-files-inboxes))
    (should (equal (rjd/org-files-capture-inbox) "~/org-agenda/inbox.org"))
    (should-not (rjd/org-files-cetos-inbox))))

;;; rjd-org-files-test.el ends here
