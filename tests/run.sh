#!/usr/bin/env bash
# Acceptance tests T1–T15. Mutating tests run in temp copies of the repo.
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
expect_eq "prod-east-1 joins" "cert-manager logging monitoring" "$(joins_for "$ROOT" prod-east-1)"
expect_eq "prod-east-2 joins" "cert-manager gpu-operator logging monitoring" "$(joins_for "$ROOT" prod-east-2)"
[[ ! -e $ROOT/apps/gpu-operator/clusters/prod-east-1 ]] || fail "apps/gpu-operator/clusters/prod-east-1 exists"

t T4 "render logging prod-east-2"
r=$OUT/logging-east2.yaml
expect_ok "render" "$S/render" logging prod-east-2
cp "$LOG" "$r"
expect_eq "route host" "logging.apps.east2.example.com" "$(kind_field "$r" Route .spec.host)"
expect_eq "image" "quay.io/example/logging:2.4.0-rc1" "$(kind_field "$r" Deployment '.spec.template.spec.containers[0].image')"
expect_eq "replicas" "3" "$(kind_field "$r" Deployment .spec.replicas)"
expect_eq "CLUSTER_NAME" "prod-east-2" "$(kind_field "$r" Deployment '.spec.template.spec.containers[0].env[] | select(.name == "CLUSTER_NAME") | .value')"
expect_eq "cluster-facts emitted" "" "$(yq -r 'select(.metadata.name == "cluster-facts") | .kind' "$r")"

t T5 "render logging prod-east-1"
r=$OUT/logging-east1.yaml
expect_ok "render" "$S/render" logging prod-east-1
cp "$LOG" "$r"
expect_eq "route host" "logging.apps.east1.example.com" "$(kind_field "$r" Route .spec.host)"
expect_eq "image" "quay.io/example/logging:2.3.0" "$(kind_field "$r" Deployment '.spec.template.spec.containers[0].image')"
expect_eq "replicas" "3" "$(kind_field "$r" Deployment .spec.replicas)"

t T6 "render monitoring on both clusters"
for n in 1 2; do
  r=$OUT/monitoring-east$n.yaml
  expect_ok "render prod-east-$n" "$S/render" monitoring prod-east-$n
  cp "$LOG" "$r"
  expect_eq "prod-east-$n host" "grafana.apps.east$n.example.com" "$(kind_field "$r" Route .spec.host)"
done
expect_eq "prod-east-1 replicas" "2" "$(kind_field "$OUT/monitoring-east1.yaml" Deployment .spec.replicas)"
expect_eq "prod-east-2 replicas" "1" "$(kind_field "$OUT/monitoring-east2.yaml" Deployment .spec.replicas)"

t T7 "argocd.json values"
aj() { yq -p=json -o=yaml -r "$3" "$ROOT/apps/$1/clusters/$2/argocd.json"; }
expect_eq "logging@east-1 auto" "true" "$(aj logging prod-east-1 .sync.auto)"
expect_eq "logging@east-1 wave" "10" "$(aj logging prod-east-1 .sync.wave)"
expect_eq "logging@east-1 wave type" "!!str" "$(aj logging prod-east-1 '.sync.wave | tag')"
expect_eq "logging@east-2 auto" "false" "$(aj logging prod-east-2 .sync.auto)"
expect_eq "monitoring@east-1 auto" "false" "$(aj monitoring prod-east-1 .sync.auto)"
expect_eq "monitoring@east-2 auto" "true" "$(aj monitoring prod-east-2 .sync.auto)"
expect_eq "cert-manager wave" "0" "$(aj cert-manager prod-east-1 .sync.wave)"
expect_eq "logging@east-2 full" \
  '{"app":"logging","cluster":"prod-east-2","mixins":["canary"],"overlay":"prod","sync":{"auto":false,"wave":"10"}}' \
  "$(cat "$ROOT/apps/logging/clusters/prod-east-2/argocd.json")"

t T8 "null removes an app"
d=$(copy_repo)
printf 'apps:\n  monitoring: null\n' >>"$d/clusters/prod-east-1/apps.yaml"
expect_ok "generate" "$d/scripts/generate"
[[ ! -e $d/apps/monitoring/clusters/prod-east-1 ]] || fail "apps/monitoring/clusters/prod-east-1 not deleted"
[[ -e $d/apps/monitoring/clusters/prod-east-2 ]] || fail "apps/monitoring/clusters/prod-east-2 deleted"
expect_ok "generate --check" "$d/scripts/generate" --check

