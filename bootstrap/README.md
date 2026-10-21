# Bootstrapping a cluster

Every cluster runs its own Argo CD (OpenShift GitOps) with argocd-agent in
**autonomous** mode. The hub only aggregates status; it does not push config.

1. Add the cluster to Git first (`make new-cluster NAME=<name> FROM=<existing> DOMAIN=<domain>`),
   merge it, and make sure the `wave-N` tag you'll follow includes the commit.
2. Install the OpenShift GitOps operator and argocd-agent in autonomous mode. Use the
   cluster name (`clusters/<name>`) as the agent name so the hub's view matches the repo.
3. Tell Argo CD which cluster it is, and which promotion wave it follows:
   ```sh
   scripts/bootstrap-secret <name> --wave N | oc apply -f -
   ```
   This creates the `in-cluster` cluster Secret labelled `gitops.example.com/local: "true"`
   with `wave: "N"`.
4. Apply the ApplicationSet (byte-identical on every cluster):
   ```sh
   oc apply -f bootstrap/applicationset.yaml
   ```
   It reads `apps/*/clusters/<name>/argocd.json` at tag `wave-N` and creates one
   Application per app, each pointing at `apps/<app>/clusters/<name>`.
   Each Application deploys to the `server` of that Secret (`https://kubernetes.default.svc`).

## Waves, promotion and rollback

- Create the tags once: `git tag wave-0 && git tag wave-1 && git tag wave-2 && git push origin --tags`.
- Each cluster follows one tag (`wave` label on its Secret). Low waves are canaries.
- **Promotion** = moving a tag forward (CI `promote-wave-N` jobs: wave 0 automatic on
  main, waves 1 and 2 manual).
- **Rollback** = moving a tag back to an earlier commit:
  `git tag -f wave-1 <good-sha> && git push -f origin refs/tags/wave-1`.

## Assumptions to verify against your Argo CD version

- The git generator's `revision` is templated from matrix params
  (`wave-{{.metadata.labels.wave}}` comes from the cluster generator). Check that your
  ApplicationSet controller version supports templating `revision` inside a matrix.
- `spec.templatePatch` (used so `syncPolicy.automated` values render as booleans) needs
  Argo CD 2.10 or later.
- `spec.syncPolicy.automated.enabled` (used to turn off automated sync per app) is a newer
  field. Check that your Argo CD version supports it. Older versions reject or ignore it.
  Without it, automated sync is on whenever the `automated` block is present.
