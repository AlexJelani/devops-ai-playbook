#!/usr/bin/env bash
# Build the boutique images for amd64, push them to ECR and deploy to EKS.
#
# Usage: k8s/deploy.sh            # build, push and deploy
#        SKIP_BUILD=1 k8s/deploy.sh  # redeploy existing images only
#
# Env: AWS_REGION (us-east-1), KUBE_CONTEXT (eks-cluster), NAMESPACE (boutique),
#      IMAGE_TAG (current git commit)
set -euo pipefail

cd "$(dirname "$0")/.."

AWS_REGION="${AWS_REGION:-us-east-1}"
KUBE_CONTEXT="${KUBE_CONTEXT:-eks-cluster}"
NAMESPACE="${NAMESPACE:-boutique}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
SERVICES=(gateway auth product-service order-service orders user-service)
kc() { kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" "$@"; }

if [[ -z "${SKIP_BUILD:-}" ]]; then
  echo "==> Logging in to ECR ($ECR_REGISTRY)"
  aws ecr get-login-password --region "$AWS_REGION" |
    docker login --username AWS --password-stdin "$ECR_REGISTRY"

  # EKS nodes are amd64; build for that even on an arm64 Mac
  for svc in "${SERVICES[@]}"; do
    echo "==> Building and pushing $svc:$IMAGE_TAG"
    docker buildx build --platform linux/amd64 --push \
      -t "$ECR_REGISTRY/$svc:$IMAGE_TAG" "backend/services/$svc"
  done
  echo "==> Building and pushing frontend:$IMAGE_TAG"
  docker buildx build --platform linux/amd64 --push \
    -f frontend/Dockerfile.k8s -t "$ECR_REGISTRY/frontend:$IMAGE_TAG" frontend
fi

echo "==> Preparing namespace $NAMESPACE"
kubectl --context "$KUBE_CONTEXT" create namespace "$NAMESPACE" --dry-run=client -o yaml |
  kubectl --context "$KUBE_CONTEXT" apply -f -

# Generate the database password once; keep it on later runs
if ! kc get secret postgres-credentials >/dev/null 2>&1; then
  kc create secret generic postgres-credentials --from-literal=password="$(openssl rand -hex 16)"
fi

kc create configmap postgres-init --from-file=database/init --dry-run=client -o yaml | kc apply -f -

echo "==> Applying manifests"
for f in k8s/postgres.yaml k8s/backend.yaml k8s/frontend.yaml; do
  sed -e "s#ECR_REGISTRY#$ECR_REGISTRY#g" -e "s#IMAGE_TAG#$IMAGE_TAG#g" "$f" | kc apply -f -
done

echo "==> Waiting for rollouts"
for d in postgres "${SERVICES[@]}" frontend; do
  kc rollout status "deployment/$d" --timeout=300s
done

echo "==> Done. Open the app with:"
echo "    kubectl --context $KUBE_CONTEXT -n $NAMESPACE port-forward svc/frontend 8088:80"
echo "    then browse to http://localhost:8088"
