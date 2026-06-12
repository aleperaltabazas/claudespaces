# Run as host user

Claude in container gets started as root. This makes it that new files are created as root and thus gives permission errors in the host then.