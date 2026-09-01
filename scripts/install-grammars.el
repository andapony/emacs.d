;;; install-grammars.el --- Pre-build tree-sitter grammars  -*- lexical-binding: t; -*-

;;; Commentary:

;; Builds every tree-sitter grammar Emacs knows a recipe for, so that
;; editing never has to.  Grammar installation shells out to git and a C
;; compiler; running this from the setup playbook keeps that toolchain a
;; provisioning dependency rather than something needed at the moment a
;; file is opened.
;;
;; Usage:
;;
;;     emacs --batch -l scripts/install-grammars.el
;;     emacs --batch -l scripts/install-grammars.el -- /path/to/grammar/dir
;;
;; With no argument the grammars go to the standard location,
;; "tree-sitter" under `user-emacs-directory'.  Pass a directory to put
;; them elsewhere -- add that directory to `treesit-extra-load-path' in
;; init.el so Emacs can find them.
;;
;; Idempotent: grammars that already load are left alone, so it is cheap
;; to re-run.  Exits non-zero if any grammar fails to build.

;;; Code:

(require 'treesit)

(unless (treesit-available-p)
  (message "This Emacs was built without tree-sitter support.")
  (kill-emacs 1))

(defconst rjd/grammar-recipe-libraries
  '(c-ts-mode cmake-ts-mode csharp-mode css-mode dockerfile-ts-mode
    elixir-ts-mode go-ts-mode heex-ts-mode html-ts-mode java-ts-mode
    js json-ts-mode lua-ts-mode markdown-ts-mode php-ts-mode python
    ruby-ts-mode rust-ts-mode sh-script toml-ts-mode treesit-x
    typescript-ts-mode yaml-ts-mode)
  "Libraries that add entries to `treesit-language-source-alist'.
Each mode ships its own recipe, so the libraries have to be loaded
before the recipes become visible.")

(defconst rjd/grammar-skip '()
  "Languages to leave alone, for grammars that will not build here.")

(defconst rjd/grammar-default-directory
  (if (eq system-type 'darwin)
      "~/Library/Application Support/emacs/tree-sitter"
    "~/.local/lib/tree-sitter")
  "Where grammars go when no directory is given.
Keep in sync with `treesit-extra-load-path' in init.el.")

(defvar rjd/grammar-directory
  ;; "--" separates our arguments from Emacs's own and is left in the list.
  (let ((arg (car (delete "--" (copy-sequence command-line-args-left)))))
    (expand-file-name (or arg rjd/grammar-default-directory)))
  "Directory to install the grammar libraries into.")

;; `treesit-language-available-p' searches this, so a non-default target
;; has to be on it or every freshly built grammar reads as a failure.
(add-to-list 'treesit-extra-load-path rjd/grammar-directory)

(dolist (lib rjd/grammar-recipe-libraries)
  (unless (require lib nil :noerror)
    (message "note: no %s in this Emacs, skipping its recipes" lib)))

(let ((langs (sort (mapcar #'car treesit-language-source-alist) #'string<))
      (built 0) (present 0) (failed '()))
  (message "Installing tree-sitter grammars into %s\n" rjd/grammar-directory)
  (dolist (lang langs)
    (cond
     ((memq lang rjd/grammar-skip)
      (message "  skip     %s" lang))
     ((treesit-language-available-p lang)
      (setq present (1+ present))
      (message "  present  %s" lang))
     (t
      (condition-case err
          (progn
            (treesit-install-language-grammar lang rjd/grammar-directory)
            ;; A build failure is reported as a warning rather than
            ;; signalled, so confirm the grammar actually loads.
            (if (treesit-language-available-p lang)
                (progn (setq built (1+ built))
                       (message "  built    %s" lang))
              (push lang failed)
              (message "  FAILED   %s" lang)))
        (error
         (push lang failed)
         (message "  FAILED   %s (%s)" lang (error-message-string err)))))))
  (message "\n%d built, %d already present, %d failed" built present (length failed))
  (when failed
    (message "failed: %s"
             (mapconcat #'symbol-name (nreverse failed) " "))
    (kill-emacs 1)))

(provide 'install-grammars)

;;; install-grammars.el ends here
