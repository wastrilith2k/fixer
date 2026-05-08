# Design: Ralph Harness Patterns for Fixer

**Date:** 2026-05-08  
**Status:** Approved  
**Scope:** Persistent state, classify sub-agent, halt-and-feedback, acceptance criteria  
**Out of scope:** Global cost/budget tracking, coordinator-level priority logic, cross-issue knowledge base

---

## 1. Overview

Four patterns from the kdp-pipeline Ralph harness are being added to Fixer as a single PR. They form a coherent group: state makes the others persistent; classify gates the fix loop; halt-and-feedback handles the NEEDS_HUMAN branch; acceptance criteria threads issue intent into the verification agents.

---

## 2. New Files

| File | Purpose |
|------|---------|
| `lib/state.sh` | State get/set/upsert as bash functions, sourced from fixer.sh |
| `prompts/classify.txt` | Classify agent prompt template |
| `tests/test_state_roundtrip.bats` | Write/read state, verify schema |
| `tests/test_skip_done.bats` | Verify done/abandoned issues are skipped |
| `tests/test_awaiting_human_no_new_comments.bats` | Verify skip when no new comments |
| `tests/test_awaiting_human_resumes_on_comment.bats` | Verify resume with new comment |
| `tests/test_classify_parsing.bats` | Verdict-line parser for all 3 verdicts + malformed |

## 3. Modified Files

| File | Change |
|------|--------|
| `fixer.sh` | Source lib/state.sh; add state machine, classify call, label management, criteria parsing |
| `prompts/fix.txt` | Add `{{VERIFICATION_CRITERIA}}` block after Rules section |
| `prompts/review.txt` | Add item 14 (acceptance criteria check) and `{{VERIFICATION_CRITERIA}}` block |
| `README.md` | Document Verification section convention, labels, state file, new env var, bats tests |

---

## 4. State Schema

File: `$HOME/.fixer/state.json` (override via `FIXER_STATE_FILE`).

```json
{
  "version": 1,
  "schema_version": 1,
  "issues": {
    "<owner>/<repo>#<number>": {
      "id": "<owner>/<repo>#<number>",
      "title": "...",
      "classification": "auto_fix" | "needs_human" | "wontfix" | null,
      "status": "queued" | "in_progress" | "awaiting_human" | "done" | "abandoned",
      "attempts": [
        {
          "timestamp": "ISO8601",
          "outcome": "success" | "verification_failed" | "no_changes" | "classify_halted" | "fix_crashed",
          "feedback_summary": "first 500 chars of feedback",
          "diff_stat": "..."
        }
      ],
      "last_question": "...",
      "last_question_timestamp": "ISO8601",
      "first_seen": "ISO8601",
      "last_run": "ISO8601"
    }
  }
}
```

`last_question_timestamp` is set whenever fixer posts a fixer-marker comment (NEEDS_HUMAN or WONTFIX). It is the reference point for "new human comment since last fixer comment" on both resume paths.

Atomic writes: write to `<state_file>.tmp` then `mv -f <state_file>.tmp <state_file>`.

### lib/state.sh functions

```
state_init()                      — mkdir -p ~/.fixer; create state.json if absent
state_get_issue(id)               — print issue JSON (or "null")
state_upsert_issue(id, jq_expr)   — merge jq_expr into issues[id], atomic write
state_append_attempt(id, attempt) — append to issues[id].attempts[], atomic write
```

---

## 5. State Machine

```
first_seen
  → queued
  → in_progress  (on processing start)
  → done         (fix passed, PR created)
  → abandoned    (WONTFIX classify OR max retries exhausted)
  → awaiting_human  (NEEDS_HUMAN classify)

awaiting_human
  → in_progress  (new non-fixer comment detected since last_question_timestamp)

abandoned (classification=wontfix only)
  → in_progress  (new non-fixer comment detected since last_question_timestamp)
```

Issues abandoned due to max retries (`classification=auto_fix, status=abandoned`) are **not** resurrectable automatically. Issues abandoned due to wontfix (`classification=wontfix, status=abandoned`) ARE resurrectable if a new human comment arrives.

---

## 6. Per-Issue Flow (complete)

