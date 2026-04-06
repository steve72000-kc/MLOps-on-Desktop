# Argo CD Layer

`infra/argocd/` defines the team root Argo CD applications and the shared
Kustomize build option used by Argo CD for this repo.

## Composition

`infra/argocd/kustomization.yaml` renders:

- `argocd-cm-kustomize-build-options.yaml`
- `application-ml-team-a-root.yaml`

`application-ml-team-b-root.yaml` is checked in but commented out in
`infra/argocd/kustomization.yaml`.

## Root Applications

Each root `Application`:

- is created in namespace `argocd`
- targets the in-cluster Gitea repo
  `http://gitea-http.gitea.svc.cluster.local:3000/gitops-admin/ai-ml.git`
- tracks `targetRevision: HEAD`
- points Argo CD at `teams/<team>/`
- reconciles into namespace `<team>`
- enables automated sync, prune, self-heal, and `CreateNamespace=true`

Current root paths:

- `ml-team-a-root` -> `teams/ml-team-a`
- `ml-team-b-root` -> `teams/ml-team-b`

The in-cluster repo path is intentionally canonical. Your local clone directory
name can differ; `bootstrap/gitops-init.sh` reconciles your local checkout to
that internal repo, pushes your current branch there, and makes the current
local branch track `gitea/<branch>`. An existing `origin` remote is preserved,
so pushing back to GitHub/Codeberg remains possible via an explicit
`git push origin <branch>`.

The team root app is the handoff from the shared infra layer to the team layer.
Everything under `teams/<team>/` is reconciled through that root application.

## Build Options

`argocd-cm-kustomize-build-options.yaml` sets:

```yaml
kustomize.buildOptions: --load-restrictor LoadRestrictionsNone
```

This allows Argo CD to render team paths that reference shared files outside the
team directory tree, including the workflow script `ConfigMap` base under
`infra/argo-workflows/scripts/`.

## Local Profile

The current local profile enables only `ml-team-a-root`.

`ml-team-b-root` remains committed and can be re-enabled by uncommenting
`application-ml-team-b-root.yaml` in `infra/argocd/kustomization.yaml`.

## Verification

Render this layer:

```bash
kustomize build infra/argocd
```

Check the root applications:

```bash
kubectl -n argocd get applications | rg 'ml-team-(a|b)-root'
```

Check the shared Argo CD build option:

```bash
kubectl -n argocd get configmap argocd-cm -o yaml | rg 'kustomize.buildOptions'
```

Expected state:

- the render includes `argocd-cm` and the enabled root applications
- `argocd-cm` includes `--load-restrictor LoadRestrictionsNone`

## Related Paths

- `teams/README.md`
- `teams/<team>/`
- `docs/architecture.md`
