---
status: accepted
---

# Mail and calendar: mbsync + mu4e, a mail container, oama, and org-gcal fetch-only

Spec: [#2](https://github.com/andapony/emacs.d/issues/2), including its
addendum comment on the mu version.


## Context

A Google Workspace account for Cetos needs its mail and calendar handled
in Emacs, next to the org-mode tasks.  Gmail authenticates IMAP and SMTP
with OAuth2 (XOAUTH2), not a password.  The existing mu4e configuration
was written for Fastmail and never brought up on macOS, and Google
Calendar was not integrated at all.

What Cetos's Workspace admins allow -- IMAP, third-party OAuth apps,
creating Cloud projects -- is not yet known.  So the approach is proven
first on a disposable personal Gmail account, and has to carry over to
Cetos as one more declared account rather than a rewrite.  Every choice
below therefore names the fallback to use if Cetos blocks it.

Two constraints shape where things run.  macOS has no packaged XOAUTH2
SASL plugin for isync's Cyrus SASL, and building one by hand is not
maintainable.  And Emacs is driven by agents in containers (see
`CLAUDE.md`), so OAuth tokens for work mail must sit where no agent
container can reach them.


## Decision

**Sync stack: mbsync + mu4e.**  This is the stack the config already
has.  Sync covers only INBOX, All Mail, Sent Mail, Drafts, Trash and
Spam; label folders are not synced, and labels stay a web-UI concern.
Archiving in mu4e moves a message out of INBOX, so it leaves Gmail's
Inbox and stays in All Mail, as archiving does on the web.  mu4e runs mbsync itself on its
update interval, so there is no separate timer to overlap with it, and
mail syncs only while Emacs runs.  Sending goes through msmtp; smtpmail
stays only for the Fastmail default identity.

**Where things run.**  The tools that authenticate -- mbsync, msmtp and
the oama token agent -- run in a dedicated OrbStack **mail container**,
defined in the `setup` repository and based on Debian trixie or later
for a current isync and the KDE XOAUTH2 SASL module.  The maildir is
mounted at the same path inside and out.  No agent container mounts the
maildir or the mail container's state, and agent containers have no
Docker access.  Emacs reaches these tools through a single **mail
command prefix**, nil in development and the mail container's
`docker exec` invocation on the host, in the same way as
`rjd/container-git`.

mu stays on the host, installed from Homebrew, and mu4e's elisp is
loaded from Homebrew's site-lisp.  The mu4e elisp has to match the
`mu server` it talks to, and Homebrew ships the two together, so they
cannot drift apart.  Reading and searching mail keep working when the
container is down.  And mu does no authentication, which is the only
reason the container exists.

During development in `claude-dev` (Debian bookworm), mu is built from
source at a pinned 1.14.x release, the one closest to Homebrew's, rather
than installed with `apt`.  Bookworm's mu is 1.8.14, or 1.10.8 from
backports, and mu4e changed a lot after that -- 1.12 brought a new
message editor and replaced variables such as `mu4e-maildir` -- so
config and tests run against the older mu4e could pass in development
and fail on the host.  isync, msmtp and oama behave the same across
these versions, so their configs carry over unchanged.

**Tokens: oama is the only token store.**  It serves mbsync (as its
password command over XOAUTH2), msmtp (as its password-eval command) and
the calendar.  One store means one place to revoke and one place to
debug, and the host needs no GPG setup.  oama encrypts with a
passphrase-less GPG key inside the container volume, protected by
FileVault and macOS file permissions.  The account's token requests the
full-mail scope plus `calendar.readonly`, so calendar access is
read-only by scope, not by convention.

Getting the token takes a one-time login in a browser, after which no
password is typed.  oama's redirect listener binds only loopback inside
its container, and Google accepts only loopback redirect URIs for a
desktop client, so the browser on the Mac cannot deliver the redirect
itself.  The login is done by hand: the consent URL is fetched from
oama inside the container and opened in the Mac browser, and the
redirect URL the browser then fails to load is copied back and
delivered to oama from inside the container (#5 has the procedure).  A
published port would not reach the listener on its own; it would need
a relay inside the container from the published port to loopback.

**Calendar: org-gcal, fetch only.**  org-gcal fetches events into a
dedicated per-account org file under the agenda directory, on agenda
open and on a timer; its sync is never invoked, so nothing done in org
can change the calendar.  An `rjd-` advice on oauth2-auto's
access-token function answers for the org-gcal provider with a token
from oama, and lets other providers through.  The calendar file is
added to `org-agenda-files` (set only in `init.el`), and kept out of
the org-sync file set and the iCalendar agenda export so that Google
events do not loop back into another calendar.  Invitations are
answered from mu4e with mu4e-icalendar, whose option to add events to
org stays off; accepted events arrive through the fetch.

**Identity: Fastmail stays the global default.**  Accounts are declared
as data in `private.el`, one plist per account, and the `rjd-mail`
package turns them into mu4e contexts.  Entering a context sets the
identity, sending function and program, and sent-messages behaviour
(delete, for Gmail, which files sent mail itself); leaving it restores
the Fastmail defaults.  On reply the context is chosen by match; on
compose mu4e asks when it is not obvious.  With no accounts declared
the package does nothing, so a machine without `private.el` starts
cleanly.

**OAuth client.**  The personal account uses Thunderbird's public
client ID.  The Cetos client is **open** until Cetos IT answers: either
an Internal app in a Cetos-owned Cloud project, or Thunderbird's ID if
it is allowlisted.


## Consequences

**Fragile hooks.**  Each of these fails quietly, so the code that
depends on one, once written, must name it in its commentary where it
applies:

- The calendar depends on oauth2-auto's access-token function returning
  an aio promise, which the `rjd-` advice imitates.  An oauth2-auto or
  org-gcal upgrade that changes this makes the calendar stop fetching.
  If the calendar disappears from the agenda after an upgrade, that
  advice is the first place to look.
- oama looks dormant, with no commits since August 2025.  If it breaks
  or is abandoned, `mutt_oauth2.py` is the drop-in replacement as the
  password command for mbsync and msmtp.
- org-gcal supports one account.  A second calendar (personal and Cetos
  at once) needs a different approach, not another declaration.
- Under Google's personal-use exemption an unverified "In production"
  client works, but a "Testing" client loses its refresh tokens after 7
  days.  This matters only on moving away from Thunderbird's ID.

Mail and calendar are opt-in, so a bad upgrade is bypassed by turning
the feature off rather than fixed under pressure.

Account details -- addresses, servers, client IDs -- live only in the
private `dotfiles` repository, as does the mbsync, msmtp and oama
configuration.  This repository holds the code and this record.


## Alternatives and fallbacks

- **lieer + notmuch** (fallback for the sync stack).  lieer talks to the
  Gmail API rather than IMAP, so it survives Cetos disabling IMAP or the
  XOAUTH2 path.  Not chosen first because the config already has
  mbsync + mu4e, and IMAP keeps the stack provider-neutral for Fastmail
  later.
- **Gnus over IMAP** (rejected).  It keeps no local index, so search
  depends on the server, and its network work runs inside Emacs, so a
  slow server stalls the editor.  It also gives up the existing mu4e
  configuration.
- **org-gcal's own plstore** (fallback for the calendar token).  If
  `calendar.readonly` cannot be added to the oama token, org-gcal keeps
  its own token in a GPG-encrypted plstore, with loopback pinentry and
  the plstore file moved out of this repository's working tree.  Not
  chosen first because it means a second token store and GPG on the
  host.
- **`mutt_oauth2.py`** (fallback for oama).  It fills the same role, as the
  password command in the mbsync and msmtp configs; used if oama stops
  working.
- **A Cetos-owned Internal OAuth app versus Thunderbird's client ID**
  (open for Cetos).  An Internal app in a Cetos Cloud project needs IT
  to allow creating one; Thunderbird's ID needs IT to allowlist it.
  Decided when Cetos IT answers.
- **Building the XOAUTH2 SASL plugin on macOS** (rejected).  Not
  reproducible from the setup playbook and fragile across Homebrew
  upgrades; Debian packages it, hence the mail container.
- **mu in the mail container** (rejected).  It would split the mu binary
  from the mu4e elisp on the host, and take search down whenever the
  container is.
- **A LaunchAgent or systemd timer for sync** (rejected).  It would
  overlap with mu4e's own update runs; syncing only while Emacs runs is
  accepted.
- **org-gcal two-way sync** (rejected).  Writing to a work calendar from
  org is out of scope; the read-only scope enforces it.
