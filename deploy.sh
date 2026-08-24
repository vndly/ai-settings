#!/usr/bin/env bash

set -euo pipefail

INPUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Deploys the settings for every supported agent. Each agent gets its own folder
# in this repository and its own preview_*/write_* pair below, since the target
# directory, the file set and the merge strategy all differ per agent. The
# preview phase runs first for every agent, then a single confirmation gates the
# write phase.

# --- Generic helpers --------------------------------------------------------

# preview_file <src> <tgt> <label>
# Print a one-line status for the file and, when it changed, a colored diff of
# the current target against the incoming source. Never writes anything.
preview_file() {
    local src="$1" tgt="$2" label="$3"

    if [ ! -e "$tgt" ]; then
        echo "NEW:       $label (target does not exist, will be created)"
        return
    fi

    # --numstat prints nothing when the files are identical, and "-<tab>-" as
    # its first fields for binary files. It exits 1 when the files differ, so
    # guard it against set -e.
    local numstat
    numstat="$(git diff --no-index --numstat -- "$tgt" "$src" 2>/dev/null || true)"

    if [ -z "$numstat" ]; then
        echo "unchanged: $label"
        return
    fi

    if [ "${numstat%%$'\t'*}" = "-" ]; then
        echo "binary:    $label (skipped, will be copied as-is)"
        return
    fi

    echo "changed:   $label"
    git diff --no-index --color=auto -- "$tgt" "$src" || true
}

# preview_folder <src_dir> <tgt_dir> <label>
# Preview the flat files of a folder, mirroring what `cp -R` will place. Nested
# directories are skipped, matching the layout the agent folders actually use.
preview_folder() {
    local src_dir="$1" tgt_dir="$2" label="$3"

    local src
    for src in "$src_dir/"*; do
        [ -f "$src" ] || continue
        preview_file "$src" "$tgt_dir/$(basename "$src")" "$label/$(basename "$src")"
    done
}

# Temp files computed during preview and reused during the write phase so the
# previewed and deployed content cannot drift. Cleaned up on every exit path.
CLAUDE_MERGED_SETTINGS=""
CODEX_MERGED_CONFIG=""
CODEX_MERGED_RULES=""
AGY_MERGED_SETTINGS=""
AGY_MERGED_HOOKS=""

cleanup() {
    rm -f -- "$CLAUDE_MERGED_SETTINGS" "$CODEX_MERGED_CONFIG" "$CODEX_MERGED_RULES" "$AGY_MERGED_SETTINGS" "$AGY_MERGED_HOOKS"
}
trap cleanup EXIT

# --- Claude Code ------------------------------------------------------------

CLAUDE_INPUT="$INPUT/claude"
CLAUDE_OUTPUT="$HOME/.claude"

preview_claude() {
    echo "Claude Code -> $CLAUDE_OUTPUT"
    echo

    # CLAUDE.md: straight overwrite.
    preview_file "$CLAUDE_INPUT/CLAUDE.md" "$CLAUDE_OUTPUT/CLAUDE.md" "CLAUDE.md"

    # settings.json: deep-merge into the existing file so locally-added keys
    # (extra enabledPlugins, marketplaces, etc.) survive. jq's "*" recursively
    # merges objects with the right operand winning, so the repo's values take
    # precedence. Preview the *merged result* (not the raw source) against the
    # current target, since that is what the write phase will actually produce.
    if [ -f "$CLAUDE_OUTPUT/settings.json" ]; then
        CLAUDE_MERGED_SETTINGS="$(mktemp)"
        jq -s '.[0] * .[1]' "$CLAUDE_OUTPUT/settings.json" "$CLAUDE_INPUT/settings.json" > "$CLAUDE_MERGED_SETTINGS"
        preview_file "$CLAUDE_MERGED_SETTINGS" "$CLAUDE_OUTPUT/settings.json" "settings.json (merged)"
    else
        echo "NEW:       settings.json (target does not exist, will be created)"
    fi

    preview_folder "$CLAUDE_INPUT/data" "$CLAUDE_OUTPUT/data" "data"
    preview_folder "$CLAUDE_INPUT/scripts" "$CLAUDE_OUTPUT/scripts" "scripts"
}

