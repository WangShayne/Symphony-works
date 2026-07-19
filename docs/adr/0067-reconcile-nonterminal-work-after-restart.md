# Reconcile nonterminal work after restart

After acquiring active-orchestrator ownership, startup rebuilds projections from coordination events and reconciles every nonterminal task with Runner containers, workspaces, Trackers, and change requests. Operations interrupted with unknown outcomes are classified as Interrupted and reconciled before retry, preventing restart from blindly repeating external side effects.
