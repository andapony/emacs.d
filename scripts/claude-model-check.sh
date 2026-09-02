#!/usr/bin/env bash
#
# Report whether upgrading claude-agent-acp would bring in new Claude models.
#
# agent-shell drives Claude Code through the claude-agent-acp adapter, which
# pins an *exact* @anthropic-ai/claude-agent-sdk version and bundles that
# version's `claude` binary.  New models therefore reach agent-shell only when
# the adapter bumps that pin: neither acp.el nor agent-shell carries a model
# list of its own -- both take whatever the adapter reports over ACP.
#
# Two checks, cheapest first:
#
#   1. Registry metadata only (~1s).  Is a newer adapter published, and does it
#      move the CLI pin?  An unchanged pin means no new models are possible and
#      the second check is skipped.
#
#   2. Model diff (~15s).  Stream the newly pinned binary straight through tar
#      into strings and diff its model list against the installed one.  Nothing
#      is written to disk.
#
# CAVEAT: the model list is scraped out of a minified binary, not read from any
# supported interface, so treat it as a tripwire for new *generations* rather
# than as an inventory -- it misses dated pins (claude-haiku-4-5-20251001) and
# models with no picker row.  The extraction can also break outright when
# upstream reshapes the build, and a broken extraction looks exactly like "no
# new models".  An empty extraction is therefore a hard error, never a pass.
#
# Ground truth after upgrading is the protocol itself: the adapter reports
# availableModels in its ACP session response, and agent-shell renders that
# under "Available models" when a shell starts.
#
# Usage: scripts/claude-model-check.sh [--constants] [SDK_VERSION]
#
#   --constants  Diff the Vertex region constants (VERTEX_REGION_CLAUDE_*),
#                which encode family and version, instead of the user-facing
#                model-picker descriptions.  These are compiler-emitted
#                identifiers rather than prose, so use them as a cross-check
#                when a picker row has merely been reworded.
#   SDK_VERSION  Compare against this @anthropic-ai/claude-agent-sdk version
#                rather than the one the latest adapter pins.
#
# Run this where the adapter is installed.  agent-shell-command-prefix sends
# every command into the claude-dev container, so the adapter lives there --
# run this inside the container too, not on the host.

set -euo pipefail

ADAPTER_PKG=@agentclientprotocol/claude-agent-acp
SDK_PKG=@anthropic-ai/claude-agent-sdk

die() { printf 'claude-model-check: %s\n' "$*" >&2; exit 1; }

for tool in npm curl tar strings node diff; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

mode=descriptions
want_sdk=
while [ $# -gt 0 ]; do
    case $1 in
        --constants) mode=constants ;;
        -h|--help) sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) want_sdk=$1 ;;
    esac
    shift
done

# Locate the installed adapter.  `npm root -g` is the common case; fall back to
# resolving the bin on PATH, which is how it is reachable when installed under
# a version manager.
adapter_root=
if root=$(npm root -g 2>/dev/null) && [ -d "$root/$ADAPTER_PKG" ]; then
    adapter_root=$root/$ADAPTER_PKG
elif bin=$(command -v claude-agent-acp 2>/dev/null); then
    # .../claude-agent-acp/dist/index.js -> walk up to the package root.
    dir=$(dirname "$(readlink -f "$bin")")
    while [ "$dir" != / ] && [ ! -f "$dir/package.json" ]; do dir=$(dirname "$dir"); done
    [ -f "$dir/package.json" ] && adapter_root=$dir
fi
[ -n "$adapter_root" ] || die "$ADAPTER_PKG not found (are you inside the claude-dev container?)"

pkg_field() { node -p "require('$1/package.json')$2" 2>/dev/null; }

have_acp=$(pkg_field "$adapter_root" ".version") || die "cannot read adapter package.json"
have_sdk=$(pkg_field "$adapter_root" ".dependencies['$SDK_PKG']") || die "adapter does not pin $SDK_PKG"

