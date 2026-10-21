# Multi-cluster GitOps example

Kustomize config for several OpenShift clusters, each running its own Argo CD
(argocd-agent, autonomous mode). The repo separates:

- **how** an app is configured → `apps/<app>/`
- **where** it runs, and with which values → `clusters/<cluster>/`

Thin **generated** kustomizations ("joins") at `apps/<app>/clusters/<cluster>/` connect the two, so

```sh
kustomize build apps/<app>/clusters/<cluster>     # or: scripts/render <app> <cluster>
```

is exactly what Argo CD applies on that cluster.

## Layout

```
apps/<app>/
  argocd.yaml              default Argo settings (sync.wave, sync.automated.*)
  base/                    the app
  overlays/<intent>/       named by intent: prod, qa, prod-abc, … (not by cluster)
  mixins/<name>/           optional Components: canary, ha, …
  clusters/<cluster>/      GENERATED join + resolved argocd.json — never edit
clusters/<cluster>/
  facts/                   Component (identical for every cluster) + facts.yaml: name, domain,
                           clusterType, environment; local-config, never emitted
  apps.yaml                this cluster's exceptions to its profiles
  argocd/                  what the cluster's root Application syncs: its ApplicationSets
    kustomization.yaml     uses bootstrap/bases/<clusterType>
    revisions.env          the commit each ApplicationSet is pinned to (scripts/promote)
profiles/
  cluster-type/<type>.yaml which apps each cluster type runs
  environment/<env>.yaml   how apps are configured in each environment
tenants/<tenant>/          tenant config (stands in for a separate tenants repo; tenants/README.md)
bootstrap/                 ApplicationSets, bases, revisions Component, bootstrap steps (bootstrap/README.md)
docs/                      design notes (revision-pinning.md, revision-pinning-nested-matrix.md)
scripts/                   generate, lint, render, render-all, diff, new-cluster, promote, bootstrap-root, whatruns
tests/run.sh               acceptance tests (make test)
```

**Never edit `apps/*/clusters/*`.** Change a profile or `clusters/<cluster>/apps.yaml` and
run `make generate`. CI fails if the joins are out of date (`make check`).

A join holds only one overlay, zero or more mixins, and the cluster facts (always last).
It never holds patches. Facts are values only; release or canary state belongs in
mixins and overlays.

## Cluster types and environments

Every cluster has a **clusterType** (`hub`, `workload`) and an **environment** (`qa`,
`prod`), set in `clusters/<cluster>/facts/facts.yaml`. Cluster names follow
`<environment>-<clusterType>-<region>-<id>` (e.g. `prod-workload-east-2`, `prod-hub-east-1`),
so they sort by environment; lint and `new-cluster` check the name matches the facts.

```yaml
data:
  name: prod-workload-east-2
  domain: apps.east2.example.com
  clusterType: workload
  environment: prod
```

- **Which ApplicationSets run** follows the clusterType: the cluster's
  `argocd/kustomization.yaml` uses `bootstrap/bases/<clusterType>`. `hub` runs cluster-config;
  `workload` runs cluster-config and tenant-config. Lint checks the base matches.
- **Which apps are generated, and how they're configured,** come from
  `profiles/cluster-type/<clusterType>.yaml`, then `profiles/environment/<environment>.yaml`,
  then the cluster's `apps.yaml` (see the rules below).

Adding a cluster type means a profile and a base; adding an environment means a profile
(and the overlays its entries name).

## Which commit a cluster runs

Each cluster pins a commit per ApplicationSet in `clusters/<cluster>/argocd/revisions.env`
(default: main). A change reaches a cluster only when that cluster's pin moves, which happens
through an MR (`make promote`). Pin and roll out clusters one at a time. See
[docs/revision-pinning.md](docs/revision-pinning.md).

## Override rules

**App lists** are resolved in three layers. At each layer an entry **replaces** the previous
entry for that app entirely (shallow, not a deep merge), and `<app>: null` removes it:

1. `profiles/cluster-type/<clusterType>.yaml` selects the apps.
2. `profiles/environment/<environment>.yaml` replaces entries, **only for apps the cluster
   type selected**. Listing an app here never adds it to a cluster, so the prod profile can
   configure `logging` without putting it on hubs.
