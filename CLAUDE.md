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
accounts declared in `private.el` as `rjd/mail-accounts` into mu4e
contexts.  Entering one sets the account's identity and folders, and
leaving it restores the global defaults -- the Fastmail identity -- so
mail written outside mu4e keeps that identity; with no account
declared there are no contexts.  A context stays entered after mu4e
quits, so message buffers outside mu4e get the default identity and
sending function back buffer-locally, from `message-mode-hook`.
`rjd/mail-mode` also keeps each account's Spam and Trash out of every
search that does not name them, through `mu4e-query-rewrite-function`,
and trashes and refiles each message into the folders of the account
whose maildir holds it, whatever context is current: mu4e chooses a
message's context only for a context's `vars`, which `rjd-mail` does
not use, so each `mu4e-trash-folder` and `mu4e-refile-folder` is a
function of the message.
It is opt-in, enabled from mu4e's form in `init.el`, which also starts
mu4e in the background at startup so mail syncs unopened.

An account's aliases (Fastmail's plus, subdomain and catch-all
addresses) are one regexp, its optional `:addresses`, set in
`private.el` and never here.  Mail to an alias picks the account's
context, a From of one sends through its msmtp, and the context sets
`message-alternative-emails` so a reply is from the alias written to.
`mu init --my-address` needs the same addresses in `/.../` form, so mu
counts that mail as personal: one `--my-address` per alias form,
written in syntax PCRE and Emacs share (no `|` or groups), since mu
reads it as PCRE and mu4e as an Emacs regexp.

Sending is decided by the message's From, at send time:
`rjd/mail-send-it` sends an active account's mail through that
account's msmtp and hands any other to smtpmail, so a draft goes out
as the account it was written as, whatever context is current.  Where
accounts are active `rjd/mail-mode` makes it the global
`message-send-mail-function`, not only the contexts', because smtpmail
has no credentials on the Mac: so mail from the Fastmail address goes
through Fastmail's msmtp from any message buffer.  `C-x m` itself, and
everything else that calls `compose-mail`, opens mu4e's compose:
mu4e's form makes `mu4e-user-agent` the `mail-user-agent` wherever mu4e
is installed, so all mail is written in a context and filed.  Only
`message-mail` called directly still makes a buffer outside mu4e.
Mail is spell-checked as it is sent, by jinx (see Spelling in
`init.el`).  smtpmail, which `init.el` sets,
stays the fallback for any other From, and the default where no
account is active.  It is
its own function, not message's sendmail path, whose `-oi` would land
inside the prefix (`docker -oi exec ...`).

Replies to calendar invitations, which mu4e-icalendar builds with
gnus-icalendar, carry only the replying attendee, by `:around` advice
from `rjd/mail-mode` on gnus-icalendar's private
`gnus-icalendar-event--build-reply`.  Emacs 31's builder copies every
ATTENDEE into the REPLY, and Google ignores a reply with more than
one.  The advice also calls the private
`gnus-icalendar-event--find-attendee`, and relies on the builder
reusing the invitation's attendee nodes; an Emacs upgrade can break
either silently, the replies simply carrying every attendee again.
**If an acceptance stops showing on the organiser's calendar, that
advice is the first place to look**; `rjd-mail.el`'s commentary names
what it hooks.  Remove it once Emacs fixes the builder upstream.

An invitation to any active account's address or alias gets its
Accept, Tentative and Decline buttons whatever context is current:
`rjd/mail-mode` filters the return of gnus-icalendar's
`gnus-icalendar-identities` with `:filter-return` advice, adding a
predicate true of every active account's address and `:addresses`.
Without it gnus-icalendar knows only the current context's identity,
so an invitation to a Fastmail alias with no name to match, opened in
the Gmail context, could not be answered.  It relies on
gnus-icalendar's attendee lookup accepting predicates as identities;
an upgrade that renames the function or drops that breaks it silently,
the buttons simply missing.  **If an invitation to an alias shows no
buttons, that advice is the first place to look.**  Replies stay mail
only: nothing is written to any calendar.

