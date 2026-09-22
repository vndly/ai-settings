#!/usr/bin/env bash

set -euo pipefail

INPUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Claude Code, Codex, and Antigravity play the same notification sound, so it lives once
# in this repository's data folder and is copied into each of their data folders.
NOTIFICATION_SOUND="$INPUT/data/notification.ogg"

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
        HAS_CHANGES=1
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
        HAS_CHANGES=1
        echo "binary:    $label (skipped, will be copied as-is)"
        return
    fi

    HAS_CHANGES=1
    echo "changed:   $label"
    git diff --no-index --color="$PREVIEW_COLOR" -- "$tgt" "$src" || true
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

# merge_settings <tgt> <src>
# Deep-merges JSON settings source over target so locally-added keys survive.
# jq's `*` recurses into objects but lets the source win outright for arrays and
# scalars, so this repository owns every key it declares -- including the
# permissions.allow/deny/ask lists, where an entry removed here has to disappear
# from the target too. Keys the source does not declare are left untouched;
# settings_local_only lists them during the preview.
merge_settings() {
    local tgt="$1" src="$2"

    jq -s '.[0] * .[1]' "$tgt" "$src"
}

# settings_local_only <tgt> <src>
# Print the key paths merge_settings will carry over from the target untouched,
# one per line, because this repository says nothing about them. This walks the
# two files exactly the way jq's `*` merges them -- recursing only while both
# sides hold an object, and stopping at the first key the source does not have,
# since the whole subtree below it is the target's. Anything the source does
# declare is left out: `*` gives it to the source outright, whatever its shape.
settings_local_only() {
    local tgt="$1" src="$2"

    jq -s -r '
        def local_only($src):
            if (type == "object" and ($src | type) == "object") then
                [ to_entries[]
                  | .key as $key
                  | if ($src | has($key)) then
                        .value | local_only($src[$key])[] | [$key] + .
                    else
                        [$key]
                    end
                ]
            else
                []
            end;

        .[1] as $src
        | .[0]
        | local_only($src)[]
        | join(".")
    ' "$tgt" "$src"
}

# Temp files computed during preview and reused during the write phase so the
# previewed and deployed content cannot drift. Cleaned up on every exit path.
CLAUDE_MERGED_SETTINGS=""
CODEX_MERGED_CONFIG=""
CODEX_MERGED_RULES=""
AGY_MERGED_SETTINGS=""
AGY_MERGED_HOOKS=""
PREVIEW_OUTPUT=""
PREVIEW_COLOR=never
HAS_CHANGES=0

cleanup() {
    rm -f -- "$CLAUDE_MERGED_SETTINGS" "$CODEX_MERGED_CONFIG" "$CODEX_MERGED_RULES" "$AGY_MERGED_SETTINGS" "$AGY_MERGED_HOOKS" "$PREVIEW_OUTPUT"
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
    # (extra enabledPlugins, marketplaces, etc.) survive, while every key this
    # repository declares -- the permission lists included -- is taken from here.
    # Preview the *merged result* (not the raw source) against the current
    # target, since that is what the write phase will actually produce, then name
    # the local-only keys the merge carries over, so the parts of the deployed
    # file this repository does not control are never confirmed unseen.
    if [ -f "$CLAUDE_OUTPUT/settings.json" ]; then
        CLAUDE_MERGED_SETTINGS="$(mktemp)"
        merge_settings "$CLAUDE_OUTPUT/settings.json" "$CLAUDE_INPUT/settings.json" > "$CLAUDE_MERGED_SETTINGS"
        preview_file "$CLAUDE_MERGED_SETTINGS" "$CLAUDE_OUTPUT/settings.json" "settings.json (merged)"

        local local_only
        local_only="$(settings_local_only "$CLAUDE_OUTPUT/settings.json" "$CLAUDE_INPUT/settings.json")"
        if [ -n "$local_only" ]; then
            echo "local-only: settings.json keys kept from the deployed file"
            echo "$local_only" | sed 's/^/            /'
        fi
    else
        HAS_CHANGES=1
        echo "NEW:       settings.json (target does not exist, will be created)"
    fi

    preview_file "$NOTIFICATION_SOUND" "$CLAUDE_OUTPUT/data/notification.ogg" "data/notification.ogg"
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

    # Copy the shared sound and the folder contents
    cp "$NOTIFICATION_SOUND" "$CLAUDE_OUTPUT/data/"
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
        HAS_CHANGES=1
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
        HAS_CHANGES=1
        echo "NEW:       rules/default.rules (target does not exist, will be created)"
    fi

    if [ -f "$CODEX_OUTPUT/rules/ai-settings.rules" ]; then
        HAS_CHANGES=1
        echo "REMOVE:    rules/ai-settings.rules (replaced by rules/default.rules)"
    fi

    preview_file "$NOTIFICATION_SOUND" "$CODEX_OUTPUT/data/notification.ogg" "data/notification.ogg"
    preview_folder "$CODEX_INPUT/scripts" "$CODEX_OUTPUT/scripts" "scripts"
}

write_codex() {
    mkdir -p "$CODEX_OUTPUT/rules" "$CODEX_OUTPUT/data" "$CODEX_OUTPUT/scripts"

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

    cp "$NOTIFICATION_SOUND" "$CODEX_OUTPUT/data/"
    cp -R "$CODEX_INPUT/scripts/." "$CODEX_OUTPUT/scripts/"

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
        HAS_CHANGES=1
        echo "NEW:       antigravity-cli/settings.json (target does not exist, will be created)"
    fi

    # hooks.json: deep-merge into existing hooks if present.
    if [ -f "$AGY_CONFIG_OUTPUT/hooks.json" ]; then
        AGY_MERGED_HOOKS="$(mktemp)"
        jq -s '.[0] * .[1]' "$AGY_CONFIG_OUTPUT/hooks.json" "$AGY_INPUT/hooks.json" > "$AGY_MERGED_HOOKS"
        preview_file "$AGY_MERGED_HOOKS" "$AGY_CONFIG_OUTPUT/hooks.json" "hooks.json (merged)"
    elif [ -f "$AGY_INPUT/hooks.json" ]; then
        HAS_CHANGES=1
        echo "NEW:       hooks.json (target does not exist, will be created)"
    fi

    preview_file "$NOTIFICATION_SOUND" "$AGY_CONFIG_OUTPUT/data/notification.ogg" "data/notification.ogg"
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

    cp "$NOTIFICATION_SOUND" "$AGY_CONFIG_OUTPUT/data/"
    cp -R "$AGY_INPUT/scripts/." "$AGY_CONFIG_OUTPUT/scripts/"

    echo "Deployed Antigravity settings to $AGY_CONFIG_OUTPUT and $AGY_CLI_OUTPUT"
}

# --- Preview (read-only) ----------------------------------------------------

if [ -t 1 ]; then
    PREVIEW_COLOR=always
fi

PREVIEW_OUTPUT="$(mktemp)"
{
    echo "Previewing changes"
    echo

    preview_claude
    preview_codex
    preview_agy
} > "$PREVIEW_OUTPUT"

if [ "$HAS_CHANGES" -eq 0 ]; then
    echo "Already up to date."
    exit 0
fi

cat "$PREVIEW_OUTPUT"

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