3. `clusters/<cluster>/apps.yaml` replaces entries, adds apps (any key) or removes them.

Every resolved app must name its `overlay` explicitly; there is no default.

**Argo CD settings** are resolved per app in this order, later wins, deep merge:

1. `apps/<app>/argocd.yaml` `sync`
2. the cluster-type entry's `sync`
3. the environment entry's `sync` (only for apps the cluster type selected)
4. the cluster entry's `sync`

Before step 1 come the built-in defaults: `sync.automated.enabled`, `prune` and `selfHeal`
are all `true`. Set `enabled: false` to turn off automated sync for an app, for example
`sync: {automated: {enabled: false}}`. `sync.wave` has no default, so every app's `argocd.yaml` must set it.

The result is written to `apps/<app>/clusters/<cluster>/argocd.json`, which the
ApplicationSet reads. Every key is always present in that file, so every Application gets the full
`spec.syncPolicy.automated` block with explicit `enabled`, `prune` and `selfHeal`.

## Common tasks

| Task | How |
|---|---|
| See what runs where | `make whatruns` (or `scripts/whatruns <cluster>`): reads each cluster's pinned commit |
| Preview the rendered effect of your change | `make diff` (renders `origin/main` and your working tree; writes `rendered/manifests.diff`) |
| Add an app | Create `apps/<app>/{argocd.yaml,base/,overlays/<intent>/}`, select it in a cluster-type profile (configure it per environment) or add it in a cluster's `apps.yaml`, `make generate` |
| Add a cluster | `make new-cluster NAME=prod-workload-west-1 FROM=prod-workload-east-1 DOMAIN=apps.west1.example.com` (optionally `TYPE=hub ENVIRONMENT=qa`), then follow `bootstrap/README.md` |
| Change an app for a whole environment | Edit its entry in `profiles/environment/<env>.yaml`, `make generate` |
| Retarget an overlay on one cluster | In `clusters/<c>/apps.yaml`: `logging: {overlay: prod-abc}`, `make generate` |
| Run a canary | Add a mixin (e.g. `apps/logging/mixins/canary`) and in the cluster's `apps.yaml`: `logging: {overlay: prod, mixins: [canary], sync: {automated: {enabled: false}}}` |
| Remove an app from one cluster | In `clusters/<c>/apps.yaml`: `monitoring: null`, `make generate` |
| Give a cluster tenants | Make it a `workload` cluster, add `tenants/<tenant>/clusters/<c>/` (see `tenants/README.md`) |
| One-off cluster exception | An overlay named after the cluster is allowed but must have `metadata.annotations.owner` and `reason`; `make check` lists them as warnings |
| Roll out a change | Merge it to main, then `make promote CLUSTER=<c> REF=main` and open an MR, one cluster at a time. Roll back by promoting the previous SHA. See `bootstrap/README.md` |

Since each layer's entry replaces the previous one, repeat the overlay and any mixins you
want to keep (prod-workload-east-2's `monitoring` drops the prod profile's `ha` this way).

## Tooling

kustomize v5.4+ (the standalone binary), mikefarah yq v4, bash 4+, git. dyff is optional
and is used by `scripts/diff` when installed. `make check` runs `generate --check` and `lint`;
`make test` runs the acceptance tests in temp copies of the repo.

## Decisions where the spec was ambiguous

- **Earlier layers' `sync` when a later layer replaces the entry:** rule 6 is applied
  literally. Each layer's `sync` is still merged under the next one's, even though the rest
  of the entry (overlay, mixins) is replaced. To drop a setting, set it explicitly later.
- `generate --check` regenerates in a temp copy and diffs the whole `apps/` tree. Only
  generated files can differ there.
- The cluster kustomization lint checks (`facts/` and `argocd/` must be identical for every
  cluster, apart from `argocd/`'s base) compare each cluster to the alphabetically first one.
- `make render-all` writes to `rendered/<cluster>/`. `scripts/diff` writes `rendered/manifests.diff`.
- Developed against kustomize v5.8.1 locally. CI pins v5.4.3.
