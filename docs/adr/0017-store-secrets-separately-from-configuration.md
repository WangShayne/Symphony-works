# Store secrets separately from configuration

The Dashboard may accept model and integration credentials, but configuration revisions contain only opaque secret references. Secret values are encrypted in a separate secret store using a master key supplied by the process environment or an external secret manager, are never displayed again after creation, and are omitted from configuration exports. The database alone is insufficient to decrypt stored credentials.
