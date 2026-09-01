;;; init.el --- Emacs configuration  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved) -*-

;;; Commentary:
;; Personal Emacs configuration.
;;
;; Layout: core Emacs comes first -- bootstrap, built-in behaviour, and the
;; development tooling that ships with Emacs -- followed by third-party
;; packages grouped by what they are for.  Sections use `;;;' headers, so
;; `outline-minor-mode' and `consult-outline' can navigate between them.
;;
;; Key spellings: for the few keys that have both an ASCII name and a
;; function-key name, bind the ASCII one -- TAB not <tab>, RET not
;; <return>, and likewise ESC, DEL (<backspace>, <delete>) and C-j
;; (<linefeed>).  A window system sends the function-key event and, when
;; that is unbound, falls back through `function-key-map' to the ASCII
;; character; a terminal only ever sends the character, and no fallback
;; runs in the other direction.  So a binding on <tab> takes GUI frames
;; and silently does nothing under `emacsclient -nw', which is the worse
;; failure of the two -- the key keeps working, it just means something
;; else.  The fallback carries modifiers, which is how org's M-RET answers
;; Meta-Return on a GUI frame despite org never binding M-<return>.
;;
;; Reach for the function-key name only to tell the two apart on purpose.
;; Keys with no ASCII form -- <f5>, the arrows -- are unaffected.

;;; Code:

;;; Package management

