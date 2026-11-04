# Multi-cluster GitOps example

Kustomize config for several OpenShift clusters, each running its own Argo CD
(argocd-agent, autonomous mode). The repo separates:

- **how** an app is configured → `apps/<app>/`
- **where** it runs, and with which values → `clusters/<cluster>/`

Thin **generated** kustomizations ("joins") at `apps/<app>/clusters/<cluster>/` connect the two, so

```sh
kustomize build apps/<app>/clusters/<cluster>     # or: just render apps/<app>/clusters/<cluster>
```

is exactly what Argo CD applies on that cluster.

## Layout

```
apps/<app>/
  argocd.yaml              Argo settings (sync.wave, sync.automated.*), the same on every cluster
  base/                    the app
  components/<name>/       modular Components, one concern each (resources-large, canary, …); used by facets
  facets/                  Components that select the app for clusters and configure it (below)
    <key>/<value>[-<env>]/ key is environment, role, topology, region or platform
    per-cluster/           the app's replacements from cluster facts (optional)
    cluster/<cluster>/     one-off exception for one cluster (should rarely exist)
  clusters/<cluster>/      GENERATED join + resolved argocd.json — never edit
clusters/<cluster>/
  facts/                   Component (identical for every cluster) + facts.yaml: name, domain,
                           environment, role, topology, region, platform; local-config, never emitted
  argocd/                  what the cluster's root Application syncs: its ApplicationSets
    kustomization.yaml     uses bootstrap/bases/<role>
    revisions.env          the commit each ApplicationSet is pinned to (scripts/promote)
tenants/<tenant>/          tenant config (stands in for a separate tenants repo; tenants/README.md)
bootstrap/                 ApplicationSets, bases, revisions Component, bootstrap steps (bootstrap/README.md)
docs/                      design notes (revision-pinning.md, revision-pinning-nested-matrix.md)
scripts/                   generate, lint, render, render-all, diff, new-cluster, promote, bootstrap-root, whatruns
tests/run.sh               acceptance tests (just test)
```

**Never edit `apps/*/clusters/*`.** Add or change a facet and run `just generate`. CI fails
if the joins are out of date (`just check`).

A join (the cluster overlay) holds the app's `base`, the cluster facts, every facet of the app
that matches the cluster, and `facets/per-cluster`. It never holds patches.

## Cluster facts

Every cluster sets these in `clusters/<cluster>/facts/facts.yaml` (all required):

| Fact | Meaning | Examples |
|---|---|---|
| `name`, `domain` | used by apps' replacements | `prod-workload-east-2`, `east2.example.com` |
| `environment` | lifecycle environment | `qa`, `prod` |
| `role` | what the cluster is for | `hub`, `workload` |
| `topology` | how the control plane is laid out | `sno`, `two-node-arbiter`, `standard` (3 nodes), `compact` (control plane nodes are also workers) |
| `region` | where it runs | `us-east-1` |
| `platform` | what it's built on | `aws`, `rosa`, `hcp`, `baremetal` |

```yaml
data:
  name: prod-workload-east-2
  domain: east2.example.com
  environment: prod
  role: workload
  topology: compact
  region: us-east-2
  platform: baremetal
```

Cluster names follow `<environment>-<role>-<region>-<id>` (e.g. `prod-workload-east-2`), so
they sort by environment; lint and `new-cluster` check the name matches the facts.

**Which ApplicationSets run** follows the role: the cluster's `argocd/kustomization.yaml` uses
`bootstrap/bases/<role>`. `hub` runs cluster-config; `workload` runs cluster-config and
tenant-config. Lint checks the base matches.

## Facets: which apps run where, and how

Each app has kustomize Components under `apps/<app>/facets/`, laid out by cluster fact:
`facets/<key>/<value>[-<environment>]/`. A cluster matches, for example
(`prod-workload-east-2`):

