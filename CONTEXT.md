# Development Automation

Symphony coordinates unattended execution of development work received through task trackers.

## Language

**Automation Project**:
The top-level configuration and scheduling boundary that binds a tracker scope, one repository, target branch, model roles, task types, execution profiles, budgets, and task acceptance rules.
_Avoid_: Repository, tracker project

**Development Orchestration Service**:
The unattended system that coordinates tracked development work from intake through completion.
_Avoid_: Interactive assistant, local command runner

**Active Orchestrator**:
The sole service instance authorized to schedule work and write the coordination ledger for one workspace scope.
_Avoid_: Concurrent scheduler, standby writer

**Tracked Development Task**:
A unit of development work accepted from a Linear, GitHub, or GitLab issue for automated execution.
_Avoid_: Prompt, chat request

**Task State**:
One of the service-defined lifecycle states for a tracked task; models may explain it but cannot create additional states.
_Avoid_: Provider-native state, model status text

**Change Request**:
The pull request or merge request that exposes a tracked task's integrated result as a draft after its first accepted change and becomes review-ready only after task acceptance; the service does not merge it.
_Avoid_: Tracked development task

**Task Tracker**:
The external system that supplies and records tracked development tasks.
_Avoid_: User interface, command line

**Tracker Adapter**:
The integration that maps one tracker provider's work objects and state transitions into the service's common tracked-task language.
_Avoid_: Provider-specific orchestration

**Tracker Reconciliation**:
The two-way alignment between provider issue state and internal task state in which human terminal, cancellation, or pause actions take precedence over automation.
_Avoid_: Model-owned issue state

**Reconciliation Signal**:
A webhook or polling observation that requests the same idempotent tracker reconciliation without directly creating duplicate work.
_Avoid_: Task creation command

**Progress Comment**:
The single update-in-place Issue comment summarizing the current plan, unit progress, blockers, budget, and change-request link from durable coordination state.
_Avoid_: Coordination ledger, event-per-comment feed

**Intervention Notification**:
A Dashboard and webhook event emitted when a task requires human action because of approval, budget, persistent failure, invalid configuration, or blocking.
_Avoid_: Routine progress update

**Source Control Adapter**:
The integration that manages repositories, branches, commits, and change requests on a code-hosting provider independently of the selected task tracker.
_Avoid_: Tracker adapter

**Repository Scope**:
The single source repository assigned to one tracked development task and containing its execution workspaces, integration branch, and change request.
_Avoid_: Cross-repository task

**Task Baseline**:
The target-branch commit pinned when a tracked task begins and shared by routing, execution workspaces, and the task integration branch until an explicit rebaseline.
_Avoid_: Moving target branch

**Final Synchronization**:
The required update of the task integration branch to the latest target branch followed by renewed task acceptance before a change request becomes review-ready.
_Avoid_: Stale validation

**Task Dependency**:
A provider-declared relationship in which an unfinished tracked Issue prevents another tracked development task from entering execution.
_Avoid_: Execution-unit dependency, model-created tracker link

**Task Eligibility**:
The automation-project rule requiring an Issue to match allowed states, opt-in labels, scope, and optional assignee criteria, with exactly one project match.
_Avoid_: Any open Issue, model-selected intake

**Routing Model**:
The user-configured model that decides how a tracked development task is dispatched without executing the work itself.
_Avoid_: Main model, default model

**Routing Profile**:
The read-only execution contract that lets the routing model inspect task, ledger, and repository context through an Agent Runtime without modifying artifacts or using high-risk tools.
_Avoid_: Execution profile

**Task Type**:
A category of development work used by the routing model to classify and dispatch execution units; it may be user-configured or created dynamically by the routing model.
_Avoid_: Tracker label

**Dynamic Task Type**:
A task type created by the routing model during planning because the current task requires a category not already configured by the user; it exists only within that tracked development task unless a user promotes it.
_Avoid_: Persisted user configuration

**Task Type Promotion**:
The user-approved conversion of a recurring dynamic task type into a persisted, user-configured task type.
_Avoid_: Automatic learning

**Dynamic Type Template**:
The user-configured security and resource ceiling from which every dynamic task type derives its execution profile.
_Avoid_: Unrestricted generated configuration

**Task Model**:
A model reference selected by an execution profile for its agent runtime.
_Avoid_: Routing model

**Agent Runtime**:
The pluggable execution environment that manages model sessions, tool use, filesystem changes, and sandbox behavior for execution units.
_Avoid_: Model, model provider

**Agent Session**:
A reusable but replaceable runtime conversation for one execution unit; it is not authoritative state and may be reconstructed from durable task context.
_Avoid_: Coordination ledger, recovery checkpoint

**Model Reference**:
The configuration that identifies a model provider, model ID, endpoint, and credential reference for use by an agent runtime.
_Avoid_: Agent runtime, embedded credential

**Model Provider**:
An administrator-configured built-in or custom endpoint compatible with the selected Agent Runtime's provider protocol and validated before activation.
_Avoid_: Arbitrary chat API

