# Audit control and routing decisions

Configuration activation, secret changes, task controls, task migration, routing decisions, and fallback activation produce immutable audit events with actor, time, target, configuration revision, outcome, and a redacted change summary. Secret values and complete sensitive prompts are forbidden from audit records; operational logs do not substitute for the audit trail.
