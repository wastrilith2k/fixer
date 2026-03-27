#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fixer.sh — Automated bug-fixing agent using headless Claude
#
# Usage: ./fixer.sh <owner/repo> [issue_number ...]
#   e.g. ./fixer.sh octocat/hello-world           # all bugs
#         ./fixer.sh octocat/hello-world 42 17     # specific issues
#
# Environment:
#   REPOS_ROOT    — root directory for cloned repos (default: ~/repos)
#   MAX_RETRIES   — max fix attempts per issue (default: 3)
#   NOTIFY_METHOD — notification backend: slack, email, ntfy, or comma-separated
#                   combo (default: none)
#   SLACK_WEBHOOK — Slack incoming webhook URL (required if notify=slack)
#   NTFY_TOPIC    — ntfy.sh topic name (required if notify=ntfy)
#   SMTP_TO       — recipient email address (required if notify=email)
#   SMTP_FROM     — sender email address (default: fixer@localhost)
#   AUTO_MERGE    — set to "true" to enable auto-merge on PRs (default: true)
#   FIXER_LOG     — path to log file (default: /tmp/fixer-<timestamp>.log)
#   CLAUDE_PERM   — claude permission flag (default: auto-detected)
#                   In containers as non-root: --dangerously-skip-permissions
#                   As root: $CLAUDE_PERM
# =============================================================================

