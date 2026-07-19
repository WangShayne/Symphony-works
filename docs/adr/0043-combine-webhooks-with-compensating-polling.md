# Combine webhooks with compensating polling

Tracker webhooks provide low-latency reconciliation signals, while periodic polling recovers missed events, dependency changes, and updates made during downtime. Both paths enter one idempotent reconciliation flow and cannot independently create duplicate tracked tasks.
