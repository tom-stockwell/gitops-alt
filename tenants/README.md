# Tenants

Stands in for a separate tenants repo; the `tenant-config` ApplicationSet
(`bootstrap/appsets/tenant-config/`) reads it from this repo for now. Clusters get it by
being `workload` clusters (`role` in their facts), whose base includes `tenant-config`.

```
tenants/<tenant>/
  base/                   the tenant's namespace, access and quota
  clusters/<cluster>/     one dir per cluster the tenant is on
    kustomization.yaml    ../../base plus any per-cluster changes
```

Per-cluster overlays live under `clusters/`, as in `apps/`, so a cluster name can never
collide with `base/` or any other directory a tenant has.

Each `tenants/<tenant>/clusters/<cluster>/` directory becomes an Application named
`tenant-<tenant>` on that cluster. There's no per-tenant Argo CD config: every tenant gets the
same settings, set in the tenant-config ApplicationSet (sync wave 30, automated sync, and
`prune: false` so removing a resource from git never deletes a tenant's namespace, and
everything in it, automatically).

Unlike `apps/`, these files are written by hand. What a tenant gets on a cluster is
pinned per cluster with `scripts/promote <cluster> <ref> --appset tenant-config`.