**Model Capability Contract**:
The validated set of context, structured-output, tool, vision, and other capabilities a model reference must satisfy for its routing or execution profile.
_Avoid_: Unverified provider claim

**Model Price Snapshot**:
The input, cached-input, and output unit prices pinned with a task's configuration revision for stable cost accounting.
_Avoid_: Current provider price

**Secret Reference**:
An opaque identifier used by configuration revisions to refer to encrypted credentials without containing their plaintext value.
_Avoid_: API key, environment value

**Secret Store**:
The encrypted database-backed store for credentials entered through the Dashboard, protected by a master key held outside the database.
_Avoid_: Configuration store, plaintext settings

**Credential Broker**:
The trusted service boundary that resolves secret references and injects credentials into outbound tool or provider calls without revealing values to models or agent runtimes.
_Avoid_: Prompt variable, agent environment secret

**Viewer**:
A team member permitted to inspect tasks, plans, progress, and outcomes without changing execution or configuration.
_Avoid_: Operator, administrator

**Operator**:
A team member permitted to control task execution without managing configuration or secrets.
_Avoid_: Administrator

**Operator Instruction**:
An audited constraint or correction submitted to a paused task that triggers replanning without directly mutating its execution plan.
_Avoid_: Manual plan edit

**Trusted Control Input**:
An authenticated Dashboard action authorized by role and recorded in the audit trail; ordinary tracker content cannot act as a control command.
_Avoid_: Issue comment, model output

**Control API**:
The versioned REST surface that applies the same identity, role, audit, and idempotency rules as Dashboard task and configuration operations.
_Avoid_: Unauthenticated webhook, model tool

**Untrusted Task Content**:
Issue text, repository content, fetched pages, or tool output supplied as task material that cannot override control, permission, or configuration policy.
_Avoid_: Trusted control input

**Repository Guidance**:
Repository-provided project instructions that may constrain implementation and validation within, but never widen, the pinned execution profile or system security policy.
_Avoid_: Permission policy, trusted control input

**Security Event**:
An audited detection of attempted policy override, credential extraction, or other suspicious behavior in untrusted task content.
_Avoid_: Task failure

**Administrator**:
A team member permitted to activate configuration revisions and manage integrations, identities, and secrets.
_Avoid_: Operator

**Permission Request**:
An execution unit's audited request for a one-time, narrowly scoped capability beyond its pinned execution profile, requiring administrator approval.
_Avoid_: Automatic privilege escalation

**Clarification Request**:
An execution unit's request for an operator decision when proceeding would require an unsafe assumption, pausing only affected work until the answer is recorded.
_Avoid_: Model guess, permission request

**Audit Event**:
An immutable, redacted record of a human or automated control decision, identifying the actor, target, configuration revision, outcome, and change summary.
_Avoid_: Coordination event, application log

**Execution Trace**:
The correlated observability view connecting a task, plan revision, execution unit, model call, and tool call without treating telemetry as domain state.
_Avoid_: Coordination ledger, audit trail

**Retention Policy**:
The administrator-configured lifetime for completed coordination detail, audit events, and telemetry, with active task state retained and every deletion audited.
_Avoid_: Git artifact retention

**Backup Set**:
An encrypted SQLite snapshot containing configuration, coordination, audit, and encrypted secret values but excluding the external master key and Git workspaces.
_Avoid_: Source-code backup

**Execution Profile**:
The user-configured execution contract for a task type, covering its agent runtime, task model, instructions, available tools, permissions, budgets, concurrency limits, and acceptance rules.
_Avoid_: Model mapping, task label

**Execution Budget**:
The hierarchical cost, token, and elapsed-time limits applied at system, task, and execution-unit levels, with lower levels unable to exceed their parent ceiling.
_Avoid_: Usage estimate

**Runnable Execution Unit**:
An execution unit whose dependencies are satisfied and that is eligible to compete for constrained execution capacity.
_Avoid_: Pending unit, blocked unit

**Scheduling Priority**:
The ordering of runnable units by tracker priority and then waiting time, subject to system, provider, profile, repository, and task-integration concurrency limits.
_Avoid_: Model-selected urgency

**Tool Connector**:
An administrator-registered MCP server or external tool integration exposed through controlled capability discovery, health checks, auditing, and credential brokering.
_Avoid_: Model-created connection

**Tool Group**:
A named allowlist of registered tool capabilities that an execution profile may grant to its execution units.
_Avoid_: Unrestricted tool access

**Execution Plan**:
The versioned, schema-valid description of execution units, task types, profiles, dependencies, acceptance targets, and dynamic type definitions for one tracked development task.
_Avoid_: Independent agent plans

**Plan Revision**:
An immutable version of an execution plan created initially or in response to a rescheduling event; it preserves accepted results while replacing only pending or invalidated work.
_Avoid_: In-place plan mutation

**Execution Unit**:
An individually dispatched part of a tracked development task, assigned one task type and its execution profile while remaining coordinated through the shared execution plan.
_Avoid_: Separate task, isolated agent

