# Keep secrets out of model context

Models and agent runtimes never receive credential plaintext. A trusted credential broker resolves secret references and injects values only at the outbound provider or tool boundary. Prompts, environment snapshots, coordination events, audit events, and permission grants cannot expose or authorize reading the underlying value.
