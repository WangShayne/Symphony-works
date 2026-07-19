# Deliver through a progressive draft change request

The first accepted execution-unit result integrated into the task branch triggers creation of one draft pull request or merge request. Subsequent accepted results update that same change request, and only successful task-level acceptance may mark it ready for review. V1 never merges it into the target branch; human approval or repository policy retains that authority, and only an observed merge completes the tracked task. The change request is a delivery surface, not a second schedulable task.
