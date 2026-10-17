---
status: accepted
---

# iCloud calendars: CalDAV fetch with auth-source

Builds on [ADR-0001](0001-mail-and-calendar-architecture.md), and departs
from two of its premises: that every credential sits in the mail
container, and that a calendar is fetched only where mail can run.


## Context

The user's iCloud calendars should appear in the org agenda next to the
Google calendar.  "Apple calendars" could mean everything Calendar.app
shows, but that includes the Google calendar `rjd-gcal` already fetches
and `.ics` subscriptions -- possibly the agenda export itself, which
would loop.  The calendars meant are the **iCloud calendars**, which
also reach the Linux machines, where Calendar.app does not exist.

iCloud speaks CalDAV and authenticates with an Apple Account address
and an app-specific password over HTTP Basic.  It has no OAuth for
third parties and no scopes: an app-specific password opens every
calendar *and* the contacts, read and write.

Recurring events are one VEVENT with an RRULE, which org cannot
represent in general.  Emacs 31's new iCalendar library parses well,
but its recurrence code was found in a quick test to ignore `COUNT`,
miss UTC `EXDATE`s, and never apply `RECURRENCE-ID` overrides.


## Decision

**Fetch only.**  A new package, `rjd-icloud`, fetches the iCloud
calendars named in `private.el`, by display name, resolved by CalDAV
discovery on every fetch.  It reads with `PROPFIND` and `REPORT` and
never issues a write, so read-only rests on the code, the credential
being unable to enforce it.  Fetches run on agenda open and on a timer,
asynchronously, over a window from 30 days back to 365 days ahead.

**Recurrences are expanded by the server**, with CalDAV's `<C:expand>`,
so each occurrence arrives as its own VEVENT with overrides and
cancellations already applied.  Emacs 31's `icalendar-parser` parses
the result; its recurrence code is not used, deliberately, for the
reasons above.  iCloud honours `<C:expand>` by third-party testing,
but no published test covers moved or cancelled occurrences, so before
anything is built on it a weekly test event with one occurrence moved
and one deleted was fetched by hand on the iMac, with
`test/icloud-probe.sh`, on 2026-10-17.  iCloud got it right: one VEVENT
per occurrence, the moved one at its new time, the deleted one absent,
and no RRULE or EXDATE left.  The responses recorded there, sanitised,
are the test fixtures.

Against RFC 4791, which asks for expanded instances in UTC, iCloud
returns each `DTSTART` in the event's own zone (`TZID=...`), and a
`RECURRENCE-ID` in UTC or in that zone, so times are converted from the
named zone, never assumed to be UTC.

**One disposable calendar file per calendar.**  Each calendar is
written to its own calendar file under `~/org-agenda/calendars/`,
labelled with its display name by `#+CATEGORY:` and dated by a
`#+FETCHED:` line.  The file is named `icloud-SLUG.org`, the slug being
the display name in lower case with apostrophes dropped and every other
run of characters but letters and digits made one `-`
(`Marie/Errands & Appt's` is `icloud-marie-errands-appts.org`); two
calendars whose slugs collide are both refused, with a message.  The file is rewritten whole after a complete,
successful fetch of that calendar, and never edited by hand: notes
about an event belong in the user's own files.  A failed fetch leaves
the last good file and shows one message per run of failures.  An
entry carries the title, the time, the location as a property and the
description as body; cancelled and declined events are dropped, and
events marked free are kept.

**A calendar directory.**  `org-agenda-files` lists
`~/org-agenda/calendars/` once, so a calendar added in `private.el`
needs no change to `init.el`, which stays the only place the agenda
files are set.  The Google calendar file moves there too, and the
agenda export leaves out the whole directory, replacing the per-file
`rjd/gcal-file-p` check.  org-sync's file set is an explicit list, so
it needs no change.

**Password from auth-source.**  The app-specific password comes from
auth-source, so from each machine's existing `authinfo` file, as
gptel's key does; the backend is each machine's choice.  The iCloud
line belongs in the plain `~/.authinfo`, mode 600: no agent container
mounts the home directory, and FileVault covers the iMac's disk.  A
timer fetch never prompts: if the password would need a passphrase,
that run is skipped, and only a fetch started by opening the agenda
may ask.  Each machine has its own app-specific password, labelled
with the machine's name.

**A calendar fed from org is never fetched.**  The account holds a
calendar that beorg writes; fetched, its events would come back into
the agenda as copies of org's own entries, the loop ADR-0001 keeps the
Google calendar out of the export for.  It is simply not named in
`private.el`; the same goes for any calendar that subscribes to the
agenda export.

**Where it runs.**  On any machine that has an account in `private.el`
and a password in auth-source, mail or no mail -- but never inside a
container, so no agent's Emacs holds the password, with an override for
testing.  `rjd/icloud-mode` is opt-in, enabled from org-agenda's form,
so a bad upgrade is bypassed by turning it off.


## Consequences

- An app-specific password can write every calendar and read the
  contacts, whatever this code does with it.  Revoking a machine's
  password at account.apple.com is the remedy for a leaked one.
- Changing the Apple Account password revokes every app-specific
  password at once: every machine stops fetching together, each with
  its one failure message, and each needs a new password.  An account
  has at most 25.
- Renaming a calendar in iCloud drops it from the agenda until
  `private.el` is changed; the fetch reports the name as unmatched.
  `rjd/icloud-list-calendars` shows the names the account has.
- iCloud sometimes returns hrefs on `caldav.icloud.com` instead of the
  account's `pNN-caldav.icloud.com` host, so either must work.
- Anything typed into a calendar file is lost at the next fetch.


## Alternatives and fallbacks

- **Calendar.app's own store, through EventKit or `icalBuddy`**
  (rejected).  macOS only, and it shows every calendar Calendar.app
  does, Google and subscriptions included.
- **org-caldav** (rejected).  Its model is two-way sync with a
  direction switch, so one misconfiguration writes to iCloud; and it
  keeps state and IDs in the org files.
- **Two-way sync of one dedicated "Org" calendar** (deferred).  It
  would narrow what a bug could damage but not what the password can,
  and org already reaches calendar apps through the agenda export.  If
  wanted later, it replaces the export and gets its own ADR.
- **Client-side expansion with `icalendar-recur`** (rejected, and the
  fallback only if the expansion check fails).  It mishandles exactly
  the cases server expansion gets right, so it would mean writing our
  own recurrence code.
- **The password in the mail container** (rejected).  The container
  exists only on the iMac, and the calendars are wanted on the Linux
  machines too.
- **`~/.authinfo.gpg`, Keychain or Secret Service** (each machine's
  choice).  auth-source reads any of them; the plain file avoids a
  passphrase prompt from a timer, and Keychain's backend is fiddly to
  match.
- **Naming calendars by URL** (rejected).  It survives a rename but is
  opaque in `private.el`, and the display name doubles as the agenda's
  category.
- **Rewriting `org-agenda-files` at runtime from `private.el`**
  (rejected).  It would end `init.el` being the only source of the list.
