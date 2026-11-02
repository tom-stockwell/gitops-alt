#!/usr/bin/env bash
# Acceptance tests T1–T18. Mutating tests run in temp copies of the repo.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)
# shellcheck source=../scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_tools kustomize yq git
ROOT=$(repo_root)
S=$ROOT/scripts

failures=0
current=""
t() { current=$1; echo "--- $1: $2"; }
fail() { echo "FAIL [$current]: $*"; failures=$((failures + 1)); }
expect_eq() { # <description> <expected> <actual>
  [[ $2 == "$3" ]] || fail "$1: expected '$2', got '$3'"
}
expect_ok() { # <description> <cmd...>
  local d=$1; shift
  "$@" >"$LOG" 2>&1 || { fail "$d: exited non-zero"; sed 's/^/    /' "$LOG"; }
}
expect_fail() { # <description> <cmd...>
  local d=$1; shift
  if "$@" >"$LOG" 2>&1; then fail "$d: expected non-zero exit"; fi
}

LOG=$(mktemp)
cleanup_add "$LOG"

# copy_repo: print a fresh temp copy of the working tree, committed in a new git repo.
copy_repo() {
  local d
  d=$(mktemp -d)
  cleanup_add "$d"
  tar -C "$ROOT" --exclude=./.git --exclude=./rendered -cf - . | tar -C "$d" -xf -
  git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" -c user.name=test -c user.email=test@example.com commit -qm test
  echo "$d"
}

kind_field() { # <rendered-file> <kind> <yq-path>
  K=$2 yq -r "select(.kind == strenv(K)) | $3" "$1"
}

