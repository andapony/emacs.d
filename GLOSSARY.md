# Emacs configuration

Personal Emacs configuration: org-mode tasks, mail and calendars in
one editor, set up the same way on every machine.

## Calendars

**Calendar file**:
An org file in the agenda that holds one external calendar's events,
labelled by that calendar's name.  Only a fetch writes it, so it is
disposable: nothing typed into it is kept.
_Avoid_: calendar org file, gcal file

**Fetch**:
Copying a calendar's events into its calendar file.  It never changes
the calendar itself.
_Avoid_: sync, pull, import

**Sync**:
Two-way exchange between org and a calendar, where a change on either
side reaches the other.  Not done for any calendar.
_Avoid_: fetch (which is one-way)

**iCloud calendar**:
A calendar stored in the user's iCloud account, the same on every
machine.  Not everything Calendar.app shows is one: Google calendars
and `.ics` subscriptions it displays are not.
_Avoid_: Apple calendar, Calendar.app calendar

**Fastmail calendar**:
A calendar stored in the user's Fastmail account, such as its default
"Calendar", where Fastmail adds incoming invitations.  org-pa's
calendar there is one too, but is fed from org, so is never fetched.
_Avoid_: invitation calendar

**CalDAV account**:
An account on a CalDAV server whose calendars are fetched, such as the
user's iCloud or Fastmail account: a server, a user and the calendars
named in `private.el`.  Its name begins each of its calendar files' names.
_Avoid_: source, provider

**Agenda export**:
The single `.ics` file built from the org agenda files, so other
calendar apps can show org's dated tasks.  Calendar files are left out
of it, so a fetched event never loops back into a calendar.
_Avoid_: combined ics, org calendar