t T9 "drift detection"
d=$(copy_repo)
echo 'patches: []' >>"$d/apps/logging/clusters/prod-east-1/kustomization.yaml"
expect_fail "generate --check" "$d/scripts/generate" --check
expect_fail "lint" "$d/scripts/lint"
grep -q 'patches' "$d/apps/logging/clusters/prod-east-1/kustomization.yaml" || fail "--check modified the tree"

t T10 "bad references"
d=$(copy_repo)
yq -i '.apps.logging.overlay = "nope"' "$d/clusters/prod-east-2/apps.yaml"
expect_fail "unknown overlay" "$d/scripts/generate"
grep -q "logging.*apps/logging/overlays/nope" "$LOG" || fail "error doesn't name app and path: $(cat "$LOG")"
d=$(copy_repo)
yq -i '.apps.logging.mixins = ["nope"]' "$d/clusters/prod-east-2/apps.yaml"
expect_fail "unknown mixin" "$d/scripts/generate"
grep -q "logging.*apps/logging/mixins/nope" "$LOG" || fail "error doesn't name app and path: $(cat "$LOG")"

t T11 "new-cluster"
d=$(copy_repo)
expect_ok "new-cluster" "$d/scripts/new-cluster" prod-west-1 --from prod-east-1 --domain apps.west1.example.com
expect_eq "facts name" "prod-west-1" "$(yq -r .data.name "$d/clusters/prod-west-1/facts.yaml")"
expect_eq "facts domain" "apps.west1.example.com" "$(yq -r .data.domain "$d/clusters/prod-west-1/facts.yaml")"
expect_eq "apps.yaml" "extends: prod" "$(cat "$d/clusters/prod-west-1/apps.yaml")"
expect_eq "joins" "cert-manager logging monitoring" "$(joins_for "$d" prod-west-1)"
expect_ok "render" "$d/scripts/render" logging prod-west-1
expect_eq "route host" "logging.apps.west1.example.com" "$(kind_field "$LOG" Route .spec.host)"
expect_ok "lint" "$d/scripts/lint"
expect_ok "generate --check" "$d/scripts/generate" --check
expect_fail "existing name" "$d/scripts/new-cluster" prod-west-1 --from prod-east-1
expect_fail "bad name" "$d/scripts/new-cluster" Prod_West --from prod-east-1

t T12 "render cert-manager prod-east-1"
expect_ok "render" "$S/render" cert-manager prod-east-1
expect_eq "issuer" "letsencrypt-prod" "$(kind_field "$LOG" ConfigMap .data.issuer)"

t T13 "diff on a clean tree"
d=$(copy_repo)
expect_ok "diff HEAD" "$d/scripts/diff" HEAD
[[ -f $d/rendered/manifests.diff && ! -s $d/rendered/manifests.diff ]] || fail "rendered/manifests.diff missing or non-empty"
[[ $(git -C "$d" worktree list | wc -l) -eq 1 ]] || fail "worktree not cleaned up"

t T14 "bootstrap-secret"
expect_ok "bootstrap-secret" "$S/bootstrap-secret" prod-east-2 --wave 0
expect_eq "name" "prod-east-2" "$(yq -r .stringData.name "$LOG")"
expect_eq "wave label" '"0"' "$(yq -o=json '.metadata.labels.wave' "$LOG")"
expect_eq "local label" '"true"' "$(yq -o=json '.metadata.labels["gitops.example.com/local"]' "$LOG")"
expect_fail "unknown cluster" "$S/bootstrap-secret" nope

t T15 "applicationset"
a=$ROOT/bootstrap/applicationset.yaml
expect_ok "parses" yq -e . "$a"
expect_eq "cluster selector" "true" \
  "$(yq -r '.spec.generators[0].matrix.generators[0].clusters.selector.matchLabels["gitops.example.com/local"]' "$a")"
expect_eq "destination" "https://kubernetes.default.svc" "$(yq -r .spec.template.spec.destination.server "$a")"

echo
if [[ $failures -gt 0 ]]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
