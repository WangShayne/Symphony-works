# Journal external side effects

Before mutating a Tracker, repository, change request, Runner, or side-effecting tool, the service records an Effect Record containing a unique operation identity and intent, then records the observed result. Recovery queries the external target and reconciles unknown outcomes before retry, providing replay-safe at-least-once execution without obvious duplicate effects.
