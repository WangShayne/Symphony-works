# Validate configuration before atomic activation

A configuration revision cannot become active until schema, reference integrity, permission ceilings, budget relationships, secret resolution, and Tracker, source-control, model, Runtime, and tool health checks pass. Activation is atomic, prior revisions remain available for rollback, and already running tasks retain their pinned revision.
