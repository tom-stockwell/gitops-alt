# Bootstrapping a cluster

Every cluster runs its own Argo CD (OpenShift GitOps) with argocd-agent in
**autonomous** mode. The hub only aggregates status; it does not push config.

1. Add the cluster to git first (`just new-cluster <name> <existing> --domain <domain>`)
   and merge it to main. A new cluster has no pins, so it tracks main until you promote it.
2. Install the OpenShift GitOps operator and argocd-agent in autonomous mode. Use the
   cluster name (`clusters/<name>`) as the agent name so the hub's view matches the repo.
3. Apply the cluster's root Application. This is the only thing applied by hand:
   ```sh
   scripts/bootstrap-root <name> | oc apply -f -
   ```
   It tracks main at `clusters/<name>/argocd/`, which renders this cluster's ApplicationSets
   with their pinned revisions. From here on everything is managed from git.

## What's in here

```
bootstrap/
  appsets/<name>/           one ApplicationSet each, with REVISION/CLUSTER placeholders
    cluster-config/         one Application per apps/<app>/clusters/<cluster>/argocd.json
    tenant-config/          one Application per tenants/<tenant>/clusters/<cluster>/argocd.json
  appset-revisions/         default revision for every ApplicationSet (all main); local-config
  bases/<role>/      the ApplicationSets each role runs
    hub/                    cluster-config
    workload/               cluster-config + tenant-config
  revisions/                Component: fills every ApplicationSet's placeholders from
                            appset-revisions + cluster facts (skips ones not in the base)
clusters/<cluster>/argocd/
  kustomization.yaml        uses bootstrap/bases/<role>; otherwise identical for every cluster
  revisions.env             this cluster's pins (overrides the defaults key by key)
```

Run `kustomize build clusters/<cluster>/argocd` to see exactly what a cluster's root
Application applies. A cluster's base must match the `role` in its facts (lint checks
this); `just new-cluster ... --role <role>` sets both.

## Promotion and rollback

Each cluster pins a commit per ApplicationSet in `clusters/<cluster>/argocd/revisions.env`.
The ApplicationSet uses that commit both to find the apps and their settings and to fetch
their manifests, so everything a cluster runs comes from one commit.

- **Promote one cluster:** `just promote prod-workload-east-1 main` (or a tag or SHA),
  adding `--appset tenant-config` to pin tenants instead. This writes the full SHA. Commit it,
  open an MR, and the cluster moves when it merges. Then do the next cluster in its own MR.
- **Roll back:** promote the previous SHA, or `git revert` the promote commit.
- **Track main:** remove the cluster's line. Unset keys use `bootstrap/appset-revisions/revisions.env`.

`just check` (lint) rejects pins that aren't a full SHA or `main`, that name an
ApplicationSet the cluster's base doesn't include, or (for cluster-config) that point at a
commit without this cluster's joins.

See [docs/revision-pinning.md](../docs/revision-pinning.md) for why it works this way, how to
add more ApplicationSets, and [the nested-matrix alternative](../docs/revision-pinning-nested-matrix.md)
to use when cluster Secrets can be set up reliably.

## Assumptions to verify against your Argo CD version

- `spec.templatePatch` (used so `syncPolicy.automated` values render as booleans) needs
  Argo CD 2.10 or later.
- `spec.syncPolicy.automated.enabled` (used to turn off automated sync per app) is a newer
  field. Check that your Argo CD version supports it. Older versions reject or ignore it.
  Without it, automated sync is on whenever the `automated` block is present.
