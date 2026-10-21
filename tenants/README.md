# Tenants

Stands in for a separate tenants repo; the `tenant-config` ApplicationSet
(`bootstrap/appsets/tenant-config/`) reads it from this repo for now. Clusters get it by using
the `base-with-tenants` base in `clusters/<cluster>/argocd/kustomization.yaml`.

```
tenants/<tenant>/
  base/                   the tenant's namespace, access and quota
  clusters/<cluster>/     one dir per cluster the tenant is on
    kustomization.yaml    ../../base plus any per-cluster changes
    argocd.json           Argo CD settings for this tenant on this cluster
```

Per-cluster overlays live under `clusters/`, as in `apps/`, so a cluster name can never
collide with `base/` or any other directory a tenant has.

`argocd.json` has the same shape as the generated `apps/*/clusters/*/argocd.json`:
`tenant` (the Application is named `tenant-<tenant>`), `cluster`, and `sync`
(`wave` required, `automated.{enabled,prune,selfHeal}` optional, default true). The
examples set `prune: false` so removing a resource from git never deletes a tenant's
namespace (and everything in it) automatically.

Unlike `apps/`, these files are written by hand. What a tenant gets on a cluster is
pinned per cluster with `scripts/promote <cluster> <ref> --appset tenant-config`.
