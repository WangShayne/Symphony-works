# Back up authoritative database state

V1 provides scheduled online SQLite backups and an Administrator-triggered Dashboard backup. Encrypted backup sets include configuration, coordination events and projections, audits, effect records, and encrypted secret values, but exclude the external master key, workspaces, and Git artifacts. Restore is an offline operation followed by full external-state reconciliation.
