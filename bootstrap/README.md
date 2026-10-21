# Bootstrapping a cluster

Every cluster runs its own Argo CD (OpenShift GitOps) with argocd-agent in
**autonomous** mode. The hub only aggregates status; it does not push config.

1. Add the cluster to git first (`make new-cluster NAME=<name> FROM=<existing> DOMAIN=<domain>`)
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
  appsets/                  base: every ApplicationSet, with REVISION/CLUSTER placeholders
    cluster-config.yaml     one Application per apps/<app>/clusters/<cluster>/argocd.json
    revisions.env           default revision per ApplicationSet (main)
  revisions/                Component: fills the placeholders from appset-revisions + cluster facts
clusters/<cluster>/argocd/
  kustomization.yaml        identical for every cluster: base + facts + revisions Component
  revisions.env             this cluster's pins (overrides the defaults key by key)
```

Run `kustomize build clusters/<cluster>/argocd` to see exactly what a cluster's root
Application applies.

## Promotion and rollback

Each cluster pins a commit per ApplicationSet in `clusters/<cluster>/argocd/revisions.env`.
The ApplicationSet uses that commit both to find the apps and their settings and to fetch
their manifests, so everything a cluster runs comes from one commit.

- **Promote one cluster:** `make promote CLUSTER=prod-east-1 REF=main` (or a tag or SHA).
  This writes the full SHA. Commit it, open an MR, and the cluster moves when it merges.
  Then do the next cluster in its own MR.
- **Roll back:** promote the previous SHA, or `git revert` the promote commit.
- **Track main:** remove the cluster's line. Unset keys use `bootstrap/appsets/revisions.env`.

`make check` (lint) rejects pins that aren't a full SHA or `main`, that name an unknown
ApplicationSet, or that point at a commit without this cluster's joins.

See [docs/revision-pinning.md](../docs/revision-pinning.md) for why it works this way, how to
add more ApplicationSets, and the alternative to use when cluster Secrets can be set up reliably.

## Assumptions to verify against your Argo CD version

- `spec.templatePatch` (used so `syncPolicy.automated` values render as booleans) needs
  Argo CD 2.10 or later.
- `spec.syncPolicy.automated.enabled` (used to turn off automated sync per app) is a newer
  field. Check that your Argo CD version supports it. Older versions reject or ignore it.
  Without it, automated sync is on whenever the `automated` block is present.
