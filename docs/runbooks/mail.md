# Run-book: bringing up mu4e, mbsync, msmtp and oama

How to configure this repository's mail system on the Mac from nothing,
and what to do when a piece of it stops working.  The design and its
reasons are in [ADR 0001](../adr/0001-mail-and-calendar-architecture.md);
this is the procedure.

**No addresses, domains or secrets belong in this file.**  The repository
is public.  Every account value comes from `private.el`
(`rjd/mail-accounts`) or from the `dotfiles` repository's
`mail-container/`, and is written here as a placeholder.  Fill them in
from those files as you go; do not paste them back.

Throughout:

|Placeholder          |Where to read its value                                                                                |
|---------------------|-------------------------------------------------------------------------------------------------------|
|`$CETOS`             |`private.el`, the `cetos` account's `:address`                                                         |
|`$FASTMAIL`          |`private.el`, the `fastmail` account's `:address`                                                      |
|`$FASTMAIL_DOMAIN_RE`|the domain in that account's `:addresses` regexp, each dot escaped (`\.`) so that it matches only a dot|
|`$ALIAS`             |any further whole address in `:addresses`                                                              |
|`$MAC`               |this Mac's host name in the `setup` repository's `inventory`                                           |


## What is being configured

Two accounts, declared in `private.el` as `rjd/mail-accounts` and turned
into mu4e contexts by `rjd/mail-mode` (`user-lisp/rjd-mail.el`).
`cetos` is a Google Workspace account, so it is Gmail to every tool:

|Account         |IMAP                           |SMTP                                  |Auth                    |Maildir                 |
|----------------|-------------------------------|--------------------------------------|------------------------|------------------------|
|`cetos`         |`imap.gmail.com:993` (IMAPS)   |`smtp.gmail.com:587` (STARTTLS)       |XOAUTH2, token from oama|`~/Mail/cetos/`         |
|`fastmail`      |`imap.fastmail.com:993` (IMAPS)|`smtp.fastmail.com:465` (implicit TLS)|LOGIN, app password     |`~/Mail/fastmail/`      |

Plus the global default identity, also in `private.el`: the Fastmail
address over `smtpmail`, used by mail written outside mu4e on a machine
where no account is active.

The tools run in two places:

- **In the `mail` container** (OrbStack Docker, Debian trixie): `mbsync`
  fetches, `msmtp` sends, `oama` holds the Google token.  They are there
  because Debian packages the XOAUTH2 SASL module isync needs and macOS
  does not, and because the tokens must sit where no agent container can
  reach them.  Emacs reaches them through `rjd/mail-command`, which puts
  `rjd/mail-command-prefix` — `docker exec -i mail` — in front.
- **On the host**: `mu` and `mu4e`, from Homebrew, indexing and reading
  the maildir the container writes.  `~/Mail` is mounted at the same
  path inside and out, so the two see one maildir.  Reading and
  searching keep working while the container is down.

What decides *when* mail syncs is host Emacs.  Every
`mu4e-update-interval` seconds (300), and on `U`, mu4e runs
`rjd/mail-get-mail-command` — `docker exec -i mail mbsync …` — so
`mbsync` itself runs in the container; when it exits, mu4e has the
host's `mu` index the result.  The timer runs only while mu4e does, so
there is no LaunchAgent and no second sync to overlap it.
`rjd/mail-start-syncing` starts mu4e in the background from
`emacs-startup-hook`, so mail syncs without mu4e being opened.

