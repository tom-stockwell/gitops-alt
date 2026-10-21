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
  argocd.yaml            default Argo settings (sync.wave, sync.automated.*)
  base/                  the app
  overlays/<intent>/     named by intent: prod, prod-abc, … (not by cluster)
  mixins/<name>/         optional Components: canary, ha, …
  clusters/<cluster>/    GENERATED join + resolved argocd.json — never edit
clusters/<cluster>/
  kustomization.yaml     Component; identical for every cluster
  facts.yaml             values only (name, domain); local-config, never emitted
  apps.yaml              which apps run here: extends a profile, lists differences
profiles/<profile>.yaml  default app lists
bootstrap/               the ApplicationSet and bootstrap steps (bootstrap/README.md)
scripts/                 generate, lint, render, render-all, diff, new-cluster, bootstrap-secret, whatruns
tests/run.sh             acceptance tests (make test)
```

**Never edit `apps/*/clusters/*`.** Change `clusters/<cluster>/apps.yaml` or a profile and
run `make generate`. CI fails if the joins are out of date (`make check`).

A join holds only one overlay, zero or more mixins, and the cluster facts (always last).
It never holds patches. Facts are values only; release or canary state belongs in
mixins and overlays.

## Override rules

**App lists** (`profiles/<p>.yaml` + `clusters/<c>/apps.yaml` with `extends: <p>`):

- A cluster entry **replaces** the profile entry for that app entirely (shallow, not a deep merge).
- `<app>: null` removes the app from that cluster.
- A key that isn't in the profile adds the app.

**Argo CD settings** are resolved per app in this order, later wins, deep merge:

1. `apps/<app>/argocd.yaml` `sync`
2. the profile entry's `sync`
3. the cluster entry's `sync`

Before step 1 come the built-in defaults: `sync.automated.enabled`, `prune` and `selfHeal`
are all `true`. Set `enabled: false` to turn off automated sync for an app, for example
`sync: {automated: {enabled: false}}`. `sync.wave` has no default, so every app's `argocd.yaml` must set it.

The result is written to `apps/<app>/clusters/<cluster>/argocd.json`, which the
ApplicationSet reads. Every key is always present in that file, so every Application gets the full
`spec.syncPolicy.automated` block with explicit `enabled`, `prune` and `selfHeal`.

## Common tasks

| Task | How |
|---|---|
| See what runs where | `make whatruns` (or `scripts/whatruns <cluster>`) |
| Preview the rendered effect of your change | `make diff` (renders `origin/main` and your working tree; writes `rendered/manifests.diff`) |
| Add an app | Create `apps/<app>/{argocd.yaml,base/,overlays/<intent>/}`, add it to a profile or a cluster's `apps.yaml`, `make generate` |
| Add a cluster | `make new-cluster NAME=prod-west-1 FROM=prod-east-1 DOMAIN=apps.west1.example.com`, then follow `bootstrap/README.md` |
| Retarget an overlay | In `clusters/<c>/apps.yaml`: `logging: {overlay: prod-abc}`, `make generate` |
| Run a canary | Add a mixin (e.g. `apps/logging/mixins/canary`) and in the cluster's `apps.yaml`: `logging: {overlay: prod, mixins: [canary], sync: {automated: {enabled: false}}}` |
| Remove an app from one cluster | In `clusters/<c>/apps.yaml`: `monitoring: null`, `make generate` |
| One-off cluster exception | An overlay named after the cluster is allowed but must have `metadata.annotations.owner` and `reason`; `make check` lists them as warnings |
| Promote | Merge to main (wave 0 follows automatically), then run the manual `promote-wave-1` and `promote-wave-2` CI jobs. See `bootstrap/README.md` |

Since a cluster entry replaces the profile entry, remember to repeat the overlay and any
mixins you want to keep (prod-east-2's `monitoring` drops `ha` this way).

## Tooling

kustomize v5.4+ (the standalone binary), mikefarah yq v4, bash 4+, git. dyff is optional
and is used by `scripts/diff` when installed. `make check` runs `generate --check` and `lint`;
`make test` runs the acceptance tests in temp copies of the repo.

## Decisions where the spec was ambiguous

- **Profile `sync` when a cluster replaces the entry:** rule 6 is applied literally. The
  profile entry's `sync` is still merged under the cluster entry's `sync`, even though the
  rest of the profile entry (overlay, mixins) is replaced. To drop a profile sync setting,
  set it explicitly in the cluster entry.
- `generate --check` regenerates in a temp copy and diffs the whole `apps/` tree. Only
  generated files can differ there.
- The cluster kustomization lint check (every cluster's file must be identical) compares
  each cluster to the alphabetically first one (prod-east-1).
- `make render-all` writes to `rendered/<cluster>/`. `scripts/diff` writes `rendered/manifests.diff`.
- Developed against kustomize v5.8.1 locally. CI pins v5.4.3.
