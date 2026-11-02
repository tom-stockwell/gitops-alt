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
  argocd.yaml              Argo settings (sync.wave, sync.automated.*), the same on every cluster
  base/                    the app
  components/<name>/       modular Components, one concern each (resources-large, canary, …); used by profiles
  profiles/<profile>/      Components that select the app for clusters and configure it (below)
    per-cluster/           the app's replacements from cluster facts (optional)
  clusters/<cluster>/      GENERATED join + resolved argocd.json — never edit
clusters/<cluster>/
  facts/                   Component (identical for every cluster) + facts.yaml: name, domain,
                           clusterType, environment; local-config, never emitted
  argocd/                  what the cluster's root Application syncs: its ApplicationSets
    kustomization.yaml     uses bootstrap/bases/<clusterType>
    revisions.env          the commit each ApplicationSet is pinned to (scripts/promote)
tenants/<tenant>/          tenant config (stands in for a separate tenants repo; tenants/README.md)
bootstrap/                 ApplicationSets, bases, revisions Component, bootstrap steps (bootstrap/README.md)
docs/                      design notes (revision-pinning.md, revision-pinning-nested-matrix.md)
scripts/                   generate, lint, render, render-all, diff, new-cluster, promote, bootstrap-root, whatruns
tests/run.sh               acceptance tests (make test)
```

**Never edit `apps/*/clusters/*`.** Add or change a profile and run `make generate`. CI fails
if the joins are out of date (`make check`).

A join (the cluster overlay) holds the app's `base`, the cluster facts, every profile of the
app that matches the cluster, and `profiles/per-cluster`. It never holds patches.

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

**Which ApplicationSets run** follows the clusterType: the cluster's
`argocd/kustomization.yaml` uses `bootstrap/bases/<clusterType>`. `hub` runs cluster-config;
`workload` runs cluster-config and tenant-config. Lint checks the base matches.

## Profiles: which apps run where, and how

Each app has kustomize Components under `apps/<app>/profiles/`, named after cluster facts.
A cluster matches these names:

| Profile | Example (`prod-hub-east-1`) |
|---|---|
| `<environment>` | `prod` |
| `<clusterType>` | `hub` |
| `<environment>-<clusterType>` | `prod-hub` |
| `<cluster>` | `prod-hub-east-1` |

**An app runs on a cluster if it has at least one profile the cluster matches.** For
example, `prod-hub-east-1` gets every app with a `prod`, `hub`, `prod-hub` or
`prod-hub-east-1` profile. No list of apps per cluster exists. Add a profile to put an app on
clusters, and delete it to take the app off. Apps run on sets of clusters: if some clusters
need an app and others don't, they should be different profiles (clusterType or environment).
An `<environment>` profile selects the app for every cluster type in that environment, so an
app that only runs on workload clusters uses `prod-workload`/`qa-workload` rather than
`prod`/`qa` (see `apps/logging/profiles/`).

**`<cluster>` profiles are one-off exceptions and should not normally exist.** Give each one
`# owner:` and `# reason:` comments at the top of its `kustomization.yaml`. They should generally
only be used if an app needs per-cluster changes that can't be implemented using replacements
from cluster facts.
`apps/gpu-operator/profiles/prod-workload-east-2/` is one example.

A profile with nothing to change still has to be a valid Component. kustomize rejects one
with no fields, so give it `resources: []` (see `apps/cert-manager/profiles/qa/`).

**`apps/<app>/profiles/per-cluster/`** holds the app's replacements from the cluster facts (route
hosts, cluster names, …). It is included in every cluster overlay for the app, but no cluster
matches its name, so it never selects the app. It's optional. The cluster's `facts/` Component only supplies the
`cluster-facts` ConfigMap. The replacements that use it live with the app, so each app
decides which of its fields come from facts.

Components in a cluster overlay, in order:

1. `clusters/<cluster>/facts`: the facts ConfigMap
2. `profiles/<environment>`, `profiles/<clusterType>`, `profiles/<environment>-<clusterType>`
   (those that exist)
3. `profiles/per-cluster`: after those, so it fills placeholders they add
4. `profiles/<cluster>`: last, so it can override anything

Lint warns about profiles that match no cluster (usually a typo).

### Components

`apps/<app>/components/<name>/` are small, single-purpose Components: one patch or setting
each, named for what they do (`replicas-3`, `ha`, `canary`, `issuer-letsencrypt-prod`). Profiles
compose them with `components: [../../components/<name>]`, so a change shared by several
profiles is made once. For example, logging's `qa-workload` and `prod-workload-east-2` profiles
both use `components/canary`. A component never selects an app and is never listed in a
cluster overlay directly. Lint warns about components that no profile uses. An app directory
may only contain `argocd.yaml`, `base/`, `components/`, `profiles/` and `clusters/`.

### Argo CD settings

Argo CD settings are set per app only, in `apps/<app>/argocd.yaml`, and are the same on every
cluster the app runs on. Profiles can't change them (lint rejects an `argocd.yaml` in a
profile). On top of built-in defaults (`sync.automated.enabled`, `prune` and `selfHeal` all
`true`), `argocd.yaml` sets `sync.wave` (required) and optionally `sync.automated.*`, e.g.
`sync: {automated: {enabled: false}}` for manual sync.

The result is written to `apps/<app>/clusters/<cluster>/argocd.json` (app, cluster, the
matching profiles, sync), which the ApplicationSet reads. Every key is always present in that
file, so every Application gets the full `spec.syncPolicy.automated` block with explicit
`enabled`, `prune` and `selfHeal`.

## Which commit a cluster runs

Each cluster pins a commit per ApplicationSet in `clusters/<cluster>/argocd/revisions.env`
(default: main). A change reaches a cluster only when that cluster's pin moves, which happens
through an MR (`make promote`). Pin and roll out clusters one at a time. See
[docs/revision-pinning.md](docs/revision-pinning.md).

## Common tasks

| Task | How |
|---|---|
| See what runs where | `make whatruns` (or `scripts/whatruns <cluster>`): reads each cluster's pinned commit |
| Preview the rendered effect of your change | `make diff` (renders `origin/main` and your working tree; writes `rendered/manifests.diff`) |
| Add an app | Create `apps/<app>/{argocd.yaml,base/}`, at least one profile under `profiles/` (built from `components/`), and `profiles/per-cluster/` if it uses cluster facts. Then `make generate` |
| Add a cluster | `make new-cluster NAME=prod-workload-west-1 FROM=prod-workload-east-1 DOMAIN=apps.west1.example.com` (optionally `TYPE=hub ENVIRONMENT=qa`), then follow `bootstrap/README.md` |
| Put an app on a set of clusters | Add `apps/<app>/profiles/<environment\|clusterType\|environment-clusterType>/`, `make generate` |
| Take an app off a set of clusters | Delete the profile that selects it there, `make generate` |
| Change an app for an environment | Edit `apps/<app>/profiles/<env>/` (or `<env>-<clusterType>/`), `make generate` |
| Change Argo CD settings for an app | Edit `apps/<app>/argocd.yaml` (applies on every cluster), `make generate` |
| Run a canary on one cluster | `apps/<app>/profiles/<cluster>/` with the canary change (see `apps/logging/profiles/prod-workload-east-2/`). Delete it afterwards |
| Give a cluster tenants | Make it a `workload` cluster, add `tenants/<tenant>/clusters/<c>/` (see `tenants/README.md`) |
| Roll out a change | Merge it to main, then `make promote CLUSTER=<c> REF=main` and open an MR, one cluster at a time. Roll back by promoting the previous SHA. See `bootstrap/README.md` |

## Tooling

kustomize v5.4+ (the standalone binary), mikefarah yq v4, bash 4+, git. dyff is optional
and is used by `scripts/diff` when installed. `make check` runs `generate --check` and `lint`;
`make test` runs the acceptance tests in temp copies of the repo.

## Decisions where the spec was ambiguous

- **Combined profile name:** `<environment>-<clusterType>` (e.g. `prod-hub`), matching the
  cluster name prefix.
- `generate --check` regenerates in a temp copy and diffs the whole `apps/` tree. Only
  generated files can differ there.
- The cluster kustomization lint checks (`facts/` and `argocd/` must be identical for every
  cluster, apart from `argocd/`'s base) compare each cluster to the alphabetically first one.
- `make render-all` writes to `rendered/<cluster>/`. `scripts/diff` writes `rendered/manifests.diff`.
- Developed against kustomize v5.8.1 locally. CI pins v5.4.3.