What crosses the container boundary: `~/Mail`; the `mail-state` volume
(oama's tokens, the GPG key that encrypts them, Fastmail's encrypted app
password, msmtp's log); `~/.config/mail-container`, read-only, holding
the configs; and `127.0.0.1:8765`, for the OAuth login redirect only.


## Prerequisites

1. **OrbStack installed and running.**  `docker version` must succeed;
   the playbook fails early if it does not.
2. **The `dotfiles` checkout at `~/projects/dotfiles`**, holding
   `mail-container/.mbsyncrc`, `mail-container/.config/msmtp/config` and
   `mail-container/.config/oama/config.yaml`.  A work Mac (the `setup`
   inventory's `work` group) takes them from the checkout its
   `group_vars/work.yml` names instead, with the `cetos` account alone, so there everything below
   about Fastmail is skipped and there is one context.
3. **`private.el` linked into this repository**, by the `setup`
   playbook's `dotfile_links`.  Without it there are no accounts: mu4e
   still reads mail, but there is nothing to sync or send as.
4. **A Google OAuth client** in the oama config.  See
   [Google OAuth client](#2-google-oauth-client) below; the existing
   client's values are already in `dotfiles` and need no work on a
   second machine.
5. **A Fastmail app password**, made for this machine alone.  See
   [step 4](#4-store-fastmails-app-password).


## First-time setup

### 1. Run the playbook's `email` tag

From the `setup` checkout:

```sh
./run.sh -l $MAC --tags email --check --diff   # dry run first
./run.sh -l $MAC --tags email
```

**Always pass `-l $MAC`**, the inventory name, not `localhost`, which
no play targets.  Every host in the inventory, leroy and
bulldog included, has `ansible_connection=local`, so without the limit
the Linux play's `email` tasks would run on the Mac too, as root.

That does everything that can be automated:

- installs `mu` (which ships mu4e's elisp) and `texinfo`, and lists
  Homebrew's Info manuals in its `dir` file;
- creates `~/Mail` and one maildir root per account, mode 0700 —
  `mbsync` will not create them;
- copies `dotfiles`' `mail-container/` to `~/.config/mail-container`.
  **Copied, not linked**: the container sees the copy through its
  read-only mount, so an edit in `dotfiles` reaches it only when this
  tag runs again.  That directory's presence is also what
  `rjd/mail-default-command-prefix` takes to mean this host has the
  container;
- builds the image and runs the container, publishing
  `127.0.0.1:8765`;
- makes oama's passphrase-less GPG key (`oama@localhost`) inside the
  state volume, if it is not already there;
- checks that SASL in the container offers XOAUTH2, failing if it does
  not.

Confirm the container is up:

```sh
docker ps --filter name=mail
```

### 2. Google OAuth client

Only needed once per Google Cloud project; skip on a second machine.

The `cetos` account logs in through a personal **Desktop app** client,
in a personal Cloud project published **"In production"** and left
unverified, under Google's personal-use exemption; Cetos's Workspace
admin policy lets it in (ADR 0001's last addendum).  The project
belongs to the old trial Gmail account, which must therefore stay:
deleting that Google account or the project stops Cetos mail and
calendar.  If Cetos's admins block unconfigured third-party apps, the
fallbacks are in that addendum.  Two constraints, both learned the hard
way:

- Thunderbird's public client ID **cannot** be used.  Google approves it
  only for Thunderbird's own scopes and blocks it outright ("This app is
  blocked") when it asks for `calendar.readonly`.
- The client must stay **"In production"**, not "Testing": a Testing
  client loses its refresh tokens after 7 days.  Its login shows a
  "Google hasn't verified this app" warning, which is expected.

The client ID and secret, the scope
(`https://mail.google.com/` plus `calendar.readonly`, so the calendar is
read-only by scope rather than by convention), the fixed
`redirect_uri` on port 8765 and `auth_http_method: GET` all live in
`dotfiles`' `mail-container/.config/oama/config.yaml`.  Edit them there
and re-run step 1; never copy them into this repository.

### 3. Authorize Google

The one time a browser is involved.  In one terminal:

```sh
docker exec -it mail oama authorize google $CETOS
```

Then, in the Mac's browser, open:

```
http://localhost:8765/start
```

`auth_http_method: GET` makes that a plain 302 to Google, so the consent
page opens on the host rather than needing a browser in the container.
Accept the "Google hasn't verified this app" warning and grant access.
The redirect to `http://localhost:8765` arrives at the published port,
which a `socat` relay in the container carries to oama's `[::1]:8765`
listener — that relay is the container's long-running process.

If the browser cannot load the redirect after you consent — it may have
tried `::1` only — copy the failed `http://localhost:8765/?state=…&code=…`
URL from the address bar and, while `oama authorize` is still running,
hand it to oama from inside the container:

```sh
docker exec mail curl -s 'PASTED-URL'
```

Use single quotes, and be prompt: the code is single-use and
short-lived.

Check the token:

```sh
docker exec mail oama list
docker exec mail oama access $CETOS   # prints an access token
```

### 4. Store Fastmail's app password

Fastmail offers third-party clients no OAuth, so `mbsync` and `msmtp`
log in with an app password.  Make one in Fastmail's web settings, scoped
to mail (IMAP/SMTP), for this machine alone — so the Mac's access can be
revoked without touching the Linux machines.

It is read by `mbsync`'s `PassCmd` and `msmtp`'s `passwordeval` from
`~/.local/state/passwords/fastmail.gpg` in the container, GPG-encrypted
to the same `oama@localhost` key as the tokens.  The image makes that
directory, mode 0700, but Docker copies it into the `mail-state` volume
only when the volume is new, so the command below makes it too, for a
volume older than the image's.

Store the password with it, which prompts without echoing:

```sh
docker exec -it mail bash -c 'umask 077; mkdir -p ~/.local/state/passwords && IFS= read -rsp "Fastmail app password: " pw && echo && printf %s "$pw" | gpg --batch --yes --encrypt --recipient oama@localhost --output ~/.local/state/passwords/fastmail.gpg; unset pw'
```

The password never appears on a command line, so it is in neither
shell's history; it is never shown on screen; and it is never written
unencrypted.  A "checking the trustdb" message from gpg is harmless.

Enter it as Fastmail shows it.  Then check its length, without showing
it:

```sh
docker exec mail sh -c 'gpg --quiet --batch --decrypt ~/.local/state/passwords/fastmail.gpg | wc -c'
```

That prints 16, or 19 if the spaces Fastmail shows between its groups
went in too.  If the first sync then fails to log in with 19, store it
again without the spaces.  Never check it by decrypting to the terminal:
that puts it in the scrollback.  To replace a revoked or rotated
password, run the same command again.

### 5. First sync

Run it by hand once, before Emacs ever does, so that an authentication
failure shows up here rather than in a background update:

```sh
docker exec mail mbsync -a            # both accounts
docker exec mail mbsync cetos   # or one group at a time
docker exec mail mbsync fastmail
```

The first run of each is the long one.  `mbsync -V cetos` is
the verbose form when something is wrong.

What the configuration syncs, and why it matters to mu4e's folders:

- **Cetos (Gmail)**: six folders only — INBOX, All Mail, Sent Mail, Drafts,
  Trash and Spam — under short local names (`inbox`, `all`, `sent`,
  `drafts`, `trash`, `spam`), which are `rjd/mail-gmail-folders` in
  `rjd-mail.el`.  Label folders are not synced; labels stay a web-UI
  concern.  Archiving refiles to `all`, so the message leaves the Inbox
  and stays in All Mail, as on the web.
- **Fastmail**: every folder (`Patterns *`), by name, into
  `~/Mail/fastmail/` — its folders are real folders, not labels.  Its
  `:folders` in `private.el` names them (`/INBOX`, `/Sent`, `/Drafts`,
  `/Trash`, `/Archive`, `/Spam`).

Both use `Expunge Both`, so a move in mu4e is a move on the server.

### 6. Index on the host

`mu` runs on the host, not in the container, and finds the maildir from
the root given here — there is no maildir setting in `init.el`.

Quit mu4e first: its `mu server` holds the store, and `mu init` cannot
rebuild it while that runs.  On an existing store, `mu info store` shows
the personal addresses it has now; `mu init` must be given every one
again, since it keeps none of them.

```sh
mu init --maildir="$HOME/Mail" \
        --my-address="$CETOS" \
        --my-address="$FASTMAIL" \
        --my-address="/[^@]+@$FASTMAIL_DOMAIN_RE\$/" \
        --my-address="/[^@]+@[^@]+\.$FASTMAIL_DOMAIN_RE\$/" \
        --my-address="$ALIAS"
mu index
mu find maildir:/fastmail/INBOX | head   # lists Fastmail mail
```

The first pattern covers the domain's plus and catch-all addresses, the
second its subdomain addresses.

The alias arguments need care.  `private.el` gives the account's aliases
— Fastmail's plus, subdomain and catch-all addresses — as one Emacs
regexp, its `:addresses`.  `mu init` needs the same addresses in `/.../`
form so that mu counts mail to them as personal and reply-to-all leaves
them out.  So:

- **one `--my-address` per alternative** of that regexp, never the whole
  regexp with its `\|`;
- **in syntax PCRE and Emacs regexps share** — no alternation, no groups
  — because mu matches it as PCRE and mu4e's
  `mu4e-personal-address-p` as an Emacs regexp;
- plain addresses can go in literally, without the slashes.

Two settings in `init.el` depend on this list being right:
`message-dont-reply-to-names` and the `:from-or-to` headers field, which
shows "To " and the recipient when the sender is one of these addresses.

Re-run `mu init` whenever `:addresses` changes in `private.el`; it
rebuilds the database, so follow it with `mu index`.

### 7. Start Emacs

Restart Emacs.  Nothing else is needed: `init.el`'s mu4e form turns
`rjd/mail-mode` on, which builds a context per account, and
`rjd/mail-start-syncing` starts mu4e in the background from
`emacs-startup-hook`.  `C-c M` opens it.


## Verification

Work down this list; each step assumes the ones above it.

1. **The host thinks mail can run.**  `M-:`
   `(rjd/mail-available-p)` → `t`, and
   `rjd/mail-command-prefix` → `("docker" "exec" "-i" "mail")`.
   If the first is `nil`, nothing below will work: the accounts are
   being ignored, and Emacs is behaving as it does on leroy.  And
   `(locate-library "mu4e")` is under Homebrew's site-lisp, with
   `mu4e-mu-version` matching `mu --version`.
2. **The contexts exist.**  `M-:` `(length mu4e-contexts)` → 2 (1 on
   a work Mac).  In mu4e, `;` lists them.  Entering mu4e takes the
   first context without asking (`mu4e-context-policy` is
   `pick-first`), so the order `private.el` declares the accounts in
   decides which.  The context does not decide where `d` and `r` send a
   message: each goes to the Trash and Archive of the account whose
   maildir holds it, whatever context is current.  Trash one message
   from each account, from the same context, to check.
3. **The fetch command is right.**  `M-:`
   `(rjd/mail-get-mail-command)` → `docker exec -i mail mbsync
   cetos fastmail`.  With no active account it is `true`, and
   an update only indexes.
4. **Mail is indexed.**  `mu find maildir:/fastmail/INBOX | head`, and
   in mu4e the Unread bookmark (`b u`) lists something.
5. **Junk is excluded.**  `M-:`
   `(rjd/mail-search-query "flag:unread")` → the query with each
   account's Spam and Trash subtracted.  A query that names Spam or
   Trash, asks for `flag:trashed`, or looks a message up by `msgid:`
   is left alone.
6. **Sending works, per account.**  Compose in mu4e with `C`, which
   asks which account to send as (`mu4e-compose-context-policy` is
   `ask`), and send one message from each to yourself.  Then check
   msmtp's log:
   ```sh
   docker exec mail tail ~/.local/state/msmtp/msmtp.log
   ```
   `rjd/mail-send-it` chooses the msmtp account from the message's
   **From at send time**, not from the current context, so a draft goes
   out as the account it was written as.
7. **Sending from outside mu4e works.**  `C-x m` opens mu4e's compose,
   not a bare message buffer: wherever mu4e is installed, `init.el`
   makes `mu4e-user-agent` the `mail-user-agent`, so everything that
   calls `compose-mail` writes in a context.  To check the path outside
   mu4e, `M-x message-mail`, which is the only way left to one: the
   buffer has the default (Fastmail) identity, and the send goes
   through Fastmail's msmtp too.  Where accounts are active,
   `rjd/mail-mode` makes `rjd/mail-send-it` the *global*
   `message-send-mail-function`, because `smtpmail` has no credentials
   on the Mac.  A From that no active account owns still falls back to
   `smtpmail`.
8. **A reply from an alias.**  Reply to a message sent to one of the
   Fastmail aliases; the From should be the alias it was sent to, which
   the context arranges through `message-alternative-emails`.
9. **Sent mail is filed once.**  Gmail files its own sent mail, so its
   context's `:sent-messages-behavior` defaults to `delete`; Fastmail
   does not file SMTP-sent mail, so its account sets `sent`, and mu4e
   saves the copy to `/Sent`.  Check that a sent message appears exactly
   once in each account's Sent folder.
10. **Invitations.**  Open a calendar invitation; Accept, Tentative and
    Decline buttons should appear, and answering opens a draft to send
    with `C-c C-c`.  The acceptance must appear on the organiser's
    calendar — see the troubleshooting table if it does not.
    mu4e-icalendar with mu 1.14 has traps (#10):
    - The answer is a **draft**, not sent: nothing reaches the organiser
      until `C-c C-c`, and killing the buffer sends nothing.  Its subject
      is `Re: …`, not `Accepted: …`.
    - **Send each reply before answering the next.**  The draft's
      calendar part refers to the `*CAL*` buffer, read only at send
      time, so a second answer overwrites the first's; a draft resumed
      in a later session has no `*CAL*` at all.
    - An invitation to any active account's address or alias gets its
      buttons whatever context is current, through `rjd/mail-mode`'s
      advice on `gnus-icalendar-identities`.  If one shows "Uninvited
      Accept" and so on, or no buttons, see the troubleshooting table.
    - An abandoned reply can leave an auto-save file (`#…#`) in the
      account's `drafts/cur/`, which mbsync would upload as a draft.
      Delete it.
11. **The calendar.**  `rjd/gcal-account` in `private.el` uses the same
    oama token; `~/org-agenda/calendars/gcal.org` should fill in.
    `test/rjd-gcal-test.el` covers the code.

The ERT suites are `test/rjd-mail-test.el` and `test/rjd-gcal-test.el`,
and the whole config loads in batch through `test/smoke-test.el`:

```sh
emacs --batch --init-directory=/Users/rob/projects/emacs.d -l test/smoke-test.el
```


## Routine operations

|Task                                       |Command                                                                                                                                                |
|-------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------|
|Change an mbsync, msmtp or oama config     |edit it in `dotfiles`, then `./run.sh -l $MAC --tags email` in `setup` — the container reads a copy, so an edit alone does nothing                |
|Rebuild after a Dockerfile or option change|`./run.sh -l $MAC --tags email`; the run options and image ID are hashed into a `setup.spec` label, and a change to either recreates the container|
|Sync by hand                               |`docker exec mail mbsync -a`                                                                                                                           |
|Re-index                                   |`mu index` (on the host)                                                                                                                               |
|Rebuild the index from scratch             |quit mu4e, then `mu init …` with every address, as in step 6, then `mu index`                                                                          |
|Re-login to Google                         |`docker exec -it mail oama authorize google $CETOS`, then `http://localhost:8765/start`, as in step 3                                                  |
|Rotate Fastmail's app password             |revoke in Fastmail, make a new one, redo step 4                                                                                                        |
|Stop syncing                               |turn `rjd/mail-mode` off, or set `rjd/mail-enabled` to `nil` in `private.el`                                                                           |

A `docker stop mail` leaves the container stopped across restarts; the
playbook starts it again.  Mail and calendar are both opt-in minor modes
precisely so that a bad upgrade is bypassed by turning one off rather
than fixed under pressure.


## Troubleshooting

Most of these fail *quietly* — the feature simply stops working rather
than raising an error.

| Symptom | Where to look |
| --- | --- |
| `rjd/mail-available-p` is `nil` on the Mac | `~/.config/mail-container` is missing, so `rjd/mail-default-command-prefix` chose `nil`.  Re-run `./run.sh -l $MAC --tags email`.  `rjd/mail-enabled` forces the answer either way |
| mbsync: Gmail refuses the login | the XOAUTH2 SASL module.  `docker exec mail saslpluginviewer -c` must list XOAUTH2 |
| mbsync or msmtp: no token | `docker exec mail oama list`.  A new state volume means a new GPG key, and then the Google login must be done again |
| Google logins stop lasting | the OAuth client slipped back to "Testing", which loses refresh tokens after 7 days |
| mbsync or msmtp: Fastmail password fails | `~/.local/state/passwords/fastmail.gpg` — missing directory (a volume older than the image's), the spaces Fastmail shows between the groups (`wc -c` gives 19, not 16; see step 4), or a revoked password |
| The login redirect never arrives | the `socat` relay or the published port.  With no login running the connection is refused, which is all it does.  Meanwhile, hand oama the failed URL with `docker exec mail curl -s 'URL'`, as in step 3 |
| **`d` or `r` on a message files it in the other account's folder**, or mu4e asks "`~/Mail/Trash` does not exist yet.  Create now?" | `rjd/mail-message-folder`: `rjd/mail-mode` makes `mu4e-trash-folder` and `mu4e-refile-folder` functions of the message, giving the folders of the active account whose maildir holds it.  A message in no account's maildir, or one marked with `rjd/mail-mode` off, gets `init.el`'s defaults for leroy and bulldog.  **Answer no**: a folder mbsync does not sync takes the messages out of the server's view, which for Fastmail is in effect a delete |
| **An invitation to an alias shows no buttons**, or "Uninvited Accept" | the `:filter-return` advice on gnus-icalendar's `gnus-icalendar-identities`, which adds every active account's address and `:addresses`.  An upgrade that renames that function, or stops accepting predicates as identities, breaks it silently |
| **A reply to mail Bcc'd to an alias is from the account's address** | the `:after` advice on `message-use-alternative-email-as-from`, which falls back to the delivery headers (`X-Delivered-To`, `X-Original-To`, `Delivered-To`) |
| `U` fails with docker's "container … is not running" | expected with the container stopped; `docker start mail`.  Reading and searching keep working meanwhile |
| `mu init` fails, or the store is locked | mu4e is running, and its `mu server` holds the store.  Quit mu4e first |
| Mail syncs but mu4e shows nothing | `mu index` on the host; check `mu init`'s maildir root is `~/Mail` |
| A starred unread message loses its star on the next sync | `rjd/mail-move-flagged-new-to-cur`, run before each index (#18).  mu reads a file in `new/` as New and ignores its other flags |
| Spam or trashed mail appears in a search | `mu4e-query-rewrite-function`, and `mu4e-search-include-related` being `nil` in `init.el` |
| A message appears twice in a Gmail search | `mu4e-search-skip-duplicates`; every synced Gmail folder holds its own copy |
| Mail from the default address stops sending | `rjd/mail--fallback-send-function`; `smtpmail` has no credentials on the Mac |
| `docker -oi exec …` in an error | something is sending through message's sendmail path instead of `rjd/mail-send-it`, which exists exactly because `-oi` would land inside the prefix |
| **An acceptance stops showing on the organiser's calendar** | `rjd/mail--reply-as-one-attendee`, the `:around` advice on gnus-icalendar's private `gnus-icalendar-event--build-reply` (#20).  An Emacs upgrade can break it silently, the replies simply carrying every attendee again.  Remove the advice once Emacs fixes the builder upstream |
| **The calendar disappears from the agenda** | the `:around` advice in `rjd-gcal.el` on oauth2-auto's `oauth2-auto-access-token`.  An org-gcal or oauth2-auto upgrade breaks it silently |
| mu4e's elisp does not load, or does not match `mu` | the `:load-path` in `init.el`'s mu4e form.  The elisp must be the one Homebrew shipped with that `mu` |

Fallbacks, if a dependency fails outright: `mutt_oauth2.py` replaces
oama as the password command for mbsync and msmtp (oama has had no
commits since August 2025); lieer + notmuch replaces the sync stack if
IMAP or XOAUTH2 is closed off.  ADR 0001 has the rest.


## Development, in `claude-dev`

Inside the container the prefix is `nil` and the tools run directly:
`rjd/mail-default-command-prefix` returns `nil` because
`/.dockerenv` exists, and `rjd/mail-available-p` is then true only
because `mbsync` is on `exec-path`.  `mu` is built from source at a
pinned 1.14.x release, the closest to Homebrew's, because Debian
bookworm's is far older and mu4e changed a great deal after 1.12 — so
config and tests run against the older mu4e could pass here and fail on
the Mac.  isync, msmtp and oama behave the same across these versions,
so their configs carry over unchanged.

**The toolchain is not in the image.**  `claude-dev` has no root, so it
was installed by hand under `~/.local` (#5 has the steps): Debian
packages unpacked with a user-space apt, the oama release binary, and
`mu` built against a private glib.  `~/.local/mail-env.sh` sets `PATH`,
`LD_LIBRARY_PATH` and `SASL_PATH`, and must be sourced before any of the
tools run.  Only `~/.claude` and `~/projects` are mounts, so recreating
the container loses all of it, the oama login and its GPG key included:
then `mu`, `mbsync`, `msmtp` and `oama` are simply missing,
`rjd/mail-available-p` is `nil`, and Emacs behaves as on leroy.
Reinstalling means repeating #5.

The same `mbsyncrc`, msmtp config and oama config apply, read from the
container's own home rather than through the read-only mount, and the
oama GPG key lives in that home.  The steps are otherwise steps 3 to 7
above without the `docker exec` prefix.


## Machines where mail is off

**Presumed broken: #33.**  leroy and bulldog declare the accounts in
`private.el` like every machine, but have no mail container, so
`rjd/mail-available-p` is `nil` and `rjd/mail-active-accounts` is empty:
no contexts, no background mu4e, and since mu4e's fetch command is then
`true`, an update only indexes.  Nothing else runs their `.mbsyncrc`
either, so Fastmail probably no longer syncs there at all.  #33 tracks
the repair; update this section with what it settles.  The folder settings and bookmarks outside every context in `init.el` are
Fastmail's as those machines sync it, at the root of `~/Mail`.  Sending
there goes over `smtpmail`, with the server and identity from
`private.el`.