write_claude() {
    # Make sure the target folders exist
    mkdir -p "$CLAUDE_OUTPUT/data" "$CLAUDE_OUTPUT/scripts"

    # CLAUDE.md: safe to overwrite outright
    cp "$CLAUDE_INPUT/CLAUDE.md" "$CLAUDE_OUTPUT/CLAUDE.md"

    # settings.json: reuse the merged file built during the preview when the
    # target already existed; otherwise this is a first deploy, so copy the
    # source as-is.
    if [ -n "$CLAUDE_MERGED_SETTINGS" ]; then
        mv "$CLAUDE_MERGED_SETTINGS" "$CLAUDE_OUTPUT/settings.json"
        CLAUDE_MERGED_SETTINGS=""
    else
        cp "$CLAUDE_INPUT/settings.json" "$CLAUDE_OUTPUT/settings.json"
    fi

    # Copy the folder contents
    cp -R "$CLAUDE_INPUT/data/." "$CLAUDE_OUTPUT/data/"
    cp -R "$CLAUDE_INPUT/scripts/." "$CLAUDE_OUTPUT/scripts/"

    echo "Deployed Claude Code settings to $CLAUDE_OUTPUT"
}

# --- Codex ------------------------------------------------------------------

CODEX_INPUT="$INPUT/codex"
CODEX_OUTPUT="${CODEX_HOME:-$HOME/.codex}"
CODEX_RULES_SOURCE="$CODEX_INPUT/rules/default.rules"
CODEX_RULES_TARGET="$CODEX_OUTPUT/rules/default.rules"

preview_codex() {
    echo
    echo "Codex -> $CODEX_OUTPUT"
    echo

    # AGENTS.md: straight overwrite.
    preview_file "$CODEX_INPUT/AGENTS.md" "$CODEX_OUTPUT/AGENTS.md" "AGENTS.md"

    # config.toml: overlay the repository-owned keys while preserving unrelated
    # user settings such as model selection, MCP servers, and trusted projects.
    # The small AWK merger understands the simple scalar and one-line array keys
    # owned by this repository and leaves every other line untouched.
    if [ -f "$CODEX_OUTPUT/config.toml" ]; then
        CODEX_MERGED_CONFIG="$(mktemp)"
        awk -f "$CODEX_INPUT/scripts/merge-config.awk" \
            "$CODEX_INPUT/config.toml" \
            "$CODEX_OUTPUT/config.toml" > "$CODEX_MERGED_CONFIG"
        preview_file "$CODEX_MERGED_CONFIG" "$CODEX_OUTPUT/config.toml" "config.toml (merged)"
    else
        echo "NEW:       config.toml (target does not exist, will be created)"
    fi

    # default.rules: replace only this repository's marked block so rules Codex
    # learned locally survive and repeated deploys do not duplicate entries.
    if [ -f "$CODEX_RULES_TARGET" ]; then
        CODEX_MERGED_RULES="$(mktemp)"
        awk -f "$CODEX_INPUT/scripts/merge-rules.awk" \
            "$CODEX_RULES_TARGET" \
            "$CODEX_RULES_SOURCE" > "$CODEX_MERGED_RULES"
        preview_file "$CODEX_MERGED_RULES" "$CODEX_RULES_TARGET" "rules/default.rules (merged)"
    else
        echo "NEW:       rules/default.rules (target does not exist, will be created)"
    fi

    if [ -f "$CODEX_OUTPUT/rules/ai-settings.rules" ]; then
        echo "REMOVE:    rules/ai-settings.rules (replaced by rules/default.rules)"
    fi
}

write_codex() {
    mkdir -p "$CODEX_OUTPUT/rules"

    cp "$CODEX_INPUT/AGENTS.md" "$CODEX_OUTPUT/AGENTS.md"

    if [ -n "$CODEX_MERGED_CONFIG" ]; then
        mv "$CODEX_MERGED_CONFIG" "$CODEX_OUTPUT/config.toml"
        CODEX_MERGED_CONFIG=""
    else
        cp "$CODEX_INPUT/config.toml" "$CODEX_OUTPUT/config.toml"
    fi

    if [ -n "$CODEX_MERGED_RULES" ]; then
        mv "$CODEX_MERGED_RULES" "$CODEX_RULES_TARGET"
        CODEX_MERGED_RULES=""
    else
        cp "$CODEX_RULES_SOURCE" "$CODEX_RULES_TARGET"
    fi

    rm -f -- "$CODEX_OUTPUT/rules/ai-settings.rules"

    echo "Deployed Codex settings to $CODEX_OUTPUT"
}

