# Decompose tasks into coordinated execution units

A tracked development task may be decomposed into multiple execution units, each assigned its own task type and task model. A durable coordination ledger is the sole source of truth for their messages, status, blockers, dependency changes, artifact references, and unified progress. Point-to-point notifications may improve responsiveness but cannot replace ledger entries, allowing coordination to survive process restarts.
