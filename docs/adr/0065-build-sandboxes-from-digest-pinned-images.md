# Build sandboxes from digest-pinned images

Automation Projects configure a base OCI image and execution profiles may select a more specific image. Configuration activation resolves mutable tags to immutable digests, and tasks pin those digests through their configuration revision. Execution units may install dependencies inside disposable containers but cannot mutate the base image or another unit's environment.
