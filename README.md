# fixer

Automated bug-fixing agent powered by Claude. Give it a GitHub repo and it will fetch open bug issues, generate fixes with regression tests, verify them through code review / test / security sub-agents, and open pull requests — all unattended.

## How it works

```
Issue #42: "Login fails when email has uppercase"
  │
  ▼
┌─────────────────────────────────────────────┐
│  State check (~/.fixer/state.json)          │
│  - already done? → skip                     │
│  - awaiting human? → check for new replies  │
└─────────────┬───────────────────────────────┘
              │ process
              ▼
┌─────────────────────────────────────────────┐
│  Classify Agent (Claude)                    │
│  - reads issue + codebase context           │
│  - outputs AUTO_FIX / NEEDS_HUMAN / WONTFIX │
└──────┬──────────────┬────────────────┬──────┘
       │ AUTO_FIX     │ NEEDS_HUMAN    │ WONTFIX
       │              ▼                ▼
       │    post question +     post note +
       │    await reply         skip issue
       ▼
┌─────────────────────────────────────────────┐
│  Fix Agent (Claude)                         │
│  - reads the codebase                       │
│  - implements a minimal, targeted fix       │
│  - writes regression tests                  │
└─────────────┬───────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────┐
│  Verification (3 parallel sub-agents)       │
│  ┌─────────────┬────────────┬─────────────┐ │
│  │ Code Review │ Test Suite │  Security   │ │
│  │   Agent     │   Agent    │   Agent     │ │
│  └─────────────┴────────────┴─────────────┘ │
│  All three must PASS                        │
└─────────────┬───────────────────────────────┘
              │
         PASS │ ◄── retries up to 3x on failure
              ▼
┌─────────────────────────────────────────────┐
│  Push branch → Open PR → Auto-merge        │
│  Notify via Slack / ntfy / email            │
└─────────────────────────────────────────────┘
```

Each issue gets up to 3 attempts (configurable). On each retry, failure feedback from the verification agents is fed back into the fix agent so it can correct its approach.

## Prerequisites

