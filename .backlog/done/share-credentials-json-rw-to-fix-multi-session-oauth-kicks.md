# share .credentials.json rw to fix multi-session OAuth kicks

OAuth refresh tokens rotate per use. Each workspace had its own copy of .credentials.json so rotation in one container invalidated the others. Bind-mount the host file rw directly into ~/.claude/.credentials.json instead of copying via /claudespaces/host/.