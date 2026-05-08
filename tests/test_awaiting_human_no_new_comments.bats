#!/usr/bin/env bats

setup() {
    export FIXER_STATE_FILE
    FIXER_STATE_FILE="$(mktemp)"
    source "$BATS_TEST_DIRNAME/../lib/state.sh"
    state_init
    state_init_issue "owner/repo#1" "Test" "2026-05-08T00:00:00Z"
    state_upsert_issue "owner/repo#1" \
        '{"status":"awaiting_human","last_question_timestamp":"2026-05-08T12:00:00Z"}'
    # Stub gh: return empty comment array
    gh() { printf '[]\n'; }
    export -f gh
}

teardown() {
    rm -f "$FIXER_STATE_FILE"
}

@test "awaiting_human with no new comments → skip" {
    local rc=0
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body" || rc=$?
    [ "$rc" -eq 1 ]
    [[ "$FIXER_SKIP_REASON" == *"awaiting human"* ]]
    [ -z "$FIXER_AUGMENTED_BODY" ]
}