Every mail command (mbsync, msmtp, oama) is built with
`rjd/mail-command`, which puts `rjd/mail-command-prefix` in front: nil
inside `claude-dev`, the mail container's `docker exec -i mail` on the
host.  The default is chosen when the package loads, by
`rjd/mail-default-command-prefix`: the container if Emacs is not
itself in one and the `setup` playbook has written
`~/.config/mail-container/` (the container's configuration, outside
`~/projects`, so no agent can edit what runs beside the tokens); nil
otherwise.

Declared accounts, and the calendar account, take effect only where
`rjd/mail-available-p` says mail can run: where the prefix is set, or
inside a container with `mbsync` on `exec-path` (`claude-dev` with
the dev toolchain).  On leroy or bulldog Emacs starts as if none were
declared; `rjd/mail-enabled` forces it either way.  `private.el` only
declares data; the decision stays here, under test.  On the Mac, mu
and mu4e come from Homebrew, and mu4e's form puts Homebrew's
site-lisp on `load-path`.  ERT tests: `test/rjd-mail-test.el`.

## Calendar

Every external calendar is fetched, read-only, into its own calendar
file in `rjd/calendar-directory`, `~/org-agenda/calendars/`.
`org-agenda-files` lists the directory, so the agenda reads every file
in it, and the combined `.ics` export leaves the whole directory out
(advice in `init.el`), so no fetched event loops back into a calendar.
org-sync, whose file set is the `setup` repo's, never names these files.

Google Calendar reaches the agenda through `rjd-gcal` (user-lisp), which
has org-gcal fetch one account's calendar into
`~/org-agenda/calendars/gcal-gmail-personal.org`.  The account is set in
`private.el` as `rjd/gcal-account`; without it, or where mail cannot
run (see Mail), nothing is fetched and there is no timer.  The
token comes from oama, through `rjd/mail-command`, by `:around` advice
on oauth2-auto's `oauth2-auto-access-token` -- an upgrade of org-gcal or
oauth2-auto can break that silently, the calendar simply no longer
updating.  **If the calendar disappears from the agenda, that advice is
the first place to look**; `rjd-gcal.el`'s commentary names what it
hooks, and `rjd/gcal-mode` is opt-in, enabled from org-agenda's form in
`init.el`, so nothing loads before the agenda does.  Nothing
calls org-gcal's sync, only its fetch.  ERT tests:
`test/rjd-gcal-test.el`.

CalDAV calendars, iCloud's among them, reach the agenda through
`rjd-caldav` (user-lisp).  `private.el` declares its accounts as
`rjd/caldav-accounts`, each a plist of a name, a CalDAV server URL, a
user and the calendars to fetch, by display name.  Each calendar is
fetched into `NAME-SLUG.org` (so iCloud's are `icloud-SLUG.org`),
rewriting the file whole after each successful fetch.  It only ever
sends PROPFIND and REPORT: each password, from auth-source under its
server's host (`caldav.icloud.com` for iCloud) and the account's user,
could write, so read-only rests on the code.  A calendar fed from org
is never fetched, even if named: `rjd-caldav` refuses the one at
org-pa's `org-pa-caldav-url`, read from the value `:custom` saves on
the symbol until org-pa loads, so `private.el` must set that URL in a
deferred form, not under `:after`.  The accounts are fetched
together, one failing without stopping another, and failures are
reported once per run, naming the account.  Recurrences are expanded by
the server, not here, and iCloud sends each time in its event's TZID
with no VTIMEZONE, which `rjd-caldav` resolves from the system's zone
database.  **If the iCloud calendars disappear from the agenda, or
their times shift, those two iCloud behaviours are the first place to
look**; `test/caldav-probe.sh`, run on the host, shows what a server
now sends (iCloud's by default, any other named in `CALDAV_SERVER`),
and `rjd-caldav.el`'s commentary has the rest.  Nothing is fetched
inside a container, so no agent's Emacs holds a password, and a
timer's fetch never prompts for a passphrase.  `rjd/caldav-mode` is
opt-in, enabled from org-agenda's form beside `rjd/gcal-mode`.  ERT
tests: `test/rjd-caldav-test.el`, against sanitised recordings in
`test/fixtures/caldav/`, one directory per server; ADR-0002 has the
design, and ADR-0003 its generalisation to several accounts.

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
