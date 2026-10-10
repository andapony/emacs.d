# Emacs configuration

Personal Emacs configuration.  The repository root *is*
`user-emacs-directory`: the Ansible playbook in the `setup` repo clones
this repo to `~/projects/emacs.d` and symlinks `~/.emacs.d` to it.  It
lives under `~/projects` rather than being cloned straight to
`~/.emacs.d` so that it falls inside the claude-container mount.

Because Emacs runs with this directory as `user-emacs-directory`, it
writes runtime state — `elpa/`, `eln-cache/`, `url/` and friends —
directly into the working tree.  Those paths are gitignored, as are the
artefacts Emacs generates inside `user-lisp/` (`*.elc` and
`.user-lisp-autoloads.el`).

The main config is `init.el`.  Local packages live in `user-lisp/`,
which Emacs 31 recursively byte-compiles, scrapes for `;;;###autoload`
cookies and adds to `load-path` automatically — so a command defined
there is available from `M-x` without `init.el` requiring it.  Give new
commands an autoload cookie rather than adding a `require`.

A package big enough for its own repository stays loaded the same way:
its checkout under `~/projects` is symlinked into `user-lisp/`, which
Emacs follows.  The `setup` repo's `emacs_user_lisp_repos` list clones
each one and makes its link.  The Book list, org-pa, c2log and
note-maker are linked this way, each as `user-lisp/NAME` ->
`~/projects/NAME`; each has its
own `CLAUDE.md`, and their settings stay in `private.el`.  Each such
symlink is gitignored and must tolerate being absent, since it dangles
on a machine without the checkout, and then the package's commands are
simply missing.  `early-init.el` adds `test` and `tmp` to
`user-lisp-ignored-directories`, so these packages' test suites and
scratch stay out of the session.

This repository is public, and meant to set up a new machine — a work
one, say — on its own.  Personal values live in `private.el`, which
`init.el` loads with `:noerror` after `custom.el`: the mail identity,
calendar endpoints, paths to unpublished work, and every private
package's settings.  It is gitignored here because it is a symlink into
the private `dotfiles` repo, `emacs-private/private.el`, made by the
`setup` repo's `dotfile_links`.  Edit it there and commit it in
`dotfiles`; never copy its values into this repository.  Anything set
there needs a usable default where it is declared, since a machine
without `dotfiles` has no `private.el` at all.

`vendor/` is added to `load-path` by `init.el` and holds files symlinked
in by the `setup` repo's `org-sync` role.  It is gitignored, so anything
loaded from it must tolerate being absent.

## Smoke test

`test/smoke-test.el` loads the whole config in batch and checks what it
actually set.  Run it from the checkout under test, a worktree included:
`emacs --batch --init-directory=/Users/rob/projects/emacs.d -l
test/smoke-test.el`.  Its commentary covers the batch-loading traps it
handles and how to add an assertion.

## agent-shell

Claude Code is driven from Emacs through `agent-shell`, which does not
run the agent on this host: `agent-shell-command-prefix` is `docker exec
-i claude-dev`, so every command lands inside the `claude-dev`
container.  `~/projects` is mounted at the same path inside and out, so
path translation is the identity and no resolver function is needed.
The subscription login lives in a volume in that container; agent-shell
itself holds no API key.

Two local packages add things agent-shell has no concept of.
`rjd-agent-shell-budget` puts the 5-hour and weekly subscription windows
in the header, which agent-shell cannot know because the ACP
`usage_update` notification carries only context tokens and cost.
`rjd-agent-shell-version` puts the running Claude Code version there,
which agent-shell cannot know because it keeps only `agentCapabilities`
and `modes` from the ACP `initialize` response and drops `agentInfo`.

Both advise `agent-shell--make-header-model`, a private function, so an
agent-shell upgrade can break them — and does so *silently*, by the
field vanishing from the header rather than by any error.  Two further
internal dependencies fail the same quiet way: `rjd-agent-shell-version`
globs into the ACP adapter's `node_modules` for the bundled `claude`
binary and falls back to the one on `PATH`, which reports a different
build rather than nothing; `rjd-agent-shell-budget` calls an
undocumented usage endpoint.  **If the version or the budget disappears
from the header, that advice is the first place to look** — each file's
commentary names what it hooks.  Both are opt-in minor modes, enabled
from `init.el`, so the recovery from a bad upgrade is to turn one off
rather than to fix it under pressure.

## Mail

