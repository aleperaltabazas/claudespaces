#!/bin/bash
set -e

if [ -d /claudespaces/.claude ]; then
    mkdir -p ~/.claude
    cp -r /claudespaces/.claude/. ~/.claude/
fi

if [ -f /claudespaces/.claude.json ]; then
    cp /claudespaces/.claude.json ~/.claude.json
fi

exec /root/.local/bin/claude "$@"
