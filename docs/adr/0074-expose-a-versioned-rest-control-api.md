# Expose a versioned REST control API

V1 exposes `/api/v1` REST resources for task queries and controls, Automation Projects and configuration revisions, approvals and clarifications, and audit queries. OIDC service identities, the same RBAC policy, audit events, and idempotency keys protect API writes. GraphQL is outside V1.
