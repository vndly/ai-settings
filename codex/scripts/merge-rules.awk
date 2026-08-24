# Replace the block managed by this repository while retaining Codex rules that
# were learned locally and written outside that block.

BEGIN {
    begin_marker = "# BEGIN ai-settings managed rules"
    end_marker = "# END ai-settings managed rules"
}

FILENAME == ARGV[1] {
    if ($0 == begin_marker) {
        in_managed_block = 1
        next
    }
    if (in_managed_block) {
        if ($0 == end_marker) {
            in_managed_block = 0
        }
        next
    }

    existing[++existing_count] = $0
    next
}

FNR == 1 {
    while (existing_count > 0 && existing[existing_count] ~ /^[[:space:]]*$/) {
        existing_count--
    }
    for (line_number = 1; line_number <= existing_count; line_number++) {
        print existing[line_number]
    }
    if (existing_count > 0) {
        print ""
    }
}

{
    print
}
