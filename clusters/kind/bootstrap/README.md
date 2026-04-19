# Kind Bootstrap Layer

`clusters/kind/bootstrap/` is the GitOps entrypoint tracked by
`Application/ai-ml-root`.

## Composition

`clusters/kind/bootstrap/kustomization.yaml` renders:

- `../../../infra`

This path does not render team resources directly.

## Role In The Reconciliation Chain

- `bootstrap/install.sh` pre-applies the committed
  `infra/argocd/argocd-cm-kustomize-build-options.yaml` and restarts the Argo
  CD components that consume it
- `bootstrap/gitops-init.sh` then creates `ai-ml-root`
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

Check the bootstrap pre-seed and GitOps path validation wiring:

```bash
rg -n 'argocd-cm-kustomize-build-options|clusters/kind/bootstrap|gitops_paths_to_validate|infra' \
  bootstrap/install.sh bootstrap/gitops-init.sh
```

Expected state:

- the render composes `infra/`
- `bootstrap/install.sh` seeds the committed `argocd-cm` config before
  `Application/ai-ml-root` is created
- `bootstrap/gitops-init.sh` resolves `ARGOCD_APP_PATH` to
  `clusters/kind/bootstrap`
- `bootstrap/gitops-init.sh` validates both `clusters/kind/bootstrap` and
  `infra/` because the bootstrap entrypoint composes the shared infra tree

## Related Paths

- `infra/README.md`
- `infra/argocd/README.md`
- `docs/architecture.md`