# The bundled binary lives in a per-platform package alongside the adapter.
# Read the platform off the installed directory rather than guessing from uname
# so the streamed comparison uses the same build as the local one.
native_dir=$(find "$adapter_root/node_modules/$SDK_PKG"-* -maxdepth 0 -type d 2>/dev/null | head -1) \
    || die "bundled native package not found under $adapter_root"
[ -n "$native_dir" ] || die "bundled native package not found under $adapter_root"
[ -f "$native_dir/claude" ] || die "bundled claude binary not found in $native_dir"
# basename drops the npm scope, so put it back from SDK_PKG's own scope.
native_pkg="${SDK_PKG%%/*}/$(basename "$native_dir")"

latest_acp=$(npm view "$ADAPTER_PKG" version 2>/dev/null) || die "npm view failed for $ADAPTER_PKG"
latest_sdk=$(npm view "$ADAPTER_PKG@$latest_acp" "dependencies.$SDK_PKG" 2>/dev/null) \
    || die "cannot read pinned $SDK_PKG for $ADAPTER_PKG@$latest_acp"

printf 'adapter: %s -> %s\n' "$have_acp" "$latest_acp"
printf 'CLI pin: %s -> %s\n' "$have_sdk" "$latest_sdk"

target=${want_sdk:-$latest_sdk}

if [ -z "$want_sdk" ] && [ "$have_sdk" = "$latest_sdk" ]; then
    printf '\nCLI pin unchanged -- no new models are possible. Nothing to pick up.\n'
    exit 0
fi

# Extract a model list from a `claude` binary on stdin.  Both patterns are
# scraped from minified output; see the CAVEAT above.
extract() {
    if [ "$mode" = constants ]; then
        # Compiler-emitted region constants: VERTEX_REGION_CLAUDE_FABLE_5_1.
        # Deliberately not the adjacent ["claude-x","VERTEX_REGION_y"] literal
        # -- that pairing is only emitted by newer builds, so diffing it
        # against an older installed binary yields a spurious empty side.
        strings -n 4 | grep -oE 'VERTEX_REGION_CLAUDE_[A-Z0-9_]+'
    else
        # Model-picker rows: "Opus 5 - best for everyday, complex tasks"
        strings -n 12 \
            | grep -oiE '(Opus|Sonnet|Haiku|Fable|Mythos) [0-9.]+ - [a-z ,-]{10,70}'
    fi | sort -u
}

models_installed() { extract < "$native_dir/claude"; }

models_published() {
    local tarball
    tarball=$(npm view "$native_pkg@$1" dist.tarball 2>/dev/null | tr -d '"')
    [ -n "$tarball" ] || die "no published tarball for $native_pkg@$1"
    curl -sfL "$tarball" | tar xzO package/claude | extract
}

printf '\ncomparing model lists (%s), streaming %s@%s ...\n' "$mode" "$native_pkg" "$target"

# grep exits 1 on no match, which pipefail would surface as a pipeline failure;
# capture permissively and treat emptiness as the hard error it is.
have_list=$(models_installed || true)
want_list=$(models_published "$target" || true)

[ -n "$have_list" ] || die "extraction produced nothing for the installed binary -- the $mode pattern has probably gone stale; do not read this as 'no new models'"
[ -n "$want_list" ] || die "extraction produced nothing for $native_pkg@$target -- the $mode pattern has probably gone stale; do not read this as 'no new models'"

if diff <(printf '%s\n' "$have_list") <(printf '%s\n' "$want_list"); then
    printf '\nNo model changes. Upgrade only if you want the adapter fixes.\n'
    exit 0
fi

cat <<EOF

Model list differs ('<' installed, '>' published).  To pick it up:

    npm i -g $ADAPTER_PKG@$latest_acp

Then restart the agent-shell session and check "Available models".  Note that
an adapter upgrade can silently break rjd-agent-shell-version (it globs into
the adapter's node_modules for the bundled claude) and the header advice both
it and rjd-agent-shell-budget add -- if the version or budget vanishes from the
header afterwards, look there first.
EOF
exit 1