| Facet | Matches |
|---|---|
| `environment/<env>` | `environment/prod` (never suffixed) |
| `role/<role>[-<env>]` | `role/workload`, `role/workload-prod` |
| `topology/<topology>[-<env>]` | `topology/compact`, `topology/compact-prod` |
| `region/<region>[-<env>]` | `region/us-east-2`, `region/us-east-2-prod` |
| `platform/<platform>[-<env>]` | `platform/baremetal`, `platform/baremetal-prod` |
| `cluster/<cluster>` | `cluster/prod-workload-east-2` (never suffixed) |

**An app runs on a cluster if it has at least one facet the cluster matches.** No list of
apps per cluster exists. Add a facet to put an app on clusters, and delete it to take the app
off. Apps run on sets of clusters: if some clusters need an app and others don't, they should
differ in a fact. For example, gpu-operator has only `platform/baremetal`, so it runs only on
baremetal clusters.

**The `-<environment>` suffix promotes a facet through environments.** `role/workload-qa`
applies to qa workload clusters only. To roll a change forward, add it as `<value>-qa`, then
`<value>-prod`, and fold it into `<value>` (all environments) once it's everywhere. Logging's
`role/workload-qa` and `role/workload-prod` are examples. Note that an `environment/<env>` facet
selects the app for every role in that environment. An app that only runs on workload clusters
uses `role/workload[-<env>]` instead.

**`cluster/<cluster>` facets are one-off exceptions and should not normally exist.** Give each one
`# owner:` and `# reason:` comments at the top of its `kustomization.yaml`. They should generally
only be used if an app needs per-cluster changes that can't be implemented using replacements
from cluster facts, or with a facet.
`apps/logging/facets/cluster/prod-workload-east-2/` (a canary) is one example.

A facet with nothing to change still has to be a valid Component. kustomize rejects one with
no fields, so give it `resources: []` (see `apps/cert-manager/facets/environment/qa/`).

**`apps/<app>/facets/per-cluster/`** holds the app's replacements from the cluster facts (route
hosts, cluster names, …). It is included in every cluster overlay for the app, but it never
selects the app. It's optional. The cluster's `facts/` Component only supplies the
`cluster-facts` ConfigMap. The replacements that use it live with the app, so each app decides
which of its fields come from facts.

Components in a cluster overlay, in order (later wins):

1. `clusters/<cluster>/facts`: the facts ConfigMap
2. `facets/environment/<env>`
3. `facets/role/<role>`, then `facets/role/<role>-<env>`
4. the same for `topology`, `region`, then `platform`
5. `facets/per-cluster`: after those, so it fills placeholders they add
6. `facets/cluster/<cluster>`: last, so it can override anything

So key order is precedence: `topology/compact` (monitoring without HA) overrides
`environment/prod` (monitoring with HA) on prod-workload-east-2.

Lint checks facets against the facts the clusters actually have:

- **Error:** an invalid facet: a value no cluster has (`platform/gcp` with no gcp cluster), a
  suffix that isn't an environment any cluster has (`role/workload-staging`), a `cluster/<name>`
  for a cluster that doesn't exist, or anything else under `facets/` (unknown keys, stray files).
  Add the cluster first, then its facets.
- **Warning:** a valid facet no single cluster matches, e.g. `role/hub-qa` while there's no qa hub.
  The same goes for a component no facet uses.
- **Error:** a cluster overlay that doesn't match the facets, i.e. `just generate` wasn't run. That
  covers an overlay that's missing, one that should be gone, or one whose components or
  `argocd.json` differ from what generate would write.

`just generate` also deletes overlays nothing selects any more, including all overlays of a
deleted cluster.

### Components

`apps/<app>/components/<name>/` are small, single-purpose Components: one patch or setting
each, named for what they do (`replicas-3`, `ha`, `canary`, `issuer-letsencrypt-prod`). Facets
compose them with `components: [../../../components/<name>]`, so a change shared by several facets is made once. For example,
logging's `role/workload-qa` and `prod-workload-east-2` facets both use `components/canary`. A component never selects an app and is never listed in a
cluster overlay directly. Lint warns about components that no facet uses. An app directory
may only contain `argocd.yaml`, `base/`, `components/`, `facets/` and `clusters/`.

