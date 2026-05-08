# Ralph Harness Patterns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent state, classify-before-fix, halt-and-feedback, and acceptance-criteria threading to fixer in one PR.

**Architecture:** Two new `lib/` files (`state.sh`, `classify.sh`) are sourced by `fixer.sh`. The per-issue loop gains a state machine that runs before any git work: load state, decide to skip/resume/process, classify the issue, then route to NEEDS_HUMAN halt, WONTFIX abandon, or the existing AUTO_FIX retry loop. A `## Verification` section in issue bodies seeds `{{VERIFICATION_CRITERIA}}` threaded into fix and review prompts. Six bats files cover the state machine and verdict parser.

**Tech Stack:** bash, jq (already required), gh CLI (already required), bats-core (dev-only test runner)

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `lib/state.sh` | State file CRUD, comment fetching, skip/resume decision |
| Create | `lib/classify.sh` | Classify verdict parser |
| Create | `prompts/classify.txt` | Classify agent prompt template |
| Create | `tests/test_state_roundtrip.bats` | State file read/write |
| Create | `tests/test_skip_done.bats` | Skip logic for done/abandoned-auto_fix |
| Create | `tests/test_awaiting_human_no_new_comments.bats` | Skip when no new comments |
| Create | `tests/test_awaiting_human_resumes_on_comment.bats` | Resume on new comment |
| Create | `tests/test_wontfix_resurrection.bats` | Wontfix resurrection |
| Create | `tests/test_classify_parsing.bats` | Verdict-line parser |
| Modify | `fixer.sh` | Source libs; wire state machine, classify, labels, criteria |
| Modify | `prompts/fix.txt` | Add `{{VERIFICATION_CRITERIA}}` block |
| Modify | `prompts/review.txt` | Add item 14 + `{{VERIFICATION_CRITERIA}}` block |
| Modify | `prompts/test.txt` | Add `{{VERIFICATION_CRITERIA}}` block |
| Modify | `README.md` | Document all new features |

---

## Task 1: lib/state.sh — state CRUD + skip/resume decision

**Files:**
- Create: `lib/state.sh`
- Create: `tests/test_state_roundtrip.bats`

- [ ] **Step 1.1: Install bats-core if not present**

```bash
if ! command -v bats &>/dev/null; then
    # macOS
    brew install bats-core 2>/dev/null || \
    # Debian/Ubuntu/WSL
    sudo apt-get install -y bats 2>/dev/null || \
    # Manual (any platform)
    git clone https://github.com/bats-core/bats-core.git /tmp/bats-core && \
    sudo /tmp/bats-core/install.sh /usr/local
fi
bats --version
```

Expected: `Bats 1.x.x`

- [ ] **Step 1.2: Write the failing bats test**

Create `tests/test_state_roundtrip.bats`:

```bash
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
```

- [ ] **Step 1.3: Run test to confirm it fails**

```bash
cd ~/projs/fixer
bats tests/test_state_roundtrip.bats
```

Expected: `command not found: state_init` (or similar — lib/state.sh does not exist yet)

- [ ] **Step 1.4: Create lib/state.sh**

```bash
mkdir -p ~/projs/fixer/lib
```

Create `lib/state.sh`:

```bash
#!/usr/bin/env bash
# lib/state.sh — Persistent issue state for fixer.
# Sourced by fixer.sh. Requires: jq.
# FIXER_STATE_FILE env var overrides the default path.

FIXER_STATE_FILE="${FIXER_STATE_FILE:-$HOME/.fixer/state.json}"

state_init() {
    local dir
    dir="$(dirname "$FIXER_STATE_FILE")"
    mkdir -p "$dir"
    if [[ ! -f "$FIXER_STATE_FILE" ]]; then
        printf '{"version":1,"schema_version":1,"issues":{}}\n' > "$FIXER_STATE_FILE"
    fi
}

state_get_issue() {
    local id="$1"
    jq -r --arg id "$id" '.issues[$id] // "null"' "$FIXER_STATE_FILE"
}

# Create the issue record if it doesn't exist. No-op if it already exists.
state_init_issue() {
    local id="$1" title="$2" now="$3"
    local tmp="${FIXER_STATE_FILE}.tmp"
    jq --arg id "$id" --arg title "$title" --arg now "$now" \
        'if .issues[$id] then . else
         .issues[$id] = {
           id: $id, title: $title,
           classification: null, status: "queued",
           attempts: [],
           last_question: null, last_question_timestamp: null,
           first_seen: $now, last_run: null
         } end' \
        "$FIXER_STATE_FILE" > "$tmp" && mv -f "$tmp" "$FIXER_STATE_FILE"
}

# Merge the given JSON object into the issue record.
state_upsert_issue() {
    local id="$1" updates="$2"
    local tmp="${FIXER_STATE_FILE}.tmp"
    jq --arg id "$id" --argjson u "$updates" \
        '.issues[$id] += $u' \
        "$FIXER_STATE_FILE" > "$tmp" && mv -f "$tmp" "$FIXER_STATE_FILE"
}

# Append a single attempt JSON object to issues[id].attempts[].
state_append_attempt() {
    local id="$1" attempt="$2"
    local tmp="${FIXER_STATE_FILE}.tmp"
    jq --arg id "$id" --argjson a "$attempt" \
        '.issues[$id].attempts += [$a]' \
        "$FIXER_STATE_FILE" > "$tmp" && mv -f "$tmp" "$FIXER_STATE_FILE"
}

# Returns the non-fixer comments posted after since_ts on this issue.
# Output: JSON array (may be empty). Filters out fixer-marker comments.
fetch_new_human_comments() {
    local owner="$1" repo="$2" issue_num="$3" since_ts="$4"
    gh api "repos/$owner/$repo/issues/$issue_num/comments?since=$since_ts" \
        --jq '[.[] | select(.body | test("<!-- fixer:state-comment -->|Generated by \\[fixer\\]") | not)]'
}

# ── Skip/resume decision ─────────────────────────────────────────────────────
# Globals set by issue_get_action:
FIXER_SKIP_REASON=""    # set on skip
FIXER_AUGMENTED_BODY="" # set when body should be augmented with new comments

# Evaluate whether to process or skip an issue based on its current state.
# Returns 0 (process) or 1 (skip).
# On augmented-process, sets FIXER_AUGMENTED_BODY.
# On skip, sets FIXER_SKIP_REASON.
issue_get_action() {
    local id="$1" owner="$2" repo="$3" issue_num="$4" original_body="$5"
    FIXER_SKIP_REASON=""
    FIXER_AUGMENTED_BODY=""

    local issue
    issue="$(state_get_issue "$id")"
    [[ "$issue" == "null" ]] && return 0   # no prior state → process

    local status classification ts
    status="$(printf '%s' "$issue" | jq -r '.status')"
    classification="$(printf '%s' "$issue" | jq -r '.classification // ""')"

    case "$status" in
        done)
            FIXER_SKIP_REASON="already done"
            return 1 ;;

        abandoned)
            if [[ "$classification" == "wontfix" ]]; then
                ts="$(printf '%s' "$issue" | jq -r '.last_question_timestamp // ""')"
                if _fixer_augment_body "$owner" "$repo" "$issue_num" "$ts" "$original_body"; then
                    return 0   # wontfix resurrection
                fi
                FIXER_SKIP_REASON="wontfix — no new context since $ts"
                return 1
            fi
            FIXER_SKIP_REASON="max retries exhausted"
            return 1 ;;

        awaiting_human)
            ts="$(printf '%s' "$issue" | jq -r '.last_question_timestamp // ""')"
            if _fixer_augment_body "$owner" "$repo" "$issue_num" "$ts" "$original_body"; then
                return 0   # resume
            fi
            FIXER_SKIP_REASON="awaiting human input since $ts"
            return 1 ;;

        *)
            return 0 ;;
    esac
}

# Internal: fetch new human comments and set FIXER_AUGMENTED_BODY.
# Returns 0 if new comments found, 1 if none.
_fixer_augment_body() {
    local owner="$1" repo="$2" issue_num="$3" since_ts="$4" original_body="$5"
    local new_comments count
    new_comments="$(fetch_new_human_comments "$owner" "$repo" "$issue_num" "$since_ts")"
    count="$(printf '%s' "$new_comments" | jq 'length')"
    [[ "$count" -eq 0 ]] && return 1
    local extra
    extra="$(printf '%s' "$new_comments" | jq -r 'map(.body) | join("\n\n")')"
    FIXER_AUGMENTED_BODY="${original_body}"$'\n\n'"## Additional context from maintainer"$'\n'"${extra}"
    return 0
}
```

