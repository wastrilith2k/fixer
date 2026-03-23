#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# run-container.sh — Run fixer agent inside a Docker container
#
# Usage: ./run-container.sh <owner/repo> [issue_number ...]
#
# Runs as non-root user so --dangerously-skip-permissions works (no prompts).
# Forwards GitHub and Anthropic auth + notification config into the container.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="fixer-agent"

# Rebuild image if Dockerfile or prompts changed
echo "[fixer] Building Docker image..."
docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"

# Get GH token
GH_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null || true)}"
if [[ -z "$GH_TOKEN" ]]; then
    echo "Error: GH_TOKEN not set and could not get token from gh auth" >&2
    exit 1
fi

# Get Anthropic API key from environment or Claude config
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    # Try to extract from Claude's config
    ANTHROPIC_API_KEY="$(jq -r '.apiKey // empty' ~/.claude/settings.json 2>/dev/null || true)"
fi

ENV_ARGS=(
    -e "GH_TOKEN=$GH_TOKEN"
    -e "REPOS_ROOT=/home/fixer/repos"
)

if [[ -n "$ANTHROPIC_API_KEY" ]]; then
    ENV_ARGS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
fi

# Mount Claude auth files (OAuth config + session data)
MOUNT_ARGS=()
if [[ -d "$HOME/.claude" ]]; then
    MOUNT_ARGS+=(-v "$HOME/.claude:/home/fixer/.claude:ro")
fi
if [[ -f "$HOME/.claude.json" ]]; then
    MOUNT_ARGS+=(-v "$HOME/.claude.json:/home/fixer/.claude.json:ro")
fi

# Forward optional config vars if set
for var in MAX_RETRIES NOTIFY_METHOD SLACK_WEBHOOK NTFY_TOPIC SMTP_TO SMTP_FROM AUTO_MERGE; do
    if [[ -n "${!var:-}" ]]; then
        ENV_ARGS+=(-e "$var=${!var}")
    fi
done

echo "[fixer] Running in container (non-root, full permissions)..."
docker run --rm \
    "${ENV_ARGS[@]}" \
    "${MOUNT_ARGS[@]}" \
    "$IMAGE_NAME" \
    "$@"
