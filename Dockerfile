FROM code-container:latest

# Install gh CLI and jq (not included in code-container base)
RUN apt-get update && apt-get install -y --no-install-recommends jq \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user so --dangerously-skip-permissions works
# Copy claude installation + NVM node so claude works as non-root
RUN useradd -m -s /bin/bash fixer \
    && cp -r /root/.local /home/fixer/.local \
    && cp -r /root/.nvm /home/fixer/.nvm \
    && chown -R fixer:fixer /home/fixer/.local /home/fixer/.nvm \
    && rm -f /home/fixer/.local/bin/claude \
    && ln -s /home/fixer/.local/share/claude/versions/$(ls /root/.local/share/claude/versions/) /home/fixer/.local/bin/claude

# Ensure claude, node, gh, jq are all on PATH for the fixer user
ENV NVM_DIR="/home/fixer/.nvm"
ENV PATH="/home/fixer/.local/bin:/home/fixer/.nvm/versions/node/v22.22.1/bin:$PATH"

USER fixer
WORKDIR /home/fixer

COPY --chown=fixer:fixer fixer.sh /home/fixer/fixer.sh
COPY --chown=fixer:fixer prompts/ /home/fixer/prompts/

ENTRYPOINT ["/home/fixer/fixer.sh"]
