#!/usr/bin/env bash

set -euo pipefail

# One-line remote installer for these Claude Code settings. Intended to be run
# straight from a pipe:
#
#   curl -fsSL https://raw.githubusercontent.com/vndly/claude-code-settings/main/install.sh | bash
#
# It clones the repository into a throwaway directory and hands off to deploy.sh,
# which previews the changes and asks for confirmation before writing anything.

REPO_URL="https://github.com/vndly/claude-code-settings.git"
BRANCH="main"

# --- Preconditions ----------------------------------------------------------

# The clone needs git; deploy.sh additionally needs git (for its --no-index
# diffs) and jq (for the settings merge). Fail early with a clear message.
for cmd in git jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: '$cmd' is required but not installed." >&2
        exit 1
    fi
done

# deploy.sh reads its y/n confirmation from the terminal. Under `curl ... | bash`
# our own stdin is the curl pipe, so we hand deploy.sh /dev/tty instead (see the
# redirect below). Verify that terminal is actually reachable first, otherwise
# the diff could never be confirmed and the deploy would silently abort. The
# open is done in a subshell so the outer 2>/dev/null swallows the "No such
# device" message when there is no controlling terminal.
if ! ( exec < /dev/tty ) 2>/dev/null; then
    echo "Error: an interactive terminal is required to review and confirm the changes." >&2
    exit 1
fi

# --- Clone ------------------------------------------------------------------

# Throwaway clone directory, removed on exit (success, failure, or Ctrl-C).
tmp=""
trap 'rm -rf "$tmp"' EXIT
tmp="$(mktemp -d)"

echo "Downloading settings..."
# GIT_TERMINAL_PROMPT=0 makes a failed clone (repo missing/renamed/private) fail
# fast with a clear error instead of blocking on an interactive credential prompt
# — /dev/tty is reachable here, so git would otherwise stop and wait for input.
GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --branch "$BRANCH" "$REPO_URL" "$tmp"

# --- Deploy -----------------------------------------------------------------

# Redirect stdin from the terminal so deploy.sh's confirmation prompt works even
# though our own stdin is the curl pipe. stdout/stderr stay on the terminal, so
# the colored diff preview is shown as usual.
#
# GIT_PAGER=cat stops deploy.sh's `git diff` from paging the preview through
# less: for a one-shot installer we want the diff to stream inline with the
# confirm prompt right after it, rather than dropping the user into a pager they
# must quit. Color survives because git keeps it on for the pager (color.pager,
# on by default).
GIT_PAGER=cat bash "$tmp/deploy.sh" < /dev/tty
