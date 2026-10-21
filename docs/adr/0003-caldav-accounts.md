---
status: accepted
---

# CalDAV calendars: one fetcher, a list of accounts

Spec: [#49](https://github.com/andapony/emacs.d/issues/49).  Amends
[ADR-0002](0002-icloud-calendars-caldav-fetch.md), whose principles it
keeps: fetch only, recurrences expanded by the server, one disposable
calendar file per calendar, passwords from auth-source, never inside a
container, and never fetching a calendar fed from org.  What it replaces
is ADR-0002's iCloud-specific framing: the package's name, the single
account, and its fixed auth-source host.


## Context

ADR-0002's fetcher, `rjd-icloud`, knew one account on one server:
`rjd/icloud-account` and `rjd/icloud-calendars` in `private.el`, the
server and the auth-source host `caldav.icloud.com` as constants, and
the prefix `icloud-` on every calendar file.

Fastmail's calendars are wanted in the agenda too, among them the one
Fastmail adds incoming invitations to.  Fastmail speaks the same
CalDAV, and answers discovery in the shapes the iCloud code already
parses.  A second fetcher would duplicate everything ADR-0002 decided,
and two fetchers sharing a calendar directory would each need to know
the other's file names.


## Decision

**One fetcher, generalised rather than copied.**  `rjd-icloud` becomes
`rjd-caldav`, and its settings and mode `rjd/caldav-...`, renamed with
no compatibility aliases.  `emacs.d` and `dotfiles` change together: a
machine that pulls one without the other fetches no calendars, and
starts cleanly.

**An account is a plist**, in the one list `rjd/caldav-accounts` in
`private.el`:

- `:name`, which is also the calendar file prefix (`icloud`);
- `:server`, the CalDAV URL where discovery starts
  (`https://caldav.icloud.com/`);
- `:user`, the account's address;
- `:calendars`, by display name, each optionally `(NAME . CATEGORY)`,
  as before;
- optionally `:addresses`, a regexp matched against whole addresses
  regardless of case, as `rjd-mail`'s `:addresses` is, and named the
  same since it is the same regexp.  An event is
  left out as declined when an attendee who has declined it is the
  account's user or an address this matches, so a decline made in
  Fastmail's own calendar, to an alias, takes effect.

An account without a user or calendars is not fetched.  Further keys
are added as accounts need them.

**The auth-source host is the server URL's host**, with the account's
user as login, so iCloud's stays `caldav.icloud.com` and no host is
written down twice.

**Calendar file names** are the account's name, a hyphen, and
ADR-0002's slug of the display name.  iCloud's files keep their names
(`icloud-SLUG.org`), and another account's cannot clash with them
unless the two accounts share a name, or an account's name with a
hyphen in it meets a calendar's slug.  Calendars whose files would
collide are all refused, across accounts as within one, and the
collision is reported once.

**One shared fetch state, but failures by account.**  The timer, the
guard against two fetches at once and the time of the last fetch are
kept once, not per account; the only thing kept per account between
fetches is whether its failing has been reported.  A fetch takes every
account together: each account's password is looked up separately,
and one with no password to hand is skipped -- silently from a timer,
reported when the fetch was begun by hand.  The accounts are fetched
side by side, the fetch finishing when all have, so one account's
outage does not stop another's.  Errors are collected per account,
each named by its account, and each account's run of failing fetches
is reported once, independently of the others: an account that starts
failing while another already is still gets reported, and an
account's success re-arms only its own report.  The agenda is redone
at the end.

**A refused password is told apart where the account is known.**  The
request function knows only a URL and a header, so it reports a 401 as
`unauthorized`; the fetch turns that into a message naming the
account's user, its auth-source host, and `auth-source-forget-all-cached`.

**A calendar fed from org is never fetched**, for any account, even if
`private.el` names it.  ADR-0002 relied on its not being named; with
Fastmail, where org-pa uploads its calendar, one slip in `private.el`
would bring org's own entries back into the agenda as copies.  So the
fetcher refuses any discovered calendar whose URL is recorded as fed
from org, sends it no REPORT, and reports it as it reports a name that
matches no calendar; the account's other calendars are still fetched.
The record is a list of variables, `rjd/caldav-fed-from-org`, whose
first and only one is org-pa's own `org-pa-caldav-url`: the URL stays
in `private.el` alone, written once, where org-pa uploads to it.

org-pa loads lazily, and the guard must hold whenever the agenda
opens, so each variable is read from its value once its package has
loaded, and before that from the value Custom has saved on the symbol
(`saved-value`), which use-package's `:custom` sets at once for a
deferred package.  URLs are compared by their paths, percent-decoded
and ending in a slash, so another form of the host (iCloud's
`p01-caldav.icloud.com:443` for `caldav.icloud.com`), an encoded `@`
in Fastmail's `/user/ADDRESS/` path, or a missing trailing slash still
match.

**The probe** becomes `test/caldav-probe.sh`.  It probes iCloud unless
`CALDAV_SERVER` names another server, whose host is then the
`~/.authinfo` machine, and prints display names by their string value,
so a CDATA section comes out as the plain name.  Fixtures move to
`test/fixtures/caldav/`, one directory per server.


## Fastmail

Fastmail is the second account, so that the calendar it adds incoming
invitations to (its default calendar, "Calendar") reaches the agenda.
Its `:server` is the `/dav/` root on its CalDAV host,
`https://caldav.fastmail.com/dav/`.

**What the probe found**, on the iMac on 2026-10-20, recorded in
`test/fixtures/caldav/fastmail/` with the address and every UUID
replaced:

- Discovery is standard: the principal, calendar home and calendar list
  come back in the shapes iCloud's do.  Display names arrive as CDATA,
  which Emacs's XML parser reads as plain text.
- The scheduling inbox and outbox are typed as such, not as calendars,
  and the home collection has a display name but no calendar type, so
  the existing type check leaves all three out.
- A to-do list collection is typed as a calendar.  It holds no events,
  so naming it would fetch an empty calendar file.
- With server-side expansion, a weekly event of five occurrences, one
  moved and one deleted, came back as four events, the moved one at its
  new time and the deleted one absent, with no RRULE or EXDATE left.
  The first occurrence carries no RECURRENCE-ID; nothing depends on it.
- Every time is in UTC, as RFC 4791 asks, and was right across the 1
  November change.  iCloud's TZID handling is not needed, and does no
  harm.
- Every event gives its length as `DURATION`, with no `DTEND`.  Without
  reading `DURATION` every Fastmail event would have had no end; that
  was the one change Fastmail's data needed.
- Fastmail adds a vendor property, `X-JMAP-USEDEFAULTALERTS`, which the
  parser ignores.

**The password is org-pa's.**  org-pa's CalDAV upload already reads its
password from auth-source, with the account address as login.  It does
so through url.el's Basic auth, which files it under the host and port,
`caldav.fastmail.com:443`, so the fetcher looks under the bare host
first and then under the host and port.  So no new app password is
made, and the one entry serves both.  That password can write -- org-pa clears and re-uploads its
calendar with it, and Fastmail scopes app passwords by service
(Calendars), not by read and write -- so read-only for Fastmail rests
wholly on the fetcher sending only PROPFIND and REPORT.

Where the entry sits in `~/.authinfo.gpg`, a timer's fetch skips
Fastmail rather than prompt, and it is fetched only on agenda open or
by hand.  Moving the line into the plain `~/.authinfo` (mode 600), as
ADR-0002 recommends for iCloud, gives timer fetches.  That is each
machine's choice; the code is the same either way.


## Consequences

- Adding an account, or a calendar to one, is a change to `private.el`
  alone.
- Every account's password can write, so for each, read-only rests on
  the code, which sends only PROPFIND and REPORT to any server.
- A timer's fetch is skipped for an account whose password sits in an
  encrypted auth-source, while the others are fetched; that account is
  fetched only on agenda open or by hand.
- `:custom` under use-package's `:after` saves nothing until the
  package it waits for loads, so a `private.el` form that sets
  `org-pa-caldav-url` that way leaves the guard empty until org-pa has
  loaded.  The URL is set in a form that is only deferred.
- A calendar fed from org by something other than org-pa, such as
  beorg, is still refused only by not being named, until its URL is
  recorded too.
- `rjd/caldav-list-calendars` asks which account to list, when there is
  more than one.
- The message a failure shows names its account first
  (`icloud: Home: ...`), so a run of failures across accounts is still
  one message.


## Alternatives and fallbacks

- **A second package beside `rjd-icloud`** (rejected).  It would copy
  discovery, parsing, the file writing and the fetch control, and the
  two would drift.
- **Keeping the iCloud names with compatibility aliases** (rejected).
  Only `private.el` sets them, and it changes in the same deployment.
- **Per-account timers and failure state** (rejected).  One timer and
  one report per run of failures is what the user sees either way, and
  the shared state is what ADR-0002 already had.
- **Refusing org-pa's calendar by name** (rejected).  Display names
  change, and the name would have to be written into this public
  repository or kept in step with `private.el`; the URL is what org-pa
  itself uses.
- **Loading org-pa to read its setting** (rejected).  It would load
  org-pa on every fetch for one string Custom already holds.
- **The auth-source host as its own key** (rejected for now).  Every
  server so far files its password under its own host; a key can be
  added if one does not.
