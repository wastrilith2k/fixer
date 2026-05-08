#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../lib/classify.sh"
}

@test "AUTO_FIX verdict sets kind=AUTO_FIX and empty detail" {
    parse_classify_verdict "CLASSIFICATION: AUTO_FIX"
    [ "$CLASSIFY_KIND" = "AUTO_FIX" ]
    [ -z "$CLASSIFY_DETAIL" ]
}

@test "NEEDS_HUMAN em-dash extracts question" {
    parse_classify_verdict "CLASSIFICATION: NEEDS_HUMAN — What is the expected output?"
    [ "$CLASSIFY_KIND" = "NEEDS_HUMAN" ]
    [ "$CLASSIFY_DETAIL" = "What is the expected output?" ]
}

@test "NEEDS_HUMAN en-dash (model drift) also extracts question" {
    parse_classify_verdict "CLASSIFICATION: NEEDS_HUMAN – What is the expected output?"
    [ "$CLASSIFY_KIND" = "NEEDS_HUMAN" ]
    [ "$CLASSIFY_DETAIL" = "What is the expected output?" ]
}

@test "NEEDS_HUMAN hyphen also extracts question" {
    parse_classify_verdict "CLASSIFICATION: NEEDS_HUMAN - What is the expected output?"
    [ "$CLASSIFY_KIND" = "NEEDS_HUMAN" ]
    [ "$CLASSIFY_DETAIL" = "What is the expected output?" ]
}

@test "WONTFIX extracts reason" {
    parse_classify_verdict "CLASSIFICATION: WONTFIX — Duplicate of #42"
    [ "$CLASSIFY_KIND" = "WONTFIX" ]
    [ "$CLASSIFY_DETAIL" = "Duplicate of #42" ]
}

@test "classification line can appear after preamble" {
    parse_classify_verdict "Let me analyze this issue.

After review:
CLASSIFICATION: AUTO_FIX"
    [ "$CLASSIFY_KIND" = "AUTO_FIX" ]
}

@test "malformed verdict defaults to AUTO_FIX with warning on stderr" {
    run bash -c "source $BATS_TEST_DIRNAME/../lib/classify.sh; parse_classify_verdict 'no verdict here'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]] || [[ "$stderr" == *"WARN"* ]]
    # CLASSIFY_KIND must default to AUTO_FIX
    source "$BATS_TEST_DIRNAME/../lib/classify.sh"
    parse_classify_verdict "no verdict here" 2>/dev/null
    [ "$CLASSIFY_KIND" = "AUTO_FIX" ]
}

@test "empty output defaults to AUTO_FIX" {
    parse_classify_verdict "" 2>/dev/null
    [ "$CLASSIFY_KIND" = "AUTO_FIX" ]
}