mu4e reads mail through `rjd-mail` (user-lisp), which turns the
accounts declared in `private.el` as `rjd-mail-accounts` into mu4e
contexts.  Entering one sets the account's identity and folders and
leaving it restores the global defaults -- the Fastmail identity and
smtpmail -- so mail written outside mu4e is unchanged; with no account
declared there are no contexts.  Every mail command (mbsync, msmtp,
oama) is built with `rjd-mail-command`, which puts
`rjd-mail-command-prefix` in front: nil inside `claude-dev`, the mail
container's `docker exec` on the host.  The package's symbols use the
`rjd-mail-` prefix, not `rjd/`, because that interface was fixed for
the calendar to build on.  `rjd-mail-mode` is opt-in, enabled from
mu4e's form in `init.el`.  ERT tests: `test/rjd-mail-test.el`.

## Calendar

Google Calendar reaches the agenda through `rjd-gcal` (user-lisp), which
has org-gcal fetch one account's calendar, read-only, into
`~/org-agenda/gcal-gmail-personal.org`.  The account is set in
`private.el` as `rjd/gcal-account`; without it nothing is fetched.  The
token comes from oama, through `rjd-mail-command`, by `:around` advice
on oauth2-auto's `oauth2-auto-access-token` -- an upgrade of org-gcal or
oauth2-auto can break that silently, the calendar simply no longer
updating.  **If the calendar disappears from the agenda, that advice is
the first place to look**; `rjd-gcal.el`'s commentary names what it
hooks, and `rjd/gcal-mode` is opt-in, enabled from `init.el`.  Nothing
calls org-gcal's sync, only its fetch.  The file is kept out of the
combined `.ics` export (advice in `init.el`) and out of org-sync, whose
file set is the `setup` repo's.  ERT tests: `test/rjd-gcal-test.el`.

## Git through the container

On the host, Magit and vc run git through claude-container's
`container-git` wrapper (`rjd/container-git` in `init.el`), so a repo's
agent-writable `.git/config` and hooks execute inside the container, not
as the host user.  It is nil, and git is plain git, inside the container
and on a machine without that checkout.

Commit editing depends on with-editor's private `with-editor--pid`:
`rjd/with-editor-return-in-container` takes the PID from it so that
with-editor's own host-side `kill` never sees a container PID.  If a
with-editor upgrade stops reading it there, that `kill` would signal
whichever *host* process has the number.  After upgrading with-editor,
recheck that `with-editor-return` still reads `with-editor--pid` before
signalling.

## Conventions

- Always use `rjd/` as a prefix for any new global identifiers (functions,
  variables, etc.) defined in the configuration.
- Use `use-package` for all package configuration.
- Helper functions that are only used by one package belong inside that
  package's `use-package` form, in `:preface` -- not `:config`, and not at
  the top level.
- Sections are delimited by `;;; Section name` headers with two blank lines
  before each header.
- Divide each form by what the code *is*: `:custom` sets variables,
  `:preface` defines functions, `:config` does side-effecting setup (mode
  activation, hooks, advice).  The split is not only tidiness.  `:preface`
  is evaluated as `init.el` is read, but `:config` -- for any package that
  is not `:demand t` -- expands into `eval-after-load`, which runs while
  the package's own file is still loading.  A `defun` there is recorded in
  `load-history` against *that* file, so `M-.` on the function opens, say,
  `org.el.gz`, fails to find any such definition in it, and lands at line
  1.  The function itself works; only navigation breaks, and it breaks
  silently.  `:preface` keeps the attribution on `init.el`.
- Two consequences of `:preface` being early.  Its body must not *call*
  into the package at definition time -- naming the package's functions
  inside a `defun` body is fine, since that runs later.  And it survives
  `:if`/`:when`/`:unless`, which guard every other keyword but are hoisted
  around `:preface`; only `:disabled`, or deleting the form, removes it.
- `:preface` goes immediately after the load-control keywords (`:ensure`,
  `:defer`, `:demand`) and before everything else, so a definition always
  precedes the `:custom`, `:hook`, `:bind` or `:config` entries that name
  it.  `use-package` sorts keywords itself, so this is for the reader
  rather than for correctness -- which is why it is a fixed slot and not a
  judgement call per form.
- For keys that have both an ASCII and a function-key name, bind the ASCII
  one: `TAB` not `<tab>`, `RET` not `<return>`, and likewise `ESC`, `DEL`
  and `C-j`.  A window system falls back from the function-key event to the
  character, but a terminal never sends the event at all, so `<tab>` works
  on a GUI frame and *silently does nothing* under `emacsclient -nw` --
  the key goes on meaning whatever it meant before.  Use the function-key
  name only to distinguish the two deliberately.  `init.el`'s commentary
  has the full reasoning; keys with no ASCII form (`<f5>`, the arrows) are
  unaffected.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on `andapony/emacs.d`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default triage labels, each named for its role. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