### Argo CD settings

Argo CD settings are set per app only, in `apps/<app>/argocd.yaml`, and are the same on every
cluster the app runs on. Facets can't change them (lint rejects an `argocd.yaml` in a
facet). On top of built-in defaults (`sync.automated.enabled`, `prune` and `selfHeal` all
`true`), `argocd.yaml` sets `sync.wave` (required) and optionally `sync.automated.*`, e.g.
`sync: {automated: {enabled: false}}` for manual sync.

The result is written to `apps/<app>/clusters/<cluster>/argocd.json` (app, cluster, the
matching facets, sync), which the ApplicationSet reads. Every key is always present in that
file, so every Application gets the full `spec.syncPolicy.automated` block with explicit
`enabled`, `prune` and `selfHeal`.

## Which commit a cluster runs

Each cluster pins a commit per ApplicationSet in `clusters/<cluster>/argocd/revisions.env`
(default: main). A change reaches a cluster only when that cluster's pin moves, which happens
through an MR (`just promote`). Pin and roll out clusters one at a time. See
[docs/revision-pinning.md](docs/revision-pinning.md).

## Common tasks

| Task | How |
|---|---|
| See what runs where | `just whatruns` (or `scripts/whatruns <cluster>`): reads each cluster's pinned commit |
| Preview the rendered effect of your change | `just diff` (renders `origin/main` and your working tree; writes `rendered/manifests.diff`) |
| Add an app | Create `apps/<app>/{argocd.yaml,base/}`, at least one facet under `facets/` (built from `components/`), and `facets/per-cluster/` if it uses cluster facts. Then `just generate` |
| Add a cluster | `just new-cluster prod-workload-west-1 prod-workload-east-1 --domain west1.example.com` (optionally `--environment`, `--role`, `--topology`, `--region`, `--platform`; the rest are copied from the source cluster), then follow `bootstrap/README.md` |
| Put an app on a set of clusters | Add `apps/<app>/facets/<key>/<value>/`, `just generate` |
| Take an app off a set of clusters | Delete the facet that selects it there, `just generate` |
| Change an app for an environment | Edit `apps/<app>/facets/environment/<env>/` (or `<key>/<value>-<env>/`), `just generate` |
| Promote a change through environments | Add it to `facets/<key>/<value>-qa/`, then `<value>-prod/`, then move it into `<value>/` |
| Change Argo CD settings for an app | Edit `apps/<app>/argocd.yaml` (applies on every cluster), `just generate` |
| Run a canary on one cluster | `apps/<app>/facets/cluster/<cluster>/` with the canary change (see `apps/logging/facets/cluster/prod-workload-east-2/`). Delete it afterwards |
| Give a cluster tenants | Make it a `workload` cluster, add `tenants/<tenant>/clusters/<c>/` (see `tenants/README.md`) |
| Roll out a change | Merge it to main, then `just promote <c> main` and open an MR, one cluster at a time. Roll back by promoting the previous SHA. See `bootstrap/README.md` |

## Tooling

kustomize v5.4+ (the standalone binary), mikefarah yq v4, bash 4+, git, and
[just](https://github.com/casey/just) for the recipes (each wraps a script in `scripts/`;
`just` lists them). dyff is optional and is used by `scripts/diff` when installed. `just check`
runs lint, which also fails if any overlay isn't what `just generate` would write; `just test` runs the acceptance tests in temp copies of the
repo. `just build` is an alias for `just generate`.

## Notes

- The cluster kustomization lint checks (`facts/` and `argocd/` must be identical for every
  cluster, apart from `argocd/`'s base) compare each cluster to the alphabetically first one.
- `just render-all` writes to `rendered/<cluster>/`. `scripts/diff` writes `rendered/manifests.diff`.
- Developed against kustomize v5.8.1 locally. CI pins v5.4.3.
