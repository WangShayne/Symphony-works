# Decouple task tracking from source control

Task tracking and source control are configured as independent integrations. Linear is optional; a deployment may run purely on GitHub Issues and pull requests, purely on GitLab Issues and merge requests, or use a tracker and code host from different providers. GitHub and GitLab therefore implement separate tracker and source-control contracts rather than leaking provider pairing assumptions into orchestration.
