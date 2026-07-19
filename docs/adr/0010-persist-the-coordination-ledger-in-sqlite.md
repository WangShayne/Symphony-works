# Persist the coordination ledger in SQLite

V1 will persist immutable coordination events in local SQLite and derive rebuildable progress projections from them. This fits the single-instance operating model and keeps deployment and recovery simple; the storage boundary remains replaceable so a future multi-instance version can adopt PostgreSQL without changing coordination semantics.