```
load_state(issue_id)

# ── Skip / Resume decisions ────────────────────────────────────────────
if status == done:
    log "skipping (already done)"
    continue

if status == abandoned:
    if classification == wontfix:
        new_comments = fetch_new_human_comments(since=last_question_timestamp)
        if new_comments is empty:
            log "skipping (wontfix, no new context)"
            continue
        augment ISSUE_BODY with new comments
        remove fixer:wontfix label
        # fall through to in_progress
    else:  # auto_fix abandoned = max retries exhausted
        log "skipping (max retries exhausted)"
        continue

if status == awaiting_human:
    new_comments = fetch_new_human_comments(since=last_question_timestamp)
    if new_comments is empty:
        log "skipping (awaiting human input since <last_question_timestamp>)"
        continue
    augment ISSUE_BODY with new comments
    # fall through to in_progress

# ── Start processing ────────────────────────────────────────────────────
PREV_STATUS="$current_status"  # save before overwriting — used below in AUTO_FIX path
state_upsert(status=in_progress, last_run=now)  # first_seen=now if absent
ensure_labels(owner, repo)
gh issue edit --add-label fixer:in-progress

git setup (checkout default branch, create/switch branch, .gitignore .claude/)

CODEBASE_CONTEXT = gather_codebase_context(REPO_DIR)
VERIFICATION_CRITERIA = parse_verification_criteria(ISSUE_BODY)

# ── Classify ────────────────────────────────────────────────────────────
classify_output = run_classify(issue, CODEBASE_CONTEXT)
verdict = parse_classify_verdict(classify_output)  # defaults to AUTO_FIX + warning on parse failure
# Store lowercase classification ("auto_fix" | "needs_human" | "wontfix") — parser produces uppercase internally
state_upsert(classification=lowercase(verdict.kind))

if verdict.kind == NEEDS_HUMAN:
    post_needs_human_comment(verdict.question, now)
    gh issue edit --add-label fixer:awaiting-human --remove-label fixer:in-progress
    state_upsert(status=awaiting_human,
                 last_question=verdict.question,
                 last_question_timestamp=now)
    state_append_attempt(outcome=classify_halted, feedback_summary="NEEDS_HUMAN: <question>", diff_stat="")
    continue

if verdict.kind == WONTFIX:
    post_wontfix_comment(verdict.reason, now)
    # --remove-label is idempotent; removing fixer:awaiting-human handles the
    # awaiting_human → WONTFIX resume path without breaking the first-time path
    gh issue edit --add-label fixer:wontfix \
                  --remove-label fixer:in-progress \
                  --remove-label fixer:awaiting-human
    state_upsert(status=abandoned,
                 last_question_timestamp=now)
    state_append_attempt(outcome=classify_halted, feedback_summary="WONTFIX: <reason>", diff_stat="")
    continue

# ── AUTO_FIX path ───────────────────────────────────────────────────────
if PREV_STATUS == awaiting_human:
    gh issue edit --remove-label fixer:awaiting-human  # fixer:in-progress already applied above

ISSUE_RESOLVED = false
for attempt in 1..MAX_RETRIES:
    build fix prompt (VERIFICATION_CRITERIA threaded in)
    run fix agent → FIX_OUTPUT
    if fix agent crashed:
        state_append_attempt(outcome=fix_crashed, feedback_summary=last-20-lines, diff_stat="")
        continue
    if no changes:
        state_append_attempt(outcome=no_changes, feedback_summary="No changes made", diff_stat="")
        continue
    commit changes
    diff_stat = git diff --stat DEFAULT_BRANCH...HEAD
    run_verification (VERIFICATION_CRITERIA threaded into review.txt)
    if pass:
        state_append_attempt(outcome=success, diff_stat=diff_stat, feedback_summary="")
        ISSUE_RESOLVED = true
        break
    else:
        state_append_attempt(outcome=verification_failed, diff_stat=diff_stat,
                             feedback_summary=first-500-chars-of-FEEDBACK)

if ISSUE_RESOLVED:
    push, create PR, comment on issue, enable auto-merge, notify
    gh issue edit --remove-label fixer:in-progress
    state_upsert(status=done)
else:
    post failure comment
    gh issue edit --remove-label fixer:in-progress
    state_upsert(status=abandoned)
```

---

## 7. Comment Templates

### NEEDS_HUMAN

```markdown
## Fixer needs more information

<question>

Reply to this issue with the details above and Fixer will retry on its
next run.

<!-- fixer:state-comment -->
<!-- fixer:status=awaiting_human -->
<!-- fixer:question_timestamp=<ISO8601> -->
```

### WONTFIX

```markdown
## Fixer won't attempt this issue

<reason>

This issue has been labeled `fixer:wontfix` and won't be retried automatically. If you disagree, remove the label and reply with additional context — Fixer will re-classify on the next run.

<!-- fixer:state-comment -->
<!-- fixer:status=abandoned -->
```

---

## 8. Fixer-Comment Detection