- [ ] **Step 1.5: Run tests and confirm pass**

```bash
bats tests/test_state_roundtrip.bats
```

Expected: `7 tests, 0 failures`

- [ ] **Step 1.6: Commit**

```bash
git add lib/state.sh tests/test_state_roundtrip.bats
git commit -m "feat(state): add lib/state.sh with CRUD and skip/resume decision"
```

---

## Task 2: Skip/resume bats tests

**Files:**
- Create: `tests/test_skip_done.bats`
- Create: `tests/test_awaiting_human_no_new_comments.bats`
- Create: `tests/test_awaiting_human_resumes_on_comment.bats`
- Create: `tests/test_wontfix_resurrection.bats`

- [ ] **Step 2.1: Write test_skip_done.bats**

```bash
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
    issue_get_action "owner/repo#1" "owner" "repo" "1" "body"
    [ "$?" -eq 0 ]
    [ -z "$FIXER_SKIP_REASON" ]
}

@test "status=done → skip" {
    state_init_issue "owner/repo#1" "Test" "2026-05-08T00:00:00Z"
    state_upsert_issue "owner/repo#1" '{"status":"done"}'
    issue_get_action "owner/repo#1" "owner" "repo" "1" "body"
    [ "$?" -eq 1 ]
    [[ "$FIXER_SKIP_REASON" == *"done"* ]]
}

@test "status=in_progress → process (re-entry after crash)" {
    state_init_issue "owner/repo#1" "Test" "2026-05-08T00:00:00Z"
    state_upsert_issue "owner/repo#1" '{"status":"in_progress"}'
    issue_get_action "owner/repo#1" "owner" "repo" "1" "body"
    [ "$?" -eq 0 ]
}

@test "status=abandoned, classification=auto_fix → skip (max retries)" {
    state_init_issue "owner/repo#1" "Test" "2026-05-08T00:00:00Z"
    state_upsert_issue "owner/repo#1" '{"status":"abandoned","classification":"auto_fix"}'
    issue_get_action "owner/repo#1" "owner" "repo" "1" "body"
    [ "$?" -eq 1 ]
    [[ "$FIXER_SKIP_REASON" == *"max retries"* ]]
}
```

- [ ] **Step 2.2: Write test_awaiting_human_no_new_comments.bats**

```bash
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
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body"
    [ "$?" -eq 1 ]
    [[ "$FIXER_SKIP_REASON" == *"awaiting human"* ]]
    [ -z "$FIXER_AUGMENTED_BODY" ]
}
```

- [ ] **Step 2.3: Write test_awaiting_human_resumes_on_comment.bats**

```bash
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
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body"
    [ "$?" -eq 0 ]
}

@test "awaiting_human with new comment → augmented body contains new context" {
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body"
    [[ "$FIXER_AUGMENTED_BODY" == *"Additional context from maintainer"* ]]
    [[ "$FIXER_AUGMENTED_BODY" == *"The bug occurs when X is true."* ]]
}

@test "awaiting_human with new comment → original body preserved" {
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body"
    [[ "$FIXER_AUGMENTED_BODY" == "original body"* ]]
}
```

- [ ] **Step 2.4: Write test_wontfix_resurrection.bats**

