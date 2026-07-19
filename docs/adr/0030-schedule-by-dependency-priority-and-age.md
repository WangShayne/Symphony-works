# Schedule by dependency, priority, and age

Only dependency-satisfied execution units compete for capacity. Runnable units are ordered by tracker priority and then waiting time while respecting system, model-provider, execution-profile, and repository concurrency limits; integration for one task is serialized. Routing models cannot bypass these fairness and capacity rules.
