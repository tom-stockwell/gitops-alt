# Alternative: revision pinning with a nested matrix generator

This repo pins revisions with a root Application per cluster that renders kustomized
ApplicationSets ([revision-pinning.md](revision-pinning.md)). This doc describes the
alternative: identical ApplicationSets on every cluster that read each cluster's pins from a
`revisions.yaml` on main, using a nested matrix generator. It isn't implemented here.

The goals are the same either way:
- Each cluster pins a commit per ApplicationSet, in this repo.
- Promoting a cluster is an MR that changes only its pin, one cluster at a time.
- Each ApplicationSet uses the same revision for its git generator (which apps exist, their
  sync settings) and for `targetRevision` (their manifests).

## When to prefer it

**Prefer the nested matrix when every cluster's local Argo CD cluster Secret can be relied on
to be set up correctly**: present, labelled `gitops.example.com/local: "true"`, with the
right `name`. For example, when the platform's cluster provisioning creates it rather than a
person.

**Otherwise use the root-app approach in use here.** It doesn't depend on that Secret, because
the cluster name comes from `clusters/<cluster>/facts/`.

What you gain with the nested matrix:
- Fewer moving parts: no root Application, bases, revisions Component or local-config
  ConfigMaps. Each ApplicationSet is a single plain file, identical everywhere.
- Each cluster's pins are a small YAML file, with no Kustomize to understand.

What you give up:
- **The cluster Secret becomes a source of truth.** If it's missing, mislabelled or has the
  wrong `name`, the ApplicationSets silently generate nothing (or another cluster's apps).
- **The ApplicationSets aren't managed from git** unless you add something to sync them, such
  as a root app.
- **Unverified Argo behaviour:** it relies on passing parameters through a nested matrix (see
  [Risks](#risks)).

## How it works

```
cluster Secret (local)                       → .name, .server, .metadata.labels
  → git (main)  clusters/<name>/revisions.yaml → the cluster's pins
  → git (<pin>) apps/*/clusters/<name>/argocd.json → one Application per app
```

### The pins: `clusters/<cluster>/revisions.yaml`

One file per cluster on main, with a key per ApplicationSet. A missing key means main.

```yaml
# clusters/prod-workload-east-2/revisions.yaml
# Commit each ApplicationSet runs on this cluster. Change with scripts/promote, one cluster per MR.
cluster-config: 3f2c9a1e4b7d6c5a8f9e0d1c2b3a4f5e6d7c8b9a
tenant-config: 9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c
```

The file must exist, even if it's empty (`{}`). Without it the inner git generator produces
no parameters, and the cluster gets no Applications.

### The cluster Secret

Created at bootstrap by provisioning, or by a script like the `bootstrap-secret` this repo
used to have. Labels decide which ApplicationSets a cluster runs, taking the place of
`bootstrap/bases/`.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: in-cluster
  namespace: openshift-gitops
  labels:
    argocd.argoproj.io/secret-type: cluster
    gitops.example.com/local: "true"
    gitops.example.com/tenants: "true"       # only on clusters that run tenant-config
stringData:
  name: prod-workload-east-2
  server: https://kubernetes.default.svc
```

### The ApplicationSets

`cluster-config`, identical on every cluster:

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
      # 1. Which cluster am I, and what are its pins? (read from main)
      - matrix:
          generators:
          - clusters:
              selector:
                matchLabels:
                  gitops.example.com/local: "true"
          - git:
              repoURL: https://git.example.com/platform/gitops.git
              revision: main
              pathParamPrefix: pins       # keeps this file's path params out of .path.*
              files:
              - path: 'clusters/{{.name}}/revisions.yaml'
      # 2. What runs at the pinned commit.
      - git:
          repoURL: https://git.example.com/platform/gitops.git
          revision: '{{ dig "cluster-config" "main" . }}'
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
        targetRevision: '{{ dig "cluster-config" "main" . }}'
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

`tenant-config` is the same pattern, with three differences:
- the cluster selector adds `gitops.example.com/tenants: "true"`;
- it reads the `tenant-config` key: `{{ dig "tenant-config" "main" . }}`;
- its generator path is `tenants/*/clusters/{{.name}}/argocd.json`, and Applications are named
  `tenant-{{.tenant}}`.

Notes on the templates:
- **Hyphenated keys need `dig` (or `index`):** `{{.cluster-config}}` isn't valid template
  syntax. `dig` also supplies the `main` default when a cluster doesn't pin that ApplicationSet.
  Unlike `missingkey=error`, it doesn't fail on a missing key.
- **`pathParamPrefix` is required:** both git generators produce `.path.*` parameters. The
  prefix moves the pins file's to `.pins.path.*`, so `.path.path` is still the app's directory.
- **The nested matrix must be the first child:** the outer matrix passes the first child's
  parameters (`.name`, the pins) into the second child. Argo CD allows only one level of
  matrix nesting.

## Day to day

| Task | How |
|---|---|
| Promote a cluster | `scripts/promote <cluster> <ref> [--appset <name>]` writes the full SHA into `clusters/<cluster>/revisions.yaml`; MR; merge |
| Roll back | Promote the previous SHA, or `git revert` the promote commit |
| Track main | Remove the key |
| Give a cluster tenants | Add the `gitops.example.com/tenants: "true"` label to its Secret (outside git) |
| Add an ApplicationSet | Add another identical ApplicationSet reading its own key, selecting clusters by label |

A pin change takes effect at the next generator refresh (about 3 minutes by default) unless a
git webhook triggers the ApplicationSet controller. A `main` default follows main the same way.

## Switching this repo to it

1. **Pins:** move each `clusters/<c>/argocd/revisions.env` to `clusters/<c>/revisions.yaml`
   (`key=value` → `key: value`).
2. **Remove:** `clusters/<c>/argocd/`, `bootstrap/bases/`, `bootstrap/revisions/`,
   `bootstrap/appset-revisions/` and `scripts/bootstrap-root`.
3. **ApplicationSets:** replace the `REVISION`/`CLUSTER` placeholders in
   `bootstrap/appsets/<name>/applicationset.yaml` with the templates above.
4. **Bootstrap:** bring back a `scripts/bootstrap-secret` that prints the Secret with the
   right labels. Bootstrap becomes applying the Secret and the ApplicationSets.
5. **Scripts:**
   - `promote`, `lint` and `whatruns` read and write `revisions.yaml` with yq instead of the
     `.env` helpers.
   - lint keeps its checks: full SHA or main, known ApplicationSet, and a pinned commit that
     contains the cluster's joins.
   - Lint can't check which ApplicationSets a cluster runs, because that's now in its Secret's
     labels.
6. **Facts:** `clusters/<c>/facts/` can stay where it is. The joins still use it, and only
   the ApplicationSets stop needing it.

## Risks

- **Nested-matrix parameter passing is unverified.** Before relying on it, test on your Argo
  CD version that:
  - `.name` reaches the inner git generator's path;
  - the pins and `.name` reach the outer git generator's `revision` and `files`;
  - `.server` and the pins reach the template.
- **A missing or wrong Secret fails silently.** Monitor the ApplicationSet's status
  conditions, or alert when a cluster has no Applications.
- **A missing `revisions.yaml`** also yields no Applications, so keep one per cluster. Lint
  can check this.
- **ApplicationSet changes reach every cluster at once,** the same gap as the root-app
  approach.