```bash
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
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body"
    [ "$?" -eq 1 ]
    [[ "$FIXER_SKIP_REASON" == *"no new context"* ]]
}

@test "wontfix with new human comment → process (resurrection)" {
    gh() {
        printf '[{"body":"Actually this IS a bug — repro: step 1, step 2.","created_at":"2026-05-09T00:00:00Z"}]\n'
    }
    export -f gh
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body"
    [ "$?" -eq 0 ]
}

@test "wontfix resurrection augments body with maintainer context" {
    gh() {
        printf '[{"body":"Additional repro info here.","created_at":"2026-05-09T00:00:00Z"}]\n'
    }
    export -f gh
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body"
    [[ "$FIXER_AUGMENTED_BODY" == *"Additional context from maintainer"* ]]
    [[ "$FIXER_AUGMENTED_BODY" == *"Additional repro info here."* ]]
}

@test "wontfix resurrection: fixer-marker comment treated as no new context (gh filters it)" {
    # Simulate gh api --jq having filtered out the fixer-marker comment
    gh() { printf '[]\n'; }
    export -f gh
    issue_get_action "owner/repo#1" "owner" "repo" "1" "original body"
    [ "$?" -eq 1 ]
    [[ "$FIXER_SKIP_REASON" == *"no new context"* ]]
}
```

- [ ] **Step 2.5: Run all four test files**

```bash
bats tests/test_skip_done.bats \
     tests/test_awaiting_human_no_new_comments.bats \
     tests/test_awaiting_human_resumes_on_comment.bats \
     tests/test_wontfix_resurrection.bats
```

Expected: all pass (the functions are already in lib/state.sh from Task 1)

- [ ] **Step 2.6: Commit**

```bash
git add tests/test_skip_done.bats \
        tests/test_awaiting_human_no_new_comments.bats \
        tests/test_awaiting_human_resumes_on_comment.bats \
        tests/test_wontfix_resurrection.bats
git commit -m "test(state): add skip/resume bats tests for all state transitions"
```

---

## Task 3: lib/classify.sh — verdict parser + tests

**Files:**
- Create: `lib/classify.sh`
- Create: `tests/test_classify_parsing.bats`

- [ ] **Step 3.1: Write the failing test**

Create `tests/test_classify_parsing.bats`:

```bash
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
```

- [ ] **Step 3.2: Run test to confirm it fails**

```bash
bats tests/test_classify_parsing.bats
```

Expected: `command not found: parse_classify_verdict`

- [ ] **Step 3.3: Create lib/classify.sh**

```bash
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
```

- [ ] **Step 3.4: Run tests**

```bash
bats tests/test_classify_parsing.bats
```

Expected: `8 tests, 0 failures`

- [ ] **Step 3.5: Commit**

```bash
git add lib/classify.sh tests/test_classify_parsing.bats
git commit -m "feat(classify): add lib/classify.sh verdict parser with portability fixes"
```

---

## Task 4: prompts/classify.txt

**Files:**
- Create: `prompts/classify.txt`

- [ ] **Step 4.1: Write prompts/classify.txt**

```
You are a classification agent for a bug-fixing system. Your only job is to
classify one GitHub issue into one of three categories. Do not suggest fixes.

## Output Format

End your response with EXACTLY ONE of these lines (no other text after it):

CLASSIFICATION: AUTO_FIX
CLASSIFICATION: NEEDS_HUMAN — <specific question for the human>
CLASSIFICATION: WONTFIX — <reason>

## Classify NEEDS_HUMAN when the issue:

- Lacks reproducible steps AND the bug is not obvious from the description alone
- Describes a design decision or feature request rather than a concrete bug
- Requires runtime data (logs, metrics, production database state) not present in the repo
- Mentions credentials, secrets, or production data needing rotation or inspection
- Is itself a clarifying question rather than a bug report
- Would require touching more than 15 files to fix (estimate with grep before deciding)

For NEEDS_HUMAN, the question MUST be specific enough that the human can answer it
without guessing what you need. "Can you provide more details?" is not acceptable.
"What is the exact error message when X happens?" is acceptable.

## Classify WONTFIX when the issue:

- Is already resolved in spirit by a recent commit (check git log for references to this issue)
- Describes behavior that is working as designed per the project's convention files
  (CLAUDE.md, .cursorrules, AGENTS.md, CONTRIBUTING.md)
- Is a duplicate ("same as #N" or "duplicate of #N" appears in the body)

## Otherwise: AUTO_FIX

If the issue describes a clear, reproducible bug that can be fixed by editing
files in the repository, classify it as AUTO_FIX.

When in doubt, prefer AUTO_FIX over NEEDS_HUMAN. Only classify as NEEDS_HUMAN
when you genuinely cannot form a coherent fix plan from the available information.

## Codebase Context

{{CODEBASE_CONTEXT}}

## Issue to Classify

ISSUE_NUMBER: {{ISSUE_NUMBER}}
ISSUE_TITLE: {{ISSUE_TITLE}}

ISSUE_BODY:
{{ISSUE_BODY}}
```

- [ ] **Step 4.2: Commit**

```bash
git add prompts/classify.txt
git commit -m "feat(classify): add classify agent prompt template"
```

---

## Task 5: fixer.sh — source libs, state_init, per-issue state machine

**Files:**
- Modify: `fixer.sh`

This task wires the state machine into the per-issue loop. No classify call yet — that's Task 7.

- [ ] **Step 5.1: Source libs and initialise state at script startup**

In `fixer.sh`, find the block (around line 36) where `SCRIPT_DIR` is set and `REPOS_ROOT` etc. are defined. Add after the env var defaults block (after line 53, before the logging functions):

```bash
# Source lib modules
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/classify.sh
source "$SCRIPT_DIR/lib/classify.sh"
```

Then find the dependency check block (around line 164-169):
```bash
for cmd in gh claude git jq curl; do
```

Add after the `done` that closes the dependency check:
```bash
# Initialise persistent state file
state_init
log "State file: $FIXER_STATE_FILE"
```

- [ ] **Step 5.2: Add FIXER_STATE_FILE to the env var block**

In `fixer.sh`, after line `FIXER_LOG="${FIXER_LOG:-/tmp/fixer-..."`:

```bash
FIXER_STATE_FILE="${FIXER_STATE_FILE:-$HOME/.fixer/state.json}"
export FIXER_STATE_FILE
```

(The `export` lets bats tests set it from the environment without re-sourcing.)

- [ ] **Step 5.3: Add state init and skip/resume at the start of the per-issue loop**

