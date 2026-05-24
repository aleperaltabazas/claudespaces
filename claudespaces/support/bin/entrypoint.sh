#!/bin/bash
set -e

if [ -d /claudespaces/.claude ]; then
    mkdir -p ~/.claude
    cp -r /claudespaces/.claude/. ~/.claude/
fi

if [ -f /claudespaces/.claude.json ]; then
    cp /claudespaces/.claude.json ~/.claude.json
fi

IS_SANDBOX=1 exec /root/.local/bin/claude --allow-dangerously-skip-permissions --dangerously-skip-permissions --enable-auto-mode --add-dir / "$@"
