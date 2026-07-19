# Deliver relevant unit context

An execution unit receives a relevant view of the coordination ledger rather than the complete history: task objective, current plan slice, unit responsibility, direct dependency summaries, artifact references, and addressed messages. The full ledger remains queryable on demand, and every unit publishes progress, blockers, and collaboration requests back to it. This preserves communication without exhausting model context on unrelated events.
