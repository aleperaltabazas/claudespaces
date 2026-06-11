# git usable inside container

## Problem

Mounting ~/.gitconfig into the container gives Claude the user's git identity (name, email) but git still refuses to operate on workspace repos:

  fatal: detected dubious ownership in repository at '/workspace/my-project'

Root cause: git's safe-directory check (CVE-2022-24765). The workspace files are owned by the host user (e.g. UID 1000) but the container runs as root (UID 0). Git considers any repo whose directory owner differs from the current process UID as untrusted and refuses all operations.

## Possible fixes

### Option A – Inject safe.directory via entrypoint (simplest)
In entrypoint.sh, after the existing setup, add:
  git config --global --add safe.directory '*'
or, more surgically, enumerate /workspace/* and add each as a safe.directory entry.
This is a one-liner change to entrypoint.sh and requires no new config surface. The wildcard form ('*') is what GitHub Actions uses in their runners for the same reason. Downside: it suppresses a real security check, though in a container already running with --allow-dangerously-skip-permissions that's not a meaningful regression.

### Option B – Run container as the host user (most correct)
Pass the host UID/GID to container.create_container and use docker's user= option to run as that UID instead of root. This makes file ownership match and the safe-directory check passes naturally.
Challenges: the image is built expecting root (e.g., /root/.local/bin/claude); running as an arbitrary UID requires the image to have that user configured, or the entrypoint to create it. More invasive.

### Option C – Bridge git through the host (sidesteps the problem)
Add a 'git' shim operation to the host bridge. Claude's git calls get forwarded to the host where the UID matches. Path translation is needed: /workspace/<basename> in the container must be mapped back to the real host path. The workspace record already stores the host dirs list, so this mapping is feasible but non-trivial to implement correctly for subpaths. Also does not help if something other than Claude (e.g., a script) calls git directly.

### Option D – Mount .gitconfig with a safe.directory override already in it
Document that users should add the following to their ~/.gitconfig before using additional-mounts to share it:
  [safe]
    directory = *
Requires no code changes but pushes the burden to the user.

## Recommendation
Option A is the right first step: one-line entrypoint change, no new config surface, works immediately for all workspace mounts. Option B is the 'correct' long-term solution if running as non-root becomes desirable for other reasons.