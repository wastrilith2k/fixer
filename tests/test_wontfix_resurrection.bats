#!/usr/bin/env bats

setup() {
    export FIXER_STATE_FILE
    FIXER_STATE_FILE="$(mktemp)"
    source "$BATS_TEST_DIRNAME/../lib/state.sh"
    state_init
    state_init_issue "owner/repo#1" "Test" "2026-05-08T00:00:00Z"
    state_upsert_issue "owner/repo#1" '{
        "status": "abandoned",
        "classification": "wontfix",
        "last_question_timestamp": "2026-05-08T12:00:00Z"
    }'
}

teardown() {
    rm -f "$FIXER_STATE_FILE"
}

@test "wontfix with no new comments → skip" {
    gh() { printf '[]\n'; }
    export -f gh
    local rc=0
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body" || rc=$?
    [ "$rc" -eq 1 ]
    [[ "$FIXER_SKIP_REASON" == *"no new context"* ]]
}

@test "wontfix with new human comment → process (resurrection)" {
    gh() {
        printf '[{"body":"Actually this IS a bug — repro: step 1, step 2.","created_at":"2026-05-09T00:00:00Z"}]\n'
    }
    export -f gh
    local rc=0
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body" || rc=$?
    [ "$rc" -eq 0 ]
}

@test "wontfix resurrection augments body with maintainer context" {
    gh() {
        printf '[{"body":"Additional repro info here.","created_at":"2026-05-09T00:00:00Z"}]\n'
    }
    export -f gh
    local rc=0
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body" || rc=$?
    [[ "$FIXER_AUGMENTED_BODY" == *"Additional context from maintainer"* ]]
    [[ "$FIXER_AUGMENTED_BODY" == *"Additional repro info here."* ]]
}

@test "wontfix resurrection: fixer-marker comment treated as no new context (gh filters it)" {
    # Simulate gh api --jq having filtered out the fixer-marker comment
    gh() { printf '[]\n'; }
    export -f gh
    local rc=0
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body" || rc=$?
    [ "$rc" -eq 1 ]
    [[ "$FIXER_SKIP_REASON" == *"no new context"* ]]
}
