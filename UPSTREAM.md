# Upstream provenance

This repository evolves the Elixir implementation of [OpenAI Symphony](https://github.com/openai/symphony).

| Field | Value |
| --- | --- |
| Upstream repository | `https://github.com/openai/symphony.git` |
| Imported commit | `7af5a7648c9fbffa08825fe0c0b18be00100aff3` |
| Import date | 2026-07-20 |
| Upstream license | Apache License 2.0 |
| Import scope | Upstream repository except its `.git`, `.codegraph`, and `.cursor` metadata |

The upstream `LICENSE`, `NOTICE`, `README.md`, and `SPEC.md` are retained at the repository root. New project work remains Apache-2.0 compatible and preserves upstream attribution. “Symphony” is a development name; this repository does not claim official OpenAI endorsement.

The source snapshot under `.research/upstream` is read-only provenance evidence. It is excluded from version control, is not a runtime dependency, and must not be edited to make product changes. Product changes belong in the promoted root tree.

The initial promotion copies upstream source bytes unchanged. Project-specific domain, design, planning, research, agent, migration, and provenance documents are additive. See `docs/migration/upstream-parity.md` for the planned disposition of every upstream production module.

## Reproduce the source identity check

```shell
git -C .research/upstream remote get-url origin
git -C .research/upstream rev-parse HEAD
```

Expected values are the upstream repository and imported commit recorded above.
