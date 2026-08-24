# Overlay the simple keys in the repository's config.toml onto an existing
# Codex config. Existing keys and tables not present in the source survive.

function section_name(line, value) {
    value = line
    sub(/^[[:space:]]*/, "", value)
    sub(/[[:space:]]*(#.*)?$/, "", value)
    if (value !~ /^\[[^][]+\]$/) {
        return missing
    }
    sub(/^\[/, "", value)
    sub(/\]$/, "", value)
    return value
}

function assignment_key(line, value) {
    value = line
    sub(/^[[:space:]]*/, "", value)
    if (value !~ /^[A-Za-z0-9_-]+[[:space:]]*=/) {
        return missing
    }
    sub(/[[:space:]]*=.*/, "", value)
    return value
}

function remember_section(section) {
    if (!(section in source_section)) {
        source_section[section] = 1
        source_section_order[++source_section_count] = section
    }
}

function remember_key(section, key, line, id, position) {
    id = section SUBSEP key
    if (!(id in source_value)) {
        position = source_key_count[section] + 1
        source_key_count[section] = position
        source_key_order[section SUBSEP position] = key
    }
    source_value[id] = line
}

function flush_missing(section, i, key, id) {
    if (!(section in source_section) || section_flushed[section]) {
        return
    }

    for (i = 1; i <= source_key_count[section]; i++) {
        key = source_key_order[section SUBSEP i]
        id = section SUBSEP key
        if (!(id in applied)) {
            print source_value[id]
            applied[id] = 1
        }
    }
    section_flushed[section] = 1
}

BEGIN {
    missing = "\034"
    current_section = ""
}

# The first input is the repository-owned config overlay.
FNR == NR {
    parsed_section = section_name($0)
    if (parsed_section != missing) {
        current_source_section = parsed_section
        remember_section(current_source_section)
        next
    }

    parsed_key = assignment_key($0)
    if (parsed_key != missing) {
        remember_section(current_source_section)
        remember_key(current_source_section, parsed_key, $0)
    }
    next
}

# The second input is the user's existing config.
{
    parsed_section = section_name($0)
    if (parsed_section != missing) {
        flush_missing(current_section)
        current_section = parsed_section
        seen_section[current_section] = 1
        print
        next
    }

    parsed_key = assignment_key($0)
    id = current_section SUBSEP parsed_key
    if (parsed_key != missing && id in source_value) {
        print source_value[id]
        applied[id] = 1
        next
    }

    print
}

END {
    flush_missing(current_section)

    for (section_index = 1; section_index <= source_section_count; section_index++) {
        section = source_section_order[section_index]
        if (section == "" || section in seen_section) {
            continue
        }

        print ""
        print "[" section "]"
        flush_missing(section)
    }
}
