# Enforce hierarchical execution budgets

V1 enforces cost, token, and elapsed-time budgets at system, tracked-task, and execution-unit levels, with child limits bounded by their parent. A soft threshold creates a rescheduling event so the routing model can reduce scope or change strategy; a hard limit prevents further model or tool calls until an Operator intervenes.
