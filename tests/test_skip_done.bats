#!/usr/bin/env bats

setup() {
    export FIXER_STATE_FILE
    FIXER_STATE_FILE="$(mktemp)"
    source "$BATS_TEST_DIRNAME/../lib/state.sh"
    state_init
    # Stub gh — should never be called for done/auto_fix-abandoned issues
    gh() { printf 'UNEXPECTED gh call: %s\n' "$*" >&2; return 1; }
    export -f gh
}

teardown() {
    rm -f "$FIXER_STATE_FILE"
}

@test "no state → process" {
    local rc=0
    issue_get_action "owner/repo#1" "owner" "repo" "1" "body" || rc=$?
    [ "$rc" -eq 0 ]
    [ -z "$FIXER_SKIP_REASON" ]
}

@test "status=done → skip" {
    state_init_issue "owner/repo#1" "Test" "2026-05-08T00:00:00Z"
    state_upsert_issue "owner/repo#1" '{"status":"done"}'
    local rc=0
    issue_get_action "owner/repo#1" "owner" "repo" "1" "body" || rc=$?
    [ "$rc" -eq 1 ]
    [[ "$FIXER_SKIP_REASON" == *"done"* ]]
}

@test "status=in_progress → process (re-entry after crash)" {
    state_init_issue "owner/repo#1" "Test" "2026-05-08T00:00:00Z"
    state_upsert_issue "owner/repo#1" '{"status":"in_progress"}'
    local rc=0
    issue_get_action "owner/repo#1" "owner" "repo" "1" "body" || rc=$?
    [ "$rc" -eq 0 ]
}

@test "status=abandoned, classification=auto_fix → skip (max retries)" {
    state_init_issue "owner/repo#1" "Test" "2026-05-08T00:00:00Z"
    state_upsert_issue "owner/repo#1" '{"status":"abandoned","classification":"auto_fix"}'
    local rc=0
    issue_get_action "owner/repo#1" "owner" "repo" "1" "body" || rc=$?
    [ "$rc" -eq 1 ]
    [[ "$FIXER_SKIP_REASON" == *"max retries"* ]]
}
