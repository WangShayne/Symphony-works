# Support dashboard-managed configuration

V1 requires a Web Dashboard that can create and modify database-backed model references, task types, execution profiles, and tracker or source-control adapter settings. The database is the runtime source of truth; files are limited to bootstrap, import, and export and are not synchronized bidirectionally. Dashboard changes produce configuration revisions, and the orchestrator loads only an explicitly activated revision. A read-only status dashboard is insufficient; configuration management is part of the product's operational surface.
