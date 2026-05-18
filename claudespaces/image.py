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

    dockerfile_content = (
        f"FROM {base_tag}\n"
        "RUN apt-get update && apt-get install -y curl && \\\n"
        "    curl -fsSL https://claude.ai/install.sh | sh\n"
    )
    with tempfile.TemporaryDirectory() as tmpdir:
        with open(os.path.join(tmpdir, "Dockerfile"), "w") as f:
            f.write(dockerfile_content)
        docker_client.images.build(path=tmpdir, tag=intermediate_tag)

    return intermediate_tag
