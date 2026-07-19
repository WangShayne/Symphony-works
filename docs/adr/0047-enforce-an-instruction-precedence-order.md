# Enforce an instruction precedence order

Execution follows system security policy, then pinned configuration and execution profile, then repository guidance, and finally Issue content. Repository files such as `AGENTS.md` may define coding, testing, and workflow expectations but cannot add tools, network access, credentials, or filesystem permissions beyond higher-level policy.