- [Claude CLI](https://docs.anthropic.com/en/docs/claude-cli) — installed and authenticated
- [GitHub CLI (`gh`)](https://cli.github.com/) — installed and authenticated (`gh auth login`)
- `git`, `jq`, `curl`
- Node.js >= 18

## Installation

Install globally from the git repo:

```bash
npm install -g github:wastrilith2k/fixer
```

Or clone and link locally:

```bash
git clone https://github.com/wastrilith2k/fixer.git
cd fixer
npm link
```

Verify everything is working:

```bash
fixer doctor
```

## Quick start

```bash
# 1. Set up config (interactive)
fixer init

# 2. Run on a repo — fixes all open issues labeled "bug"
fixer run octocat/hello-world

# 3. Or fix specific issues
fixer run octocat/hello-world 42 17
```

## CLI reference

```
fixer <command> [options]

Commands:
  init            Create a .fixer.json config file interactively
  run <repo> [#]  Run fixer against a repo (or use default from config)
  doctor          Check that all dependencies are installed and configured
  docker <repo>   Run fixer inside a Docker container
  help            Show help
```

### `fixer init`

Interactive setup wizard that creates a `.fixer.json` config file in the current directory. Prompts for:

- Default repository (`owner/repo`)
- Max retries per issue (default: 3)
- Auto-merge behavior (default: true)
- Notification method and credentials

### `fixer run`

The main command. Processes issues and opens PRs.

```bash
# Fix all open "bug" issues
fixer run octocat/hello-world

# Fix specific issues by number
fixer run octocat/hello-world 42 17

# Shorthand (omit "run" — auto-detected when first arg contains "/")
fixer octocat/hello-world 42
```

If a default repo is set in `.fixer.json`, you can omit it:

```bash
fixer run        # uses repo from config
fixer run 42 17  # specific issues from config repo
```

### `fixer doctor`

Checks that all required tools are installed and configured:

```
$ fixer doctor
[fixer] Checking dependencies...

[fixer]   gh — found
[fixer]   claude — found
[fixer]   git — found
[fixer]   jq — found
[fixer]   curl — found

[fixer]   gh auth — authenticated
[fixer]   config — .fixer.json

[fixer] All checks passed. You're good to go!
```

### `fixer docker`

Runs fixer inside a Docker container. Useful for CI or isolated environments. Requires Docker and a `code-container:latest` base image.

```bash
fixer docker octocat/hello-world 42
```

## Configuration

### Config file (`.fixer.json`)

Created by `fixer init`. Searched upward from the current directory (like `.eslintrc`).

```json
{
  "repo": "octocat/hello-world",
  "maxRetries": 3,
  "autoMerge": true,
  "notify": "slack",
  "slackWebhook": "https://hooks.slack.com/services/T.../B.../xxx"
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `repo` | `string` | — | Default `owner/repo` when none is passed as argument |
| `maxRetries` | `number` | `3` | Max fix attempts per issue before giving up |
| `autoMerge` | `boolean` | `true` | Enable auto-merge on PRs (squash, merges when CI passes) |
| `notify` | `string` | `"none"` | Notification method: `none`, `slack`, `ntfy`, `email`, or comma-separated combo |
| `slackWebhook` | `string` | — | Slack incoming webhook URL |
| `ntfyTopic` | `string` | — | [ntfy.sh](https://ntfy.sh) topic name |
| `smtpTo` | `string` | — | Recipient email address |
| `smtpFrom` | `string` | `fixer@localhost` | Sender email address |

### Environment variables

Environment variables take precedence over config file values. Useful for CI or one-off overrides.

| Variable | Config equivalent | Description |
|----------|-------------------|-------------|
| `REPOS_ROOT` | — | Root directory for cloned repos (default: `~/repos`) |
| `MAX_RETRIES` | `maxRetries` | Max fix attempts per issue |
| `AUTO_MERGE` | `autoMerge` | `"true"` or `"false"` |
| `KEEP_REPO` | — | `"true"` to keep the cloned repo after completion (default: `"false"`) |
| `NOTIFY_METHOD` | `notify` | Notification backend(s) |
| `SLACK_WEBHOOK` | `slackWebhook` | Slack webhook URL |
| `NTFY_TOPIC` | `ntfyTopic` | ntfy.sh topic |
| `SMTP_TO` | `smtpTo` | Recipient email |
| `SMTP_FROM` | `smtpFrom` | Sender email |
| `FIXER_LOG` | — | Log file path (default: `/tmp/fixer-<timestamp>.log`) |
| `FIXER_STATE_FILE` | — | Path to persistent state file (default: `~/.fixer/state.json`) |
| `CLAUDE_PERM` | — | Override Claude permission flags |
| `GH_TOKEN` | — | GitHub token (default: from `gh auth`) |
| `ANTHROPIC_API_KEY` | — | Anthropic API key (Docker mode) |

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

## Notifications

Fixer can notify you when PRs are created or when fixes fail. Configure via `fixer init` or set environment variables directly.

### Slack

```bash
export SLACK_WEBHOOK="https://hooks.slack.com/services/T.../B.../xxx"
fixer run octocat/hello-world
```

Or in `.fixer.json`:

```json
{
  "notify": "slack",
  "slackWebhook": "https://hooks.slack.com/services/T.../B.../xxx"
}
```

### ntfy

```bash
export NTFY_TOPIC="my-fixer-alerts"
export NOTIFY_METHOD="ntfy"
fixer run octocat/hello-world
```

### Email

Requires a working `sendmail` on the host.

```json
{
  "notify": "email",
  "smtpTo": "you@example.com",
  "smtpFrom": "fixer@example.com"
}
```

### Multiple methods

Comma-separate notification methods to use more than one:

```json
{
  "notify": "slack,ntfy"
}
```

## Docker

For isolated runs (CI pipelines, cron jobs), fixer includes Docker support. The container runs as a non-root user with full Claude permissions (no interactive prompts).

### Prerequisites

- Docker
- A `code-container:latest` base image (must include Claude CLI and Node.js)

### Usage

```bash
# Via the CLI
fixer docker octocat/hello-world

# Or directly
./run-container.sh octocat/hello-world 42
```

The container:

1. Builds the `fixer-agent` Docker image (auto-rebuilds when files change)
2. Mounts your `~/.claude` and `~/.claude.json` configs read-only
3. Copies them into the container user's home (fixes ownership)
4. Configures git credentials from `GH_TOKEN`
5. Runs `fixer.sh` with full permissions

### Environment variables for Docker

Pass these to `run-container.sh` or `fixer docker`:

```bash
GH_TOKEN="ghp_..." \
ANTHROPIC_API_KEY="sk-ant-..." \
MAX_RETRIES=5 \
NOTIFY_METHOD=slack \
SLACK_WEBHOOK="https://hooks.slack.com/..." \
fixer docker octocat/hello-world
```

## Architecture

```
fixer/
├── bin/fixer.js          # CLI entry point (Node.js, zero dependencies)
├── fixer.sh              # Core agent orchestrator (bash)
├── lib/
│   ├── state.sh          # Persistent state management (sourced by fixer.sh)
│   └── classify.sh       # Classify verdict parser (sourced by fixer.sh)
├── prompts/
│   ├── classify.txt      # Classify sub-agent prompt template
│   ├── fix.txt           # Fix agent prompt template
│   ├── review.txt        # Code review sub-agent prompt
│   ├── test.txt          # Test runner sub-agent prompt
│   └── security.txt      # Security review sub-agent prompt
├── tests/                # bats test suite (dev-only)
├── Dockerfile            # Container image definition
├── entrypoint.sh         # Container entrypoint (config setup)
├── run-container.sh      # Docker run wrapper
└── package.json
```

### Agent pipeline

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
7. **Verification** — three sub-agents run in parallel:
   - **Code review agent** — checks correctness, regressions, edge cases, scope
   - **Test runner agent** — runs the project's test suite
   - **Security agent** — scans the diff for vulnerabilities
8. If any verification fails, the feedback is appended to the fix prompt and the fix agent retries (up to `maxRetries`)
9. On success: **push**, **create PR**, **enable auto-merge**, **notify**

### Prompt templates

Prompts use `{{PLACEHOLDER}}` syntax for variable substitution. Available variables:

| Variable | Available in | Description |
|----------|-------------|-------------|
| `{{ISSUE_NUMBER}}` | classify, fix, review, test | GitHub issue number |
| `{{ISSUE_TITLE}}` | classify, fix, review, test | Issue title |
| `{{ISSUE_BODY}}` | classify, fix, review | Full issue body |
| `{{CODEBASE_CONTEXT}}` | classify, fix, review | Convention files, factory patterns, singletons |
| `{{VERIFICATION_CRITERIA}}` | fix, review, test | Parsed from `## Verification` section |
| `{{DIFF}}` | review, security | Git diff of changes |

You can customize the prompts by editing the files in `prompts/`.

## Examples

### Fix all bugs in a repo

```bash
fixer run octocat/hello-world
```

Fetches all open issues labeled `bug` and processes them sequentially.

### Fix specific issues

```bash
fixer run octocat/hello-world 42 17 88
```

### CI/CD integration

```yaml
# GitHub Actions example
name: Auto-fix bugs
on:
  schedule:
    - cron: '0 2 * * *'  # nightly at 2am
  workflow_dispatch:

jobs:
  fix:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: |
          npm install -g claude-cli
          npm install -g github:wastrilith2k/fixer

      - name: Run fixer
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          NOTIFY_METHOD: slack
          SLACK_WEBHOOK: ${{ secrets.SLACK_WEBHOOK }}
        run: fixer run ${{ github.repository }}
```

### Cron job with Docker

```bash
# Run nightly at 2am
0 2 * * * GH_TOKEN="ghp_..." ANTHROPIC_API_KEY="sk-ant-..." /usr/local/bin/fixer docker octocat/hello-world >> /var/log/fixer.log 2>&1
```

## Troubleshooting

### `fixer doctor` shows missing dependencies

Install the missing tools:

- **Claude CLI**: `npm install -g @anthropic-ai/claude-cli`
- **GitHub CLI**: See [cli.github.com](https://cli.github.com/)
- **jq**: `apt install jq` / `brew install jq`

### "Fix agent did not make any changes"

The fix agent couldn't determine what to change. This usually means:

- The issue description is too vague
- The bug is in a dependency, not the project code
- The codebase is too large for the agent to navigate

Try providing more detail in the issue body.

### "Could not enable auto-merge"

The target repo needs auto-merge enabled in GitHub settings and branch protection rules configured. You can disable auto-merge:

```json
{ "autoMerge": false }
```

### Permission errors

When running as root, fixer uses `--permission-mode acceptEdits` with an explicit tool allowlist. When running as a non-root user, it uses `--dangerously-skip-permissions`. Override with:

```bash
CLAUDE_PERM="--dangerously-skip-permissions" fixer run owner/repo
```

### Logs

Every run writes a log to `/tmp/fixer-<timestamp>.log` (or `FIXER_LOG` if set). On failure, sub-agent output is preserved in a temp directory printed at the end of the run.

## License

MIT
