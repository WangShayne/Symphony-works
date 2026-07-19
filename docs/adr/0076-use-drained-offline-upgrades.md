# Use drained offline upgrades

V1 upgrades may use planned downtime. The operation runs preflight health checks and backup, stops intake, drains or safely interrupts active units, applies database migrations, restarts, and reconciles external state. Zero-downtime rolling upgrades are not promised, but each release documents rollback constraints and recovery steps.