# --- Antigravity (agy) ------------------------------------------------------

AGY_INPUT="$INPUT/agy"
AGY_CLI_OUTPUT="$HOME/.gemini/antigravity-cli"
AGY_CONFIG_OUTPUT="$HOME/.gemini/config"

preview_agy() {
    echo
    echo "Antigravity -> $AGY_CONFIG_OUTPUT, $AGY_CLI_OUTPUT"
    echo

    # AGENTS.md: straight overwrite.
    preview_file "$AGY_INPUT/AGENTS.md" "$AGY_CONFIG_OUTPUT/AGENTS.md" "AGENTS.md"

    # settings.json: deep-merge into the existing file so locally-added keys
    # (trustedWorkspaces, etc.) survive.
    if [ -f "$AGY_CLI_OUTPUT/settings.json" ]; then
        AGY_MERGED_SETTINGS="$(mktemp)"
        jq -s '.[0] * .[1]' "$AGY_CLI_OUTPUT/settings.json" "$AGY_INPUT/settings.json" > "$AGY_MERGED_SETTINGS"
        preview_file "$AGY_MERGED_SETTINGS" "$AGY_CLI_OUTPUT/settings.json" "antigravity-cli/settings.json (merged)"
    else
        echo "NEW:       antigravity-cli/settings.json (target does not exist, will be created)"
    fi

    # hooks.json: deep-merge into existing hooks if present.
    if [ -f "$AGY_CONFIG_OUTPUT/hooks.json" ]; then
        AGY_MERGED_HOOKS="$(mktemp)"
        jq -s '.[0] * .[1]' "$AGY_CONFIG_OUTPUT/hooks.json" "$AGY_INPUT/hooks.json" > "$AGY_MERGED_HOOKS"
        preview_file "$AGY_MERGED_HOOKS" "$AGY_CONFIG_OUTPUT/hooks.json" "hooks.json (merged)"
    elif [ -f "$AGY_INPUT/hooks.json" ]; then
        echo "NEW:       hooks.json (target does not exist, will be created)"
    fi

    preview_folder "$AGY_INPUT/data" "$AGY_CONFIG_OUTPUT/data" "data"
    preview_folder "$AGY_INPUT/scripts" "$AGY_CONFIG_OUTPUT/scripts" "scripts"
}

write_agy() {
    mkdir -p "$AGY_CONFIG_OUTPUT/data" "$AGY_CONFIG_OUTPUT/scripts" "$AGY_CLI_OUTPUT"

    cp "$AGY_INPUT/AGENTS.md" "$AGY_CONFIG_OUTPUT/AGENTS.md"

    if [ -n "$AGY_MERGED_SETTINGS" ]; then
        mv "$AGY_MERGED_SETTINGS" "$AGY_CLI_OUTPUT/settings.json"
        AGY_MERGED_SETTINGS=""
    else
        cp "$AGY_INPUT/settings.json" "$AGY_CLI_OUTPUT/settings.json"
    fi

    if [ -n "$AGY_MERGED_HOOKS" ]; then
        mv "$AGY_MERGED_HOOKS" "$AGY_CONFIG_OUTPUT/hooks.json"
        AGY_MERGED_HOOKS=""
    elif [ -f "$AGY_INPUT/hooks.json" ]; then
        cp "$AGY_INPUT/hooks.json" "$AGY_CONFIG_OUTPUT/hooks.json"
    fi

    cp -R "$AGY_INPUT/data/." "$AGY_CONFIG_OUTPUT/data/"
    cp -R "$AGY_INPUT/scripts/." "$AGY_CONFIG_OUTPUT/scripts/"

    echo "Deployed Antigravity settings to $AGY_CONFIG_OUTPUT and $AGY_CLI_OUTPUT"
}

# --- Preview (read-only) ----------------------------------------------------

echo "Previewing changes"
echo

preview_claude
preview_codex
preview_agy

# --- Confirm ----------------------------------------------------------------

echo
printf 'Proceed with deploy? [y/n] '
read -r reply || reply=""
case "$reply" in
    [yY] | [yY][eE][sS]) ;;
    *)
        echo "Aborted. Nothing was written."
        exit 0
        ;;
esac

# --- Write ------------------------------------------------------------------

write_claude
write_codex
write_agy