Find the beginning of the `for i in $(seq ...)` per-issue loop (around line 427). The loop currently extracts `ISSUE_NUMBER`, `ISSUE_TITLE`, `ISSUE_BODY`, `BRANCH_NAME` and then does `cd "$REPO_DIR"`. Insert the following block AFTER those four variables are set and BEFORE `cd "$REPO_DIR"`:

```bash
    ISSUE_ID="${REPO}#${ISSUE_NUMBER}"
    NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # --- State: create record if absent; skip or resume based on current status ---
    state_init_issue "$ISSUE_ID" "$ISSUE_TITLE" "$NOW"

    if ! issue_get_action "$ISSUE_ID" "$OWNER" "$NAME" "$ISSUE_NUMBER" "$ISSUE_BODY"; then
        log "Skipping #${ISSUE_NUMBER} (${ISSUE_TITLE}): $FIXER_SKIP_REASON"
        RESULTS+=("#${ISSUE_NUMBER}: SKIP — $FIXER_SKIP_REASON")
        continue
    fi

    # Augment body with new human comments when resuming from awaiting_human or wontfix
    if [[ -n "$FIXER_AUGMENTED_BODY" ]]; then
        ISSUE_BODY="$FIXER_AUGMENTED_BODY"
    fi

    # Read current state once so we can check both status and classification
    # before overwriting them (used for label cleanup and wontfix resurrection detection)
    _ISSUE_BEFORE="$(state_get_issue "$ISSUE_ID")"
    PREV_STATUS="$(printf '%s' "$_ISSUE_BEFORE" | jq -r '.status')"
    PREV_CLASSIFICATION="$(printf '%s' "$_ISSUE_BEFORE" | jq -r '.classification // ""')"

    # Transition to in_progress
    state_upsert_issue "$ISSUE_ID" \
        "$(jq -n --arg t "$NOW" '{status:"in_progress",last_run:$t}')"
```

- [ ] **Step 5.4: Run fixer.sh sanity check (no issue numbers — just sees "no issues")**

```bash
# Dry-run: if the repo has no "bug" issues this just exits cleanly
cd ~/projs/fixer
bash -n fixer.sh   # syntax check only — no network calls
```

Expected: no syntax errors printed.

- [ ] **Step 5.5: Commit**

```bash
git add fixer.sh
git commit -m "feat(fixer): wire state machine into per-issue loop (state init + skip/resume)"
```

---

## Task 6: fixer.sh — ensure_labels and in-progress label lifecycle

**Files:**
- Modify: `fixer.sh`

- [ ] **Step 6.1: Add ensure_labels helper to fixer.sh**

Add this function to `fixer.sh` after the `extract_verdict` helper (around line 325):

```bash
# -----------------------------------------------------------------------------
# Helper: create fixer labels on the target repo if they don't already exist.
# Idempotent — gh label create exits non-zero if label exists; we ignore that.
# -----------------------------------------------------------------------------
ensure_labels() {
    local owner="$1" repo="$2"
    gh label create "fixer:in-progress"    --color "0075CA" \
        --description "Fixer is actively working on this issue" \
        -R "$owner/$repo" 2>/dev/null || true
    gh label create "fixer:awaiting-human" --color "FBCA04" \
        --description "Fixer needs more information from the maintainer" \
        -R "$owner/$repo" 2>/dev/null || true
    gh label create "fixer:wontfix"        --color "808080" \
        --description "Fixer determined this issue should not be auto-fixed" \
        -R "$owner/$repo" 2>/dev/null || true
}
```

- [ ] **Step 6.2: Call ensure_labels, apply fixer:in-progress, and handle wontfix resurrection label**

Immediately after the `state_upsert_issue` call from Task 5, add:

```bash
    # Ensure fixer labels exist on the target repo (idempotent)
    ensure_labels "$OWNER" "$NAME"
    gh issue edit "$ISSUE_NUMBER" -R "$REPO" --add-label "fixer:in-progress" 2>/dev/null || true

    # Wontfix resurrection: remove the fixer:wontfix label so it doesn't persist
    if [[ "$PREV_STATUS" == "abandoned" && "$PREV_CLASSIFICATION" == "wontfix" ]]; then
        gh issue edit "$ISSUE_NUMBER" -R "$REPO" --remove-label "fixer:wontfix" 2>/dev/null || true
    fi
```

- [ ] **Step 6.3: Remove fixer:in-progress on the done path**

Find the `if $ISSUE_RESOLVED; then` block (near line 529). After the `PR_URL=...` assignment and `ok "PR created: ..."`, add:

```bash
        gh issue edit "$ISSUE_NUMBER" -R "$REPO" --remove-label "fixer:in-progress" 2>/dev/null || true
```

Place it right before the `ok "Commenting on issue #..."` line.

- [ ] **Step 6.4: Remove fixer:in-progress on the abandoned path**

In the `else` branch (after `err "Issue #${ISSUE_NUMBER}: FAILED after $MAX_RETRIES attempts"`), after the failure comment is posted, add:

```bash
        gh issue edit "$ISSUE_NUMBER" -R "$REPO" --remove-label "fixer:in-progress" 2>/dev/null || true
```

- [ ] **Step 6.5: Syntax check**

```bash
bash -n fixer.sh
```

- [ ] **Step 6.6: Commit**

```bash
git add fixer.sh
git commit -m "feat(fixer): add ensure_labels and fixer:in-progress label lifecycle"
```

---

## Task 7: fixer.sh — run classify + NEEDS_HUMAN + WONTFIX paths

**Files:**
- Modify: `fixer.sh`

- [ ] **Step 7.1: Add parse_verification_criteria helper**

