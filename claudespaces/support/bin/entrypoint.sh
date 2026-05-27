#!/bin/bash
set -e

mkdir -p ~/.claude

if [ -f /claudespaces/host/settings.json ]; then
    cp /claudespaces/host/settings.json ~/.claude/settings.json
fi

if [ -d /claudespaces/host/plugins ]; then
    cp -r /claudespaces/host/plugins/. ~/.claude/plugins/
    # Fix host-absolute installPath → /root/.claude/...
    if [ -f ~/.claude/plugins/installed_plugins.json ] && [ -n "$HOST_HOME" ]; then
        sed -i "s|${HOST_HOME}/.claude|${HOME}/.claude|g" ~/.claude/plugins/installed_plugins.json
    fi
fi

if [ -f /claudespaces/host/credentials.json ]; then
    cp /claudespaces/host/credentials.json ~/.claude/.credentials.json
fi

IS_SANDBOX=1 exec /root/.local/bin/claude \
    --allow-dangerously-skip-permissions \
    --dangerously-skip-permissions \
    --enable-auto-mode \
    --add-dir / "$@"
