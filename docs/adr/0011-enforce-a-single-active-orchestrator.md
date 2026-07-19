# Enforce a single active orchestrator

V1 permits only one active orchestrator for a coordination ledger and workspace root. Startup must acquire exclusive ownership and a competing instance must fail clearly rather than schedule concurrently. Cross-instance claims, distributed locks, and automatic high-availability failover are outside the V1 boundary.