;;
;; Uses the built-in package.el with MELPA.  use-package is built into
;; Emacs 29+.
(require 'package)

(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)

(package-initialize)

;; Packages that live in a Git repository rather than an archive are
;; declared in private.el, which is loaded further down: the repositories
;; are not public, so neither their URLs nor the fact of them belongs here.

;;; Custom file

;;
;; Keeps customize from appending to this file.
(use-package emacs
  :config
  (setq custom-file (file-name-concat user-emacs-directory "custom.el"))
  (unless (file-exists-p custom-file)
    (write-region "" nil custom-file))
  (load custom-file))

;;; Private settings

;;
;; Personal values that have no place in a public repository: the mail
;; identity to send as, calendar endpoints, paths to unpublished work, what
;; I read, and the whole configuration of local and git-hosted packages that
;; have never been released.  Loaded
;; after custom.el, so it wins over anything Customize has written.  The
;; setup repo symlinks it into place; tolerate its absence so that a bare
;; checkout still loads, which means anything set there must also have a
;; usable default where it is declared.
(load (file-name-concat user-emacs-directory "private.el") :noerror :nomessage)

;;; Load path

;;
;; Emacs 31 byte-compiles user-lisp/, scrapes it for `;;;###autoload'
;; cookies and adds it to `load-path' automatically, so nothing here needs
;; to require those files.  Only vendor/ still needs adding by hand.
(use-package emacs
  :config
  (add-to-list 'load-path (file-name-concat user-emacs-directory "vendor"))

  ;; Before Emacs 31 there is no user-lisp/ handling at all, so put it on
  ;; `load-path' by hand.  Nothing there is autoloaded on those versions --
  ;; the commands need an explicit `load-library' first -- but the directory
  ;; is at least reachable rather than invisible.
  (unless (boundp 'user-lisp-directory)
    (add-to-list 'load-path
                 (file-name-concat user-emacs-directory "user-lisp"))))

;;; Environment

;; A GUI Emacs is started by the window server or a desktop launcher rather
;; than by a shell, so it inherits none of the login shell's environment --
;; PATH above all, which everything below relies on to find gopls, clangd,
;; aspell and the rest.  A terminal Emacs already has it, hence the test.
;;
;; `ns' is the macOS Cocoa build; `x' and `pgtk' are the two Linux ones,
;; pgtk being the Wayland-native build.  Not `mac' -- that value belongs to
;; the third-party emacs-mac port, not to GNU Emacs, whose `window-system'
;; only ever reports the values above.
;;
;; `daemonp' covers what the frame test cannot: under --daemon no frame
;; exists yet at init time, so `window-system' is nil and the import would
;; be skipped for every emacsclient frame that followed.
(use-package exec-path-from-shell
  :ensure t
  :if (or (daemonp) (memq window-system '(ns x pgtk)))
  :config
  (exec-path-from-shell-initialize))

;;; Frames, theme and fonts

(use-package emacs
  :custom
  (inhibit-startup-screen t)
  (menu-bar-mode nil)
  (tool-bar-mode nil)
  (scroll-bar-mode nil)
  (visible-bell t)
  :init
  (add-to-list 'initial-frame-alist '(fullscreen . maximized)))

(use-package emacs
  :init
  (setq modus-themes-italic-constructs t
        modus-themes-bold-constructs t
        modus-themes-region '(bg-only no-extend)
        modus-themes-org-blocks 'gray-background
        modus-themes-mixed-fonts t)
  :config
  (load-theme 'modus-operandi :no-confirm)
  :bind ("<f5>" . modus-themes-toggle))

;; See prot's notes on mixed font heights:
;; https://protesilaos.com/codelog/2020-09-05-emacs-note-mixed-font-heights/
;;
;; `fixed-pitch' and `variable-pitch' take a :height of 1.0 so they scale
;; with `default' rather than pinning an absolute size of their own.
(defconst rjd/mono-spaced-font "Ubuntu Mono"
  "Font family for `default' and `fixed-pitch'.")

(defconst rjd/proportionately-spaced-font "Ubuntu"
  "Font family for `variable-pitch'.")

;; TODO: confirm which way round this goes.  Leroy and Bulldog take the
;; lower value, which implies they render larger per unit of height, but they
;; were described as rendering smaller -- which would call for a higher
;; number, not 110.  Check on one of them and make the docstring say the real
;; reason.
(defun rjd/default-font-height ()
  "Return an appropriate default font height.
Leroy and Bulldog render at a different scale from the other machines,
so they are calibrated separately rather than taking the 140 used
everywhere else."
  (cond ((member (system-name) '("Leroy" "Bulldog")) 110)
        (t 140)))

(use-package emacs
  :config
  (set-face-attribute 'default nil
                      :family rjd/mono-spaced-font
                      :height (rjd/default-font-height))
  (set-face-attribute 'fixed-pitch nil
                      :family rjd/mono-spaced-font :height 1.0)
  (set-face-attribute 'variable-pitch nil
                      :family rjd/proportionately-spaced-font :height 1.0))

;;; Editing defaults

(use-package emacs
  :custom
  (ispell-program-name "aspell"))

(use-package emacs
  :custom
  ;; TAB indents the line; when it is already indented, it completes instead.
  ;; This is what routes TAB into `completion-at-point' rather than needing a
  ;; separate key.  A showing preview takes TAB over to
  ;; `rjd/completion-preview-list-or-insert', which opens "*Completions*"
  ;; whenever there is a choice to make -- the same "offer me more" that TAB
  ;; means here.
  (tab-always-indent 'complete)
  ;; Drop commands from M-x that do not apply to the current major mode --
  ;; no org commands while editing Go, and so on.
  (read-extended-command-predicate #'command-completion-default-include-p))

;;; Buffers, files and history

;; Runs `clean-buffer-list' once a day, retiring buffers that have not been
;; displayed for a few days.  Stops a long-lived session from silting up with
;; hundreds of stale file buffers.
(use-package emacs
  :config
  (midnight-mode))

(use-package ibuffer
  :bind (("C-x C-b" . ibuffer)))

(use-package emacs
  :config
  (global-auto-revert-mode)
  (recentf-mode 1))

(use-package dired
  :preface
  (defun rjd/dired-do-occur (regexp)
    "Run `occur' with REGEXP on marked files in dired."
    (interactive "sRegexp: ")
    (multi-occur
     (mapcar #'find-file-noselect (dired-get-marked-files))
     regexp))
  :custom
  ;; macOS ships BSD ls, which has no --dired, so dired probes for it on
  ;; the first listing and reports the failure in *Messages*.  Answer the
  ;; question up front instead, preferring coreutils' gls where it is
  ;; installed: --dired is what lets dired locate file names exactly rather
  ;; than parsing them back out of the listing, which is what makes names
  ;; containing spaces or newlines work.  `exec-path-from-shell' has run by
  ;; here, so a Homebrew gls is on `exec-path'.  The container's Emacs finds
  ;; no gls but has GNU ls, hence the `system-type' arm.
  (insert-directory-program (or (executable-find "gls") insert-directory-program))
  (dired-use-ls-dired (or (and (executable-find "gls") t)
                          (not (eq system-type 'darwin))))
  :bind (:map dired-mode-map
              ("O" . rjd/dired-do-occur)))

(use-package savehist
  :config
  (savehist-mode))

;;; Web

(use-package eww
  :defer t
  :custom
  (shr-image-animate nil))

(use-package browse-url
  :defer t
  :custom
  (browse-url-browser-function 'eww-browse-url))

;;; Remote hosts

;; Both settings below apply to any Tramp method, and none of this loads
;; until a remote file name is opened.  Nothing here is routine any more:
;; the multipass VMs this once served are gone, and the claude-dev
;; container needs no remote access at all because ~/projects is mounted
;; at the same path inside and out.  Kept because it is what makes an
;; occasional /ssh: hop behave.
(use-package tramp
  :defer t
  :config
  ;; A placeholder Tramp replaces with the remote account's own PATH, so
  ;; tools installed under that user's profile are found rather than only
  ;; those on Tramp's built-in default path.
  (add-to-list 'tramp-remote-path 'tramp-own-remote-path)

  ;; -i so a remote `M-x shell' gets an interactive bash that reads the
  ;; remote .bashrc.
  (connection-local-set-profile-variables
   'remote-bash-profile
   '((explicit-shell-file-name . "/bin/bash")
     (explicit-bash-args . ("-i"))))
  (connection-local-set-profiles
   '(:application tramp)
   'remote-bash-profile))

;;; Development

(global-set-key [C-mouse-1] 'xref-find-definitions-at-mouse)

(global-set-key [C-down-mouse-1] nil)

(global-set-key [C-mouse-3] 'xref-go-back)

(global-set-key [C-down-mouse-3] nil)

;; Emacs 31 reaches a tree-sitter mode by two different routes, and t turns
;; on both:
;;
;;   - Languages that already have a traditional mode (python, c, sh, css,
;;     js, ruby ...) are swapped for the ts equivalent through
;;     `major-mode-remap-alist'.
;;   - Languages that have none (yaml, rust, typescript, dockerfile, cmake)
;;     are dispatched via a `foo-ts-mode-maybe' function that falls back to
;;     `fundamental-mode' unless enabled here.
;;
;; That second group is why this is t rather than a list of the languages
;; used here: .yaml, .yml, Dockerfile and CMakeLists.txt were otherwise
;; getting no major mode at all.
;;
;; Grammars are fetched on first visit, which needs network plus a C
;; compiler.  `treesit-auto-install-grammar' is `always' here rather than
;; its default `ask' for two reasons: declining the prompt leaves the buffer
;; in a ts mode with no parser, which is worse than the mode it replaced,
;; and the prompt has nothing to read from under `emacs --batch', so it
;; blocks there outright.  scripts/install-grammars.el is the bulk route
;; that keeps first visits from paying for this at all.
;;
;; The dodge, should a particular swap prove unwelcome: enable everything,
;; then delete that one entry.  For instance sh-mode understands dialects
;; the bash grammar does not, and mhtml-mode does sub-mode editing inside
;; <script>/<style> blocks:
;;
;;   :config
;;   (dolist (m '((sh-mode . bash-ts-mode) (mhtml-mode . html-ts-mode)))
;;     (setq major-mode-remap-alist (delete m major-mode-remap-alist)))
;;
;; Remapped buffers run `foo-ts-mode-hook' and use `foo-ts-mode-map' -- the
;; ts mode is not derived from the old one.  Per-language configuration must
;; therefore use the ts spelling or it silently does nothing, which is why
;; the Go, C and Markdown configuration below names only the ts modes --
;; entries under the old names would never fire.
(use-package emacs
  :custom
  (treesit-enabled-modes t)
  (treesit-auto-install-grammar 'always)
  ;; Grammars are platform-specific shared libraries (.so on Linux, .dylib
  ;; on macOS), so they cannot be shared between machines.  Keep them out of
  ;; ~/.emacs.d, which on macOS is a symlink into this repo -- build output
  ;; does not belong in the working tree.  Populate with
  ;; scripts/install-grammars.el; keep this in sync with the default there.
  (treesit-extra-load-path
   (list (expand-file-name
          (if (eq system-type 'darwin)
              "~/Library/Application Support/emacs/tree-sitter"
            "~/.local/lib/tree-sitter")))))

(use-package project
  :preface
  (defun rjd/project-find-go-module (dir)
    "Return a Go module project for DIR, or nil if none found."
    (when-let* ((root (locate-dominating-file dir "go.mod")))
      (cons 'go-module root)))
  :custom
  (project-mode-line t)
  (project-switch-commands
   '((project-find-file "Find file")
     (project-find-regexp "Find regexp")
     (project-find-dir "Find directory")
     (magit-project-status "Magit" 109)
     (project-shell "Shell" 115)))
  :bind (:map project-prefix-map
              ;; New in Emacs 31, and the only one of its project additions
              ;; without a default binding.  Jumps to the same file in another
              ;; project, which is what you want across git worktrees.
              ("m" . project-find-matching-buffer))
  :config
  (cl-defmethod project-root ((project (head go-module)))
    (cdr project))

  (add-hook 'project-find-functions #'rjd/project-find-go-module))

;; Diagnostics navigation moves off M-n/M-p, which now walk completion
;; candidates in both the preview and "*Completions*" maps.  `next-error'
;; (M-g n, M-g M-n) is where Emacs puts this anyway, and flycheck already
;; supplies a `next-error-function', so teaching flymake to do the same
;; leaves one pair of keys for diagnostics whichever checker produced them.
(use-package flymake
  :preface
  ;; `flymake-mode's docstring suggests setting `next-error-function' to
  ;; `flymake-goto-next-error' directly, but their arguments disagree:
  ;; `next-error' passes RESET in the slot flymake reads as FILTER, a list
  ;; of diagnostic types, which it then searches -- so a reset (the first
  ;; M-g n in a buffer, or M-g <) fails with (wrong-type-argument sequencep
  ;; t).  Going through a wrapper keeps RESET meaning what it should.
  (defun rjd/flymake-next-error (n reset)
    "Move to the Nth next Flymake diagnostic, starting over if RESET.
Adapts `flymake-goto-next-error' to the `next-error-function' calling
convention."
    (when reset (goto-char (point-min)))
    (flymake-goto-next-error n nil t))

  (defun rjd/flymake-use-next-error ()
    "Point `next-error' at Flymake's diagnostics in the current buffer."
    (when flymake-mode
      (setq-local next-error-function #'rjd/flymake-next-error)))
  :config
  (add-hook 'flymake-mode-hook #'rjd/flymake-use-next-error))

;; Not used for snippets of our own -- there are none, and no snippet
;; library is installed.  It is here solely because eglot expands LSP
;; completions through `yas-expand-snippet': `eglot--snippet-expansion-fn'
;; tests `fboundp' on `yas-minor-mode', which an autoload satisfies, and
;; enables the minor mode itself when a server first sends a template.
;;
;; Without it eglot advertises :snippetSupport :json-false and clangd drops
;; the parameter fields from every function completion.  So it looks unused
;; and is not: leave it declared next to the package that needs it.
(use-package yasnippet
  :ensure t
  :defer t)

(use-package eglot
  :defer t
  :preface
  ;; :preface, not :config: this runs from the mode hook, which can fire
  ;; before eglot has been loaded.  `:preface' is evaluated as init.el is
  ;; read, outside the `eval-after-load' that `:config' expands into.
  (defun rjd/eglot-format-buffer-on-save ()
    "Add a buffer-local hook to format the buffer via eglot before saving."
    (add-hook 'before-save-hook #'eglot-format-buffer -10 t))
  :config
  ;; JUCE projects have thousands of headers; 30s default is too short for
  ;; the initial clangd index build.
  (setq eglot-connect-timeout 120)

  ;; `usePlaceholders' makes gopls send a completion carrying the whole
  ;; signature -- Printf(${1:format}, ${2:a ...any}) -- rather than just the
  ;; name and parentheses.  It is inert without the snippet support declared
  ;; above the eglot block.
  (setq-default eglot-workspace-configuration
                '((:gopls . ((staticcheck . t)
                             (matcher . "CaseSensitive")
                             (gofumpt . t)
                             (usePlaceholders . t)))))

  ;; Format on save is deliberately Go-only.  gofmt is canonical, so
  ;; reformatting a Go buffer is uncontroversial.  C and C++ have no
  ;; equivalent consensus and clangd applies whatever .clang-format it
  ;; happens to find, which can rewrite far more than the current edit.
  ;; Left off pending a decision about what is actually wanted there --
  ;; the omission is the point, not an oversight.
  ;; Tree-sitter modes only.  `treesit-enabled-modes' is t, so c-mode,
  ;; c++-mode and go-mode are all remapped before their hooks would run --
  ;; entries for them never fire.
  :hook ((go-ts-mode . eglot-ensure)
         (go-ts-mode . rjd/eglot-format-buffer-on-save)
         (c-ts-mode . eglot-ensure)
         (c++-ts-mode . eglot-ensure)))

;;; Org

(use-package org
  :preface
  (defun rjd/org-mode-setup ()
    "Enable variable-pitch and visual-line modes for org buffers."
    (variable-pitch-mode 1)
    (visual-line-mode 1))

  (defun rjd/org-fix-blank-lines (&optional subtree)
    "Normalize the blank lines before Org headings to exactly one.
Operate on the whole buffer; with a prefix arg SUBTREE, only on the
subtree at point.  Every heading is left with exactly one blank line above
it -- runs of excess blanks are collapsed and missing ones inserted --
except a heading at the very top of the buffer, which gets none.  Body
text and drawers are left untouched.

Heading markers are collected first and the buffer edited afterward:
mutating the text before a heading while `org-map-entries' is still
traversing corrupts its iteration."
    (interactive "P")
    (save-excursion
      (let ((markers (org-map-entries #'point-marker t
                                      (if subtree 'tree nil))))
        (dolist (m markers)
          (goto-char m)
          (let ((heading (point)))
            (skip-chars-backward "\n")
            (delete-region (point) heading)
            (unless (bobp)
              (insert "\n\n")))
          (set-marker m nil)))))
  :custom
  ;; An org.el option despite the name, and read by `org-refile-targets'
  ;; below as much as by the agenda -- so it belongs here, not in the
  ;; org-agenda block.
  (org-agenda-files '("~/org-agenda/inbox.org"
                      "~/org-agenda/projects.org"
                      "~/org-agenda/areas.org"
                      "~/org-agenda/someday.org"))
  (org-directory "~/org-agenda")
  (org-ellipsis "…")
  (org-hide-emphasis-markers t)
  (org-image-actual-width nil)
  (org-image-max-width 'window)
  (org-log-done 'time)
  (org-log-into-drawer t)
  (org-pretty-entities t)
  (org-refile-targets '((org-agenda-files :maxlevel . 3)))
  ;; Offer the whole outline path as a single candidate instead of
  ;; descending one level at a time.  The stepwise default suits setups
  ;; without a completion UI; with candidates filtered as you type, the
  ;; full path can be matched in one go.
  (org-refile-use-outline-path 'file)
  (org-outline-path-complete-in-steps nil)
  (org-reverse-note-order t)
  (org-special-ctrl-a/e t)
  (org-todo-keywords '((sequence "TODO" "NEXT" "WAITING" "|" "DONE" "CANCELLED")))
  ;; Faces rather than colour strings.  <f5> toggles between modus-operandi
  ;; and modus-vivendi, and a literal colour cannot follow: "light blue" on
  ;; the light theme's white background had no contrast to speak of.  These
  ;; three are defined by both themes, checked for contrast at either
  ;; polarity, and `warning'/`shadow' land on much the same hues the strings
  ;; were reaching for.
  (org-todo-keyword-faces
   '(("NEXT"      . font-lock-keyword-face)
     ("WAITING"   . warning)
     ("CANCELLED" . shadow)))
  :config
  (add-hook 'org-mode-hook #'rjd/org-mode-setup)
  ;; Restores the "<el TAB" structure-template expansion that org moved out
  ;; of core after 9.1; entries in `org-structure-template-alist' become
  ;; tempo shortcuts again.
  (require 'org-tempo)
  (add-to-list 'org-structure-template-alist '("el" . "src emacs-lisp"))
  ;; Register mu4e as a known link type so org-lint doesn't flag mu4e: links
  ;; as unknown fuzzy locations when mu4e isn't loaded yet.
  (org-link-set-parameters "mu4e")
  :bind (("C-c l" . org-store-link)
         ("C-c c" . org-capture)
         ("C-c a" . org-agenda)
         (:map org-mode-map
               ("C-c b" . rjd/org-fix-blank-lines))))

(use-package org-agenda
  :defer t
  :custom
  (org-agenda-show-all-dates nil)
  (org-agenda-skip-deadline-if-done t)
  (org-agenda-skip-scheduled-if-deadline-is-shown t)
  (org-agenda-skip-scheduled-if-done t)
  (org-agenda-span 'day)
  (org-agenda-tags-column 0)
  (org-agenda-todo-ignore-deadlines 'near)
  (org-agenda-todo-ignore-scheduled 'all)
  (org-agenda-window-setup 'current-window)
  (org-deadline-warning-days 21)
  (org-agenda-custom-commands
   '(("d" "Dashboard"
      ((agenda "" ((org-agenda-span 7)))
       (todo "NEXT"
             ((org-agenda-overriding-header "Next Actions")))
       (todo "WAITING"
             ((org-agenda-overriding-header "Waiting For")))
       (todo "TODO"
             ((org-agenda-files '("~/org-agenda/inbox.org"))
              (org-agenda-overriding-header "Inbox (process me)"))))))))

(use-package org-capture
  :defer t
  :custom
  (org-capture-templates
   '(("n" "New note (with Denote)" plain
      (file denote-last-path)
      #'denote-org-capture :jump-to-captured t :kill-buffer t :no-save t :immediate-finish nil)
     ("i" "Inbox" entry
      (file "~/org-agenda/inbox.org")
      "* TODO %?\n  %U" :prepend nil :empty-lines 1)
     ("N" "Note" entry
      (file "~/org-agenda/inbox.org")
      "* %?\n  %U" :prepend nil :empty-lines 1)
     ;; `org-web-tools--url-as-readable-org' is private.  A rename upstream
     ;; takes this template out with a void-function error at capture time,
     ;; not at load, so it will look like a capture problem rather than a
     ;; dependency one.
     ("a" "Link to web page (alphapapa)" entry
      (file+olp+datetree "~/Sync/org-more/alphapapa-links.org")
      "%(org-web-tools--url-as-readable-org)" :empty-lines 1)
     ("h" "Heirloom task" entry
      (file+olp+datetree "~/Sync/org/heirloom.org" "Heirloom")
      "* %^{Task description} :%^{Tag|misc|meeting|review|code}:\n%U"
      :clock-in t :clock-keep t)
     )))

;; Settings for `org-icalendar-combine-agenda-files', which writes the
;; combined .ics that the calendar subscribes to.  Nothing in this file
;; calls it -- the export is run on demand or from outside Emacs.
(use-package ox-icalendar
  :defer t
  :custom
  (org-icalendar-combined-agenda-file "~/Sync/org/agenda.ics")
  (org-icalendar-include-todo t)
  (org-icalendar-use-deadline '(event-if-todo event-if-not-todo))
  (org-icalendar-use-scheduled '(event-if-todo)))

;; Loaded from vendor/, which the setup repo symlinks into place; tolerate
;; its absence so the rest of this file still loads on a bare checkout.
(when (require 'rjd-org-sync nil :noerror)
  (rjd/org-sync-setup))

;;; Appearance

(use-package spacious-padding
  :ensure t
  :custom
  (spacious-padding-subtle-frame-lines t)
  :config
  (spacious-padding-mode 1))

(use-package org-modern
  :ensure t
  :after org
  :custom
  (org-modern-star nil)
  :config
  ;; org-modern's own face, so it can only be set once the package has
  ;; loaded.  The rest of the font setup is under "Frames, theme and fonts".
  (set-face-attribute 'org-modern-symbol nil
                      :family rjd/mono-spaced-font :height 1.0)
  (global-org-modern-mode))

;;; Interface

(use-package diminish
  :ensure t
  :config
  (diminish 'visual-line-mode)
  ;; `variable-pitch-mode' is a thin wrapper over `buffer-face-mode', so
  ;; `rjd/org-mode-setup' turns the latter on in every org buffer.
  (diminish 'buffer-face-mode))

;; Built into Emacs since 30.1, so there is nothing to :ensure -- package.el
;; counts it as installed and would never fetch it anyway.  `which-key-mode'
;; is off by default, though, so it does have to be turned on.
(use-package which-key
  :custom
  (which-key-idle-delay 0.5)
  ;; Blanked rather than diminished.  The lighter is a plain user option, so
  ;; setting it here drops this block's dependency on diminish loading first.
  (which-key-lighter "")
  :config
  (which-key-mode))

;;; Completion

(use-package orderless
  :ensure t
  :custom
  ;; `basic' first, so a literal prefix match settles before orderless's
  ;; unordered matching is considered at all.
  (completion-styles '(basic orderless))
  ;; The default pins `styles' per completion category -- buffer,
  ;; project-file and xref-location among them -- which would override
  ;; `completion-styles' in precisely the places orderless is most wanted.
  (completion-category-defaults nil))

;; Emacs 31's own minibuffer completion, in place of vertico.  Two new
;; options do most of what `vertico-mode' did: `completion-eager-display'
;; puts "*Completions*" on screen as soon as the minibuffer opens rather
;; than waiting for TAB, and `completion-eager-update' refilters it as you
;; type.  Both default to `auto', which leaves the choice to the completion
;; table, so only forcing them on makes every command behave alike.
;;
;; M-n/M-p here match the `completion-preview-active-mode-map' bindings
;; further down, so the same two keys walk the candidates whether they are
;; inline or in "*Completions*".  Accepting is M-RET in both places, which
;; `completion-in-region-mode-map' already binds, so it needs nothing here.
(use-package minibuffer
  ;; :bind needs the keymap, which lives in this file.
  :demand t
  :bind (:map completion-in-region-mode-map
              ("M-n" . minibuffer-next-completion)
              ("M-p" . minibuffer-previous-completion))
  :custom
  (completion-eager-display t)
  ;; The one to back off first.  Refiltering on every keystroke is what
  ;; makes this feel like vertico, but the manual warns it can slow typing
  ;; on large or inefficient tables; `auto' restores the table's own say.
  (completion-eager-update t)
  ;; UP/DOWN also walk the list while LEFT/RIGHT still move point in what
  ;; you have typed, and RET takes the selected candidate.  The `up-down'
  ;; value is new in 31.1 -- plain t gives all four arrows to the list,
  ;; which makes editing the input awkward.
  (minibuffer-visible-completions 'up-down)
  ;; Recently chosen candidates first, rather than strict alphabetical.
  (completions-sort 'historical)
  ;; One candidate per line, rather than the default newspaper columns.
  ;; Also one of the two formats the 31.1 lazy-insertion optimisation
  ;; applies to, which matters once eager display shows every list.
  (completions-format 'one-column)
  (completions-max-height 15)
  ;; The "N possible completions:" heading is noise when the buffer is on
  ;; screen for every prompt.
  (completions-header-format nil)
  ;; Annotate candidates with what they are -- function signatures and the
  ;; first line of a docstring for elisp, LSP detail for eglot's modes.
  (completions-detailed t))

;; Marginalia annotates the completion metadata rather than the UI, so it
;; is not tied to vertico and keeps working against "*Completions*".
(use-package marginalia
  :ensure t
  :config
  (marginalia-mode))

;; Emacs 31's own in-buffer completion, in place of corfu.  Two halves that
;; complement each other: `completion-preview-mode' shows the leading
;; candidate inline as you type, and `completion-at-point' (on TAB, via
;; `tab-always-indent') opens "*Completions*" for the full list.
;;
;; Unlike corfu, whose `corfu-auto' defaults to nil, the preview is
;; automatic -- it appears without being asked for.  `completion-preview-
;; minimum-symbol-length' keeps it quiet until there is enough of a symbol
;; to be worth completing.
(use-package completion-preview
  ;; :bind below would otherwise defer loading, and
  ;; `global-completion-preview-mode' in :config would never run.
  :demand t
  :preface
  ;; `completion-preview--get' is private.  It is the only way to ask how
  ;; many candidates the preview is standing in for, which is what tells
  ;; "accept it" from "show me the list".  An upgrade that renames it breaks
  ;; TAB with a void-function error -- loudly, unlike the header advice in
  ;; user-lisp/.
  (defun rjd/completion-preview-list-or-insert ()
    "List the completion candidates, or insert the only one."
    (interactive nil completion-preview-active-mode)
    (if (cdr (completion-preview--get 'completion-preview-suffixes))
        (completion-help-at-point)
      (completion-preview-insert)))
  :custom
  (completion-preview-minimum-symbol-length 2)
  :bind (:map completion-preview-active-mode-map
              ;; TAB opens "*Completions*" whenever there is a choice to
              ;; make, and never commits, so it reads the same whether or
              ;; not a preview happens to be up.  Accepting is M-RET for the
              ;; whole candidate, M-i for one word at a time.
              ;;
              ;; `completion-preview-complete' -- the stock TAB, and what
              ;; was here before -- is deliberately left unbound.  It
              ;; inserts the longest common prefix, which *commits*,
              ;; :exit-function and all, whenever that prefix is itself a
              ;; candidate: on `fmt' it takes `fmt.Append' and expands
              ;; gopls's snippet rather than offering Appendf and Appendln.
              ;; Common-prefix insertion is still on TAB inside
              ;; "*Completions*", where the list is visible first.
              ;;
              ;; TAB and M-RET rather than <tab> and M-<return>, per the
              ;; key-spelling note at the top of this file.  M-RET does
              ;; shadow `org-meta-return' while a preview is up, but org's
              ;; capf only offers candidates in places like `#+' keywords,
              ;; not in prose.
              ("TAB" . rjd/completion-preview-list-or-insert)
              ("M-RET" . completion-preview-insert)
              ("M-i" . completion-preview-insert-word)
              ("M-n" . completion-preview-next-candidate)
              ("M-p" . completion-preview-prev-candidate))
  :config
  (global-completion-preview-mode))

(use-package consult
  :ensure t
  :bind (("M-g g" . consult-goto-line)
         ("M-g o" . consult-outline))
  :custom
  ;; Show eglot xref results (go-to-definition, find-references) in a
  ;; consult interface rather than the default *xref* buffer.
  (xref-show-xrefs-function #'consult-xref)
  (xref-show-definitions-function #'consult-xref)
  :config
  ;; Debounce preview so it doesn't fire on every keystroke while
  ;; navigating candidates.
  (consult-customize
   consult-theme :preview-key '(:debounce 0.2 any)
   consult-xref  :preview-key '(:debounce 0.4 any)))

;;; Version control

;; No :bind here.  `magit-define-global-key-bindings' defaults to `default',
;; so magit installs C-x g for `magit-status' and C-x M-g for
;; `magit-dispatch' on its own.
(use-package magit
  :ensure t
  :defer t)

(use-package git-commit
  ;; Configure only -- git-commit.el ships inside the magit package, which
  ;; requires it when it loads.
  :defer t
  :custom
  (git-commit-style-convention-checks
   '(non-empty-second-line overlong-summary-line)))

;; Magit does the day-to-day work, but vc still runs on every `find-file',
;; so it is worth it not being wasteful about it.
(use-package vc-hooks
  :custom
  ;; Only Git is used here.  Left at the default, vc asks each of seven
  ;; backends in turn whether it manages a file -- cheap locally, a round
  ;; trip apiece over the /ssh: hops Tramp is kept for.
  (vc-handled-backends '(Git))
  ;; This tree is reached through symlinks by design: ~/.emacs.d is one on
  ;; macOS, and vendor/ is nothing but symlinks placed by the setup repo's
  ;; org-sync role.  The default `ask' turns each of those into a prompt
  ;; whose answer is always yes.
  (vc-follow-symlinks t))

;;; Syntax checking

(use-package flycheck
  :ensure t
  ;; Nothing here defers loading any more, but say so anyway:
  ;; `global-flycheck-mode' in :config has to run at startup.
  :demand t
  :preface
  ;; org-lint (newer org-mode) returns line numbers as propertized strings;
  ;; flycheck expects plain integers.  Convert before flycheck sees them.
  ;;
  ;; Named rather than an anonymous lambda: `advice-add' de-duplicates by
  ;; identity, and each load of this file would build a fresh closure, so a
  ;; lambda stacks up another copy every time init.el is re-loaded.
  (defun rjd/org-lint-integer-line-numbers (results)
    "Coerce line numbers in org-lint RESULTS from strings to integers."
    (mapcar (lambda (e)
              (pcase e
                (`(,n [,line ,trust ,desc ,checker])
                 (list n (vector (if (stringp line)
                                     (string-to-number line)
                                   line)
                                 trust desc checker)))
                (_ e)))
            results))
  :custom
  (flycheck-emacs-lisp-load-path 'inherit)
  ;; Eglot drives Flymake in the modes it manages (Go, C/C++), so restrict
  ;; Flycheck to the modes eglot doesn't touch.  Running both in one buffer
  ;; duplicates diagnostics and splits navigation across two keymaps.
  ;;
  ;; org-mode belongs here despite the general preference for Flymake:
  ;; flycheck's org-lint checker has no Flymake counterpart, and there is
  ;; no LSP server for org, so there is nothing for it to collide with.
  (flycheck-global-modes '(emacs-lisp-mode ledger-mode org-mode))
  ;; No :bind for error navigation: `flycheck-mode' installs
  ;; `flycheck-next-error-function' as the buffer's `next-error-function',
  ;; so M-g n and M-g p already walk its diagnostics.
  :config
  (advice-add 'org-lint :filter-return #'rjd/org-lint-integer-line-numbers)
  (global-flycheck-mode))

(use-package flycheck-hledger
  :ensure t
  :after flycheck)

;;; Languages

;; go-ts-mode registers ".go" itself, and `treesit-enabled-modes' is t, so
;; every Go buffer is a go-ts-mode buffer -- go-mode never gets a look in.
(use-package go-ts-mode
  :defer t
  :preface
  (defun rjd/go-outline-regexp ()
    "Set `outline-regexp' for Go source files.
`///' is an ad hoc section marker used in some of these files; there are
no firm rules about where it goes.  The default `outline-level' counts
matched characters, so `///' comes out at level 3 against 5 for `func '
and `type ' -- which nests the declarations under whatever marker
precedes them.

`setq-local' rather than `setq': `outline-regexp' is not automatically
buffer-local, so a plain assignment here would leave every later buffer
that does not set its own -- markdown and plain text among them --
navigating by Go declarations."
    (setq-local outline-regexp "///\\|func \\|type "))
  :hook (go-ts-mode . rjd/go-outline-regexp)
  :bind (:map go-ts-mode-map
              ("M-o" . consult-outline)))

;; Registers the golangci-lint checker but does not run it: go-ts-mode is
;; not in `flycheck-global-modes', so gopls (via Flymake) is the automatic
;; checker.
;; Run golangci-lint on demand with `M-x flycheck-mode' in a Go buffer.
(use-package flycheck-golangci-lint
  :ensure t
  :defer t
  :hook (go-ts-mode . flycheck-golangci-lint-setup))

;; Emacs 31 ships markdown-ts-mode but wires nothing up to it: the library
;; carries no autoload cookies at all, so stock Emacs maps ".md" to nothing.
;; These :mode entries are what make it reachable.  It needs both the
;; markdown and markdown-inline grammars, which scripts/install-grammars.el
;; builds because markdown-ts-mode is in its recipe-library list.
(use-package markdown-ts-mode
  :preface
  (defun rjd/markdown-setup ()
    "Enable visual-line mode for markdown buffers."
    (visual-line-mode 1))
  :mode (("\\.md\\'" . markdown-ts-mode)
         ("\\.markdown\\'" . markdown-ts-mode)
         ("\\.Rmd\\'" . markdown-ts-mode))
  :config
  (add-hook 'markdown-ts-mode-hook #'rjd/markdown-setup))

(use-package ledger-mode
  :ensure t
  :defer t
  :custom
  (ledger-mode-should-check-version nil)
  (ledger-binary-path "hledger"))

(use-package csv-mode
  :ensure t
  :defer t)

(use-package csv
  :ensure t
  :defer t)

(use-package ob-mermaid
  :ensure t
  :defer t)

(use-package mermaid-mode
  :ensure t
  :defer t
  :after ob-mermaid
  :config
  (org-babel-do-load-languages 'org-babel-load-languages '((mermaid . t))))

;;; Notes and writing

(use-package org-web-tools
  :ensure t
  :defer t
  :after org
  :custom
  (org-web-tools-pandoc-sleep-time 5.0))

(use-package denote
  :ensure t
  :defer t
  :custom
  (denote-directory "~/Sync/notes"))

(use-package org-reading-list
  :ensure nil
  :commands (org-reading-list-insert
             org-reading-list-loc-enrich
             org-reading-list-loc-tags
             org-reading-list-set-holdings
             org-reading-list-download-pdf)
  :custom
  (org-reading-list-holdings-codes '("OWN" "IA" "MILIB" "SFPL"))
  :init
  ;; `org-capture-templates' is a defcustom, so it only becomes bound when
  ;; org-capture actually loads -- :custom merely records the value against
  ;; the use-package theme.  Wait for the load before appending to it.
  (with-eval-after-load 'org-capture
    (add-to-list 'org-capture-templates
                 '("r" "Book for the reading list" entry
                   (file+function org-reading-list-file
                                  org-reading-list-goto-headline)
                   "%(org-reading-list-capture)" :empty-lines 1))))

(use-package org-chronicle
  :after org
  :demand t
  :custom
  (org-chronicle-lane-column-width 24)
  :config
  ;; Globalized mode; only actually turns on in org files under
  ;; `org-chronicle-root'.
  (org-chronicle-global-entity-links-mode 1))

;;; Mail

(use-package mu4e
  :defer t
  :bind ("C-c M" . mu4e)
  :custom
  (mu4e-maildir "~/Mail")
  (mu4e-get-mail-command "mbsync -a")
  (mu4e-update-interval 300)           ; backup poll (systemd timer is primary)

  ;; Folder mapping — verify the names with `ls ~/Mail/` after the first sync
  (mu4e-sent-folder   "/Sent")
  (mu4e-drafts-folder "/Drafts")
  (mu4e-trash-folder  "/Trash")
  (mu4e-refile-folder "/Archive")

  ;; Sending goes out over SMTP; the server, port, stream type and the
  ;; identity to send as are all set in private.el.  Without that file mu4e
  ;; still reads mail, and sending is simply unconfigured.
  (message-send-mail-function   'smtpmail-send-it)

  ;; UI
  (mu4e-headers-date-format "%Y-%m-%d")
  (mu4e-compose-dont-reply-to-self t)
  (mu4e-headers-fields
   '((:human-date . 12)
     (:flags      .  6)
     (:from       . 22)
     (:subject    . nil)))

  ;; Plain rendering — no HTML fonts or colours
  (shr-use-fonts  nil)
  (shr-use-colors nil)

  ;; Rename files when moving so mbsync can track moves correctly
  (mu4e-change-filenames-when-moving t)

  ;; Don't keep message buffers around
  (message-kill-buffer-on-exit t)

  (mu4e-bookmarks
   '((:name "Unread"      :query "flag:unread AND NOT flag:trashed AND NOT maildir:/Spam" :key ?u)
     (:name "Today"       :query "date:today..now AND NOT flag:trashed AND NOT maildir:/Spam" :key ?t)
     (:name "Last 7 days" :query "date:7d..now AND NOT flag:trashed AND NOT maildir:/Spam" :key ?w)
     (:name "Flagged"     :query "flag:flagged"     :key ?f))))

;;; Feeds

(use-package elfeed
  :ensure t
  :defer t
  :preface
  (defun rjd/elfeed-toggle-star ()
    "Toggle the star tag on the entry at point."
    (interactive)
    (elfeed-search-toggle-all 'star))

  (defun rjd/elfeed-load-db-and-open ()
    "Load the elfeed db from disk before opening.
Plain `elfeed' goes through `elfeed-db-ensure', which does nothing when a
database is already in memory -- so on its own it would not pick up
whatever another machine has synced in since."
    (interactive)
    (elfeed-db-load)
    (elfeed)
    (elfeed-search-update :force))
  :custom
  (elfeed-db-directory "~/Sync/elfeed")
  ;; The database sits in a synced directory, so it needs to be on disk by
  ;; the time the sync tool looks.  elfeed already saves it from
  ;; `quit-window-hook' and `kill-buffer-hook'; nil only stops it deferring
  ;; that save through a ten-second idle timer.
  (elfeed-db-save-idle nil)

  :bind (("C-c e" . rjd/elfeed-load-db-and-open)
         :map elfeed-search-mode-map
         ;; Not m, which elfeed itself binds to `elfeed-search-mark'.  The
         ;; recipe this came from predates that, and taking m back would
         ;; leave M (unmark) with nothing able to mark.
         ("*" . rjd/elfeed-toggle-star)))

;;; AI assistants

(use-package gptel
  :ensure t
  :defer t
  :config
  (setq gptel-backend
        (gptel-make-anthropic "Claude"
          :stream t
          :key (lambda ()
                 (auth-source-pick-first-password
                  :host "api.anthropic.com"))))
  (setq gptel-model 'claude-sonnet-4-6))

(use-package agent-shell
  :ensure t                     ; MELPA; pulls acp.el and shell-maker
  :preface
  ;; ── Chat label overlays ──────────────────────────────────────────
  ;; The label overlays take their `category' from the *face* symbol that
  ;; styles them, and an overlay inherits any property it lacks from that
  ;; symbol's plist.  A face's internal ID lives on that same plist under
  ;; `face' -- that is what `face-id' reads -- so redisplay finds an integer
  ;; where a face reference belongs, and logs "Invalid face reference: N"
  ;; every time it merges faces over that character.  The label's styling
  ;; is carried by the overlay's `before-string', so shadowing the
  ;; inherited value with an explicit nil costs nothing.
  ;;
  ;; Keyed on the value being a number rather than on a category name, so
  ;; it covers the agent label as well as "Me".  Advice on a private
  ;; function again, and it fails as quietly as the two modes above: a
  ;; rename upstream brings the messages back rather than raising anything.
  (defun rjd/agent-shell-chat-clear-overlay-face (overlay)
    "Shadow OVERLAY's category-inherited numeric `face'."
    (when (numberp (overlay-get overlay 'face))
      (overlay-put overlay 'face nil))
    overlay)

  ;; ── Stray filename completion ────────────────────────────
  ;; shell-maker derives this mode from `comint-mode', which completes any
  ;; word at point as a filename under `default-directory' -- so typing
  ;; "us" mid-sentence offers "user-lisp/", and the inline preview shows
  ;; it.  Nothing here wants that: agent-shell's own file and command
  ;; completions are separate capfs, keyed on a leading @ or /, and they
  ;; are unaffected.
  (defun rjd/agent-shell-drop-comint-completion ()
    "Stop `comint-mode' completing prose as filenames in this buffer."
    (setq-local comint-dynamic-complete-functions nil))
  :custom
  ;; ── Container execution ──────────────────────────────────────────
  ;; -i is required: acp.el speaks JSON-RPC over the adapter's stdin.
  (agent-shell-command-prefix '("docker" "exec" "-i" "claude-dev"))

  ;; Identity mount (~/projects at same path inside/out) makes path
  ;; translation the identity — no resolver function needed.
  ;; (agent-shell-path-resolver-function ...)        ; deliberately unset

  ;; Have the agent read/write files directly inside the container
  ;; rather than through Emacs's fs capabilities. With the identity
  ;; mount the effect on your files is the same, but this keeps file
  ;; I/O on the container side of the boundary (see note below).
  (agent-shell-text-file-capabilities nil)

  ;; The container is the sandbox, so there is nothing left for the
  ;; per-tool prompts to protect. Requested as an ACP session mode once
  ;; the session is up, not a command-line flag — a plain defcustom, so
  ;; unlike the two `setq's below it survives being set before load.
  (agent-shell-anthropic-default-session-mode-id "bypassPermissions")

  ;; ── Transcript ───────────────────────────────────────────────────
  ;; Show thinking without disclosing it by hand. Both are needed: a
  ;; thought carries its own fold, but sits inside an activity group
  ;; whose default ('latest) refolds it the moment the agent moves on.
  ;; Tool bodies stay folded — expanding those too makes a long turn
  ;; unreadable.
  (agent-shell-thought-process-expand-by-default t)
  (agent-shell-activity-group-expand-by-default t)

  :config
  ;; ── Claude specifics ─────────────────────────────────────────────
  ;; These two resist `:custom', which runs before the package loads:
  ;; neither constructor is autoloaded, so evaluating them there gets a
  ;; void-function warning and the setting is silently dropped.
  ;;
  ;; Subscription login lives in the claude-config volume (the one-time
  ;; `docker exec -it claude-dev claude` login); no keys in Emacs.
  (setq agent-shell-anthropic-authentication
        (agent-shell-anthropic-make-authentication :login t))

  ;; Skip the agent picker; new shells default to Claude.
  (setq agent-shell-preferred-agent-config
        (agent-shell-anthropic-make-claude-code-config))

  ;; ── Rate-limit budget in the header ──────────────────────────────
  ;; agent-shell only knows the context window; the 5-hour and weekly
  ;; subscription windows come from rjd-agent-shell-budget, which reads
  ;; the token through `agent-shell-command-prefix' (the login lives in
  ;; the container, not on this host). Private interfaces on both sides
  ;; — see the caveat in that file if the budget ever vanishes.
  (rjd/agent-shell-budget-mode 1)

  ;; ── Claude Code version in the header ────────────────────────────
  ;; Also absent from agent-shell: the ACP handshake may carry an
  ;; `agentInfo' version, but agent-shell keeps only the capabilities
  ;; and modes from that response. rjd-agent-shell-version asks the CLI
  ;; through `agent-shell-command-prefix' instead.
  ;;
  ;; It asks the binary the ACP adapter actually spawns -- bundled and
  ;; version-pinned inside claude-agent-acp -- not the `claude' on PATH,
  ;; which is a different and newer build. A `⇧' beside the version
  ;; means the adapter has published a release carrying a newer Claude
  ;; Code, i.e. rebuilding the container would now get you something.
  (rjd/agent-shell-version-mode 1)

  (advice-add 'agent-shell-chat--upsert-overlay :filter-return
              #'rjd/agent-shell-chat-clear-overlay-face)

  (add-hook 'agent-shell-mode-hook #'rjd/agent-shell-drop-comint-completion)

  ;; ── Ergonomics (optional, but suited to your complaints) ─────────
  ;; RET inserts a newline; explicit send. Multi-line prompts stop
  ;; being a fight.
  :bind (:map agent-shell-mode-map
              ("RET"     . newline)
              ("C-c C-c" . shell-maker-submit)
              ("C-c C-k" . agent-shell-interrupt)))

;;; Utilities

(use-package ripgrep
  :ensure t
  :defer t)

;;; init.el ends here
