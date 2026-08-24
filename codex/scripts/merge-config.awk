# Overlay the simple keys in the repository's config.toml onto an existing
# Codex config. Existing keys and tables not present in the source survive.
#
# Only the target is parsed for multi-line values; the overlay itself must keep
# every value on a single line and use no array-of-tables.

function section_name(line, value) {
    value = line
    sub(/^[[:space:]]*/, "", value)
    sub(/[[:space:]]*(#.*)?$/, "", value)

    # Array-of-tables elements keep their brackets, so the name returned here
    # can never match a section this repository owns. The boundary still flushes
    # the previous section, but nothing inside the element is touched.
    if (value ~ /^\[\[[^][]+\]\]$/) {
        return value
    }

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

# Scans one line and returns the nesting it leaves open. Brackets inside a
# string, and anything after a comment, do not count. Multi-line basic and
# literal strings are tracked in ml_quote, which persists across lines, so their
# bodies are never mistaken for assignments or headers of their own.
function scan_line(line, i, ch, triple, delta, quote, escaped) {
    delta = 0
    quote = ""
    escaped = 0

    for (i = 1; i <= length(line); i++) {
        ch = substr(line, i, 1)
        triple = substr(line, i, 3)

        # Inside a multi-line string only its closing delimiter matters.
        if (ml_quote != "") {
            if (triple == ml_quote) {
                ml_quote = ""
                i += 2
            }
            continue
        }

        if (quote != "") {
            if (escaped) {
                escaped = 0
            } else if (quote == "\"" && ch == "\\") {
                escaped = 1
            } else if (ch == quote) {
                quote = ""
            }
            continue
        }

        if (triple == "\"\"\"" || triple == "'''") {
            ml_quote = triple
            i += 2
        } else if (ch == "\"" || ch == "'") {
            quote = ch
        } else if (ch == "#") {
            break
        } else if (ch == "[" || ch == "{") {
            delta++
        } else if (ch == "]" || ch == "}") {
            delta--
        }
    }

    return delta
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

# The second input is the user's existing config. Every line is scanned, so the
# multi-line string state stays accurate whichever branch below handles it.
{
    line_delta = scan_line($0)

    # A line that continues the value above it — the rest of a bracketed value,
    # or the body of a multi-line string — belongs to the assignment that opened
    # it. Pass it through, or drop it when that assignment was replaced by the
    # overlay, rather than parse it as a header or key of its own.
    if (in_value) {
        continuation += line_delta
        if (!value_dropped) {
            print
        }
        if (continuation <= 0 && ml_quote == "") {
            continuation = 0
            in_value = 0
            value_dropped = 0
        }
        next
    }

    parsed_section = section_name($0)
    if (parsed_section != missing) {
        flush_missing(current_section)
        current_section = parsed_section
        seen_section[current_section] = 1
        print
        next
    }

    parsed_key = assignment_key($0)
    if (parsed_key != missing) {
        continuation = line_delta
        if (continuation < 0) {
            continuation = 0
        }
        in_value = (continuation > 0 || ml_quote != "")

        id = current_section SUBSEP parsed_key
        if (id in source_value) {
            print source_value[id]
            applied[id] = 1
            value_dropped = in_value
            next
        }
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
