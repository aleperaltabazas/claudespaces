#!/bin/bash
set -e

mkdir -p ~/.claude

if [ -f /claudespaces/host/settings.json ]; then
    cp /claudespaces/host/settings.json ~/.claude/settings.json
fi

if [ -d /claudespaces/host/plugins ]; then
    mkdir -p ~/.claude/plugins/
    cp -r /claudespaces/host/plugins/. ~/.claude/plugins/
    # Fix host-absolute paths → container paths in plugin metadata files
    if [ -n "$HOST_HOME" ]; then
        for f in ~/.claude/plugins/installed_plugins.json ~/.claude/plugins/known_marketplaces.json; do
            if [ -f "$f" ]; then
                sed -i "s|${HOST_HOME}/.claude|${HOME}/.claude|g" "$f"
            fi
        done
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