Add after `ensure_labels` (after Task 6's addition):

```bash
# -----------------------------------------------------------------------------
# Helper: extract acceptance criteria from a "## Verification" section in the
# issue body. Returns a string ready to be substituted into prompts.
# -----------------------------------------------------------------------------
parse_verification_criteria() {
    local body="$1"
    local criteria
    criteria="$(printf '%s\n' "$body" \
        | awk '/^## Verification/{found=1; next} found && /^## /{exit} found{print}')"
    if [[ -z "$(printf '%s' "$criteria" | tr -d '[:space:]')" ]]; then
        printf '%s' "(none specified — use general code quality standards)"
    else
        printf '%s' "$criteria"
    fi
}
```

- [ ] **Step 7.2: Add post_needs_human_comment helper**

Add after `parse_verification_criteria`:

```bash
# Post a NEEDS_HUMAN comment on the issue and apply the awaiting-human label.
post_needs_human_comment() {
    local issue_number="$1" question="$2" ts="$3"
    local body
    body="$(cat <<COMMENT_EOF
## Fixer needs more information

${question}

Reply to this issue with the details above and Fixer will retry on its
next run.

<!-- fixer:state-comment -->
<!-- fixer:status=awaiting_human -->
<!-- fixer:question_timestamp=${ts} -->
COMMENT_EOF
)"
    gh issue comment "$issue_number" -R "$REPO" --body "$body" 2>/dev/null \
        && ok "  Posted NEEDS_HUMAN question on issue #${issue_number}" \
        || warn "  Could not post NEEDS_HUMAN comment on issue #${issue_number}"
}
```

- [ ] **Step 7.3: Add post_wontfix_comment helper**

Add after `post_needs_human_comment`:

```bash
# Post a WONTFIX comment and apply the wontfix label.
post_wontfix_comment() {
    local issue_number="$1" reason="$2" ts="$3"
    local body
    body="$(cat <<COMMENT_EOF
## Fixer won't attempt this issue

${reason}

This issue has been labeled \`fixer:wontfix\` and won't be retried automatically. If you disagree, remove the label and reply with additional context — Fixer will re-classify on the next run.

<!-- fixer:state-comment -->
<!-- fixer:status=abandoned -->
<!-- fixer:question_timestamp=${ts} -->
COMMENT_EOF
)"
    gh issue comment "$issue_number" -R "$REPO" --body "$body" 2>/dev/null \
        && ok "  Posted WONTFIX comment on issue #${issue_number}" \
        || warn "  Could not post WONTFIX comment on issue #${issue_number}"
}
```

- [ ] **Step 7.4: Wire classify into fixer.sh — after gather_codebase_context and before the retry loop**

Find the `gather_codebase_context` call (around line 457):
```bash
    log "  Gathering codebase context..."
    CODEBASE_CONTEXT="$(gather_codebase_context "$REPO_DIR")"
```

Add immediately after it:

```bash
    # --- Parse acceptance criteria from issue body ---
    VERIFICATION_CRITERIA="$(parse_verification_criteria "$ISSUE_BODY")"

    # --- Classify (single call, not retried) ---
    log "  Running classify agent..."
    CLASSIFY_PROMPT="$(render_prompt "$SCRIPT_DIR/prompts/classify.txt" \
        "ISSUE_NUMBER=$ISSUE_NUMBER" \
        "ISSUE_TITLE=$ISSUE_TITLE" \
        "ISSUE_BODY=$ISSUE_BODY" \
        "CODEBASE_CONTEXT=$CODEBASE_CONTEXT")"
    CLASSIFY_OUTPUT_FILE="$TMPDIR/classify-${ISSUE_NUMBER}.txt"
    echo "$CLASSIFY_PROMPT" | claude -p $CLAUDE_PERM > "$CLASSIFY_OUTPUT_FILE" 2>&1 \
        || warn "  Classify agent exited non-zero; will parse output anyway"
    CLASSIFY_RAW="$(cat "$CLASSIFY_OUTPUT_FILE")"
    parse_classify_verdict "$CLASSIFY_RAW"
    log "  Classification: $CLASSIFY_KIND${CLASSIFY_DETAIL:+ — $CLASSIFY_DETAIL}"

    # Store classification (lowercase for schema)
    CLASSIFY_KIND_LOWER="$(printf '%s' "$CLASSIFY_KIND" | tr '[:upper:]' '[:lower:]')"
    state_upsert_issue "$ISSUE_ID" \
        "$(jq -n --arg c "$CLASSIFY_KIND_LOWER" '{classification:$c}')"

    if [[ "$CLASSIFY_KIND" == "NEEDS_HUMAN" ]]; then
        post_needs_human_comment "$ISSUE_NUMBER" "$CLASSIFY_DETAIL" "$NOW"
        gh issue edit "$ISSUE_NUMBER" -R "$REPO" \
            --add-label "fixer:awaiting-human" \
            --remove-label "fixer:in-progress" 2>/dev/null || true
        state_upsert_issue "$ISSUE_ID" "$(jq -n \
            --arg q "$CLASSIFY_DETAIL" --arg t "$NOW" \
            '{status:"awaiting_human",last_question:$q,last_question_timestamp:$t}')"
        state_append_attempt "$ISSUE_ID" "$(jq -n \
            --arg t "$NOW" --arg s "NEEDS_HUMAN: $CLASSIFY_DETAIL" \
            '{timestamp:$t,outcome:"classify_halted",
              feedback_summary:($s|.[0:500]),diff_stat:""}')"
        RESULTS+=("#${ISSUE_NUMBER}: NEEDS_HUMAN — question posted")
        git checkout "$DEFAULT_BRANCH" 2>/dev/null
        continue
    fi

    if [[ "$CLASSIFY_KIND" == "WONTFIX" ]]; then
        post_wontfix_comment "$ISSUE_NUMBER" "$CLASSIFY_DETAIL" "$NOW"
        gh issue edit "$ISSUE_NUMBER" -R "$REPO" \
            --add-label "fixer:wontfix" \
            --remove-label "fixer:in-progress" \
            --remove-label "fixer:awaiting-human" 2>/dev/null || true
        state_upsert_issue "$ISSUE_ID" "$(jq -n \
            --arg t "$NOW" '{status:"abandoned",last_question_timestamp:$t}')"
        state_append_attempt "$ISSUE_ID" "$(jq -n \
            --arg t "$NOW" --arg s "WONTFIX: $CLASSIFY_DETAIL" \
            '{timestamp:$t,outcome:"classify_halted",
              feedback_summary:($s|.[0:500]),diff_stat:""}')"
        RESULTS+=("#${ISSUE_NUMBER}: WONTFIX — abandoned")
        git checkout "$DEFAULT_BRANCH" 2>/dev/null
        continue
    fi

    # AUTO_FIX path: remove awaiting-human label if resuming
    if [[ "$PREV_STATUS" == "awaiting_human" ]]; then
        gh issue edit "$ISSUE_NUMBER" -R "$REPO" \
            --remove-label "fixer:awaiting-human" 2>/dev/null || true
    fi
```

- [ ] **Step 7.5: Syntax check**

```bash
bash -n fixer.sh
```

- [ ] **Step 7.6: Commit**

```bash
git add fixer.sh
git commit -m "feat(fixer): add classify integration, NEEDS_HUMAN halt, WONTFIX abandon"
```

---

## Task 8: Thread VERIFICATION_CRITERIA into prompts

**Files:**
- Modify: `prompts/fix.txt`
- Modify: `prompts/review.txt`
- Modify: `prompts/test.txt`
- Modify: `fixer.sh`

- [ ] **Step 8.1: Update prompts/fix.txt — add VERIFICATION_CRITERIA block**

After the `## Rules` section (after the `### Feedback` block), add:

```
## Acceptance Criteria (if any)

Your fix MUST satisfy each of these criteria. The review agent will check
them explicitly. If no criteria are listed below, apply general code quality
standards instead.

{{VERIFICATION_CRITERIA}}
```

- [ ] **Step 8.2: Update prompts/review.txt — add item 14 and VERIFICATION_CRITERIA block**

After item 13 (`13. **Thread safety**...`), add:

```
14. **Acceptance criteria**: If criteria are listed in the section below,
    explicitly verify each one. Failing any single criterion is an automatic
    VERDICT: FAIL — name the specific criterion that failed.
```

At the very end of `review.txt` (after `{{DIFF}}`), add:

```
## Acceptance Criteria (if any)

{{VERIFICATION_CRITERIA}}
```

- [ ] **Step 8.3: Update prompts/test.txt — add VERIFICATION_CRITERIA block**

At the end of `test.txt` (after the `## Issue Context` section), add:

```
## Acceptance Criteria (if any)

If criteria are listed below, ensure the test suite validates each one.
Report any criterion not covered by tests as a FAIL.

{{VERIFICATION_CRITERIA}}
```

- [ ] **Step 8.4: Wire VERIFICATION_CRITERIA into render_prompt calls in fixer.sh**

Find the fix prompt render_prompt call in the retry loop:

```bash
        FIX_PROMPT="$(render_prompt "$SCRIPT_DIR/prompts/fix.txt" \
            "ISSUE_NUMBER=$ISSUE_NUMBER" \
            "ISSUE_TITLE=$ISSUE_TITLE" \
            "ISSUE_BODY=$ISSUE_BODY" \
            "CODEBASE_CONTEXT=$CODEBASE_CONTEXT")"
```

Add `"VERIFICATION_CRITERIA=$VERIFICATION_CRITERIA"` as the last argument:

```bash
        FIX_PROMPT="$(render_prompt "$SCRIPT_DIR/prompts/fix.txt" \
            "ISSUE_NUMBER=$ISSUE_NUMBER" \
            "ISSUE_TITLE=$ISSUE_TITLE" \
            "ISSUE_BODY=$ISSUE_BODY" \
            "CODEBASE_CONTEXT=$CODEBASE_CONTEXT" \
            "VERIFICATION_CRITERIA=$VERIFICATION_CRITERIA")"
```

Find the review_prompt render call:

```bash
    review_prompt="$(render_prompt "$SCRIPT_DIR/prompts/review.txt" \
        "ISSUE_NUMBER=$issue_number" \
        "ISSUE_TITLE=$issue_title" \
        "ISSUE_BODY=$issue_body" \
        "CODEBASE_CONTEXT=$CODEBASE_CONTEXT" \
        "DIFF=$diff")"
```

Add `"VERIFICATION_CRITERIA=$VERIFICATION_CRITERIA"` before `"DIFF=$diff"`:

```bash
    review_prompt="$(render_prompt "$SCRIPT_DIR/prompts/review.txt" \
        "ISSUE_NUMBER=$issue_number" \
        "ISSUE_TITLE=$issue_title" \
        "ISSUE_BODY=$issue_body" \
        "CODEBASE_CONTEXT=$CODEBASE_CONTEXT" \
        "VERIFICATION_CRITERIA=$VERIFICATION_CRITERIA" \
        "DIFF=$diff")"
```

Find the test_prompt render call:

```bash
    test_prompt="$(render_prompt "$SCRIPT_DIR/prompts/test.txt" \
        "ISSUE_NUMBER=$issue_number" \
        "ISSUE_TITLE=$issue_title")"
```

Add `VERIFICATION_CRITERIA`:

```bash
    test_prompt="$(render_prompt "$SCRIPT_DIR/prompts/test.txt" \
        "ISSUE_NUMBER=$issue_number" \
        "ISSUE_TITLE=$issue_title" \
        "VERIFICATION_CRITERIA=$VERIFICATION_CRITERIA")"
```

Note: `run_verification` currently receives `issue_number`, `issue_title`, `issue_body`, `attempt`, `tmpdir` as arguments. It uses a local `$CODEBASE_CONTEXT` which is actually the outer-scope global. `VERIFICATION_CRITERIA` is also an outer-scope global so it is accessible inside the function without changes.

- [ ] **Step 8.5: Syntax check**

```bash
bash -n fixer.sh
```

- [ ] **Step 8.6: Commit**

```bash
git add fixer.sh prompts/fix.txt prompts/review.txt prompts/test.txt
git commit -m "feat(criteria): thread VERIFICATION_CRITERIA into fix, review, test prompts"
```

---

## Task 9: Attempt tracking and terminal state transitions in fixer.sh

**Files:**
- Modify: `fixer.sh`

- [ ] **Step 9.1: Refresh NOW at the start of each attempt**

Each attempt needs its own timestamp. At the very start of the `for attempt in $(seq 1 "$MAX_RETRIES")` loop body (before the fix prompt is built), add:

```bash
        NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

This does not affect the classify-step uses of `NOW` (which occur before the loop).

- [ ] **Step 9.2: Track fix_crashed attempts**

In the retry loop, find:

```bash
        if ! echo "$FIX_PROMPT" | claude -p \
            $CLAUDE_PERM \
            --verbose \
            > "$FIX_OUTPUT" 2>&1; then
            err "  Fix agent failed"
            FEEDBACK="Fix agent crashed. Error output: $(tail -20 "$FIX_OUTPUT")"
            continue
        fi
```

Replace with:

```bash
        if ! echo "$FIX_PROMPT" | claude -p \
            $CLAUDE_PERM \
            --verbose \
            > "$FIX_OUTPUT" 2>&1; then
            err "  Fix agent failed"
            FEEDBACK="Fix agent crashed. Error output: $(tail -20 "$FIX_OUTPUT")"
            state_append_attempt "$ISSUE_ID" "$(jq -n \
                --arg t "$NOW" --arg s "${FEEDBACK:0:500}" \
                '{timestamp:$t,outcome:"fix_crashed",
                  feedback_summary:$s,diff_stat:""}')"
            continue
        fi