joins_for() { # <repo> <cluster> → sorted app names
  local j
  for j in "$1"/apps/*/clusters/"$2"/kustomization.yaml; do
    [[ -f $j ]] && basename "$(dirname "$(dirname "$(dirname "$j")")")"
  done | LC_ALL=C sort | paste -sd' ' -
}

OUT=$(mktemp -d)
cleanup_add "$OUT"

t T1 "generate is idempotent"
expect_ok "generate" "$S/generate"
expect_ok "generate --check" "$S/generate" --check

t T2 "lint"
expect_ok "lint" "$S/lint"

t T3 "join counts"
expect_eq "prod-workload-east-1 joins" "cert-manager logging monitoring" "$(joins_for "$ROOT" prod-workload-east-1)"
expect_eq "prod-workload-east-2 joins" "cert-manager gpu-operator logging monitoring" "$(joins_for "$ROOT" prod-workload-east-2)"
expect_eq "prod-hub-east-1 joins" "cert-manager monitoring" "$(joins_for "$ROOT" prod-hub-east-1)"
expect_eq "qa-workload-east-1 joins" "cert-manager logging monitoring" "$(joins_for "$ROOT" qa-workload-east-1)"
[[ ! -e $ROOT/apps/logging/clusters/prod-hub-east-1 ]] || fail "apps/logging/clusters/prod-hub-east-1 exists"
[[ ! -e $ROOT/apps/gpu-operator/clusters/prod-workload-east-1 ]] || fail "apps/gpu-operator/clusters/prod-workload-east-1 exists"

t T4 "render logging prod-workload-east-2"
r=$OUT/logging-east2.yaml
expect_ok "render" "$S/render" logging prod-workload-east-2
cp "$LOG" "$r"
expect_eq "route host" "logging.apps.east2.example.com" "$(kind_field "$r" Route .spec.host)"
expect_eq "image" "quay.io/example/logging:2.4.0-rc1" "$(kind_field "$r" Deployment '.spec.template.spec.containers[0].image')"
expect_eq "replicas" "3" "$(kind_field "$r" Deployment .spec.replicas)"
expect_eq "CLUSTER_NAME" "prod-workload-east-2" "$(kind_field "$r" Deployment '.spec.template.spec.containers[0].env[] | select(.name == "CLUSTER_NAME") | .value')"
expect_eq "cluster-facts emitted" "" "$(yq -r 'select(.metadata.name == "cluster-facts") | .kind' "$r")"

t T5 "render logging prod-workload-east-1"
r=$OUT/logging-east1.yaml
expect_ok "render" "$S/render" logging prod-workload-east-1
cp "$LOG" "$r"
expect_eq "route host" "logging.apps.east1.example.com" "$(kind_field "$r" Route .spec.host)"
expect_eq "image" "quay.io/example/logging:2.3.0" "$(kind_field "$r" Deployment '.spec.template.spec.containers[0].image')"
expect_eq "replicas" "3" "$(kind_field "$r" Deployment .spec.replicas)"

t T6 "render monitoring on both clusters"
for n in 1 2; do
  r=$OUT/monitoring-east$n.yaml
  expect_ok "render prod-workload-east-$n" "$S/render" monitoring prod-workload-east-$n
  cp "$LOG" "$r"
  expect_eq "prod-workload-east-$n host" "grafana.apps.east$n.example.com" "$(kind_field "$r" Route .spec.host)"
done
expect_eq "prod-workload-east-1 replicas" "2" "$(kind_field "$OUT/monitoring-east1.yaml" Deployment .spec.replicas)"
expect_eq "prod-workload-east-2 replicas" "1" "$(kind_field "$OUT/monitoring-east2.yaml" Deployment .spec.replicas)"

t T7 "argocd.json values"
aj() { yq -p=json -o=yaml -r "$3" "$ROOT/apps/$1/clusters/$2/argocd.json"; }
expect_eq "logging@east-1 automated.enabled" "true" "$(aj logging prod-workload-east-1 .sync.automated.enabled)"
expect_eq "logging@east-1 wave" "10" "$(aj logging prod-workload-east-1 .sync.wave)"
expect_eq "logging@east-1 wave type" "!!str" "$(aj logging prod-workload-east-1 '.sync.wave | tag')"
expect_eq "logging@east-2 automated.enabled" "true" "$(aj logging prod-workload-east-2 .sync.automated.enabled)"
expect_eq "monitoring@east-1 automated.enabled" "false" "$(aj monitoring prod-workload-east-1 .sync.automated.enabled)"
expect_eq "monitoring@east-2 automated.enabled" "false" "$(aj monitoring prod-workload-east-2 .sync.automated.enabled)"
expect_eq "cert-manager wave" "0" "$(aj cert-manager prod-workload-east-1 .sync.wave)"
for c in prod-workload-east-1 prod-workload-east-2; do
  for f in "$ROOT"/apps/*/clusters/$c/argocd.json; do
    app=$(basename "$(dirname "$(dirname "$(dirname "$f")")")")
    expect_eq "$app@$c prune/selfHeal default" "true true" "$(aj "$app" $c '[.sync.automated.prune, .sync.automated.selfHeal] | join(" ")')"
  done
done
d=$(copy_repo)
yq -i '.sync.automated.prune = false' "$d/apps/logging/argocd.yaml"
expect_ok "generate with prune override" "$d/scripts/generate" prod-workload-east-1
expect_eq "prune override keeps other defaults" '{"enabled":true,"prune":false,"selfHeal":true}' \
  "$(yq -p=json -o=json -I=0 .sync.automated "$d/apps/logging/clusters/prod-workload-east-1/argocd.json")"
yq -i '.sync.automated.enabled = "no"' "$d/apps/logging/argocd.yaml"
expect_fail "non-boolean enabled" "$d/scripts/generate" prod-workload-east-1
expect_eq "logging@east-2 full" \
  '{"app":"logging","cluster":"prod-workload-east-2","profiles":["prod-workload","prod-workload-east-2"],"sync":{"automated":{"enabled":true,"prune":true,"selfHeal":true},"wave":"10"}}' \
  "$(cat "$ROOT/apps/logging/clusters/prod-workload-east-2/argocd.json")"

t T8 "removing an app's last matching profile removes its joins"
d=$(copy_repo)
rm -r "$d/apps/logging/profiles/qa-workload"
expect_ok "generate" "$d/scripts/generate"
[[ ! -e $d/apps/logging/clusters/qa-workload-east-1 ]] || fail "apps/logging/clusters/qa-workload-east-1 not deleted"
[[ -e $d/apps/logging/clusters/prod-workload-east-1 ]] || fail "apps/logging/clusters/prod-workload-east-1 deleted"
expect_ok "generate --check" "$d/scripts/generate" --check

t T9 "drift detection"
d=$(copy_repo)
echo 'patches: []' >>"$d/apps/logging/clusters/prod-workload-east-1/kustomization.yaml"
expect_fail "generate --check" "$d/scripts/generate" --check
expect_fail "lint" "$d/scripts/lint"
grep -q 'patches' "$d/apps/logging/clusters/prod-workload-east-1/kustomization.yaml" || fail "--check modified the tree"

t T10 "bad profiles"
d=$(copy_repo)
mkdir -p "$d/apps/logging/profiles/workload" && touch "$d/apps/logging/profiles/workload/README"
expect_fail "profile without kustomization.yaml" "$d/scripts/generate"
grep -q "logging.*apps/logging/profiles/workload/" "$LOG" || fail "error doesn't name app and path: $(cat "$LOG")"
expect_fail "lint: profile without kustomization.yaml" "$d/scripts/lint"
d=$(copy_repo)
echo 'sync: {wave: "5"}' >"$d/apps/logging/profiles/prod-workload/argocd.yaml"
expect_fail "lint: argocd.yaml in a profile" "$d/scripts/lint"
grep -q "Argo CD settings are only set in apps/logging/argocd.yaml" "$LOG" || fail "lint doesn't explain: $(cat "$LOG")"
d=$(copy_repo)
mkdir -p "$d/apps/logging/profiles/qa-hub" && cp "$d/apps/cert-manager/profiles/qa/kustomization.yaml" "$d/apps/logging/profiles/qa-hub/"
expect_ok "lint: profile matching no cluster" "$d/scripts/lint"
grep -q "apps/logging/profiles/qa-hub: matches no cluster" "$LOG" || fail "lint doesn't warn: $(cat "$LOG")"

t T11 "new-cluster"
d=$(copy_repo)
expect_ok "new-cluster" "$d/scripts/new-cluster" prod-workload-west-1 --from prod-workload-east-1 --domain apps.west1.example.com
expect_eq "facts name" "prod-workload-west-1" "$(yq -r .data.name "$d/clusters/prod-workload-west-1/facts/facts.yaml")"
expect_eq "facts domain" "apps.west1.example.com" "$(yq -r .data.domain "$d/clusters/prod-workload-west-1/facts/facts.yaml")"
expect_eq "clusterType/environment copied" "workload prod" \
  "$(yq -r '[.data.clusterType, .data.environment] | join(" ")' "$d/clusters/prod-workload-west-1/facts/facts.yaml")"
expect_eq "joins" "cert-manager logging monitoring" "$(joins_for "$d" prod-workload-west-1)"
expect_eq "no pins copied" "" "$(env_keys "$d/clusters/prod-workload-west-1/argocd/revisions.env")"
expect_ok "render" "$d/scripts/render" logging prod-workload-west-1
expect_eq "route host" "logging.apps.west1.example.com" "$(kind_field "$LOG" Route .spec.host)"
expect_ok "lint" "$d/scripts/lint"
expect_ok "generate --check" "$d/scripts/generate" --check
expect_fail "existing name" "$d/scripts/new-cluster" prod-workload-west-1 --from prod-workload-east-1
expect_fail "bad name" "$d/scripts/new-cluster" Prod_West --from prod-workload-east-1

t T12 "render cert-manager prod-workload-east-1"
expect_ok "render" "$S/render" cert-manager prod-workload-east-1
expect_eq "issuer" "letsencrypt-prod" "$(kind_field "$LOG" ConfigMap .data.issuer)"

t T13 "diff on a clean tree"
d=$(copy_repo)
expect_ok "diff HEAD" "$d/scripts/diff" HEAD
[[ -f $d/rendered/manifests.diff && ! -s $d/rendered/manifests.diff ]] || fail "rendered/manifests.diff missing or non-empty"
[[ $(git -C "$d" worktree list | wc -l) -eq 1 ]] || fail "worktree not cleaned up"

t T14 "bootstrap-root"
expect_ok "bootstrap-root" "$S/bootstrap-root" prod-workload-east-2
expect_eq "kind" "Application" "$(yq -r .kind "$LOG")"
expect_eq "path" "clusters/prod-workload-east-2/argocd" "$(yq -r .spec.source.path "$LOG")"
expect_eq "tracks main" "main" "$(yq -r .spec.source.targetRevision "$LOG")"
expect_fail "unknown cluster" "$S/bootstrap-root" nope

t T15 "cluster ApplicationSets"
a=$OUT/appsets-east1.yaml
expect_ok "kustomize build clusters/prod-workload-east-1/argocd" kustomize build "$ROOT/clusters/prod-workload-east-1/argocd"
expect_eq "kinds" "ApplicationSet" "$(yq -r .kind "$LOG" | grep -v '^---$' | sort -u | paste -sd' ' -)"
yq 'select(.metadata.name == "cluster-config")' "$LOG" >"$a"
expect_eq "generator revision (default)" "main" "$(yq -r '.spec.generators[0].git.revision' "$a")"
expect_eq "targetRevision (default)" "main" "$(yq -r .spec.template.spec.source.targetRevision "$a")"
expect_eq "generator path" "apps/*/clusters/prod-workload-east-1/argocd.json" "$(yq -r '.spec.generators[0].git.files[0].path' "$a")"
expect_eq "destination" "https://kubernetes.default.svc" "$(yq -r .spec.template.spec.destination.server "$a")"
expect_ok "kustomize build clusters/prod-workload-east-2/argocd" kustomize build "$ROOT/clusters/prod-workload-east-2/argocd"
cp "$LOG" "$OUT/appsets-east2.yaml"
expect_eq "prod-workload-east-2 ApplicationSets" "cluster-config tenant-config" \
  "$(yq -r 'select(.kind == "ApplicationSet") | .metadata.name' "$OUT/appsets-east2.yaml" | grep -v '^---$' | sort | paste -sd' ' -)"
expect_ok "kustomize build clusters/prod-hub-east-1/argocd" kustomize build "$ROOT/clusters/prod-hub-east-1/argocd"
expect_eq "hub ApplicationSets" "cluster-config" \
  "$(yq -r 'select(.kind == "ApplicationSet") | .metadata.name' "$LOG" | grep -v -e '^---$' -e '^$' | paste -sd' ' -)"
expect_eq "tenant generator path" "tenants/*/clusters/prod-workload-east-2/argocd.json" \
  "$(yq -r 'select(.metadata.name == "tenant-config") | .spec.generators[0].git.files[0].path' "$OUT/appsets-east2.yaml")"
expect_eq "tenant revision (default)" "main main" \
  "$(yq -r 'select(.metadata.name == "tenant-config") | [.spec.generators[0].git.revision, .spec.template.spec.source.targetRevision] | join(" ")' "$OUT/appsets-east2.yaml" | grep -v -e '^---$' -e '^$')"
# Render templatePatch for a params file as the Go template would: dig returns the value if the
# key exists (even false), else the default true.
render_patch() { # <params-json>
  local patch k v
  patch=$(yq -r .spec.templatePatch "$a")
  for k in enabled prune selfHeal; do
    if [[ $(K=$k yq -p=json -o=yaml '.sync.automated // {} | has(strenv(K))' "$1") == true ]]; then
      v=$(yq -p=json -o=yaml ".sync.automated.$k" "$1")
    else
      v=true
    fi
    patch=${patch//"{{ dig \"sync\" \"automated\" \"$k\" true . }}"/$v}
  done
  echo "$patch" | yq -o=json -I=0 .spec.syncPolicy.automated
}
expect_eq "templatePatch syncPolicy" '{"enabled":false,"prune":true,"selfHeal":true}' \
  "$(render_patch "$ROOT/apps/monitoring/clusters/prod-workload-east-2/argocd.json")"
echo '{"sync":{"automated":{"prune":false}}}' >"$OUT/partial.json"
expect_eq "templatePatch defaults" '{"enabled":true,"prune":false,"selfHeal":true}' "$(render_patch "$OUT/partial.json")"

t T16 "revision pins"
d=$(copy_repo)
sha=$(git -C "$d" rev-parse HEAD)
expect_ok "promote prod-workload-east-1" "$d/scripts/promote" prod-workload-east-1 HEAD
expect_eq "revisions.env" "$sha" "$(env_get "$d/clusters/prod-workload-east-1/argocd/revisions.env" cluster-config)"
expect_ok "build prod-workload-east-1" kustomize build "$d/clusters/prod-workload-east-1/argocd"
expect_eq "pinned generator revision" "$sha" "$(yq -r 'select(.metadata.name == "cluster-config") | .spec.generators[0].git.revision' "$LOG")"
expect_eq "pinned targetRevision" "$sha" "$(yq -r 'select(.metadata.name == "cluster-config") | .spec.template.spec.source.targetRevision' "$LOG")"
expect_ok "build prod-workload-east-2" kustomize build "$d/clusters/prod-workload-east-2/argocd"
expect_eq "other cluster unchanged" "main" "$(yq -r 'select(.metadata.name == "cluster-config") | .spec.generators[0].git.revision' "$LOG")"
expect_ok "promote tenant-config on prod-workload-east-2" "$d/scripts/promote" prod-workload-east-2 HEAD --appset tenant-config
expect_ok "build prod-workload-east-2" kustomize build "$d/clusters/prod-workload-east-2/argocd"
expect_eq "tenant-config pinned" "$sha" "$(yq -r 'select(.metadata.name == "tenant-config") | .spec.template.spec.source.targetRevision' "$LOG")"
expect_eq "cluster-config still main" "main" "$(yq -r 'select(.metadata.name == "cluster-config") | .spec.template.spec.source.targetRevision' "$LOG")"
expect_ok "whatruns prod-workload-east-2" "$d/scripts/whatruns" prod-workload-east-2
grep -q "tenants (tenant-config @ ${sha:0:12}): team-a, team-b" "$LOG" || fail "whatruns doesn't list pinned tenants: $(tail -n1 "$LOG")"
expect_fail "promote an appset outside the base" "$d/scripts/promote" prod-hub-east-1 HEAD --appset tenant-config
expect_ok "promote again" "$d/scripts/promote" prod-workload-east-1 HEAD
expect_eq "no duplicate key" "cluster-config" "$(env_keys "$d/clusters/prod-workload-east-1/argocd/revisions.env")"
expect_ok "lint" "$d/scripts/lint"
expect_ok "whatruns" "$d/scripts/whatruns" prod-workload-east-1
grep -q "cluster-config @ ${sha:0:12}" "$LOG" || fail "whatruns doesn't show the pin: $(head -n1 "$LOG")"
expect_fail "unknown appset" "$d/scripts/promote" prod-workload-east-1 HEAD --appset nope
expect_fail "unknown ref" "$d/scripts/promote" prod-workload-east-1 nope
expect_ok "new-cluster" "$d/scripts/new-cluster" prod-workload-west-1 --from prod-workload-east-1
expect_fail "pin a commit without the cluster" "$d/scripts/promote" prod-workload-west-1 HEAD
env=$d/clusters/prod-workload-east-2/argocd/revisions.env
cp "$env" "$OUT/env.bak"
for bad in "cluster-config=abc123" "cluster-config=$sha " "nope=$sha" "cluster-config=$(printf 'f%.0s' {1..40})"; do
  { cat "$OUT/env.bak"; echo "$bad"; } >"$env"
  expect_fail "lint rejects '$bad'" "$d/scripts/lint"
done
cp "$OUT/env.bak" "$env"
echo "tenant-config=$sha" >>"$d/clusters/prod-hub-east-1/argocd/revisions.env"
expect_fail "lint rejects a pin outside the base" "$d/scripts/lint"

t T17 "tenants"
expect_ok "render team-a on prod-workload-east-2" kustomize build "$ROOT/tenants/team-a/clusters/prod-workload-east-2"
expect_eq "team-a quota override" "16" "$(kind_field "$LOG" ResourceQuota '.spec.hard["requests.cpu"]')"
expect_ok "render team-b on prod-workload-east-2" kustomize build "$ROOT/tenants/team-b/clusters/prod-workload-east-2"
expect_eq "team-b quota" "4" "$(kind_field "$LOG" ResourceQuota '.spec.hard["requests.cpu"]')"
expect_ok "render-all" "$S/render-all" "$OUT/rendered"
[[ -s $OUT/rendered/prod-workload-east-2/tenant-team-a.yaml && -s $OUT/rendered/prod-workload-east-2/tenant-team-a.argocd.json ]] \
  || fail "render-all didn't render tenants"
d=$(copy_repo)
echo '{"cluster":"prod-workload-east-2","sync":{"wave":30},"tenant":"team-b"}' >"$d/tenants/team-b/clusters/prod-workload-east-2/argocd.json"
expect_fail "lint rejects a non-string wave" "$d/scripts/lint"
d=$(copy_repo)
mkdir -p "$d/tenants/team-b/clusters/nope" && echo '{}' >"$d/tenants/team-b/clusters/nope/argocd.json"
expect_fail "lint rejects an unknown cluster" "$d/scripts/lint"

t T18 "profile selection"
aj_in() { yq -p=json -o=yaml -r "$4" "$1/apps/$2/clusters/$3/argocd.json"; }
expect_eq "qa env-type profile" "qa-workload" "$(aj logging qa-workload-east-1 '.profiles | join(",")')"
expect_eq "prod profile on hub" "prod" "$(aj monitoring prod-hub-east-1 '.profiles | join(",")')"
expect_eq "prod profile replicas" "2" "$("$S/render" monitoring prod-hub-east-1 | kind_field /dev/stdin Deployment .spec.replicas)"
expect_eq "join component order" \
  "../../../../clusters/prod-workload-east-2/facts ../../profiles/prod ../../profiles/per-cluster ../../profiles/prod-workload-east-2" \
  "$(yq -r '.components | join(" ")' "$ROOT/apps/monitoring/clusters/prod-workload-east-2/kustomization.yaml")"
expect_eq "cluster-name profile selects" "prod-workload-east-2" "$(aj gpu-operator prod-workload-east-2 '.profiles | join(",")')"
empty_profile() { # <repo> <app> <profile>
  mkdir -p "$1/apps/$2/profiles/$3"
  printf 'apiVersion: kustomize.config.k8s.io/v1alpha1\nkind: Component\nresources: []\n' >"$1/apps/$2/profiles/$3/kustomization.yaml"
}
d=$(copy_repo)
for p in workload prod; do empty_profile "$d" logging "$p"; done
expect_ok "generate" "$d/scripts/generate"
expect_eq "all matching profiles, env/type/env-type/per-cluster/cluster order" \
  "../../../../clusters/prod-workload-east-2/facts ../../profiles/prod ../../profiles/workload ../../profiles/prod-workload ../../profiles/per-cluster ../../profiles/prod-workload-east-2" \
  "$(yq -r '.components | join(" ")' "$d/apps/logging/clusters/prod-workload-east-2/kustomization.yaml")"
expect_eq "argocd.json profiles" "prod,workload,prod-workload,prod-workload-east-2" \
  "$(aj_in "$d" logging prod-workload-east-2 '.profiles | join(",")')"
for p in hub prod-hub prod-hub-east-1; do
  d=$(copy_repo)
  empty_profile "$d" logging "$p"
  expect_ok "generate with logging/$p" "$d/scripts/generate"
  expect_eq "logging/$p selects prod-hub-east-1" "cert-manager logging monitoring" "$(joins_for "$d" prod-hub-east-1)"
  expect_ok "render logging on prod-hub-east-1" "$d/scripts/render" logging prod-hub-east-1
  expect_eq "per-cluster applied" "logging.apps.hub1.example.com" "$(kind_field "$LOG" Route .spec.host)"
  expect_eq "CLUSTER_NAME" "prod-hub-east-1" "$(kind_field "$LOG" Deployment '.spec.template.spec.containers[0].env[] | select(.name == "CLUSTER_NAME") | .value')"
done
d=$(copy_repo)
mkdir -p "$d/apps/gpu-operator/components/hub"
printf 'apiVersion: kustomize.config.k8s.io/v1alpha1\nkind: Component\nresources: []\n' >"$d/apps/gpu-operator/components/hub/kustomization.yaml"
expect_ok "generate with an unused component" "$d/scripts/generate"
expect_eq "a component doesn't select" "cert-manager monitoring" "$(joins_for "$d" prod-hub-east-1)"
expect_ok "lint" "$d/scripts/lint"
grep -q "apps/gpu-operator/components/hub: not used by any profile" "$LOG" || fail "lint doesn't warn: $(cat "$LOG")"
d=$(copy_repo)
mv "$d/apps/logging/profiles/per-cluster" "$d/apps/logging/per-cluster"
expect_fail "lint: unknown dir in an app" "$d/scripts/lint"
grep -q "apps/logging/per-cluster: not allowed" "$LOG" || fail "lint doesn't explain: $(cat "$LOG")"
d=$(copy_repo)
rm -r "$d/apps/gpu-operator/profiles/prod-workload-east-2"
expect_ok "generate without gpu-operator's only profile" "$d/scripts/generate"
expect_eq "gpu-operator runs nowhere" "" "$(ls "$d/apps/gpu-operator/clusters" 2>/dev/null)"
d=$(copy_repo)
yq -i '.data.clusterType = "workload"' "$d/clusters/prod-hub-east-1/facts/facts.yaml"
expect_fail "lint: base must match clusterType" "$d/scripts/lint"
grep -q "base must be ../../../bootstrap/bases/workload" "$LOG" || fail "lint doesn't explain the base mismatch"
d=$(copy_repo)
yq -i 'del(.data.environment)' "$d/clusters/qa-workload-east-1/facts/facts.yaml"
expect_fail "generate: no environment" "$d/scripts/generate"
grep -q "data.environment is not set" "$LOG" || fail "generate doesn't explain: $(cat "$LOG")"
expect_fail "lint: no environment" "$d/scripts/lint"
d=$(copy_repo)
echo 'apps: {}' >"$d/clusters/prod-workload-east-1/apps.yaml"
expect_fail "lint: apps.yaml is rejected" "$d/scripts/lint"
d=$(copy_repo)
expect_ok "new-cluster --type hub" "$d/scripts/new-cluster" qa-hub-east-1 --from qa-workload-east-1 --type hub
expect_eq "hub base" "1" "$(grep -cxF -- '- ../../../bootstrap/bases/hub' "$d/clusters/qa-hub-east-1/argocd/kustomization.yaml")"
expect_eq "qa-hub-east-1 joins" "cert-manager monitoring" "$(joins_for "$d" qa-hub-east-1)"
expect_eq "qa-hub-east-1 profiles" "qa" "$(aj_in "$d" monitoring qa-hub-east-1 '.profiles | join(",")')"
expect_ok "lint" "$d/scripts/lint"
expect_fail "new-cluster name not matching type/environment" "$d/scripts/new-cluster" prod-workload-east-9 --from qa-workload-east-1
[[ ! -e $d/clusters/prod-workload-east-9 ]] || fail "new-cluster made a misnamed cluster"
d2=$(copy_repo)
yq -i '.data.environment = "qa"' "$d2/clusters/prod-workload-east-1/facts/facts.yaml"
expect_fail "lint: name must match environment/clusterType" "$d2/scripts/lint"
grep -q "cluster name must be <environment>-<clusterType>-<region>-<id>" "$LOG" || fail "lint doesn't explain the naming rule"
expect_fail "new-cluster unknown type" "$d/scripts/new-cluster" qa-nope-east-1 --from qa-workload-east-1 --type nope
[[ ! -e $d/clusters/qa-nope-east-1 ]] || fail "new-cluster left a half-made cluster"

echo
if [[ $failures -gt 0 ]]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
