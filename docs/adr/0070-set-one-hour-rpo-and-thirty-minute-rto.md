# Set one-hour RPO and thirty-minute RTO

V1 targets at most one hour of authoritative database-state loss and restoration within thirty minutes on the supported single-host deployment. Hourly backups plus retained daily and weekly sets support this target; upstream model-provider or code-host outages are excluded from service restoration time.
