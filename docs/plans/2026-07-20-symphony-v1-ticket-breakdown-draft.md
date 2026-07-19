# Symphony V1 Ticket Breakdown — Draft

Status: approved and published as GitHub Issues #1–#25 on 2026-07-20. See `docs/plans/2026-07-20-symphony-v1-ticket-publication.md`.

Source: `docs/plans/2026-07-20-symphony-v1.md` and `docs/design/v1-design-baseline.md`.

## 01 — Promote the pinned upstream baseline

**Blocked by:** None — can start immediately.

**What it delivers:** A green, provenance-preserving Symphony repository at the product root, including upstream license/source attribution, existing Elixir tests, Git initialization, an isolated implementation worktree, and a parity inventory showing which upstream modules will be retained, adapted, replaced, or retired.

## 02 — Activate the first persistent Automation Project

**Blocked by:** 01 — Promote the pinned upstream baseline.

**What it delivers:** An Administrator can create, validate, and atomically activate one database-backed Automation Project through a minimal Dashboard and REST path, and the active revision survives service restart. This tracer establishes Ecto/SQLite, the initial configuration document, a minimal bootstrap identity, and the control-plane seam without yet adding provider credentials.

## 03 — Manage the complete configuration revision lifecycle

**Blocked by:** 02 — Activate the first persistent Automation Project.

**What it delivers:** Administrators can edit drafts, validate, activate, roll back, import an upstream `WORKFLOW.md`, export redacted configuration, use starter task/profile templates, and prove that a running-task pin remains on its original immutable revision.

## 04 — Store and broker credentials without exposing plaintext

**Blocked by:** 02 — Activate the first persistent Automation Project.

**What it delivers:** Administrators can create and replace secrets through Dashboard/API forms, configuration stores only opaque references, provider probes receive credentials through a broker, exports and logs never reveal plaintext, and master-key rotation preserves all references.

## 05 — Authenticate and authorize team operations

**Blocked by:** 02 — Activate the first persistent Automation Project; 04 — Store and broker credentials without exposing plaintext.

**What it delivers:** Team members sign in through OIDC, service identities call the REST API, Viewer/Operator/Administrator permissions protect existing configuration actions, and the one-time bootstrap Administrator disappears after OIDC activation. English and Simplified Chinese navigation share the same authorization policy.

## 06 — Configure and health-check Runtime and model profiles

**Blocked by:** 03 — Manage the complete configuration revision lifecycle; 04 — Store and broker credentials without exposing plaintext.

**What it delivers:** An Administrator can configure Codex-compatible model providers, Model References, prices, Routing and Execution Profiles, run capability/structured-output health probes, and activate only compatible bindings. The same Runtime contract is demonstrated with deterministic simulated and Codex adapters.

## 07 — Exercise a bounded Runner contract without Docker

**Blocked by:** 01 — Promote the pinned upstream baseline; 02 — Activate the first persistent Automation Project.

**What it delivers:** The control plane can create, inspect, execute in, and stop a simulated sandbox through a narrow operation-ID-based Runner interface, while a health surface proves that no arbitrary host command or Docker socket access is available to the Phoenix application.

## 08 — Configure normalized Tracker and Source Control seams

**Blocked by:** 03 — Manage the complete configuration revision lifecycle; 04 — Store and broker credentials without exposing plaintext; 05 — Authenticate and authorize team operations.

**What it delivers:** Administrators configure provider-neutral Tracker and Source Control integrations, validate them against deterministic fixtures, see redacted health evidence, and prove that Issues are task inputs while PRs/MRs are delivery artifacts. Linear behavior remains available behind the normalized Tracker seam.

## 09 — Persist and recover a task through the Coordination Ledger

**Blocked by:** 02 — Activate the first persistent Automation Project; 05 — Authenticate and authorize team operations.

**What it delivers:** An authenticated API action creates a task, appends immutable coordination and audit events, updates task/unit projections, journals a simulated external effect, renders the task after restart, and refuses a second active orchestrator lease. Unknown effect outcomes reconcile before retry.

## 10 — Run the simulated single-unit walking skeleton

**Blocked by:** 06 — Configure and health-check Runtime and model profiles; 07 — Exercise a bounded Runner contract without Docker; 08 — Configure normalized Tracker and Source Control seams; 09 — Persist and recover a task through the Coordination Ledger.

