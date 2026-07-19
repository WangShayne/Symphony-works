# Make agent sessions replaceable

Normal continuation reuses an execution unit's Agent Session, but recovery does not depend on that session surviving. If it is lost, the service creates a new session from the coordination ledger, execution workspace, and unit context. Model-private conversation state cannot be the sole record of decisions or progress.
