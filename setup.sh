#!/usr/bin/env bash
# One-command setup: kind cluster "demo" + ingress-nginx + image + Helm release "demo".
# Safe to run repeatedly.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=demo
CTX="kind-${CLUSTER}"
NAMESPACE=demo
RELEASE=demo
IMAGE=demo-app:local
INGRESS_NGINX_VERSION=controller-v1.12.1
INGRESS_NGINX_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

log() { echo "==> $*"; }
k() { kubectl --context "$CTX" "$@"; }

for bin in docker kind kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing required tool: $bin" >&2; exit 1; }
done

log "kind cluster '${CLUSTER}'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "cluster exists, reusing it"
else
  kind create cluster --name "$CLUSTER" --config - <<KINDCFG
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
KINDCFG
fi

log "labelling node for ingress-nginx (needed when the cluster was created without the label)"
k label node --all ingress-ready=true --overwrite >/dev/null

log "installing ingress-nginx ${INGRESS_NGINX_VERSION}"
k apply -f "$INGRESS_NGINX_URL"
k -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=240s

log "building image ${IMAGE}"
docker build -t "$IMAGE" service

log "loading image into kind"
kind load docker-image "$IMAGE" --name "$CLUSTER"

log "installing Helm release '${RELEASE}' into namespace '${NAMESPACE}'"
for attempt in 1 2 3 4 5; do
  if helm --kube-context "$CTX" upgrade --install "$RELEASE" ./chart \
       --namespace "$NAMESPACE" --create-namespace --wait --timeout 180s; then
    break
  fi
  if [ "$attempt" = 5 ]; then
    echo "helm install failed after 5 attempts" >&2
    exit 1
  fi
  echo "helm attempt ${attempt} failed (ingress webhook may not be ready yet); retrying in 10s"
  sleep 10
done

log "done"
k -n "$NAMESPACE" get pods,svc,ingress
