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

`vendor/` is added to `load-path` by `init.el` and holds files symlinked
in by the `setup` repo's `org-sync` role.  It is gitignored, so anything
loaded from it must tolerate being absent.

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
