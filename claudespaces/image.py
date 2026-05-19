import hashlib
import os
import re
import tempfile

import docker


def resolve_image(image: str | None, dockerfile: str | None, docker_client) -> str:
    if dockerfile is not None:
        if not os.path.exists(dockerfile):
            raise FileNotFoundError(f"Dockerfile not found: {dockerfile}")
        abs_path = os.path.abspath(dockerfile)
        path_slug = hashlib.md5(abs_path.encode()).hexdigest()[:12]
        base_tag = f"claudespaces-custom:{path_slug}"
        docker_client.images.build(
            path=os.path.dirname(abs_path),
            dockerfile=os.path.basename(abs_path),
            tag=base_tag,
        )
    elif image is not None:
        base_tag = image
    else:
        base_tag = "ubuntu:24.04"

    intermediate_tag = "claudespaces-base:" + re.sub(r"[:/]", "-", base_tag)

    try:
        docker_client.images.get(intermediate_tag)
        return intermediate_tag
    except docker.errors.ImageNotFound:
        pass

    # Claude Code is a Node.js package; install Node via NodeSource LTS, then npm install.
    # DEBIAN_FRONTEND=noninteractive prevents apt from blocking on timezone prompts.
    dockerfile_content = (
        f"FROM {base_tag}\n"
        "ENV DEBIAN_FRONTEND=noninteractive\n"
        "RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg && \\\n"
        "    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \\\n"
        "    apt-get install -y nodejs && \\\n"
        "    npm install -g @anthropic-ai/claude-code\n"
    )
    with tempfile.TemporaryDirectory() as tmpdir:
        with open(os.path.join(tmpdir, "Dockerfile"), "w") as f:
            f.write(dockerfile_content)
        _, logs = docker_client.images.build(path=tmpdir, tag=intermediate_tag)
        for entry in logs:
            pass  # consume generator so BuildError carries full log on failure

    return intermediate_tag