```

- [ ] **Step 9.3: Track no_changes attempts**

Find the `warn "  No changes made by fix agent"` block:

```bash
            warn "  No changes made by fix agent"
            FEEDBACK="Fix agent did not make any changes to the codebase. You MUST edit files to fix the bug."
            continue
```

Replace with:

```bash
            warn "  No changes made by fix agent"
            FEEDBACK="Fix agent did not make any changes to the codebase. You MUST edit files to fix the bug."
            state_append_attempt "$ISSUE_ID" "$(jq -n \
                --arg t "$NOW" \
                '{timestamp:$t,outcome:"no_changes",
                  feedback_summary:"Fix agent did not make any changes.",diff_stat:""}')"
            continue
```

- [ ] **Step 9.4: Track verification_failed and success attempts**

Find the verification call and its surrounding if/else:

```bash
        if run_verification "$ISSUE_NUMBER" "$ISSUE_TITLE" "$ISSUE_BODY" "$attempt" "$TMPDIR"; then
            ok "Issue #${ISSUE_NUMBER}: ALL CHECKS PASSED on attempt $attempt"
            ISSUE_RESOLVED=true
            break
        else
            warn "  Verification failed on attempt $attempt, will retry..."
        fi
```

Replace with:

```bash
        DIFF_STAT="$(git diff --stat "${DEFAULT_BRANCH}...HEAD" 2>/dev/null)"
        if run_verification "$ISSUE_NUMBER" "$ISSUE_TITLE" "$ISSUE_BODY" "$attempt" "$TMPDIR"; then
            ok "Issue #${ISSUE_NUMBER}: ALL CHECKS PASSED on attempt $attempt"
            state_append_attempt "$ISSUE_ID" "$(jq -n \
                --arg t "$NOW" --arg d "$DIFF_STAT" \
                '{timestamp:$t,outcome:"success",
                  feedback_summary:"",diff_stat:$d}')"
            ISSUE_RESOLVED=true
            break
        else
            warn "  Verification failed on attempt $attempt, will retry..."
            state_append_attempt "$ISSUE_ID" "$(jq -n \
                --arg t "$NOW" --arg s "${FEEDBACK:0:500}" --arg d "$DIFF_STAT" \
                '{timestamp:$t,outcome:"verification_failed",
                  feedback_summary:$s,diff_stat:$d}')"
        fi