# Resolve symlinks so SCRIPT_DIR points to the real location (handles npm bin symlinks)
_source="${BASH_SOURCE[0]}"
while [[ -L "$_source" ]]; do
    _dir="$(cd "$(dirname "$_source")" && pwd)"
    _source="$(readlink "$_source")"
    [[ "$_source" != /* ]] && _source="$_dir/$_source"
done
SCRIPT_DIR="$(cd "$(dirname "$_source")" && pwd)"
REPOS_ROOT="${REPOS_ROOT:-$HOME/repos}"
MAX_RETRIES="${MAX_RETRIES:-3}"
NOTIFY_METHOD="${NOTIFY_METHOD:-none}"
AUTO_MERGE="${AUTO_MERGE:-true}"

# Auto-detect permission mode
# As root: acceptEdits + explicit allowedTools (dangerously-skip-permissions is blocked as root)
# Non-root: dangerously-skip-permissions for zero prompts
CLAUDE_TOOLS="Bash,Edit,Read,Write,Glob,Grep,NotebookEdit,WebFetch"
if [[ -z "${CLAUDE_PERM:-}" ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
        CLAUDE_PERM="--permission-mode acceptEdits --allowedTools $CLAUDE_TOOLS"
    else
        CLAUDE_PERM="--dangerously-skip-permissions"
    fi
fi
FIXER_LOG="${FIXER_LOG:-/tmp/fixer-$(date +%Y%m%d-%H%M%S).log}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { local msg="[fixer] $*"; echo -e "${BLUE}${msg}${NC}"; echo "$msg" >> "$FIXER_LOG"; }
ok()   { local msg="[  OK ] $*"; echo -e "${GREEN}${msg}${NC}"; echo "$msg" >> "$FIXER_LOG"; }
warn() { local msg="[WARN ] $*"; echo -e "${YELLOW}${msg}${NC}"; echo "$msg" >> "$FIXER_LOG"; }
err()  { local msg="[FAIL ] $*"; echo -e "${RED}${msg}${NC}"; echo "$msg" >> "$FIXER_LOG"; }

# -----------------------------------------------------------------------------
# Notifications
# -----------------------------------------------------------------------------
notify() {
    local subject="$1"
    local body="$2"

    IFS=',' read -ra methods <<< "$NOTIFY_METHOD"
    for method in "${methods[@]}"; do
        method="$(echo "$method" | xargs)"  # trim whitespace
        case "$method" in
            slack)
                if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
                    local payload
                    payload="$(jq -n --arg text "*${subject}*\n${body}" '{text: $text}')"
                    curl -sf -X POST -H 'Content-type: application/json' \
                        -d "$payload" "$SLACK_WEBHOOK" >/dev/null 2>&1 \
                        && log "Slack notification sent" \
                        || warn "Slack notification failed"
                else
                    warn "SLACK_WEBHOOK not set, skipping Slack notification"
                fi
                ;;
            ntfy)
                if [[ -n "${NTFY_TOPIC:-}" ]]; then
                    curl -sf -H "Title: $subject" \
                        -d "$body" \
                        "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null 2>&1 \
                        && log "ntfy notification sent" \
                        || warn "ntfy notification failed"
                else
                    warn "NTFY_TOPIC not set, skipping ntfy notification"
                fi
                ;;
            email)
                if [[ -n "${SMTP_TO:-}" ]]; then
                    local from="${SMTP_FROM:-fixer@localhost}"
                    printf "Subject: %s\nFrom: %s\nTo: %s\n\n%s" \
                        "$subject" "$from" "$SMTP_TO" "$body" \
                        | sendmail "$SMTP_TO" 2>/dev/null \
                        && log "Email notification sent" \
                        || warn "Email notification failed (is sendmail configured?)"
                else
                    warn "SMTP_TO not set, skipping email notification"
                fi
                ;;
            none) ;;
            *)
                warn "Unknown notification method: $method"
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    echo "Usage: $0 <owner/repo> [issue_number ...]"
    echo ""
    echo "  If no issue numbers are given, fetches all open issues labeled 'bug'."
    echo "  If issue numbers are given, processes those specific issues instead."
    echo ""
    echo "Environment variables:"
    echo "  REPOS_ROOT     Root directory for cloned repos (default: ~/repos)"
    echo "  MAX_RETRIES    Max fix attempts per issue (default: 3)"
    echo "  NOTIFY_METHOD  Notification method: slack,email,ntfy (comma-separated, default: none)"
    echo "  SLACK_WEBHOOK  Slack incoming webhook URL"
    echo "  NTFY_TOPIC     ntfy.sh topic name"
    echo "  SMTP_TO        Recipient email address"
    echo "  SMTP_FROM      Sender email address (default: fixer@localhost)"
    echo "  AUTO_MERGE     Enable auto-merge on PRs: true/false (default: true)"
    echo "  FIXER_LOG      Log file path (default: /tmp/fixer-<timestamp>.log)"
    exit 1
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
[[ $# -lt 1 ]] && usage
REPO="$1"
shift
SPECIFIC_ISSUES=("$@")
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

if [[ -z "$OWNER" || -z "$NAME" || "$OWNER" == "$NAME" ]]; then
    err "Invalid repo format. Use owner/repo (e.g., octocat/hello-world)"
    exit 1
fi

REPO_DIR="$REPOS_ROOT/$OWNER/$NAME"

# Check dependencies
for cmd in gh claude git jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command not found: $cmd"
        exit 1
    fi
done

log "Log file: $FIXER_LOG"
log "Max retries per issue: $MAX_RETRIES"
log "Notification method: $NOTIFY_METHOD"
log "Auto-merge: $AUTO_MERGE"

# -----------------------------------------------------------------------------
# Step 1: Clone or update the repo
# -----------------------------------------------------------------------------
log "Setting up repo ${BOLD}$REPO${NC} in $REPO_DIR"

if [[ -d "$REPO_DIR/.git" ]]; then
    log "Repo exists, pulling latest changes..."
    git -C "$REPO_DIR" checkout "$(git -C "$REPO_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo main)" 2>/dev/null
    git -C "$REPO_DIR" pull --ff-only || warn "Pull failed, continuing with existing state"
else
    log "Cloning $REPO..."
    mkdir -p "$REPOS_ROOT/$OWNER"
    gh repo clone "$REPO" "$REPO_DIR"
fi

# Detect default branch
DEFAULT_BRANCH="$(git -C "$REPO_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')" || DEFAULT_BRANCH="main"
log "Default branch: $DEFAULT_BRANCH"

# -----------------------------------------------------------------------------
# Step 2: Fetch issues
# -----------------------------------------------------------------------------
if [[ ${#SPECIFIC_ISSUES[@]} -gt 0 ]]; then
    log "Fetching ${#SPECIFIC_ISSUES[@]} specific issue(s): ${SPECIFIC_ISSUES[*]}"
    ISSUES_JSON="["
    for issue_num in "${SPECIFIC_ISSUES[@]}"; do
        ISSUE_DATA="$(gh issue view "$issue_num" -R "$REPO" --json number,title,body)"
        if [[ "$ISSUES_JSON" != "[" ]]; then
            ISSUES_JSON+=","
        fi
        ISSUES_JSON+="$ISSUE_DATA"
    done
    ISSUES_JSON+="]"
else
    log "Fetching open issues labeled 'bug'..."
    ISSUES_JSON="$(gh issue list -R "$REPO" --label bug --state open --json number,title,body --limit 50)"
fi

ISSUE_COUNT="$(echo "$ISSUES_JSON" | jq length)"

if [[ "$ISSUE_COUNT" -eq 0 ]]; then
    ok "No issues found. Nothing to do!"
    exit 0
fi

log "Found ${BOLD}$ISSUE_COUNT${NC} issue(s) to process"

# -----------------------------------------------------------------------------
# Helper: render a prompt template with variable substitution
# -----------------------------------------------------------------------------
render_prompt() {
    local template_file="$1"
    shift
    local content
    content="$(cat "$template_file")"

    # Replace {{KEY}} placeholders with provided key=value pairs
    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}"
        local value="${1#*=}"
        content="${content//\{\{$key\}\}/$value}"
        shift
    done
    echo "$content"
}

# -----------------------------------------------------------------------------
# Helper: extract VERDICT from sub-agent output
# -----------------------------------------------------------------------------
extract_verdict() {
    local file="$1"
    grep -oP 'VERDICT:\s*\K.*' "$file" 2>/dev/null | tail -1 || echo "UNKNOWN"
}

# -----------------------------------------------------------------------------
# Helper: run verification sub-agents and return pass/fail
# Returns 0 if all pass, 1 if any fail. Sets FEEDBACK variable with failure details.
# -----------------------------------------------------------------------------
run_verification() {
    local issue_number="$1"
    local issue_title="$2"
    local issue_body="$3"
    local attempt="$4"
    local tmpdir="$5"

    local diff
    diff="$(git diff "${DEFAULT_BRANCH}...HEAD")"

    log "  Spawning verification sub-agents (attempt $attempt)..."

    # Agent 1: Code Review
    local review_prompt review_output
    review_prompt="$(render_prompt "$SCRIPT_DIR/prompts/review.txt" \
        "ISSUE_NUMBER=$issue_number" \
        "ISSUE_TITLE=$issue_title" \
        "ISSUE_BODY=$issue_body" \
        "DIFF=$diff")"
    review_output="$tmpdir/review-${issue_number}-attempt${attempt}.txt"
    echo "$review_prompt" | claude -p $CLAUDE_PERM \
        > "$review_output" 2>&1 &
    local pid_review=$!

    # Agent 2: Test Runner
    local test_prompt test_output
    test_prompt="$(render_prompt "$SCRIPT_DIR/prompts/test.txt" \
        "ISSUE_NUMBER=$issue_number" \
        "ISSUE_TITLE=$issue_title")"
    test_output="$tmpdir/test-${issue_number}-attempt${attempt}.txt"
    echo "$test_prompt" | claude -p $CLAUDE_PERM \
        > "$test_output" 2>&1 &
    local pid_test=$!

    # Agent 3: Security Review
    local security_prompt security_output
    security_prompt="$(render_prompt "$SCRIPT_DIR/prompts/security.txt" \
        "DIFF=$diff")"
    security_output="$tmpdir/security-${issue_number}-attempt${attempt}.txt"
    echo "$security_prompt" | claude -p $CLAUDE_PERM \
        > "$security_output" 2>&1 &
    local pid_security=$!

    log "  Waiting for sub-agents (PIDs: $pid_review, $pid_test, $pid_security)..."
    wait $pid_review  || true
    wait $pid_test    || true
    wait $pid_security || true

    local verdict_review verdict_test verdict_security
    verdict_review="$(extract_verdict "$review_output")"
    verdict_test="$(extract_verdict "$test_output")"
    verdict_security="$(extract_verdict "$security_output")"

    # Print results
    echo ""
    log "  --- Verification results (attempt $attempt) ---"
    if [[ "$verdict_review" == PASS* ]]; then ok "  Code Review: $verdict_review"
    else err "  Code Review: $verdict_review"; fi
    if [[ "$verdict_test" == PASS* ]]; then ok "  Test Runner: $verdict_test"
    else err "  Test Runner: $verdict_test"; fi
    if [[ "$verdict_security" == PASS* ]]; then ok "  Security Review: $verdict_security"
    else err "  Security Review: $verdict_security"; fi

    # Build feedback for retry
    FEEDBACK=""
    if [[ "$verdict_review" == PASS* && "$verdict_test" == PASS* && "$verdict_security" == PASS* ]]; then
        return 0
    fi

    if [[ "$verdict_review" != PASS* ]]; then
        FEEDBACK+="CODE REVIEW FAILED: $verdict_review"$'\n'
        FEEDBACK+="$(cat "$review_output")"$'\n\n'
    fi
    if [[ "$verdict_test" != PASS* ]]; then
        FEEDBACK+="TEST RUNNER FAILED: $verdict_test"$'\n'
        FEEDBACK+="$(cat "$test_output")"$'\n\n'
    fi
    if [[ "$verdict_security" != PASS* ]]; then
        FEEDBACK+="SECURITY REVIEW FAILED: $verdict_security"$'\n'
        FEEDBACK+="$(cat "$security_output")"$'\n\n'
    fi
    return 1
}

# -----------------------------------------------------------------------------
# Step 3: Process each issue with retry loop
# -----------------------------------------------------------------------------
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

RESULTS=()
PASS_COUNT=0
FAIL_COUNT=0
PR_URLS=()

for i in $(seq 0 $((ISSUE_COUNT - 1))); do
    ISSUE_NUMBER="$(echo "$ISSUES_JSON" | jq -r ".[$i].number")"
    ISSUE_TITLE="$(echo "$ISSUES_JSON" | jq -r ".[$i].title")"
    ISSUE_BODY="$(echo "$ISSUES_JSON" | jq -r ".[$i].body")"
    BRANCH_NAME="fix/issue-${ISSUE_NUMBER}"

    echo ""
    log "============================================================"
    log "Processing issue #${ISSUE_NUMBER}: ${BOLD}${ISSUE_TITLE}${NC}"
    log "============================================================"

    cd "$REPO_DIR"
    ISSUE_RESOLVED=false
    FEEDBACK=""

    # --- Create or switch to branch (once, before retry loop) ---
    git checkout "$DEFAULT_BRANCH" 2>/dev/null
    if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
        git checkout "$BRANCH_NAME" 2>/dev/null
    else
        git checkout -b "$BRANCH_NAME"
    fi

    # --- Ensure .claude/ artifacts are gitignored ---
    if ! grep -qx '.claude/' "$REPO_DIR/.gitignore" 2>/dev/null; then
        echo '.claude/' >> "$REPO_DIR/.gitignore"
    fi

    for attempt in $(seq 1 "$MAX_RETRIES"); do
        log "Attempt $attempt/$MAX_RETRIES for issue #${ISSUE_NUMBER}"

        # --- Build fix prompt (include feedback from prior attempts) ---
        FIX_PROMPT="$(render_prompt "$SCRIPT_DIR/prompts/fix.txt" \
            "ISSUE_NUMBER=$ISSUE_NUMBER" \
            "ISSUE_TITLE=$ISSUE_TITLE" \
            "ISSUE_BODY=$ISSUE_BODY")"

        if [[ -n "$FEEDBACK" && $attempt -gt 1 ]]; then
            FIX_PROMPT+="

## Previous Attempt Feedback (attempt $((attempt - 1)) failed)

The previous fix attempt was rejected by the verification agents. Here is their feedback.
You MUST address these problems in your new fix:

$FEEDBACK"
        fi

        # --- Run Fix Agent ---
        log "  Running fix agent..."
        FIX_OUTPUT="$TMPDIR/fix-${ISSUE_NUMBER}-attempt${attempt}.txt"
        if ! echo "$FIX_PROMPT" | claude -p \
            $CLAUDE_PERM \
            --verbose \
            > "$FIX_OUTPUT" 2>&1; then
            err "  Fix agent failed"
            FEEDBACK="Fix agent crashed. Error output: $(tail -20 "$FIX_OUTPUT")"
            continue
        fi
        ok "  Fix agent completed"

        # --- Commit the changes ---
        # Remove any .claude worktree artifacts before staging
        git rm -rf --cached .claude/worktrees 2>/dev/null || true

        if git diff --quiet && git diff --cached --quiet; then
            # No new changes, but if prior commits exist on branch, retry verification
            if [[ "$(git rev-list --count "${DEFAULT_BRANCH}..HEAD")" -gt 0 ]]; then
                warn "  No new changes, but prior fix exists — re-running verification"
            else
                warn "  No changes made by fix agent"
                FEEDBACK="Fix agent did not make any changes to the codebase. You MUST edit files to fix the bug."
                continue
            fi
        else
            git add -A
            git commit -m "fix: resolve issue #${ISSUE_NUMBER} — ${ISSUE_TITLE}

Automated fix generated by fixer agent (attempt ${attempt}).
Includes regression tests." || {
                err "  Commit failed"
                FEEDBACK="Git commit failed."
                continue
            }
        fi
        ok "  Changes committed on branch $BRANCH_NAME"

        # --- Run verification ---
        if run_verification "$ISSUE_NUMBER" "$ISSUE_TITLE" "$ISSUE_BODY" "$attempt" "$TMPDIR"; then
            ok "Issue #${ISSUE_NUMBER}: ALL CHECKS PASSED on attempt $attempt"
            ISSUE_RESOLVED=true
            break
        else
            warn "  Verification failed on attempt $attempt, will retry..."
        fi
    done

    if $ISSUE_RESOLVED; then
        # --- Push branch and create PR ---
        log "Pushing branch and creating PR..."
        git push -u origin "$BRANCH_NAME" --force-with-lease 2>/dev/null || {
            err "  Push failed for issue #${ISSUE_NUMBER}"
            RESULTS+=("#${ISSUE_NUMBER}: PASS (verified) but push failed")
            FAIL_COUNT=$((FAIL_COUNT + 1))
            git checkout "$DEFAULT_BRANCH" 2>/dev/null
            continue
        }

        PR_BODY="$(cat <<EOF
## Automated Fix for #${ISSUE_NUMBER}

**Issue:** ${ISSUE_TITLE}

This fix was automatically generated and verified by the fixer agent.

### Verification Results
- Code Review: PASS
- Test Runner: PASS
- Security Review: PASS

Closes #${ISSUE_NUMBER}

---
Generated by [fixer](https://github.com/wastrilith2k/fixer)
EOF
)"

        PR_URL="$(gh pr create \
            -R "$REPO" \
            --base "$DEFAULT_BRANCH" \
            --head "$BRANCH_NAME" \
            --title "fix: resolve #${ISSUE_NUMBER} — ${ISSUE_TITLE}" \
            --body "$PR_BODY" 2>&1)" || {
            # PR might already exist
            PR_URL="$(gh pr view "$BRANCH_NAME" -R "$REPO" --json url -q .url 2>/dev/null || echo "unknown")"
        }

        ok "PR created: $PR_URL"
        PR_URLS+=("$PR_URL")

        # --- Comment on the issue with a summary of changes ---
        log "  Commenting on issue #${ISSUE_NUMBER}..."
        DIFF_STAT="$(git diff --stat "${DEFAULT_BRANCH}...${BRANCH_NAME}" 2>/dev/null)"
        CHANGED_FILES="$(git diff --name-only "${DEFAULT_BRANCH}...${BRANCH_NAME}" 2>/dev/null)"
        ISSUE_COMMENT="$(cat <<COMMENT_EOF
## Automated Fix Submitted

A fix has been generated and submitted as a pull request: ${PR_URL}

### Changes
\`\`\`
${DIFF_STAT}
\`\`\`

### Files Changed
$(echo "$CHANGED_FILES" | sed 's/^/- `/' | sed 's/$/`/')

### Verification Results
- Code Review: PASS
- Test Runner: PASS
- Security Review: PASS

---
*Generated by [fixer](https://github.com/wastrilith2k/fixer) (attempt ${attempt})*
COMMENT_EOF
)"
        gh issue comment "$ISSUE_NUMBER" -R "$REPO" --body "$ISSUE_COMMENT" 2>/dev/null \
            && ok "  Commented on issue #${ISSUE_NUMBER}" \
            || warn "  Could not comment on issue #${ISSUE_NUMBER}"

        # --- Enable auto-merge if configured ---
        if [[ "$AUTO_MERGE" == "true" ]]; then
            log "  Enabling auto-merge..."
            gh pr merge "$PR_URL" --auto --squash -R "$REPO" 2>/dev/null \
                && ok "  Auto-merge enabled (will merge when CI passes)" \
                || warn "  Could not enable auto-merge (repo may not support it)"
        fi

        # --- Send notification ---
        notify \
            "Fixer: PR ready for #${ISSUE_NUMBER}" \
            "Issue: ${ISSUE_TITLE}
PR: ${PR_URL}
Repo: ${REPO}
Attempts: ${attempt}
Auto-merge: ${AUTO_MERGE}

All verification checks passed."

        RESULTS+=("#${ISSUE_NUMBER}: PASS — $PR_URL")
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "Issue #${ISSUE_NUMBER}: FAILED after $MAX_RETRIES attempts"

        # --- Comment on the issue about the failure ---
        log "  Commenting on issue #${ISSUE_NUMBER} (failure)..."
        FAIL_COMMENT="$(cat <<COMMENT_EOF
## Automated Fix Attempted

The fixer agent attempted to resolve this issue but could not produce a fix that passes all verification checks after ${MAX_RETRIES} attempt(s).

A maintainer will need to look into this manually.

---
*Generated by [fixer](https://github.com/wastrilith2k/fixer)*
COMMENT_EOF
)"
        gh issue comment "$ISSUE_NUMBER" -R "$REPO" --body "$FAIL_COMMENT" 2>/dev/null \
            && ok "  Commented on issue #${ISSUE_NUMBER}" \
            || warn "  Could not comment on issue #${ISSUE_NUMBER}"

        notify \
            "Fixer: FAILED to fix #${ISSUE_NUMBER}" \
            "Issue: ${ISSUE_TITLE}
Repo: ${REPO}
Attempts: ${MAX_RETRIES}

Could not produce a fix that passes all verification checks.
Check logs: ${FIXER_LOG}"

        RESULTS+=("#${ISSUE_NUMBER}: FAIL (exhausted $MAX_RETRIES attempts)")
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    # Return to default branch for next issue
    git checkout "$DEFAULT_BRANCH" 2>/dev/null
done

# -----------------------------------------------------------------------------
# Step 4: Final summary
# -----------------------------------------------------------------------------
echo ""
log "============================================================"
log "${BOLD}FINAL SUMMARY${NC}"
log "============================================================"
log "Processed: $ISSUE_COUNT issue(s)"
ok  "Passed:    $PASS_COUNT"
[[ $FAIL_COUNT -gt 0 ]] && err "Failed:    $FAIL_COUNT"

echo ""
for result in "${RESULTS[@]}"; do
    echo "  $result"
done

if [[ ${#PR_URLS[@]} -gt 0 ]]; then
    echo ""
    log "Pull Requests created:"
    for url in "${PR_URLS[@]}"; do
        echo "  $url"
    done
fi

echo ""
log "Full log: $FIXER_LOG"

# Send summary notification
if [[ "$ISSUE_COUNT" -gt 0 ]]; then
    SUMMARY="Processed $ISSUE_COUNT issue(s): $PASS_COUNT passed, $FAIL_COUNT failed."
    if [[ ${#PR_URLS[@]} -gt 0 ]]; then
        SUMMARY+=$'\n\nPRs created:'
        for url in "${PR_URLS[@]}"; do
            SUMMARY+=$'\n'"  $url"
        done
    fi
    notify "Fixer Run Complete: $REPO" "$SUMMARY"
fi

# Keep tmpdir around if there were failures
if [[ $FAIL_COUNT -gt 0 ]]; then
    trap - EXIT
    warn "Keeping temp output in $TMPDIR for debugging"
fi

exit "$FAIL_COUNT"
