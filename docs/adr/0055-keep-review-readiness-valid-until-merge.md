# Keep review readiness valid until merge

The service monitors a Ready change request until merge. New target-branch commits, required CI failures, or task-branch changes revoke Review Readiness, return the task to Draft or Validating, and require synchronization and task acceptance again before readiness can be restored.
