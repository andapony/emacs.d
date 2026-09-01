;;; rjd-elfeed-search-contents.el --- Full-text search over elfeed article content  -*- lexical-binding: t -*-

;;; Commentary:
;; Provides `rjd/elfeed-search-content', which uses ripgrep to search the raw
;; article files in the elfeed data directory, then maps the matching files
;; back to elfeed entries and displays results in a browseable buffer.

;;; Code:

(require 'elfeed)
(require 'elfeed-db)

;;;###autoload
(defun rjd/elfeed-search-content (regexp)
  "Search elfeed article content for REGEXP and display matching entry titles.
Results are shown in a dedicated buffer sorted newest-first.
RET on a title opens the entry via `elfeed-show-entry'.
Requires rg (ripgrep) to be on PATH."
  (interactive "sSearch elfeed content (regexp): ")
  (let* (;; The elfeed data directory holds one file per article, named by
         ;; the SHA1 hash of its content (the elfeed-ref id).
         (data-dir (expand-file-name "data" elfeed-db-directory))

         ;; Use rg to find files whose content matches REGEXP, then extract
         ;; just the basename (the hash) from each returned path.
         (matched-hashes
          (mapcar #'file-name-nondirectory
                  (split-string
                   (shell-command-to-string
                    (format "rg --files-with-matches --regexp %s %s"
                            (shell-quote-argument regexp)
                            (shell-quote-argument data-dir)))
                   "\n" t)))

         ;; Store matched hashes in a hash-table for O(1) lookup below.
         (hash-set (make-hash-table :test #'equal))

         ;; Accumulator for matching elfeed entry structs.
         (matches '()))

    (if (null matched-hashes)
        (message "No elfeed articles matching: %s" regexp)

      (dolist (h matched-hashes)
        (puthash h t hash-set))

      ;; Ensure the elfeed database is loaded into memory before walking it.
      (elfeed-db-load)

      ;; Walk every entry in the database.  For each entry, retrieve its
      ;; content ref (an elfeed-ref struct) and compare its id (the hash)
      ;; against our set of rg-matched hashes.
      (maphash
       (lambda (_id entry)
         (when-let* ((ref (elfeed-entry-content entry))
                     (id  (elfeed-ref-id ref)))
           (when (gethash id hash-set)
             (push entry matches))))
       (plist-get elfeed-db :entries))

      (if (null matches)
          ;; This would mean rg found files that no live entry points to —
          ;; e.g. orphaned content from deleted entries.
          (message "Files matched but no elfeed entries found for: %s" regexp)

        (let ((buf (get-buffer-create (format "*rjd/elfeed-search: %s*" regexp))))
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              ;; Insert one line per match, newest-first, with the date
              ;; prepended.  Store the entry struct as a text property on
              ;; the line so RET can retrieve it without a second lookup.
              (dolist (entry (sort matches
                                   (lambda (a b)
                                     (> (elfeed-entry-date a)
                                        (elfeed-entry-date b)))))
                (let ((beg (point)))
                  (insert (format-time-string "%Y-%m-%d  " (elfeed-entry-date entry))
                          (elfeed-entry-title entry)
                          "\n")
                  (put-text-property beg (1- (point)) 'elfeed-entry entry)))
              (goto-char (point-min)))
            (setq buffer-read-only t)
            (use-local-map (make-sparse-keymap))
            (local-set-key (kbd "RET")
                           (lambda ()
                             (interactive)
                             (when-let* ((entry (get-text-property (point) 'elfeed-entry)))
                               (elfeed-show-entry entry))))
            (local-set-key (kbd "q") #'quit-window))
          (switch-to-buffer buf))))))

(provide 'rjd-elfeed-search-contents)

;;; rjd-elfeed-search-contents.el ends here
