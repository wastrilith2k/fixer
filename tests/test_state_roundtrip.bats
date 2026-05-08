#!/usr/bin/env bats

setup() {
    export FIXER_STATE_FILE
    FIXER_STATE_FILE="$(mktemp)"
    # shellcheck source=../lib/state.sh
    source "$BATS_TEST_DIRNAME/../lib/state.sh"
    state_init
}

teardown() {
    rm -f "$FIXER_STATE_FILE"
}

@test "state_init creates file with correct schema" {
    run jq -e '.version == 1 and .schema_version == 1 and (.issues | type) == "object"' \
        "$FIXER_STATE_FILE"
    [ "$status" -eq 0 ]
}

@test "state_get_issue returns null for unknown id" {
    run state_get_issue "owner/repo#99"
    [ "$status" -eq 0 ]
    [ "$output" = "null" ]
}

@test "state_init_issue creates queued issue with correct fields" {
    state_init_issue "owner/repo#1" "Test bug" "2026-05-08T00:00:00Z"
    local issue
    issue="$(state_get_issue "owner/repo#1")"
    run jq -e '
        .status == "queued" and
        .classification == null and
        .first_seen == "2026-05-08T00:00:00Z" and
        (.attempts | length) == 0 and
        .last_question == null and
        .last_question_timestamp == null
    ' <<< "$issue"
    [ "$status" -eq 0 ]
}

@test "state_init_issue is idempotent — does not overwrite existing state" {
    state_init_issue "owner/repo#1" "Test bug" "2026-05-08T00:00:00Z"
    state_upsert_issue "owner/repo#1" '{"status":"in_progress"}'
    state_init_issue "owner/repo#1" "Test bug" "2026-05-09T00:00:00Z"
    local st
    st="$(state_get_issue "owner/repo#1" | jq -r '.status')"
    [ "$st" = "in_progress" ]
}

@test "state_upsert_issue merges fields without destroying others" {
    state_init_issue "owner/repo#1" "Test bug" "2026-05-08T00:00:00Z"
    state_upsert_issue "owner/repo#1" '{"status":"in_progress","classification":"auto_fix"}'
    local issue
    issue="$(state_get_issue "owner/repo#1")"
    run jq -e '
        .status == "in_progress" and
        .classification == "auto_fix" and
        .first_seen == "2026-05-08T00:00:00Z"
    ' <<< "$issue"
    [ "$status" -eq 0 ]
}

@test "state_append_attempt adds to attempts array" {
    state_init_issue "owner/repo#1" "Test bug" "2026-05-08T00:00:00Z"
    state_append_attempt "owner/repo#1" \
        '{"timestamp":"2026-05-08T01:00:00Z","outcome":"success","feedback_summary":"","diff_stat":"1 file"}'
    local count
    count="$(state_get_issue "owner/repo#1" | jq '.attempts | length')"
    [ "$count" -eq 1 ]
}

@test "state_append_attempt accumulates multiple attempts" {
    state_init_issue "owner/repo#1" "Test bug" "2026-05-08T00:00:00Z"
    state_append_attempt "owner/repo#1" \
        '{"timestamp":"2026-05-08T01:00:00Z","outcome":"verification_failed","feedback_summary":"bad","diff_stat":""}'
    state_append_attempt "owner/repo#1" \
        '{"timestamp":"2026-05-08T02:00:00Z","outcome":"success","feedback_summary":"","diff_stat":"1 file"}'
    local count
    count="$(state_get_issue "owner/repo#1" | jq '.attempts | length')"
    [ "$count" -eq 2 ]
}

@test "state writes leave no .tmp file behind" {
    state_init_issue "owner/repo#1" "Test bug" "2026-05-08T00:00:00Z"
    [ ! -f "${FIXER_STATE_FILE}.tmp" ]
}
