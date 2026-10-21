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
  as before.

An account without a user or calendars is not fetched.  Further keys
are added as accounts need them; #49 plans an optional aliases regexp,
for telling declined events.

**The auth-source host is the server URL's host**, with the account's
user as login, so iCloud's stays `caldav.icloud.com` and no host is
written down twice.

**Calendar file names** are the account's name, a hyphen, and
ADR-0002's slug of the display name.  iCloud's files keep their names
(`icloud-SLUG.org`), and another account's cannot clash with them
unless the two accounts share a name.

**One shared fetch state.**  The timer, the guard against two fetches
at once, the time of the last fetch and the failing flag are kept once,
not per account; nothing else is kept between fetches, per account or
at all.  A fetch takes every account together: each account's password
is looked up separately, and one with no password to hand is skipped
-- silently from a timer, reported when the fetch was begun by hand.
The accounts are fetched side by side, the fetch finishing when all
have, so one account's outage does not stop another's.  Errors are
collected per account, each named by its account, and a run of failing
fetches is still reported once.  The agenda is redone at the end.

**A refused password is told apart where the account is known.**  The
request function knows only a URL and a header, so it reports a 401 as
`unauthorized`; the fetch turns that into a message naming the
account's user, its auth-source host, and `auth-source-forget-all-cached`.

**The probe** becomes `test/caldav-probe.sh`.  It probes iCloud unless
`CALDAV_SERVER` names another server, whose host is then the
`~/.authinfo` machine, and prints display names by their string value,
so a CDATA section comes out as the plain name.  Fixtures move to
`test/fixtures/caldav/`, one directory per server.


## Consequences

- Adding an account, or a calendar to one, is a change to `private.el`
  alone.
- Every account's password can write, so for each, read-only rests on
  the code, which sends only PROPFIND and REPORT to any server.
- A timer's fetch is skipped for an account whose password sits in an
  encrypted auth-source, while the others are fetched; that account is
  fetched only on agenda open or by hand.
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
- **The auth-source host as its own key** (rejected for now).  Every
  server so far files its password under its own host; a key can be
  added if one does not.