**What it delivers:** One eligible simulated Issue is matched to an Automation Project, pins configuration and baseline, receives a schema-valid routing plan with one execution unit, runs through simulated Runtime/Runner/Tracker/SCM adapters, records acceptance evidence, and appears as accepted in the live task view.

## 11 — Run an execution unit in an isolated Docker sandbox

**Blocked by:** 07 — Exercise a bounded Runner contract without Docker; 10 — Run the simulated single-unit walking skeleton.

**What it delivers:** The walking skeleton executes inside a digest-pinned Docker container with bounded CPU, memory, processes, mounts, timeout, output, and two-level network policy. Runner restart rediscovers labeled sandboxes, while the control plane still lacks Docker socket access.

## 12 — Route and coordinate a multi-unit task

**Blocked by:** 10 — Run the simulated single-unit walking skeleton; 11 — Run an execution unit in an isolated Docker sandbox.

**What it delivers:** A mixed development task is decomposed into typed frontend/backend/documentation units, including a safe Dynamic Task Type when necessary; dependencies govern sequential/parallel execution, units exchange ledger-backed messages and artifact references, relevant Unit Context is projected, and the Dashboard shows one unified plan and progress view.

## 13 — Integrate accepted units through isolated Git worktrees

**Blocked by:** 08 — Configure normalized Tracker and Source Control seams; 11 — Run an execution unit in an isolated Docker sandbox; 12 — Route and coordinate a multi-unit task.

**What it delivers:** All units start from one pinned Task Baseline, modify isolated branches/worktrees, pass Unit Acceptance, and integrate mechanically into one task branch. A conflict is recorded and converted into an Integration Execution Unit instead of being resolved inline or losing concurrent work.

## 14 — Resolve approvals, clarifications, and Operator corrections

**Blocked by:** 05 — Authenticate and authorize team operations; 09 — Persist and recover a task through the Coordination Ledger; 12 — Route and coordinate a multi-unit task.

**What it delivers:** Units can request a one-time bounded permission or human clarification, affected work pauses without stopping unrelated units, authenticated team roles resolve requests from Dashboard/API, Operator corrections trigger a new plan revision rather than direct plan edits, and signed webhook notifications remain redacted.

## 15 — Call a governed MCP tool from an execution unit

**Blocked by:** 04 — Store and broker credentials without exposing plaintext; 06 — Configure and health-check Runtime and model profiles; 11 — Run an execution unit in an isolated Docker sandbox; 14 — Resolve approvals, clarifications, and Operator corrections.

**What it delivers:** An Administrator registers an MCP connector and Tool Group, validates capability discovery, grants the group to an Execution Profile, and observes one unit call the tool with brokered credentials, bounded output, effect journaling, audit evidence, and no ability to invoke unregistered capabilities.

## 16 — Enforce budgets, retries, fallbacks, and immutable replanning

**Blocked by:** 06 — Configure and health-check Runtime and model profiles; 09 — Persist and recover a task through the Coordination Ledger; 12 — Route and coordinate a multi-unit task; 14 — Resolve approvals, clarifications, and Operator corrections; 15 — Call a governed MCP tool from an execution unit.

**What it delivers:** System/task/unit cost, token, and time budgets govern scheduling; priority and age fairly allocate layered capacity; transient failures retry with limits; Runtime/model unavailability uses the correct fallback role; acceptance failure triggers replanning; and accepted integrated results remain immutable across plan revisions.

## 17 — Deliver through Draft, Ready, and observed merge

**Blocked by:** 13 — Integrate accepted units through isolated Git worktrees; 16 — Enforce budgets, retries, fallbacks, and immutable replanning.

**What it delivers:** Using deterministic Source Control, the first accepted integration creates one Draft Change Request, final target synchronization and Task Acceptance make it Ready, target/CI drift revokes readiness, and only a simulated human merge completes the Issue and cleans successful workspaces. The system exposes no merge command.

## 18 — Operate tasks through the complete Dashboard and REST API

**Blocked by:** 14 — Resolve approvals, clarifications, and Operator corrections; 16 — Enforce budgets, retries, fallbacks, and immutable replanning; 17 — Deliver through Draft, Ready, and observed merge.

