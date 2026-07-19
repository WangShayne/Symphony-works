# Run routing through a read-only profile

The routing model runs through the pluggable Agent Runtime under a dedicated Routing Profile. It may inspect repository, task, code-index, and coordination context but cannot modify artifacts or invoke high-risk tools, and it has an independent budget. This gives planning real code context while preserving the routing-versus-execution boundary.
