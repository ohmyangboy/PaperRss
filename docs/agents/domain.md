# Domain Docs

How the engineering skills should consume this single-context repo's domain documentation when exploring the codebase.

## Before exploring, read these

- `CONTEXT.md` at the repo root when it exists.
- ADRs under `docs/adr/` that touch the area being changed.

If these files do not exist, proceed silently. Domain-modeling skills create them lazily when terminology or architectural decisions are actually resolved.

## File structure

This repository uses a single-context layout: one root `CONTEXT.md` and system-wide ADRs under `docs/adr/`.

## Use the glossary's vocabulary

Use terms as defined in `CONTEXT.md` for issues, tests, hypotheses, and implementation plans. If a needed concept is absent, reconsider whether a new term is necessary or record the gap for domain modeling.

## Flag ADR conflicts

Surface any conflict with an existing ADR explicitly instead of silently overriding it.
