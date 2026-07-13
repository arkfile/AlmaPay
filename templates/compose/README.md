# Compose rendering

AlmaPay does not maintain textual YAML overlays in this directory. After upstream
generation, `scripts/compose_model.py` loads the Compose document as data,
applies the SCRAM and SSH-removal changes, pins every image to the lockfile's
linux/amd64 digest, and validates the resulting model.

Upstream pull/save helper scripts are discarded. This directory is retained for
future reviewed source fragments only.
