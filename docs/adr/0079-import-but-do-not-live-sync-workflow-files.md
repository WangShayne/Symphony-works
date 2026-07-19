# Import but do not live-sync workflow files

V1 provides a one-time importer that converts an upstream `WORKFLOW.md` into an Automation Project, tracker and workspace settings, a general task type, an execution profile, Codex model configuration, and prompt instructions. After import the database is authoritative; the file is neither hot-reloaded nor synchronized back into runtime configuration.
