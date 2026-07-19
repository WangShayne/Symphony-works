# Bind one primary model to each execution profile

V1 binds exactly one primary task-model reference to each execution profile. Continued unavailability may use the separately configured execution fallback, but normal execution does not load-balance across candidates, choose models by price, or perform multi-model voting. This keeps routing decisions, cost attribution, and reproduction deterministic.
