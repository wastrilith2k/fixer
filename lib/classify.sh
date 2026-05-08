#!/usr/bin/env bash
# lib/classify.sh — Classify verdict parser.
# Sourced by fixer.sh. Sets CLASSIFY_KIND and CLASSIFY_DETAIL globals.

# Globals:
CLASSIFY_KIND=""    # "AUTO_FIX" | "NEEDS_HUMAN" | "WONTFIX"
CLASSIFY_DETAIL=""  # question (NEEDS_HUMAN) or reason (WONTFIX), empty for AUTO_FIX

# Parse the CLASSIFICATION: line from classify agent output.
# Uses awk (not grep -P) for macOS/BSD portability.
# Separator stripping is permissive: handles em-dash, en-dash, hyphen.
parse_classify_verdict() {
    local output="$1"
    CLASSIFY_KIND=""
    CLASSIFY_DETAIL=""

    local line
    line="$(awk '/^CLASSIFICATION:/{line=$0} END{print line}' <<< "$output")"
    line="${line#CLASSIFICATION:}"
    line="${line# }"  # strip one leading space

    if [[ "$line" == AUTO_FIX* ]]; then
        CLASSIFY_KIND="AUTO_FIX"
        CLASSIFY_DETAIL=""
    elif [[ "$line" == NEEDS_HUMAN* ]]; then
        CLASSIFY_KIND="NEEDS_HUMAN"
        CLASSIFY_DETAIL="$(printf '%s' "${line#NEEDS_HUMAN}" \
            | sed 's/^[[:space:]]*[—–-]\+[[:space:]]*//')"
    elif [[ "$line" == WONTFIX* ]]; then
        CLASSIFY_KIND="WONTFIX"
        CLASSIFY_DETAIL="$(printf '%s' "${line#WONTFIX}" \
            | sed 's/^[[:space:]]*[—–-]\+[[:space:]]*//')"
    else
        printf '[WARN ] Could not parse CLASSIFICATION line — defaulting to AUTO_FIX. Raw: "%s"\n' \
            "$line" >&2
        CLASSIFY_KIND="AUTO_FIX"
        CLASSIFY_DETAIL=""
    fi
}
