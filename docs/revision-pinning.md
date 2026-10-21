# Revision pinning

Each cluster pins, in this repo, the commit each of its ApplicationSets runs. Promoting a
cluster is an MR that changes only its pin, so a staged rollout is a series of MRs, one
cluster at a time. Every pin change is reviewed and recorded in git history. Nothing that
decides what a cluster runs lives outside the repo.

Each ApplicationSet uses **the same revision** for its git generator (which apps exist and
their sync settings) and for each Application's `targetRevision` (their manifests). If the two
differed, an app added on main could point at a path that doesn't exist at the pinned commit.

## How it works (in use)

```
root Application (per cluster, tracks main)
  └─ clusters/<cluster>/argocd/          kustomize build:
       bootstrap/appsets                   ApplicationSets with REVISION/CLUSTER placeholders,
                                           plus appset-revisions ConfigMap (defaults: main)
       + clusters/<cluster>/argocd/revisions.env   merged over the defaults
       + clusters/<cluster>/facts          cluster-facts ConfigMap (name)
       + bootstrap/revisions               replacements fill the placeholders
  → ApplicationSet cluster-config @ <pin>
       → one Application per apps/*/clusters/<cluster>/argocd.json @ <pin>
```

- `appset-revisions` and `cluster-facts` are local-config ConfigMaps. They feed the
  replacements and are never applied to the cluster.
- The cluster's `configMapGenerator` merge happens before the `bootstrap/revisions`
  Component runs, so the replacements see the cluster's pins.
- The facts live in `clusters/<cluster>/facts/` rather than directly in `clusters/<cluster>/`,
  because Kustomize won't load a parent directory. `clusters/<cluster>/argocd/` couldn't
  otherwise use them.
- Bootstrap needs no cluster Secret or cluster generator: `scripts/bootstrap-root <cluster>`
  prints the root Application, and the cluster name comes from the facts.

### One ConfigMap for all ApplicationSets

The pins live in one `appset-revisions` ConfigMap, generated from one `revisions.env` per
cluster, with a key per ApplicationSet:

```sh
# clusters/prod-east-1/argocd/revisions.env
cluster-config=3f2c9a1e4b7d6c5a8f9e0d1c2b3a4f5e6d7c8b9a
tenants=9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c   # once a tenants ApplicationSet exists
```

This is easier than a ConfigMap per ApplicationSet:
- Automation edits one file per cluster, one `key=value` line per ApplicationSet.
- Each ApplicationSet is still pinned and promoted separately: `scripts/promote <cluster> <ref> --appset tenants`.
- Adding an ApplicationSet doesn't touch any cluster's files. The cluster kustomization stays
  identical, and unset keys fall back to the defaults in `bootstrap/appsets/revisions.env`.

### Adding an ApplicationSet (e.g. tenants)

1. Add `bootstrap/appsets/tenants.yaml` with `REVISION` placeholders for both the generator
   `revision` and `targetRevision`, plus `CLUSTER` wherever the cluster name is needed. List
   it in `bootstrap/appsets/kustomization.yaml`.
2. Add `tenants=main` to `bootstrap/appsets/revisions.env`.
3. Add a replacement block for it in `bootstrap/revisions/kustomization.yaml`, selecting the
   ApplicationSet by name.

`make check` fails if any cluster's rendered ApplicationSets still contain a placeholder.

### Known gap

The root Application tracks main, so changes to `bootstrap/appsets/` and `bootstrap/revisions/`
(the ApplicationSet definitions themselves) reach every cluster as soon as they merge. Only
what the ApplicationSets *generate* is pinned. Keep ApplicationSet changes small and
backwards compatible, and preview them with `kustomize build clusters/<cluster>/argocd`.

## Alternative: one identical ApplicationSet, pin read through a nested matrix

**Prefer this when every cluster's local Argo CD cluster Secret can be relied on to be set up
correctly**: present, labelled `gitops.example.com/local: "true"`, with the right `name`. For
example, when the platform's cluster provisioning creates it rather than a person.
**Otherwise use the approach above**, which doesn't depend on that Secret.

With a reliable Secret, a single ApplicationSet, identical on every cluster, does it all:

```
cluster Secret → .name / .server
  → git (main) clusters/<name>/revision.yaml → .revision
  → git (.revision) apps/*/clusters/<name>/argocd.json → one Application per app
```

```yaml
# clusters/prod-east-1/revision.yaml   (the pin, on main)
revision: 3f2c9a1e4b7d6c5a8f9e0d1c2b3a4f5e6d7c8b9a
```

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cluster-config
  namespace: openshift-gitops
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
  - matrix:
      generators:
      # Which cluster am I, and which commit should I run? (read from main)
      - matrix:
          generators:
          - clusters:
              selector:
                matchLabels:
                  gitops.example.com/local: "true"
          - git:
              repoURL: https://git.example.com/platform/gitops.git
              revision: main
              pathParamPrefix: pin        # keeps this file's path params out of .path.*
              files:
              - path: 'clusters/{{.name}}/revision.yaml'
      # What runs at that commit.
      - git:
          repoURL: https://git.example.com/platform/gitops.git
          revision: '{{.revision}}'
          files:
          - path: 'apps/*/clusters/{{.name}}/argocd.json'
  template:
    metadata:
      name: '{{.app}}'
      annotations:
        argocd.argoproj.io/sync-wave: '{{.sync.wave}}'
    spec:
      project: default
      source:
        repoURL: https://git.example.com/platform/gitops.git
        targetRevision: '{{.revision}}'
        path: '{{.path.path}}'
      destination:
        server: '{{ .server }}'
  templatePatch: |
    spec:
      syncPolicy:
        automated:
          enabled: {{ dig "sync" "automated" "enabled" true . }}
          prune: {{ dig "sync" "automated" "prune" true . }}
          selfHeal: {{ dig "sync" "automated" "selfHeal" true . }}
```

| | Nested matrix | Root app + kustomized ApplicationSet (in use) |
|---|---|---|
| Applied by hand per cluster | the cluster Secret and the ApplicationSet | the root Application |
| ApplicationSet | one, identical everywhere; not managed from git unless you add a root app | rendered per cluster from a shared base, and managed from git |
| Cluster name comes from | the cluster Secret | `clusters/<cluster>/facts` |
| A pin change takes effect | at the next generator refresh (~3 min) or on a webhook | when the root app syncs |
| Risks | nested-matrix parameter passing must be verified on your Argo CD version; a wrong or missing Secret silently generates nothing | two layers to understand; ApplicationSet definitions themselves aren't pinned |

Notes if you switch to it:
- The nested matrix has to be the **first** child, so its `.name` and `.revision` reach the
  second git generator. Argo CD allows only one level of matrix nesting.
- `pathParamPrefix: pin` is required. Both git generators produce `.path.*` parameters.
- Keep `scripts/promote` and the lint checks. Only the pin's file (`revision.yaml`) and key
  change.
