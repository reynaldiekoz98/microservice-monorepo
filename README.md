# microservice-monorepo (GitOps)

Kubernetes manifests that ArgoCD watches and deploys to EKS. App source code lives in separate repos
(user-service, product-service, order-service); this repo holds only *how they run*.

```
apps/
  user-service/      deployment.yaml service.yaml
  product-service/
  order-service/     (LoadBalancer + env pointing at the other two services)
argocd/application.yaml   the single ArgoCD Application (watches apps/ recursively)
scripts/k3d-cluster.sh    local k3d cluster + ArgoCD (up | argocd | down)
```
`argocd/application.yaml` deploys all three services from `apps/`. It is applied once with kubectl; ArgoCD itself only syncs `apps/`.

## Use
1. This repo is https://github.com/reynaldiekoz98/microservice-monorepo (if you fork or rename it, change `repoURL` in `argocd/application.yaml`).
2. Push images to `ghcr.io/reynaldiekoz98/<service>:<git-sha>` (make the packages public, or add an imagePullSecret).
3. Local k3d: `./scripts/k3d-cluster.sh up` creates the cluster, installs ArgoCD, waits until it is ready and applies the Application (`./scripts/k3d-cluster.sh argocd` re-applies it). `.kubeconfig` is written here and gitignored. Service repos next to this folder are built and imported locally; otherwise images come from GHCR.
4. Get the UI address: `kubectl -n demo get svc order-service`

Deploy a new version by changing the `image:` tag in `apps/<svc>/deployment.yaml` and committing; ArgoCD syncs it
(automated sync with prune and self-heal). Use a new tag each release (not `latest`) so ArgoCD sees the change.
Plain manifests, no Kustomize or Helm. Validate syntax with any YAML linter; a real check needs a cluster (`kubectl apply --dry-run=server`).
