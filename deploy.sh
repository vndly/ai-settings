#!/usr/bin/env bash

set -euo pipefail

INPUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$HOME/.claude"

# Temp file holding the merged settings.json, computed during the preview and
# reused by the write phase so the two can never drift. Cleaned up on exit.
MERGED_SETTINGS=""
trap 'rm -f "$MERGED_SETTINGS"' EXIT

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

# --- Preview (read-only) ----------------------------------------------------

echo "Previewing changes against $OUTPUT"
echo

# CLAUDE.md: straight overwrite.
preview_file "$INPUT/CLAUDE.md" "$OUTPUT/CLAUDE.md" "CLAUDE.md"

# settings.json: deep-merge into the existing file so locally-added keys (extra
# enabledPlugins, marketplaces, etc.) survive. jq's "*" recursively merges
# objects with the right operand winning, so the repo's values take precedence.
# Preview the *merged result* (not the raw source) against the current target,
# since that is what the write phase will actually produce.
if [ -f "$OUTPUT/settings.json" ]; then
    MERGED_SETTINGS="$(mktemp)"
    jq -s '.[0] * .[1]' "$OUTPUT/settings.json" "$INPUT/settings.json" > "$MERGED_SETTINGS"
    preview_file "$MERGED_SETTINGS" "$OUTPUT/settings.json" "settings.json (merged)"
else
    echo "NEW:       settings.json (target does not exist, will be created)"
fi

# Folder contents (flat files only, mirroring what cp -R will place).
for src in "$INPUT/data/"*; do
    [ -f "$src" ] || continue
    preview_file "$src" "$OUTPUT/data/$(basename "$src")" "data/$(basename "$src")"
done
for src in "$INPUT/scripts/"*; do
    [ -f "$src" ] || continue
    preview_file "$src" "$OUTPUT/scripts/$(basename "$src")" "scripts/$(basename "$src")"
done

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

# Make sure the target folders exist
mkdir -p "$OUTPUT/data" "$OUTPUT/scripts"

# CLAUDE.md: safe to overwrite outright
cp "$INPUT/CLAUDE.md" "$OUTPUT/CLAUDE.md"

# settings.json: reuse the merged file built during the preview when the target
# already existed; otherwise this is a first deploy, so copy the source as-is.
if [ -n "$MERGED_SETTINGS" ]; then
    mv "$MERGED_SETTINGS" "$OUTPUT/settings.json"
    MERGED_SETTINGS=""
else
    cp "$INPUT/settings.json" "$OUTPUT/settings.json"
fi

# Copy the folder contents
cp -R "$INPUT/data/." "$OUTPUT/data/"
cp -R "$INPUT/scripts/." "$OUTPUT/scripts/"

echo "Deployed Claude Code settings to $OUTPUT"
