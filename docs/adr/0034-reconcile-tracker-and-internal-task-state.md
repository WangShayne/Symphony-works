# Reconcile tracker and internal task state

Tracker state and internal task state are reconciled in both directions. Human terminal, cancellation, and pause changes in Linear, GitHub, or GitLab take precedence and cause safe execution shutdown; models cannot reverse them. Internal milestones are mapped back through provider-configured states and progress updates.
