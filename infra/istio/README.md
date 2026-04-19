# Istio Layer

`infra/istio/` defines the local service mesh control plane in namespace
`istio-system`.

## Composition

`kustomization.yaml` renders six Argo CD applications:

- `application-ca.yaml` creates the mesh root CA resources in `istio-system`
- `application-base.yaml` installs the Istio base chart and CRDs
- `application-cert-manager-istio-csr.yaml` installs `cert-manager-istio-csr`
- `application-istiod.yaml` installs the Istio control plane
- `application-ingressgateway.yaml` installs the shared ingress gateway
- `application-mesh-security.yaml` applies the mesh mTLS policy

## Certificate Flow

This repo uses cert-manager as the certificate authority for Istio workload
identity.

1. `application-ca.yaml` creates a self-signed root and an `Issuer` named
   `istio-ca` in `istio-system`
2. `cert-manager-istio-csr` requests serving and workload certificates from
   that issuer through cert-manager
3. `istiod` and the ingress gateway are configured to request mesh
   certificates from `cert-manager-istio-csr`
4. injected workloads receive short-lived mesh certificates that are trusted by
   the shared Istio root

The result is a local mesh that behaves like a larger environment with a
separate certificate controller instead of relying on Istio's built-in
self-signed CA.

This repo now pins the mesh root CA explicitly in `cert-manager-istio-csr`, but
does so by projecting only the public certificate from the `istio-ca` secret.
The pod mounts just `tls.crt` from that secret as `ca.pem` and points
`app.tls.rootCAFile` at it. The private key in `istio-ca/tls.key` is not
mounted into the pod, so the mesh root stays owned by cert-manager while
`istio-csr` still gets deterministic root pinning.

## Metrics

`cert-manager-istio-csr` still exposes its normal metrics service in
`istio-system`, but this repo keeps the chart's built-in `ServiceMonitor`
disabled. The scrape object is owned under `infra/monitoring/manifests/scrape/`
instead so it is created only after the Prometheus Operator CRDs exist during a
fresh bootstrap.

## mTLS Policy

`application-mesh-security.yaml` enables strict mTLS for mesh traffic by
default and keeps a small number of namespaces in permissive mode where the
local profile intentionally mixes meshed and non-meshed workloads:

- mesh default: `STRICT`
- `knative-serving`: `PERMISSIVE`
- `monitoring`: `PERMISSIVE`
- `istio-ingressgateway` workloads: `PERMISSIVE`
- additional Knative webhook `PeerAuthentication` objects keep port `8443`
  permissive for `app=webhook` and `app=net-istio-webhook`

The `knative-serving` exception keeps the Knative control plane compatible with
sidecar injection. The `monitoring` exception lets Prometheus keep an Istio
sidecar for scrape certificate output while Grafana, Loki, Promtail, and the
operator stay outside the mesh to keep the local footprint smaller. The
monitoring namespace is intentionally left without an `istio-injection` label
so Prometheus can use pod-label opt-in under Istio 1.24. Prometheus still
disables traffic interception, so it can keep direct scrape behavior while
using Istio-issued certificates where the target path needs mTLS.

The extra Knative webhook carve-outs come from the upstream `net-istio`
integration and are narrower than the namespace-wide `knative-serving`
exception: they leave the webhook listener on port `8443` permissive while the
rest of the namespace follows the broader namespace policy.

## Runtime Relationships

At runtime, the important relationships are:

- injected workloads -> `cert-manager-istio-csr` for workload certificates
- `cert-manager-istio-csr` -> cert-manager issuer `istio-ca`
- sidecars and gateways -> `istiod` for xDS
- ingress gateway -> in-mesh services with mTLS

Tenant least-privilege policies need to reflect both halves of that control
plane path. In this repo, the tenant namespace baseline now allows egress to
both `istio-system/app=istiod` and
`istio-system/app=cert-manager-istio-csr`, so injected team workloads can keep
their network scope narrow without blocking workload certificate bootstrap.

## Rollout Note

This repo treats a fresh bootstrap as the supported path for introducing the
cert-manager-backed mesh CA. If this change is pointed at an already-running
cluster, existing meshed workloads keep their current sidecar bootstrap until
they are recreated. Restart long-lived workloads after the Argo CD sync so
their sidecars request new certificates through `cert-manager-istio-csr`.

## Verification

Check the control plane:

```bash
kubectl -n istio-system get deploy,statefulset,svc
```

Check the mesh CA resources and signer endpoint:

```bash
kubectl -n istio-system get issuer,certificate,secret | rg 'istio-ca|istiod'
kubectl -n istio-system get deploy,svc | rg 'cert-manager-istio-csr'
kubectl -n istio-system get deploy cert-manager-istio-csr -o yaml | rg 'root-ca|ca.pem|tls.crt'
```

Check the mTLS policies:

```bash
kubectl get peerauthentication -A
```
