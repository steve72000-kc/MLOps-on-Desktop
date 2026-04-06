# Contributing

Thanks for taking a look at this project.

This repo is meant to be both a working reference stack and a hands-on lab for
local MLOps platform learning. Contributions are welcome when they improve the
repo's clarity, reproducibility, operational realism, or usefulness as a
teaching artifact.

## What Fits Well Here

- documentation improvements that make the platform easier to understand or run
- validation, testing, and troubleshooting improvements
- observability improvements such as dashboards, alerts, and log views
- workflow, GitOps, or tenant-safety improvements
- additional examples that reinforce the platform model without turning the
  repo into a collection of disconnected demos

## Before You Make A Large Change

Please open an issue first if the change would significantly alter:

- the GitOps ownership model
- the MLflow intent contract or writeback flow
- tenant boundaries or multi-tenant policy assumptions
- the default local platform profile
- the repo's documented security posture

That helps keep the repo coherent and avoids people doing the same design work
in parallel.

## Development Expectations

Run the repo validation entrypoint before opening a pull request:

```bash
make validate
```

When making changes:

- keep docs and checked-in behavior aligned
- prefer focused pull requests over broad refactors
- preserve the separation between `infra/`, `teams/`, and `apps/`
- update troubleshooting or architecture docs when behavior changes materially
- avoid committing machine-local data, generated noise, or environment-specific
  secrets that are not intentional lab defaults

## Repo Boundaries

The most important project boundary is ownership:

- `infra/` is the shared platform layer
- `teams/` is the team-owned runtime layer
- `apps/tenants/` is the GitOps deployment target written by automation

Changes that blur those boundaries should be justified clearly in the pull
request description.

## Issues And Pull Requests

If this project is hosted on multiple forges, use the primary forge listed in
the repository description whenever possible. If a GitHub mirror exists, it may
lag behind or be treated as read-only.

Please include:

- what changed
- why the change is useful
- how you validated it
- any follow-up work or limitations that remain

## Code Of Conduct

Participation in this project is governed by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
