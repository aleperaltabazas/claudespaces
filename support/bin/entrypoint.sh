#!/bin/bash
set -e

# Create non-root user matching host UID/GID if needed
if [ -n "$HOST_UID" ] && [ "$HOST_UID" != "0" ]; then
    HOST_GID="${HOST_GID:-$HOST_UID}"
    groupadd -g "$HOST_GID" claude 2>/dev/null || true
    useradd -m -u "$HOST_UID" -g "$HOST_GID" -s /bin/bash claude
    echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude
    chmod 0440 /etc/sudoers.d/claude
    mkdir -p /home/claude/.local/bin
    cp /root/.local/bin/claude /home/claude/.local/bin/claude
    chown -R claude:claude /home/claude
    export HOME=/home/claude
    EXEC_PREFIX="gosu claude"
    CLAUDE_BIN="/home/claude/.local/bin/claude"
else
    EXEC_PREFIX=""
    CLAUDE_BIN="/root/.local/bin/claude"
fi

mkdir -p "$HOME/.claude"

if [ -f /claudespaces/host/settings.json ]; then
    cp /claudespaces/host/settings.json "$HOME/.claude/settings.json"
fi

if [ -d /claudespaces/host/plugins ]; then
    mkdir -p "$HOME/.claude/plugins/"
    cp -r /claudespaces/host/plugins/. "$HOME/.claude/plugins/"
    # Fix host-absolute paths → container paths in plugin metadata files
    if [ -n "$HOST_HOME" ]; then
        for f in "$HOME/.claude/plugins/installed_plugins.json" "$HOME/.claude/plugins/known_marketplaces.json"; do
            if [ -f "$f" ]; then
                sed -i "s|${HOST_HOME}/.claude|${HOME}/.claude|g" "$f"
            fi
        done
    fi
fi

if [ -f /claudespaces/host/claude.json ]; then
    cp /claudespaces/host/claude.json "$HOME/.claude.json"
fi

if [ -f /claudespaces/host/credentials.json ]; then
    cp /claudespaces/host/credentials.json "$HOME/.claude/.credentials.json"
fi

# Add claudespaces bin to PATH so claudespaces-host is always findable
export PATH="/claudespaces/bin:$PATH"

# Inject shims for host bridge overrides
if [ -f /claudespaces/shims.json ]; then
    python3 - <<'PYEOF'
import json, os, stat

with open("/claudespaces/shims.json") as f:
    shims = json.load(f)

for binary, op_name in shims.items():
    path = f"/usr/local/bin/{binary}"
    orig = f"{path}.orig"
    if os.path.exists(path) and not os.path.islink(path):
        os.rename(path, orig)
    with open(path, "w") as f:
        f.write(f"#!/bin/sh\nclaudespaces-host {op_name} \"$@\"\n")
    os.chmod(path, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH)
PYEOF
fi

git config --global --add safe.directory '*'

IS_SANDBOX=1 exec $EXEC_PREFIX "$CLAUDE_BIN" \
    --allow-dangerously-skip-permissions \
    --dangerously-skip-permissions \
    --enable-auto-mode \
    --add-dir / "$@"