**Execution Unit State**:
One of the service-defined lifecycle states controlling whether an execution unit is pending, runnable, running, blocked, awaiting approval, accepted, failed, or cancelled.
_Avoid_: Free-form progress text

**Execution Workspace**:
The isolated worktree and branch in which one execution unit changes task artifacts without sharing uncommitted state with other units.
_Avoid_: Shared task directory

**Workspace Retention**:
The terminal-state policy that removes successful local workspaces immediately and keeps failed or cancelled workspaces read-only for a configurable diagnostic period.
_Avoid_: Coordination-data retention

**Execution Sandbox**:
The production container that isolates one execution unit's workspace, processes, resources, and network access from the host and other units.
_Avoid_: Host process, shared container

**Execution Image**:
The digest-pinned OCI image selected by an Automation Project or Execution Profile as the reproducible base of an execution sandbox.
_Avoid_: Mutable image tag, shared live environment

**Runner Service**:
The host-local service solely authorized to create, inspect, and stop execution sandboxes through a narrow orchestration interface.
_Avoid_: Phoenix web process, Agent Runtime

**Network Mode**:
The execution-sandbox setting controlled by a system-wide ceiling and a profile-level choice; profiles may disable allowed access but cannot override a system-wide denial.
_Avoid_: Implicit host network policy

**Task Integration Branch**:
The task-level branch that accumulates accepted execution-unit results into the unified deliverable.
_Avoid_: Execution-unit branch

**Integration Execution Unit**:
An execution unit created to resolve merge conflicts or repair task-level failures found after otherwise mechanical integration.
_Avoid_: Automatic merge, ordinary task unit

**Unit Acceptance**:
The execution-profile evidence required before an execution unit may be integrated into the task integration branch.
_Avoid_: Model completion claim

**Acceptance Requirement**:
A mandatory check inherited from the Automation Project, execution profile, or repository guidance that models may supplement but cannot remove or weaken.
_Avoid_: Model suggestion

**Task Acceptance**:
The task-level evidence required from the integrated result before the orchestrator may mark its change request ready for review.
_Avoid_: Collection of unit completion claims

**Task Completion**:
The terminal success reached only after the review-ready change request is merged by an authorized human or repository policy.
_Avoid_: Task acceptance, ready for review

**Review Readiness**:
The revocable state indicating that the latest task branch has passed final synchronization and task acceptance but has not yet been merged.
_Avoid_: Task completion

**Coordination Ledger**:
The durable source of truth for execution-unit messages, status, blockers, dependency changes, and artifact references within one tracked development task.
_Avoid_: Chat history, private agent state

**Coordination Event**:
An immutable fact appended to the coordination ledger to record a task or execution-unit state change.
_Avoid_: Mutable status row

**Unit Context**:
The task objective, current plan slice, responsibility, dependency summaries, artifact references, and relevant messages supplied to one execution unit, with full ledger history available on demand.
_Avoid_: Full ledger dump, private task state

**Coordination Proposal**:
An execution unit's request to change responsibilities, dependencies, or decomposition; it has no effect until represented in a validated plan revision.
_Avoid_: Plan mutation

**Progress Projection**:
The rebuildable current-state view derived from coordination events for operators and scheduling decisions.
_Avoid_: Source of truth

**Configuration Store**:
The authoritative database-backed collection of model references, task types, execution profiles, and integration settings managed through the Web Dashboard.
_Avoid_: Read-only dashboard state

**Configuration Revision**:
An immutable version of the complete runtime configuration that may be validated and activated as one unit.
_Avoid_: In-place configuration mutation

**Configuration Validation**:
The activation gate covering schema, reference integrity, policy ceilings, budget relationships, secret resolution, and integration health for a configuration revision.
_Avoid_: Runtime best effort

**Pinned Configuration**:
The configuration revision fixed to a tracked development task for its complete lifecycle unless an operator explicitly migrates or restarts it.
_Avoid_: Silent hot reload

**Rescheduling Event**:
A change that invalidates or materially challenges the current execution plan, such as an execution-unit failure, blocker, dependency change, or failed task-level acceptance.
_Avoid_: Routine progress update

**Failure Class**:
The category that determines whether a failure is retried, recovered, rescheduled, blocked for intervention, or rejected as invalid configuration.
_Avoid_: Generic retryable error

**Interrupted Operation**:
An in-flight model, tool, repository, or tracker operation whose result is unknown after process loss and must be reconciled before retry.
_Avoid_: Failed operation, safe retry

**Effect Record**:
The durable intent, unique operation identity, and observed result for an external side effect used to reconcile retries and recovery.
_Avoid_: Application log, untracked API call

**Routing Fallback Model**:
The separately configured model that an Operator or a new explicit routing or rescheduling plan may select when routing cannot continue with the current model. It never takes over automatically.
_Avoid_: Execution fallback model

**Execution Fallback Model**:
The separately configured model that an Operator or explicit plan may select for an execution unit, including as the initial default for a Dynamic Task Type. It never replaces a failing or unavailable selected model automatically.
_Avoid_: Routing fallback model
