# Kind Bootstrap Layer

`clusters/kind/bootstrap/` is the GitOps entrypoint tracked by
`Application/ai-ml-root`.

## Composition

`clusters/kind/bootstrap/kustomization.yaml` renders:

- `../../../infra`

This path does not render team resources directly.

## Role In The Reconciliation Chain

- `ai-ml-root` points Argo CD at `clusters/kind/bootstrap`
- `clusters/kind/bootstrap` composes `infra/`
- `infra/argocd/` creates the team root applications
- each team root application then reconciles `teams/<team>/`

## Current Profile

The checked-in Kind profile currently enables:

- `ml-team-a-root`

The repo keeps `ml-team-b-root` committed under `infra/argocd/`, but it remains
commented out in `infra/argocd/kustomization.yaml`.

## Verification

Render this layer:

```bash
kustomize build clusters/kind/bootstrap
```

Check the root application path used by GitOps init:

```bash
rg -n 'clusters/kind/bootstrap' bootstrap/gitops-init.sh
```

Expected state:

- the render composes `infra/`
- `bootstrap/gitops-init.sh` resolves `ARGOCD_APP_PATH` to
  `clusters/kind/bootstrap`

## Related Paths

- `infra/README.md`
- `infra/argocd/README.md`
- `docs/architecture.md`
