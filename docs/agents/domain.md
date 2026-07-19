# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Repository layout

This repository uses a single domain context:

```
/
├── CONTEXT.md
└── docs/adr/
```

`CONTEXT.md` defines the shared vocabulary. `docs/adr/` records project-wide architecture decisions. Do not introduce `CONTEXT-MAP.md` or context-scoped documentation unless the repository later becomes a genuine multi-context monorepo.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in.

If either does not exist, **proceed silently**. Do not flag its absence or suggest creating it upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates domain documentation lazily when terms or decisions are resolved.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, or a test name), use the term defined in `CONTEXT.md`. Do not drift to synonyms the glossary explicitly avoids.

If the concept you need is not in the glossary, either reconsider invented language or note a genuine gap for `/domain-modeling`.

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding it:

> _Contradicts ADR-0007 — but worth reopening because…_
