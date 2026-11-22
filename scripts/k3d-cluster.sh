#!/usr/bin/env bash
# Local k3s (k3d) cluster for the microservices + ArgoCD.
#   ./scripts/k3d-cluster.sh up      create cluster, install ArgoCD, wait until it is ready, apply the Application
#   ./scripts/k3d-cluster.sh argocd  (re)apply argocd/application.yaml, after checking ArgoCD is ready
#   ./scripts/k3d-cluster.sh down    delete the cluster
set -euo pipefail
cd "$(dirname "$0")/.."
CLUSTER=${CLUSTER:-microservices}
HTTP_PORT=${HTTP_PORT:-8080}          # host port -> order-service (3003)
ARGOCD_VERSION=${ARGOCD_VERSION:-v3.6.1}
REGISTRY=ghcr.io/reynaldiekoz98
SERVICES_DIR=${SERVICES_DIR:-..}       # where the service repos are checked out (optional)
KUBECONFIG_FILE=${KUBECONFIG_FILE:-$PWD/.kubeconfig}   # dedicated file; your ~/.kube/config is untouched

# Write the cluster's kubeconfig with `k3d kubeconfig get` and point kubectl at it.
set_kubeconfig() {
  k3d kubeconfig get "$CLUSTER" > "$KUBECONFIG_FILE"
  chmod 600 "$KUBECONFIG_FILE"
  export KUBECONFIG="$KUBECONFIG_FILE"
}
# For subcommands run after `up`: reuse the file if it exists.
[ -f "$KUBECONFIG_FILE" ] && export KUBECONFIG="$KUBECONFIG_FILE"

# Checker: block until ArgoCD can accept an Application (CRD registered + every component ready).
wait_argocd_ready() {
  echo "Waiting for ArgoCD to be ready..."
  kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s
  kubectl -n argocd rollout status \
    deploy/argocd-server deploy/argocd-repo-server deploy/argocd-applicationset-controller \
    statefulset/argocd-application-controller --timeout=600s
  # the API server must really answer, not just have a Running pod
  local i
  for i in $(seq 1 30); do
    kubectl -n argocd get endpoints argocd-server -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q . && { echo "ArgoCD is ready."; return; }
    sleep 2
  done
  echo "ERROR: argocd-server has no ready endpoints" >&2; exit 1
}

apply_application() {
  wait_argocd_ready
  kubectl apply -f argocd/application.yaml
  echo "Watch: kubectl -n argocd get applications -w   then http://localhost:${HTTP_PORT}"
}

up() {
  if ! k3d cluster list -o json | grep -q "\"name\": *\"$CLUSTER\""; then
    k3d cluster create "$CLUSTER" --agents 2 --port "${HTTP_PORT}:3003@loadbalancer" --wait
  else
    k3d cluster start "$CLUSTER" >/dev/null 2>&1 || true
  fi
  set_kubeconfig
  echo "kubeconfig: $KUBECONFIG_FILE   (use it in your shell: export KUBECONFIG=$KUBECONFIG_FILE)"
  # Optional: if the service repos are next to this one, build + import images (same git-SHA tag as the
  # manifests) so no registry pull is needed. Otherwise the cluster pulls from GHCR.
  for s in user product order; do
    [ -d "$SERVICES_DIR/$s-service/.git" ] || { echo "skip local build of $s-service (not found in $SERVICES_DIR)"; continue; }
    tag=$(git -C "$SERVICES_DIR/$s-service" rev-parse --short=7 HEAD)
    docker build -q -t "$REGISTRY/$s-service:$tag" "$SERVICES_DIR/$s-service"
    k3d image import "$REGISTRY/$s-service:$tag" -c "$CLUSTER"
  done
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -n argocd --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
  apply_application
  echo "ArgoCD UI:  kubectl -n argocd port-forward svc/argocd-server 8081:443   (https://localhost:8081, user admin)"
  echo "Password:   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}

case "${1:-}" in
  up) up ;;
  argocd) apply_application ;;
  down) k3d cluster delete "$CLUSTER"; rm -f "$KUBECONFIG_FILE" ;;
  *) echo "usage: $0 up|argocd|down"; exit 1 ;;
esac