When checking for "new human comments since last_question_timestamp", a comment is fixer-owned (and must be excluded) if its body contains either:
- `<!-- fixer:state-comment -->`
- `Generated by [fixer]`

Detection is by body content, not by author. Fixer authenticates with the maintainer's `gh` PAT so author filtering would silently exclude all comments.

```bash
fetch_new_human_comments() {
    local owner="$1" repo="$2" issue_num="$3" since_ts="$4"
    gh api "repos/$owner/$repo/issues/$issue_num/comments?since=$since_ts" \
        --jq '[.[] | select(.body | test("<!-- fixer:state-comment -->|Generated by \\[fixer\\]") | not)]'
}
```

`gh api --jq` takes a single filter expression and does not accept `--arg`. The `?since=` query param (ISO8601 second precision, matches on `created_at`) is sufficient to pre-filter; no secondary timestamp guard in jq is needed.

---

## 9. Classify Prompt (`prompts/classify.txt`)

Template variables: `{{ISSUE_NUMBER}}`, `{{ISSUE_TITLE}}`, `{{ISSUE_BODY}}`, `{{CODEBASE_CONTEXT}}`.

Output format (exactly one line at end of response):
```
CLASSIFICATION: AUTO_FIX
CLASSIFICATION: NEEDS_HUMAN — <specific question for the human>
CLASSIFICATION: WONTFIX — <reason>
```

**NEEDS_HUMAN** when:
- Lacks reproducible steps and bug isn't obvious from description
- Describes a design decision or feature request rather than a bug
- Requires runtime data (logs, metrics, prod DB state) not in repo
- Mentions credentials, secrets, or production data needing rotation
- Asks a clarifying question rather than reports a bug
- Fix as described would touch >15 files (estimate from grep)

**WONTFIX** when:
- Already closed in spirit (recent commit references it)
- Describes behavior working as designed per convention files
- Is a duplicate ("same as #N" in body)

**AUTO_FIX** otherwise.

### Verdict parser

```bash
parse_classify_verdict() {
    # Sets CLASSIFY_KIND and CLASSIFY_DETAIL globals.
    # Uses awk (not grep -P) for macOS/BSD portability.
    # Separator stripping is permissive: handles em-dash, en-dash, hyphen, double-hyphen.
    local output="$1"
    local line
    line="$(awk '/^CLASSIFICATION:/{line=$0} END{print line}' <<< "$output")"
    line="${line#CLASSIFICATION:}"
    line="${line# }"  # strip one leading space

    if [[ "$line" == AUTO_FIX* ]]; then
        CLASSIFY_KIND="AUTO_FIX"; CLASSIFY_DETAIL=""
    elif [[ "$line" == NEEDS_HUMAN* ]]; then
        CLASSIFY_KIND="NEEDS_HUMAN"
        CLASSIFY_DETAIL="$(printf '%s' "${line#NEEDS_HUMAN}" | sed 's/^[[:space:]]*[—–-]\+[[:space:]]*//')"
    elif [[ "$line" == WONTFIX* ]]; then
        CLASSIFY_KIND="WONTFIX"
        CLASSIFY_DETAIL="$(printf '%s' "${line#WONTFIX}" | sed 's/^[[:space:]]*[—–-]\+[[:space:]]*//')"
    else
        warn "Could not parse CLASSIFICATION line, defaulting to AUTO_FIX. Raw: '$line'"
        CLASSIFY_KIND="AUTO_FIX"; CLASSIFY_DETAIL=""
    fi
}
```

---

## 10. GitHub Labels

Three labels, created idempotently on first use (`gh label create ... 2>/dev/null || true`):

| Label | Color (hex) | When applied |
|-------|-------------|--------------|
| `fixer:in-progress` | `0075CA` (blue) | When fix loop begins for an issue |
| `fixer:awaiting-human` | `FBCA04` (yellow) | After NEEDS_HUMAN classify |
| `fixer:wontfix` | `808080` (gray) | After WONTFIX classify |

Labels are removed:
- `fixer:in-progress` → removed when status transitions to done or abandoned
- `fixer:awaiting-human` → removed when resume into AUTO_FIX
- `fixer:wontfix` → removed when wontfix resurrection triggers

---

## 11. Verification Criteria

### Parsing from issue body

```bash
parse_verification_criteria() {
    local body="$1"
    # Extract lines between "## Verification" and the next "## " heading (or EOF)
    local criteria
    criteria="$(printf '%s\n' "$body" | awk '/^## Verification/{found=1; next} found && /^## /{exit} found{print}')"
    if [[ -z "$(printf '%s' "$criteria" | tr -d '[:space:]')" ]]; then
        printf '%s' "(none specified — use general code quality standards)"
    else
        printf '%s' "$criteria"
    fi
}
```

