# Isolate Docker control in a Runner service

The Phoenix application does not mount or access the Docker socket. A separate host-local Runner service exclusively owns Docker control and exposes only a narrow interface for creating, inspecting, and stopping policy-bounded execution sandboxes. This limits the effect of a Dashboard compromise and prevents arbitrary host-container operations through the web process.
