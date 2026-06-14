# Pass host UID via Docker build-arg

Replace runtime user creation in entrypoint with build-time user creation via --build-arg HOST_UID/HOST_GID. Container runs as the host user from the start. Tag images per-UID for cache correctness.