# host bridge: allow containers to call host operations

Add a host_bridge mechanism that lets containers invoke a configurable set of host-side operations (e.g. notify-send) via a lightweight HTTP server spawned by claudespaces start. Supports built-in ops, user-defined ops in ~/.claudespaces/config.yml, async and sync execution, and transparent shim injection for binary overrides.