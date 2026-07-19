# Revalidate after final target-branch sync

Before a change request becomes Ready for Review, the orchestrator integrates the latest target branch into the task integration branch. Conflict-free updates are mechanical; conflicts create an integration execution unit. Task-level acceptance then runs again against the synchronized result, preventing stale validation from authorizing review readiness.
