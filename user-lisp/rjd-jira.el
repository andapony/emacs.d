;;; rjd-jira.el --- Jira utilities                   -*- lexical-binding: t; -*-
;; Copyright (C) 2025  Rob Duncan

;; Author: Rob Duncan <andapony@robduncan.info>
;; Keywords: tools, convenience

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; 

;;; Code:

(require 'org)

;; jiralib2 is not managed by this configuration; load it lazily so this
;; file still byte-compiles cleanly when it is absent.
(declare-function jiralib2-jql-search "jiralib2")

(defcustom rjd-jira/jira-org-path "~/Sync/org/agenda/Jira.org"
  "The path to store the Jira contents in."
  :type '(file :must-match t)
  :group 'rjd-jira)

(defvar rjd-jira/issue-impact-priority-map
  '(("Highest" . ?A)
    ("High" . ?B)
    ("Medium" . ?C)
    ("Low" . ?D))
  "Maps the issue impact to an `org-mode' TODO priority.")

(defun rjd-jira/org-priority-from-jira-priority (prio)
  "Return the `org-mode' priority value from the issue PRIO value."
  (cdr (assoc prio rjd-jira/issue-impact-priority-map)))

(defun rjd-jira/org-todo-state-from-jira-status (status)
  "Map Jira STATUS strings (from all projects) to an `org-mode' status codes."
  (cdr (assoc status '(("To Do" . "TODO")
		       ("To-Do" . "TODO")
		       ("NOT STARTED" . "TODO")
		       ("MORE DEFINITION REQUIRED" . "WAIT")
		       ("Blocked" . "WAIT")
		       ("IN CODE REVIEW" . "VIEW")
		       ("In Progress" . "WORK")
		       ("In Progress: Off Track" . "WORK")
		       ("In Progress: On Track" . "WORK")
		       ("On Pause" . "DONE")
		       ("Won't Do" . "DONE")
		       ("Done" . "DONE")))))

(defun rjd-jira/jira-sprint-field (issue field)
  "Return the Jira sprint FIELD for ISSUE."
  (let-alist issue
    (cdr (assoc field (car .fields.customfield_10020)))))

;;;###autoload
(defun rjd-jira/update-org-tasks ()
  "Build an `org-mode' file from the current Jira sprints."
  (interactive)
  (require 'jiralib2)
  (with-temp-file rjd-jira/jira-org-path
    (org-mode)
    (dolist (issue (jiralib2-jql-search "assignee = currentUser() AND resolution = Unresolved AND issuetype != Epic"))
      (rjd-jira/org-task-for-jira-issue issue))))

(defun rjd-jira/org-task-for-jira-issue (issue)
  "Create an `org-mode' TODO heading for Jira ISSUE."
  (let-alist issue
    (let ((sprint (rjd-jira/issue-active-sprint issue))
	  (due-date .fields.duedate))
      (when (and (rjd-jira/issue-open-p issue)
		 (or sprint due-date))
	(org-insert-todo-heading nil)
	(insert (concat .key ": " .fields.summary))
	(insert "\n")
	(org-back-to-heading nil)
	(org-priority (rjd-jira/org-priority-from-jira-priority .fields.priority.name))
	(org-todo (rjd-jira/org-todo-state-from-jira-status .fields.status.name))
	(org-set-property "jira-link" (concat "jira:" .key))
	(org-set-property "jira-status" .fields.status.name)
	(when sprint
	  (let-alist sprint
	    (org-set-property "jira-sprint" .name)
	    (org-set-property "jira-sprint-start-at" .startDate)
	    (org-set-property "jira-sprint-end-at" .endDate)
	    (org-schedule nil .startDate)))
	(when due-date
	  (org-deadline nil due-date))))))

(defun rjd-jira/issue-sprints (issue)
  "Return a list of sprints for ISSUE."
  (let-alist issue .fields.customfield_10020))

(defun rjd-jira/issue-open-p (issue)
  "Return whether ISSUE has one of the open statuses."
  (let-alist issue
    (not (equal (rjd-jira/org-todo-state-from-jira-status .fields.status.name) "DONE"))))

(defun rjd-jira/issue-active-sprint (issue)
  "Return the active sprint for ISSUE; or nil if there isn't one."
  (seq-find #'rjd-jira/sprint-active-p (rjd-jira/issue-sprints issue)))

(defun rjd-jira/sprint-active-p (sprint)
  "Return whether SPRINT is active."
  (let-alist sprint
    (equal .state "active")))

(provide 'rjd-jira)

;;; rjd-jira.el ends here
