# Upstream Elixir module parity inventory

Status: baseline classification for V1 implementation planning.

Source: OpenAI Symphony commit `7af5a7648c9fbffa08825fe0c0b18be00100aff3`.

This inventory covers every module declared under the promoted upstream `elixir/lib/` tree. It records intended V1 direction, not a claim that the later cutovers are already implemented.

## Classification vocabulary

- `retain` — preserve the module and its current responsibility; bounded implementation changes remain possible.
- `adapt` — keep the module as an evolution seam while changing its contract, dependencies, or behavior.
- `replace` — supersede the module through an explicit, tested cutover; retain only compatibility code needed during migration.
- `retire` — remove the module from the supported V1 production path after its callers have migrated.

## Inventory

| Upstream module | Classification | V1 direction |
| --- | --- | --- |
| `Mix.Tasks.PrBody.Check` | `retain` | Keep the upstream pull-request quality check. |
| `Mix.Tasks.Specs.Check` | `retain` | Keep the upstream specification consistency check. |
| `Mix.Tasks.Workspace.BeforeRemove` | `adapt` | Route cleanup through the V1 workspace-retention policy. |
| `SymphonyElixir` | `retain` | Preserve the application namespace and public baseline identity. |
| `SymphonyElixir.Application` | `adapt` | Extend the OTP supervision tree for durable control-plane services. |
| `SymphonyElixir.AgentRunner` | `adapt` | Move execution behind the Agent Runtime and Runner contracts. |
| `SymphonyElixir.AgentRuntimeSupervisor` | `adapt` | Supervise execution units under the V1 coordination lifecycle. |
| `SymphonyElixir.CLI` | `adapt` | Evolve into the supported operator-focused CLI. |
| `SymphonyElixir.Codex.AppServer` | `retain` | Keep as the first Agent Runtime adapter. |
| `SymphonyElixir.Codex.DynamicTool` | `adapt` | Apply capability, MCP, audit, and execution-profile governance. |
| `SymphonyElixir.Config` | `replace` | Cut over from file-backed runtime configuration to activated database revisions. |
| `SymphonyElixir.Config.Schema` | `replace` | Replace the upstream workflow schema with normalized V1 configuration schemas. |
| `SymphonyElixir.HttpServer` | `adapt` | Keep the Phoenix entry point while expanding the control-plane surface. |
| `SymphonyElixir.Linear.Adapter` | `adapt` | Implement the normalized Tracker contract above the retained client. |
| `SymphonyElixir.Linear.AgentTool` | `adapt` | Govern tracker access as an audited execution-unit tool. |
| `SymphonyElixir.Linear.Client` | `retain` | Keep as the Linear provider client behind the Tracker adapter. |
| `SymphonyElixir.LogFile` | `retain` | Preserve structured local log-file support. |
| `SymphonyElixir.Orchestrator` | `replace` | Cut over to durable task coordination, routing, dependency scheduling, and recovery. |
| `SymphonyElixir.PathSafety` | `retain` | Preserve path-containment checks as a workspace safety invariant. |
| `SymphonyElixir.PromptBuilder` | `adapt` | Build prompts from immutable routing plans and repository guidance. |
| `SymphonyElixir.SpecsCheck` | `retain` | Preserve specification quality enforcement. |
| `SymphonyElixir.SSH` | `retire` | Remove remote-host execution from the supported single-host V1 path. |
| `SymphonyElixir.StatusDashboard` | `replace` | Replace ephemeral status state with durable projections and operator actions. |
| `SymphonyElixir.Tracker` | `adapt` | Become the provider-neutral Tracker behavior and capability seam. |
| `SymphonyElixir.Tracker.Issue` | `adapt` | Expand into the normalized tracked-task data contract. |
| `SymphonyElixir.Tracker.Memory` | `retain` | Keep as the deterministic simulated Tracker used by contract tests. |
| `SymphonyElixir.Workflow` | `adapt` | Preserve parsing only for one-time `WORKFLOW.md` import. |
| `SymphonyElixir.WorkflowStore` | `replace` | Replace hot-reloaded files with durable activated configuration revisions. |
| `SymphonyElixir.Workspace` | `adapt` | Create isolated worktrees and integrate accepted execution-unit results. |
| `SymphonyElixirWeb.Layouts` | `adapt` | Evolve the shell for the authenticated control-plane Dashboard. |
| `SymphonyElixirWeb.ObservabilityApiController` | `adapt` | Serve authenticated durable operational projections. |
| `SymphonyElixirWeb.StaticAssetController` | `retain` | Preserve packaged static-asset delivery. |
| `SymphonyElixirWeb.Endpoint` | `adapt` | Add production control-plane session, security, and transport configuration. |
| `SymphonyElixirWeb.ErrorHTML` | `retain` | Preserve HTML error rendering. |
| `SymphonyElixirWeb.ErrorJSON` | `retain` | Preserve JSON error rendering. |
| `SymphonyElixirWeb.DashboardLive` | `replace` | Replace the upstream monitor with the complete configuration and operations Dashboard. |
| `SymphonyElixirWeb.ObservabilityPubSub` | `adapt` | Publish correlated durable task, unit, audit, and health updates. |
| `SymphonyElixirWeb.Presenter` | `adapt` | Present normalized control-plane projections and operator-safe errors. |
| `SymphonyElixirWeb.Router` | `adapt` | Add authenticated Dashboard, REST API, health, and authorization routes. |
| `SymphonyElixirWeb.StaticAssets` | `retain` | Preserve embedded static-asset lookup and cache behavior. |

## Cutover constraints

- `Codex.AppServer` and `Linear.Client` remain provider adapters, not orchestration policy owners.
- `Tracker` and `Workspace` evolve behind normalized contracts before provider or Runner-specific behavior expands.
- `WorkflowStore`, `Orchestrator`, `StatusDashboard`, and `DashboardLive` remain usable until their replacements pass contract, migration, recovery, and acceptance gates.
- No classification permits silently weakening workspace isolation, explicit configuration activation, durable coordination, effect journaling, or human merge authority.