```

- [ ] **Step 9.5: Set status=done on PR creation success**

In the `if $ISSUE_RESOLVED` block, after `ok "PR created: $PR_URL"` and the `--remove-label fixer:in-progress` line added in Task 6, add:

```bash
        state_upsert_issue "$ISSUE_ID" '{"status":"done"}'
```

- [ ] **Step 9.6: Set status=abandoned on max-retries failure**

In the `else` block (after `err "Issue #${ISSUE_NUMBER}: FAILED after $MAX_RETRIES attempts"`), after the `--remove-label fixer:in-progress` line, add:

```bash
        state_upsert_issue "$ISSUE_ID" '{"status":"abandoned"}'
```

- [ ] **Step 9.7: Syntax check**

```bash
bash -n fixer.sh
```

- [ ] **Step 9.8: Commit**

```bash
git add fixer.sh
git commit -m "feat(fixer): wire attempt tracking and terminal state transitions into fix loop"
```

---

## Task 10: README updates

**Files:**
- Modify: `README.md`

- [ ] **Step 10.1: Update the Architecture > file tree section**

In the `Architecture` section's file tree, add the new files:

```
fixer/
├── bin/fixer.js          # CLI entry point (Node.js, zero dependencies)
├── fixer.sh              # Core agent orchestrator (bash)
├── lib/
│   ├── state.sh          # Persistent state management (sourced by fixer.sh)
│   └── classify.sh       # Classify verdict parser (sourced by fixer.sh)
├── prompts/
│   ├── classify.txt      # Classify sub-agent prompt template  ← new
│   ├── fix.txt           # Fix agent prompt template
│   ├── review.txt        # Code review sub-agent prompt
│   ├── test.txt          # Test runner sub-agent prompt
│   └── security.txt      # Security review sub-agent prompt
├── tests/                # bats test suite (dev-only)  ← new
├── Dockerfile
├── entrypoint.sh
├── run-container.sh
└── package.json
```

- [ ] **Step 10.2: Update the Agent pipeline section**

Update the numbered list to add the classify step and show the new flow:

```
For each issue, fixer runs this pipeline:

1. **Load state** — check `~/.fixer/state.json`; skip done/abandoned issues; resume
   awaiting-human issues when new human comments are detected
2. **Clone/update** the target repo
3. **Create a branch** (`fix/issue-<number>`)
4. **Classify** — Claude reads the issue and codebase context, then outputs
   AUTO_FIX, NEEDS_HUMAN, or WONTFIX
   - NEEDS_HUMAN: posts a question comment, labels the issue `fixer:awaiting-human`,
     and waits for the next run
   - WONTFIX: posts a wontfix comment, labels the issue `fixer:wontfix`, moves on
