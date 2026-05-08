#!/usr/bin/env bats

setup() {
    export FIXER_STATE_FILE
    FIXER_STATE_FILE="$(mktemp)"
    source "$BATS_TEST_DIRNAME/../lib/state.sh"
    state_init
    state_init_issue "owner/repo#1" "Test" "2026-05-08T00:00:00Z"
    state_upsert_issue "owner/repo#1" \
        '{"status":"awaiting_human","last_question_timestamp":"2026-05-08T12:00:00Z"}'
    # Stub gh: return one non-fixer comment
    gh() {
        printf '[{"body":"The bug occurs when X is true.","created_at":"2026-05-08T13:00:00Z"}]\n'
    }
    export -f gh
}

teardown() {
    rm -f "$FIXER_STATE_FILE"
}

@test "awaiting_human with new comment → process" {
    local rc=0
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body" || rc=$?
    [ "$rc" -eq 0 ]
}

@test "awaiting_human with new comment → augmented body contains new context" {
    local rc=0
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body" || rc=$?
    [[ "$FIXER_AUGMENTED_BODY" == *"Additional context from maintainer"* ]]
    [[ "$FIXER_AUGMENTED_BODY" == *"The bug occurs when X is true."* ]]
}

@test "awaiting_human with new comment → original body preserved" {
    local rc=0
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body" || rc=$?
    [[ "$FIXER_AUGMENTED_BODY" == "original body"* ]]
}