**What it delivers:** Viewers and Operators use bilingual task list/detail pages, plan graph, unit/context/evidence/budget panels, intervention queues, live updates, and versioned idempotent REST controls without bypassing deep module interfaces or exposing sensitive task content.

## 19 — Run the GitHub Issue-to-PR tracer

**Blocked by:** 08 — Configure normalized Tracker and Source Control seams; 17 — Deliver through Draft, Ready, and observed merge; 18 — Operate tasks through the complete Dashboard and REST API.

**What it delivers:** A real or fixture-backed eligible GitHub Issue enters through signed webhook/poll reconciliation, maintains one Progress Comment, executes the full coordinated flow, creates and monitors one GitHub Draft PR, becomes Ready only after validation, and completes only after an observed human merge.

## 20 — Run the GitLab Issue-to-MR tracer

**Blocked by:** 08 — Configure normalized Tracker and Source Control seams; 17 — Deliver through Draft, Ready, and observed merge; 18 — Operate tasks through the complete Dashboard and REST API.

**What it delivers:** A real or fixture-backed eligible GitLab Issue enters through signed webhook/poll reconciliation, maintains one Progress Comment, executes the full coordinated flow, creates and monitors one GitLab Draft MR, becomes Ready only after validation, and completes only after an observed human merge.

## 21 — Run the Linear-to-code-host mixed-provider tracer

**Blocked by:** 19 — Run the GitHub Issue-to-PR tracer; 20 — Run the GitLab Issue-to-MR tracer.

**What it delivers:** A Linear Issue maps through one Automation Project to a separately configured GitHub or GitLab repository, respects Linear blockers and human state changes, publishes one Linear Progress Comment, and delivers through the already-proven PR/MR lifecycle without assuming tracker and code host are the same provider.

## 22 — Operate audit, observability, retention, and backup

**Blocked by:** 09 — Persist and recover a task through the Coordination Ledger; 11 — Run an execution unit in an isolated Docker sandbox; 16 — Enforce budgets, retries, fallbacks, and immutable replanning; 18 — Operate tasks through the complete Dashboard and REST API.

**What it delivers:** Administrators use Dashboard/API operations to search redacted audits, inspect correlated OpenTelemetry health/cost/retry metrics, run encrypted online backup and offline restore, configure category retention, and verify that active tasks are preserved while every deletion and privileged operation is audited.

## 23 — Ship the single-host self-hosted deployment lifecycle

**Blocked by:** 05 — Authenticate and authorize team operations; 11 — Run an execution unit in an isolated Docker sandbox; 17 — Deliver through Draft, Ready, and observed merge; 22 — Operate audit, observability, retention, and backup.

**What it delivers:** Official control-plane and Runner images, Docker Compose, volumes, health checks, an operations-focused CLI, one-time admin bootstrap, hourly backup schedule, and drained upgrade/rollback scripts run on one Linux Docker host while only the Runner mounts the Docker socket.

## 24 — Prove recovery, security, and single-host capacity

**Blocked by:** 19 — Run the GitHub Issue-to-PR tracer; 20 — Run the GitLab Issue-to-MR tracer; 21 — Run the Linear-to-code-host mixed-provider tracer; 23 — Ship the single-host self-hosted deployment lifecycle.

**What it delivers:** Restart and unknown-effect fault injection prove automatic nonterminal recovery and no duplicate side effects; prompt-injection, credential, authorization, container, and network tests prove trust boundaries; restore rehearsal proves one-hour RPO/thirty-minute RTO; and load evidence proves 100 active tasks, 20 concurrent units, 10,000 retained tasks, and sub-two-second Dashboard P95 on the reference host.

## 25 — Publish complete V1 release evidence

**Blocked by:** 24 — Prove recovery, security, and single-host capacity.

**What it delivers:** Full Elixir/Runner quality gates, Compose and security scans, opt-in real Codex plus Linear/GitHub/GitLab smoke tests, English/Chinese manual QA, updated SPEC/READMEs/operator/migration/API docs, and a requirement-by-requirement evidence index proving every confirmed design section and ADR before an Apache-2.0 V1 release.

## Approval record

The user approved all 25 tickets as drafted. They were published in dependency order with the `ready-for-agent` label, textual blocker references, and GitHub native issue dependencies.
