# Isolate production execution in containers

Every production execution unit runs in its own container with only its execution workspace mounted and with explicit CPU, memory, disk, process, and network limits. Direct host execution is a development-only mode that must be visibly marked unsafe and cannot be the production default.