5. **Fix agent** — Claude reads the codebase, implements a fix, writes tests
6. **Commit** the changes
7. **Verification** — three sub-agents run in parallel (unchanged)
8. On success: **push**, **create PR**, **enable auto-merge**, **notify**
```

- [ ] **Step 10.3: Add "Issue Verification Criteria" section**

Add a new section after the "Configuration" section:

```markdown
## Issue Verification Criteria

You can add a `## Verification` section to any GitHub issue body to specify
acceptance criteria. Fixer will pass these criteria to the fix, review, and
test agents, which will check them explicitly.

**Example issue body:**

```
The login flow crashes when the email contains a `+` character.

Steps to reproduce:
1. Try to log in with `user+tag@example.com`
2. Observe the 500 error

## Verification

- Logging in with `user+tag@example.com` no longer returns a 500 error
- Logging in with a normal email still works
- A regression test covers the `+` character case
```

If no `## Verification` section is present, Fixer applies general code quality
standards instead.
```

- [ ] **Step 10.4: Add "Issue Classification" section**

Add after "Issue Verification Criteria":

```markdown
## Issue Classification

Before attempting a fix, Fixer classifies each issue:

| Classification | Meaning | Action |
|----------------|---------|--------|
| `AUTO_FIX` | Clear, reproducible bug that can be fixed from repo code | Enters fix loop |
| `NEEDS_HUMAN` | Missing repro steps, design question, or requires runtime data | Posts a question, labels `fixer:awaiting-human`, waits |
| `WONTFIX` | Already fixed, working as designed, or duplicate | Posts a note, labels `fixer:wontfix`, skips |

### Labels

Fixer creates these labels on first use (idempotent):

| Label | Color | Meaning |
|-------|-------|---------|
| `fixer:in-progress` | Blue | Fixer is actively working on the issue |
| `fixer:awaiting-human` | Yellow | Fixer posted a question and is waiting |
| `fixer:wontfix` | Gray | Fixer abandoned this issue |

### Resuming a NEEDS_HUMAN issue

Reply to the issue comment Fixer left. On the next run, Fixer detects your
reply, appends it to the issue context, and re-classifies. If it now looks
fixable, it proceeds as normal.

### Overriding WONTFIX

Remove the `fixer:wontfix` label and reply with additional context explaining
why the issue should be fixed. Fixer will re-classify on the next run.
```

- [ ] **Step 10.5: Add "Persistent State" section**

Add after "Issue Classification":

```markdown
## Persistent State

Fixer stores run history at `~/.fixer/state.json` (override with `FIXER_STATE_FILE`).

The file tracks each issue's classification, status, attempt history, and pending
questions. It is used across runs so Fixer is never blind to prior attempts.

To debug why an issue is being skipped, inspect its state:

```bash
jq '.issues["owner/repo#42"]' ~/.fixer/state.json
```

To reset an issue and force a re-run:

```bash
jq 'del(.issues["owner/repo#42"])' ~/.fixer/state.json > /tmp/state.json.tmp \
  && mv /tmp/state.json.tmp ~/.fixer/state.json
```
```

- [ ] **Step 10.6: Add "Running Tests" section**

Add to the "Troubleshooting" section or as a new "Development" section:

```markdown
## Running Tests

Fixer includes a [bats-core](https://github.com/bats-core/bats-core) test suite
covering the state machine and classify verdict parser.

Install bats (dev-only, not required for normal use):

```bash
brew install bats-core          # macOS
sudo apt-get install -y bats    # Debian/Ubuntu/WSL
```

Run the suite:

```bash
bats tests/
```

Expected output: all tests pass. The suite does not call the real `gh` API
or Claude — all external calls are stubbed.
```

- [ ] **Step 10.7: Add FIXER_STATE_FILE to the environment variables table**

In the existing env vars table, add a row:

```
| `FIXER_STATE_FILE` | — | Path to persistent state file (default: `~/.fixer/state.json`) |
```

- [ ] **Step 10.8: Commit**

```bash
git add README.md
git commit -m "docs: update README with state, classify, labels, verification criteria, tests"
```

---

## Task 11: Full test run + final verification

- [ ] **Step 11.1: Run the full bats suite**

```bash
cd ~/projs/fixer
bats tests/
```

Expected: all tests pass, `0 failures`.

- [ ] **Step 11.2: Syntax check fixer.sh and all lib files**

```bash
bash -n fixer.sh lib/state.sh lib/classify.sh
```

Expected: no output (no errors).

- [ ] **Step 11.3: Verify fixer doctor still passes**

```bash
fixer doctor
```

Expected: all dependency checks pass (bats is dev-only, not checked by doctor).

- [ ] **Step 11.4: Verify CODEBASE_CONTEXT is accessible inside run_verification**

`run_verification` in `fixer.sh` references `$CODEBASE_CONTEXT` and the new `$VERIFICATION_CRITERIA` without them being passed as arguments (they are accessed as outer-scope globals from the sourced-function context). Confirm neither is declared `local` inside `run_verification`, then verify by grepping:

```bash
grep -n 'local CODEBASE_CONTEXT\|local VERIFICATION_CRITERIA' fixer.sh
```

Expected: no output. If either appears as `local`, remove the `local` declaration.

- [ ] **Step 11.5: Create the final commit for the PR**

```bash
git log --oneline main..HEAD
```

Confirm all feature commits are present, then proceed with the PR.

---

## Self-Review Checklist (for the implementing agent)

Before marking this plan complete, verify:

- [ ] `bats tests/` is green
- [ ] `bash -n fixer.sh lib/state.sh lib/classify.sh` exits 0
- [ ] `fixer doctor` passes
- [ ] `~/.fixer/state.json` is created when `fixer.sh` is sourced/run (state_init called)
- [ ] The NEEDS_HUMAN comment body contains all three hidden marker lines
- [ ] The WONTFIX comment body contains the hidden marker lines AND the "remove the label and reply" instruction
- [ ] `VERIFICATION_CRITERIA` is substituted in all three prompt files (fix, review, test)
- [ ] Atomic writes: no `.tmp` file left behind after any state operation
- [ ] `ensure_labels` uses `|| true` so it never aborts the run
- [ ] All `gh issue edit` label calls use `|| true`
