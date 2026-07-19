# Isolate execution-unit workspaces

Each execution unit receives an isolated worktree and branch rather than sharing a writable task directory. Accepted unit results are integrated, in dependency order, into one task integration branch. The orchestrator performs conflict-free merges mechanically; merge conflicts or post-merge acceptance failures are recorded in the coordination ledger and assigned to a dedicated integration execution unit. Ordinary task models cannot privately merge other units' branches.
