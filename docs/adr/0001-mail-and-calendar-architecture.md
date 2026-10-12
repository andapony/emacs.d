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
itself.  A published port would not reach the listener on its own, so
the mail container runs a relay from the published port to loopback,
and the port is published on the Mac's loopback only (#12): the login
is then an ordinary browser round trip.  In `claude-dev`, which
publishes no port, it is done by hand: the consent URL is fetched from
oama inside the container and opened in the Mac browser, and the
redirect URL the browser then fails to load is copied back and
delivered to oama from inside the container (#5 has the procedure).

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

**OAuth client.**  The personal account uses its own "Desktop app"
OAuth client, in a personal Google Cloud project published "In
production" and left unverified, under Google's personal-use exemption.
The spec planned Thunderbird's public client ID, but Google blocks that
ID outright ("This app is blocked") when it asks for `calendar.readonly`:
it is approved only for the scopes Thunderbird itself requests, which
include full calendar but not read-only.  The Cetos client is **open**
until Cetos IT answers: either an Internal app in a Cetos-owned Cloud
project, or Thunderbird's ID if it is allowlisted -- which would carry
mail only, leaving the calendar to the plstore fallback below.


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
  days.  The personal client must therefore stay "In production", and
  its login shows a "Google hasn't verified this app" warning.

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
  to allow creating one; Thunderbird's ID needs IT to allowlist it, and
  cannot carry `calendar.readonly` in any case.  Decided when Cetos IT
  answers.
- **Thunderbird's client ID for the personal account** (rejected).
  Blocked for `calendar.readonly`, as above.  Asking it for full
  `calendar` instead would pass, but the token could then write to the
  calendar, and read-only would rest on org-gcal never syncing rather
  than on the scope.
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


## Addendum: Fastmail in the mail container

Spec: [#22](https://github.com/andapony/emacs.d/issues/22).

Fastmail was left as the global default identity, sending through
smtpmail and never synced on the Mac.  It is now a second declared
account, synced and sent by the mail container like Gmail: its mbsync
syncs every folder (`Patterns *`), since Fastmail's folders are real
folders rather than labels, into its own maildir beside Gmail's, and
its msmtp sends from its context through `rjd/mail-send-it`.  Fastmail
does not file mail sent over SMTP, so its context saves the copy
(`:sent-messages-behavior sent`).  The global default is unchanged:
mail written outside mu4e still goes out as Fastmail through smtpmail.

**The container now holds a password.**  Fastmail offers no OAuth to
third-party clients, so mbsync and msmtp log in with an app password
over TLS.  That amends "oama is the only token store": the container's
state volume holds the Fastmail app password too, GPG-encrypted with
the same passphrase-less key as oama's tokens, and read by mbsync's
`PassCmd` and msmtp's `passwordeval`.  It sits on the same terms as the
tokens -- no agent container can reach it -- and is an app password of
its own, so the Mac's access can be revoked without touching other
machines.

**Rejected: mbsync on the host, with the password in Keychain.**  Plain
LOGIN needs no XOAUTH2 SASL module, so Fastmail alone could be synced
by a Homebrew mbsync reading its password from the macOS Keychain, and
the container would hold no password.  Rejected because it splits
syncing across two places: two mbsyncs, two configurations, and two
command prefixes for `rjd/mail-command` to choose between per account,
where today one prefix reaches every mail tool.


## Addendum: Linux hosts

Spec: [#35](https://github.com/andapony/emacs.d/issues/35).

leroy and bulldog had kept the old setup: apt's isync, mu4e and msmtp
on the host, a systemd timer running `mbsync -a` into the root of
`~/Mail`, and the Fastmail password in `~/.authinfo.gpg`.
`rjd/mail-available-p` saw no mail container there, so no account took
effect, and Gmail was not available on Linux at all.  Now every
**host** -- the Mac, leroy and bulldog -- runs its own mail container,
and "the host" above means any of them rather than the Mac alone.  The
container's tasks moved into a `setup` role, `roles/mail-container`,
which both plays import under the `email` tag, so the two platforms
share one definition.  Each account syncs into its own maildir on
Linux as on the Mac, and each Linux host has its own Fastmail app
password, so any machine's access can be revoked alone.

**podman on Linux.**  The Linux container runs under rootless podman
rather than Docker.  Docker's bridge egress bypasses OpenSnitch, and
Docker needs a root daemon and the root-equivalent `docker` group;
rootless podman needs neither, and its egress reaches OpenSnitch as
pasta or slirp4netns, as `claude-dev`'s does.  `dotfiles` carries
rules allowing each of those only IMAP and SMTP at Fastmail and Gmail
and Google's OAuth endpoints, so mu4e's startup sync never waits on a
prompt.  `claude-dev` can reach the same destinations, which is
accepted: without the tokens it gains nothing.

The role is parameterised by what differs.  On Linux it runs the
container with `--userns=keep-id`, and builds the image's user at the
host user's UID, so what mbsync writes into `~/Mail` is the user's.
The restart policy is `--restart always`, with podman's
`podman-restart.service` user unit enabled to start the container
after a reboot; Docker keeps `--restart unless-stopped`.  The role runs
as the user, in the user's systemd session, so the container is the one
Emacs's `podman exec` sees.

**The runtime is recorded, not detected.**  The role writes the
runtime's name to `~/.config/mail-container/runtime`, and
`rjd/mail-default-command-prefix` builds the mail command prefix from
it: `podman exec -i mail` on Linux, `docker exec -i mail` on the Mac.
A missing file means Docker, so the Mac kept working before its next
playbook run.

**The host-native tools are retired.**  The Linux play removes apt's
`isync`, `mu4e`, `maildir-utils` and `msmtp-mta`, stops, disables and
deletes the mbsync timer and service, and unlinks the `.mbsyncrc` and
msmtp dotfiles.  mu4e drives the sync through the container, as on the
Mac, so syncing again happens only while Emacs runs.  Host `msmtp`
stays for root's restic failure mails, and `~/.authinfo.gpg` for other
auth-source users.  Moving the old mail into `~/Mail/fastmail/` is a
manual cutover per host, listed in the Linux play's comments; the
playbook moves no mail.

**mu from source, at a shared pin.**  "mu stays on the host" still
holds, but on Linux it is built from source rather than installed from
apt: `setup`'s `mu_version`, pinned to Homebrew's current mu (1.14.3),
built under `~/.local/mu` with mu4e's elisp and Info manual.
`claude-container` builds `claude-dev`'s mu at the same pin, its
`MU_VERSION` the twin of `mu_version`, so the pinned 1.14.x of the
development paragraph above is now recorded in a repository rather
than built by hand.  mu4e's form puts `~/.local/mu`'s mu4e first on
`load-path` and runs the `mu` beside it, so the elisp and the server
come from one build.  mu 1.14 needs GLib 2.80 or later, so a Linux
host must run Mint 22 (Ubuntu noble) or later; the play does not check.
`claude-dev`, on bookworm's GLib 2.74, builds GLib 2.80 into mu's own
prefix instead.

**Rejected: Docker on Linux.**  Its egress would leave OpenSnitch's
view, and it needs the daemon and the `docker` group, as above.

**Rejected: keeping the host-native tools on Linux.**  Debian packages
the XOAUTH2 module, so Linux could sync Gmail without a container.
But that is a second way of syncing beside the Mac's, with its own
configuration to drift, tokens and passwords held by the host user
rather than on the container's terms, and a timer that overlaps mu4e's
own runs.

**Rejected: Quadlet.**  A systemd unit generated by Quadlet would
restart the container, but the role's recreate-on-change logic would
then need a second, systemd-based path on Linux.  `--restart always`
with `podman-restart.service` keeps one path for both runtimes.

**Rejected: detecting the runtime.**  Looking for `docker` or `podman`
on `exec-path` could pick the wrong one on a machine that has both;
the playbook knows which it used, so it records it.

**Rejected: apt's mu4e.**  It is older than the mu 1.12 and later the
shared config is written for -- the same reason `claude-dev` does not
take bookworm's -- and a host's mu would drift from `claude-dev`'s.
