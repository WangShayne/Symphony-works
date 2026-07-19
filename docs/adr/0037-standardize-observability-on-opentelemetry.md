# Standardize observability on OpenTelemetry

V1 emits structured logs and OpenTelemetry metrics and traces using correlated task, plan-revision, execution-unit, model-call, and tool-call identifiers. Telemetry covers latency, token use, cost, retries, and failure classes. Secret values, source content, and complete sensitive prompts are excluded by default, and telemetry never replaces the coordination or audit stores.
