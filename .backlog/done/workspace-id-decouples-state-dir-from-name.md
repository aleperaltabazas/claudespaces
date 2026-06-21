# workspace id decouples state dir from name

rename currently moves the on-disk state dir, but containers' bind mounts still point at the old path so start fails. Add an immutable id field on Workspace, use it for the state dir path, and make rename pure metadata.