# Why This Project Exists

This repo is a **local-first, reproducible MLOps reference stack** that lets you run the *full* model-serving loop—**intent → GitOps → deploy → observe → break → recover**—on a laptop.

It started as a learning exercise, but it became something more practical:

- a local MLOps platform I can actually live in (not a weekend demo)
- a place to train, track, deploy, break, and fix model-serving workflows end to end
- a real environment for learning KServe, Knative, Istio, Argo, MLflow, and GitOps *together* instead of in isolation

---

## The Core Problem

Many examples teach single pieces.

Very few give you a complete local stack that feels production-like across:

- multi-tenant boundaries
- model registry and deployment intent
- autoscaling and routing
- GitOps reconciliation
- platform observability and troubleshooting

If you cannot run the full loop yourself, it is hard to trust that your architecture will hold up when complexity arrives.

---

## The Core Loop (What You Can Actually Do Here)

This repo is intentionally designed around one repeatable workflow:

1. **Bootstrap the platform** (cluster + shared services).
2. **Register a model and set deployment intent** (MLflow metadata / tags / aliases).
3. **Render and validate manifests** (platform “glue” enforces a few non-negotiables).
4. **Write desired state to Git** (GitOps is the record of truth).
5. **Reconcile via Argo CD** (KServe/Knative/Istio bring it to life).
6. **Observe behavior** (metrics/logs/events; follow the request path).
7. **Break it on purpose and recover** (quotas, routing, egress, drift, bad intent, etc).

That loop is the point. The tools are just the mechanics.

---

## Why Local-First Matters

This stack is laptop-first so people can learn by doing without waiting on enterprise access, budget approvals, or large cloud setup.

You can:

- bootstrap the platform
- deploy a model from intent
- observe and debug runtime behavior
- recover from failures

all in one repo, with one workflow.

---

## Why These Design Choices

### GitOps + Argo CD

For this level of configuration, manual changes become untraceable fast.
GitOps gives clear ownership of desired state, repeatability, and safe rollback.

### MLflow + KServe

MLflow holds model lineage and deployment intent.
KServe executes serving intent.

The custom glue in this repo maps MLflow tags/intent to deployment manifests and then reconciles through GitOps.

### Knative + Istio

These are not here for decoration.

They enable autoscaling, shared ingress/routing, and multi-tenant serving behavior that matters when teams share expensive resources.

---

## What You Can Learn Here

### In ~30 Days

- GitOps-driven platform operations with Argo CD
- model deployment flow from MLflow metadata to KServe runtime
- core KServe and Knative troubleshooting patterns
- practical observability with Prometheus, Grafana, Loki, and Promtail

### In ~90 Days

- multi-tenant policy and quota strategy
- runtime hardening and reliability tuning under resource pressure
- intent schema evolution and safer automation workflows
- reproducible platform changes with branch-based experimentation

---

## How To Know It’s Working (Success Criteria)

If you want a concrete “done” definition, aim for this:

- You can **change deployment intent** (or a model alias) and watch the platform reconcile without manual hand edits.
- Repeated sync cycles settle into **steady-state** when intent is unchanged (no churn for no reason).
- You can intentionally trigger at least one failure mode (quota, routing, egress, mis-specified intent) and **recover using the repo’s runbooks and observability**.

---

## Production-Like vs Simplified

Production-like in this repo:

- toolchain and control flow
- declarative GitOps lifecycle
- operational debugging surface (metrics/logs/events)
- multi-component integration behavior

Intentionally simplified:

- security hardening and secret-management posture
- enterprise auth and org-specific controls
- environment-specific compliance requirements
- HA and long-term retention assumptions

Those should be layered by each organization on top of this reference.

---

## Who This Is For

- engineers learning practical MLOps platform work
- teams prototyping internal multi-tenant model-serving architecture
- platform engineers who want a testbed for KServe/Knative/Istio/Argo behavior
- people who learn best by building systems and then debugging them

This is probably not for:

- users who only want single-model local inference
- users focused only on model fine-tuning without platform concerns
- anyone who doesn’t want Kubernetes/GitOps/multi-component debugging (you will hate this)

---

## How I Expect This To Be Used

- fork it and run it
- keep your own long-lived branch
- experiment freely (new runtimes, security overlays, tenancy models, workflow logic)
- share improvements back if useful

### Suggested Learning Paths

- **“Just show me a demo”**: bootstrap → deploy baseline model → confirm routing → observe metrics/logs.
- **“Teach me tenancy”**: enable a second team → quotas + network policy → shared ingress/routing.
- **“Teach me operations”**: trigger one known failure mode → use dashboards/log views/events → recover cleanly.
- **“Teach me platform automation”**: iterate on intent schema + validation + safe writeback to Git.

I expect the best contributions to be features and patterns I have not thought of yet.

---

## Final Note

This project is as much about learning the system as it is about running the system.

If it helps more people get real hands-on experience with modern MLOps platform architecture, it has done its job.