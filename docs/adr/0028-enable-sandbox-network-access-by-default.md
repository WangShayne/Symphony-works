# Enable sandbox network access by default

Production execution sandboxes have network access by default because development tasks commonly require model providers, package registries, source control, and external tools. A system-wide setting provides the maximum allowed network capability, while each execution profile may disable access further. Profiles and dynamic task types cannot override a system-wide denial or otherwise widen the configured ceiling.
