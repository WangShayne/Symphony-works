# Complete tasks only after change-request merge

Task-level acceptance moves the change request and tracked Issue into Ready for Review rather than Completed. The service marks the task complete and cleans its workspaces only after it observes a human-authorized pull-request or merge-request merge. Closing without merge follows cancellation or failure policy instead of success.
