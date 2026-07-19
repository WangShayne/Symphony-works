# Support Linear, GitHub, and GitLab trackers

V1 will ship production tracker adapters for Linear, GitHub, and GitLab behind one normalized tracker contract. Provider-specific authentication, identifiers, states, and API behavior remain inside each adapter so the orchestrator operates on the common tracked development task model. Only issues are schedulable inputs; GitHub pull requests and GitLab merge requests are task delivery artifacts and cannot independently trigger duplicate execution.
