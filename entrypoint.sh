#!/usr/bin/env bash
set -euo pipefail

# Copy mounted root-owned config files to fixer user's home and fix ownership
# This solves the volume mount permission issue when host files are owned by root

if [[ -f /mnt/claude-config/.claude.json ]]; then
    cp /mnt/claude-config/.claude.json "$HOME/.claude.json"
    chmod 600 "$HOME/.claude.json"
fi

if [[ -d /mnt/claude-config/.claude ]]; then
    cp -r /mnt/claude-config/.claude "$HOME/.claude"
    chmod -R u+rw "$HOME/.claude"
fi

# Configure git to use GH_TOKEN for auth (no SSH needed)
if [[ -n "${GH_TOKEN:-}" ]]; then
    git config --global credential.helper '!f() { echo "password=$GH_TOKEN"; }; f'
    git config --global url."https://github.com/".insteadOf "git@github.com:"
fi

git config --global user.name "${GIT_USER_NAME:-fixer-agent}"
git config --global user.email "${GIT_USER_EMAIL:-fixer@localhost}"

exec /home/fixer/fixer.sh "$@"
