# Handle failures by class

Transient network, rate-limit, and tool failures receive bounded exponential-backoff retries. Agent Runtime crashes recover from durable coordination state and use the execution fallback only after continued runtime or model unavailability. Acceptance failures trigger replanning; permission and budget shortages block for intervention; configuration and protocol errors fail fast and alert. No failure class permits unbounded retry.