### fix.txt addition (after Rules block)

```
## Acceptance Criteria (if any)

Your fix MUST satisfy each of these criteria. The review agent will check
them explicitly.

{{VERIFICATION_CRITERIA}}
```

### review.txt addition (item 14, after item 13)

```
14. **Acceptance criteria**: If a Verification section is provided below,
    explicitly check each criterion. Failing any criterion is an automatic
    VERDICT: FAIL with the specific criterion called out.

## Acceptance Criteria (if any)

{{VERIFICATION_CRITERIA}}
```

`{{VERIFICATION_CRITERIA}}` is also threaded into `test.txt` (after the Issue Context section) so the test agent can validate acceptance criteria via test assertions where applicable.

---

## 12. WONTFIX Resurrection Logic

On subsequent runs, if `status=abandoned` and `classification=wontfix`:
1. Fetch new non-fixer comments since `last_question_timestamp`.
2. If none: skip with log message.
3. If any: augment `ISSUE_BODY`, remove `fixer:wontfix` label, set `status=in_progress`, fall through to classify.
4. Re-classify with augmented context:
   - AUTO_FIX: proceed with fix loop
   - NEEDS_HUMAN: post new question, transition to awaiting_human
   - WONTFIX again: post new wontfix comment, update `last_question_timestamp`, remain abandoned

---

## 13. Open Questions (non-blocking follow-ups)

- **No re-cycle limit on NEEDS_HUMAN**: an issue could ping-pong indefinitely if the human keeps replying with insufficient context. Add a `max_needs_human_cycles` cap as a follow-up.
- **Global cost tracking**: out of scope for this PR.
- **Coordinator-level priority**: out of scope for this PR.

---

## 14. Tests (`bats tests/`)

### test_state_roundtrip.bats
- Write an issue into state, read it back, verify all fields match schema.

### test_skip_done.bats
- Populate state with `status=done`; run per-issue processing stub; verify it logs "skipping" and does not enter the fix loop.
- Repeat for `status=abandoned, classification=auto_fix`.

### test_awaiting_human_no_new_comments.bats
- State with `status=awaiting_human`; stub `gh api` to return empty array; verify "skipping" log and no fix loop entry.

### test_awaiting_human_resumes_on_comment.bats
- State with `status=awaiting_human`; stub `gh api` to return one non-fixer comment; verify status transitions to `in_progress` and fix loop is entered with augmented body.

### test_classify_parsing.bats
- `CLASSIFICATION: AUTO_FIX` → kind=AUTO_FIX, detail=""
- `CLASSIFICATION: NEEDS_HUMAN — What is the expected output?` → kind=NEEDS_HUMAN, detail="What is the expected output?"
- `CLASSIFICATION: NEEDS_HUMAN – What is...` (en-dash) → kind=NEEDS_HUMAN, same detail (permissive separator)
- `CLASSIFICATION: WONTFIX — Duplicate of #42` → kind=WONTFIX, detail="Duplicate of #42"
- Malformed / missing line → kind=AUTO_FIX, warning emitted

### test_wontfix_resurrection.bats
- State: `status=abandoned`, `classification=wontfix`, `last_question_timestamp=<T0>`
- Stub `gh api .../comments?since=T0` to return one non-fixer comment newer than T0
- Verify: `fixer:wontfix` label removed, `status` transitions to `in_progress`
- Verify: `ISSUE_BODY` passed to classify contains `## Additional context from maintainer` block with the comment text

---

## 15. README Additions

- New env var: `FIXER_STATE_FILE`
- New section: "Issue Verification Criteria" — documents `## Verification` bullet convention
- New section: "Issue Classification" — explains AUTO_FIX / NEEDS_HUMAN / WONTFIX, the three labels, and what "awaiting human" means
- Architecture section: add classify step before fix loop, add state file to file tree
- Troubleshooting: add note about `~/.fixer/state.json` for debugging repeated skips
- Testing: `bats tests/` to run unit tests (bats is a dev-only dependency)

---

## 16. Constraints

- No changes to `.fixer.json` schema or CLI signature.
- No new runtime dependencies (gh, claude, git, jq, curl already required). `bats` is dev-only.
- Core verification agent checks (correctness, scope, regressions, security) unchanged; only `{{VERIFICATION_CRITERIA}}` threaded in.
- `fixer doctor` continues to pass without checking for bats.
