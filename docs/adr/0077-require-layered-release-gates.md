# Require layered release gates

V1 releases require unit and property tests for state, budgets, plan schemas, and projections; contract tests for Tracker, source-control, Runtime, Runner, and MCP boundaries; integration tests for SQLite recovery, effect idempotency, and migrations; opt-in end-to-end smoke tests with test projects and real Codex; and dependency, image, secret-leak, and permission-boundary security scans.
